//
//  ParakeetDictation.swift
//  OpenClicky
//
//  Parakeet: an offline dictation engine for the Macs Apple's newer dictation model doesn't reach.
//  Before macOS 26 the offline engine is SFSpeechRecognizer, years behind (it typed "12245" for a
//  spoken sentence in Saathi, and restarts after every pause). NVIDIA's Parakeet TDT 0.6B v3 runs on
//  any Mac's CPU, Intel included, writes its own punctuation and capitals, and hears 25 European
//  languages. No Indian languages: those stay with Apple's recogniser or Sarvam.
//
//  The engine is the sherpa-onnx library that already ships for Kokoro; only the model (465 MB)
//  is downloaded. It downloads on its own once the welcome tour is done and takes over from
//  Apple's recogniser on every Mac (macOS 26's included: a tester on 26 only got it after finding
//  it in Settings, 2026-10-15), unless the person already moved to another engine.
//
//  The loaded model lives in a helper process that starts the moment the dictation key goes down
//  (it loads while the person speaks) and ends after three minutes without a take, or at once
//  under memory pressure.
//

import Combine
import Foundation

@MainActor
final class ParakeetDictation: ObservableObject {
    static let shared = ParakeetDictation()

    @Published private(set) var state: ModelInstallState

    nonisolated static let modelDownload = ModelDownload(
        url: URL(string: "https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/sherpa-onnx-nemo-parakeet-tdt-0.6b-v3-int8.tar.bz2")!,
        sha256: "5793d0fd397c5778d2cf2126994d58e9d56b1be7c04d13c7a15bb1b4eafb16bf", bytes: 487_170_055)
    /// What Settings says before the download, rounded.
    nonisolated static let downloadSizeText = "465 MB"

    /// The languages Parakeet v3 hears (ISO 639-1).
    nonisolated static let languageCodes: Set<String> = [
        "bg", "hr", "cs", "da", "nl", "en", "et", "fi", "fr", "de", "el", "hu", "it", "lv", "lt",
        "mt", "pl", "pt", "ro", "sk", "sl", "es", "sv", "ru", "uk",
    ]

    /// Whether it hears `bareLanguageCode` (nil: the dictation language is on auto-detect, which
    /// Parakeet does itself).
    nonisolated static func hears(bareLanguageCode: String?) -> Bool {
        guard let bareLanguageCode else { return true }
        return languageCodes.contains(bareLanguageCode)
    }

    nonisolated static var folder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("OpenClicky/Parakeet", isDirectory: true)
    }
    nonisolated static var modelFolder: URL { folder.appendingPathComponent("sherpa-onnx-nemo-parakeet-tdt-0.6b-v3-int8", isDirectory: true) }

    nonisolated static var isInstalled: Bool {
        SherpaLibrary.isEmbedded() && ["encoder.int8.onnx", "decoder.int8.onnx", "joiner.int8.onnx", "tokens.txt"].allSatisfy {
            FileManager.default.fileExists(atPath: modelFolder.appendingPathComponent($0).path)
        }
    }

    private let engine = SherpaHelperClient(flag: ParakeetHelper.flag, logName: "parakeet")
    private var downloadTask: Task<Void, Never>?
    nonisolated static let idleUnloadSeconds: UInt64 = 180
    private var idleUnloadTask: Task<Void, Never>?
    private var memoryPressureSource: DispatchSourceMemoryPressure?

    private init() {
        state = Self.isInstalled ? .installed : .notInstalled
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
        source.setEventHandler { [weak self] in
            Task { @MainActor in self?.unload(reason: "memory pressure") }
        }
        source.resume()
        memoryPressureSource = source
    }

    // MARK: Hearing

    /// The dictation key went down: start the helper and load the model while the take is spoken.
    func prepareForTake() {
        guard Self.isInstalled else { return }
        Task {
            let startedAt = Date()
            _ = try? await transcribe(pcm16: Data())
            AppLog.append(String(format: "parakeet: ready in %.1f s", Date().timeIntervalSince(startedAt)))
        }
    }

    /// The words in 16 kHz mono PCM16 audio.
    func transcribe(pcm16: Data) async throws -> String {
        guard Self.isInstalled else { throw ParakeetError.notInstalled }
        let request = ParakeetEngine.Request(pcm16Base64: pcm16.base64EncodedString(), libraryFolder: SherpaLibrary.folder, modelFolder: Self.modelFolder)
        defer { scheduleIdleUnload() }
        return try await engine.send(request, as: ParakeetEngine.Reply.self).text
    }

    private func scheduleIdleUnload() {
        idleUnloadTask?.cancel()
        idleUnloadTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.idleUnloadSeconds * 1_000_000_000)
            guard !Task.isCancelled else { return }
            self?.unload(reason: "idle")
        }
    }

    private func unload(reason: String) {
        idleUnloadTask?.cancel()
        idleUnloadTask = nil
        engine.unload { wasRunning in
            if wasRunning { AppLog.append("parakeet: unloaded (\(reason))") }
        }
    }

    // MARK: Automatic setup

    /// Set when the person removed the model or cancelled its download: it is never fetched again
    /// on its own (choosing it in Settings clears this).
    nonisolated static let declinedKey = "openclicky.parakeet.declined"

    /// Whether this Mac should get Parakeet without being asked: every Mac. Before macOS 26 the
    /// offline engine is the old recogniser; on 26 Apple's is better but Parakeet still hears more.
    nonisolated static var isRecommendedForThisMac: Bool { true }

    /// At launch and when the welcome tour ends: on a Mac whose dictation is on the offline engine,
    /// the model downloads in the background and takes over when it is ready.
    func startAutomaticSetup(tourIsFinished: Bool, engine currentEngine: DictationEngineChoice, bareLanguageCode: String?) {
        guard Self.isRecommendedForThisMac, !Self.isInstalled, tourIsFinished, downloadTask == nil,
              currentEngine == .offline, Self.hears(bareLanguageCode: bareLanguageCode),
              !UserDefaults.standard.bool(forKey: Self.declinedKey),
              ModelDownload.freeSpace() >= ModelDownload.automaticDownloadFreeSpace else { return }
        Task {
            if await ModelDownload.networkIsExpensiveOrConstrained() {
                AppLog.append("parakeet: automatic download waits for an unmetered network")
                return
            }
            AppLog.append("parakeet: automatic download started")
            download(isAutomatic: true)
        }
    }

    /// The engine once an automatic download finishes: Parakeet replaces the old offline
    /// recogniser; an engine the person moved to themselves is left alone.
    nonisolated static func engineAfterAutomaticDownload(current: DictationEngineChoice) -> DictationEngineChoice {
        current == .offline ? .parakeet : current
    }

    // MARK: Download

    func download(isAutomatic: Bool = false) {
        if !isAutomatic { UserDefaults.standard.set(false, forKey: Self.declinedKey) }
        guard downloadTask == nil, !Self.isInstalled else {
            if Self.isInstalled { state = .installed }
            return
        }
        state = .downloading(fraction: 0)
        downloadTask = Task { [weak self] in
            do {
                try await Self.modelDownload.install(into: Self.folder) { fraction in
                    Task { @MainActor in
                        // A late progress report must not undo the installed state.
                        guard let self, self.state.isBusy else { return }
                        self.state = fraction >= 1 ? .unpacking : .downloading(fraction: fraction)
                    }
                }
                guard Self.isInstalled else { throw ModelDownloadError.unpackFailed("the files weren't where they should be") }
                AppLog.append("parakeet: installed")
                self?.state = .installed
                if isAutomatic {
                    let settings = DictationSettings.shared
                    let engine = Self.engineAfterAutomaticDownload(current: settings.engine)
                    if engine != settings.engine {
                        settings.engine = engine
                        AppLog.append("parakeet: now the dictation engine")
                    }
                }
            } catch where error is CancellationError || (error as? URLError)?.code == .cancelled {
                self?.state = .notInstalled
            } catch {
                AppLog.append("parakeet: download failed: \(error.localizedDescription)")
                self?.state = .failed(error.localizedDescription)
            }
            self?.downloadTask = nil
        }
    }

    /// A cancelled download is a no: it isn't started again on its own.
    func cancelDownload() {
        UserDefaults.standard.set(true, forKey: Self.declinedKey)
        downloadTask?.cancel()
    }

    /// Deletes the model and ends the helper; dictation goes back to Apple's recogniser.
    func remove() {
        UserDefaults.standard.set(true, forKey: Self.declinedKey)
        downloadTask?.cancel()
        engine.unload()
        try? FileManager.default.removeItem(at: Self.folder)
        state = .notInstalled
        if DictationSettings.shared.engine == .parakeet { DictationSettings.shared.engine = .offline }
    }
}
