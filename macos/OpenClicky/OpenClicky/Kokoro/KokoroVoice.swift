//
//  KokoroVoice.swift
//  OpenClicky
//
//  Kokoro: an open 82M-parameter voice model that runs on this Mac, free and offline, through
//  sherpa-onnx's C library. Nothing of it ships in the app. Picking Kokoro in Settings downloads
//  the library (universal, 19 MB) and the model (350 MB), checks both against pinned SHA-256s,
//  unpacks them into Application Support, and loads them in-process with dlopen; the app's
//  `disable-library-validation` entitlement is what allows a library signed by someone else.
//
//  The model stays loaded once used: loading takes about three seconds, while a sentence then
//  takes about 0.3× its spoken length on an M2 Pro and 0.55× under Rosetta (the closest stand-in
//  measured for an Intel Mac). The int8 model is smaller but was slower on both (0.86× / 1.3×).
//

import Combine
import CryptoKit
import Foundation

@MainActor
final class KokoroVoice: ObservableObject {
    static let shared = KokoroVoice()

    enum State: Equatable {
        case notInstalled
        case downloading(fraction: Double)
        case unpacking
        case installed
        case failed(String)
    }

    @Published private(set) var state: State

    struct Download: Sendable {
        let url: URL
        let sha256: String
        let bytes: Int64
    }

    /// sherpa-onnx's universal (arm64 + x86_64) shared library; must match sherpa-onnx-c-api.h.
    nonisolated static let runtimeVersion = "1.13.8"
    nonisolated static let runtimeDownload = Download(
        url: URL(string: "https://github.com/k2-fsa/sherpa-onnx/releases/download/v1.13.8/sherpa-onnx-v1.13.8-osx-universal2-shared-lib.tar.bz2")!,
        sha256: "c1cca5b4a1867543e27d42fbea513983e73f629d0aa53b43b51555a71d2108d9", bytes: 18_819_320)
    /// Kokoro v1.0, multilingual, full precision.
    nonisolated static let modelDownload = Download(
        url: URL(string: "https://github.com/k2-fsa/sherpa-onnx/releases/download/tts-models/kokoro-multi-lang-v1_0.tar.bz2")!,
        sha256: "c5f7e2d2caf082bc1d20fb70334a61d99d20b484500aad32e7cf84c128ea3298", bytes: 349_906_910)
    /// What Settings says before the download: the two archives, rounded.
    nonisolated static let downloadSizeText = "370 MB"

    nonisolated static var folder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("OpenClicky/Kokoro", isDirectory: true)
    }
    nonisolated static var libraryFolder: URL { folder.appendingPathComponent("sherpa-onnx-v\(runtimeVersion)-osx-universal2-shared-lib/lib", isDirectory: true) }
    nonisolated static var modelFolder: URL { folder.appendingPathComponent("kokoro-multi-lang-v1_0", isDirectory: true) }

    nonisolated static var isInstalled: Bool {
        let fileManager = FileManager.default
        return [libraryFolder.appendingPathComponent("libsherpa-onnx-c-api.dylib"),
                libraryFolder.appendingPathComponent("libonnxruntime.dylib"),
                modelFolder.appendingPathComponent("model.onnx"),
                modelFolder.appendingPathComponent("voices.bin"),
                modelFolder.appendingPathComponent("tokens.txt"),
                modelFolder.appendingPathComponent("espeak-ng-data")].allSatisfy { fileManager.fileExists(atPath: $0.path) }
    }

    private var downloadTask: Task<Void, Never>?
    private let engine = KokoroEngine()

    private init() {
        state = Self.isInstalled ? .installed : .notInstalled
    }

    // MARK: Speakers

    struct Speaker: Identifiable, Equatable, Sendable {
        /// The speaker's index in the model's voice table.
        let id: Int
        let name: String
        let languageCode: String
        let accent: String
        var label: String { "\(name), \(accent)" }
    }

    /// The speakers offered in Settings: the model has 54, these are the clearest per language.
    nonisolated static let speakers: [Speaker] = [
        Speaker(id: 3, name: "Heart", languageCode: "en", accent: "American"),
        Speaker(id: 2, name: "Bella", languageCode: "en", accent: "American"),
        Speaker(id: 6, name: "Nicole", languageCode: "en", accent: "American"),
        Speaker(id: 9, name: "Sarah", languageCode: "en", accent: "American"),
        Speaker(id: 16, name: "Michael", languageCode: "en", accent: "American"),
        Speaker(id: 11, name: "Adam", languageCode: "en", accent: "American"),
        Speaker(id: 21, name: "Emma", languageCode: "en", accent: "British"),
        Speaker(id: 26, name: "George", languageCode: "en", accent: "British"),
        Speaker(id: 31, name: "Alpha", languageCode: "hi", accent: "Hindi"),
        Speaker(id: 33, name: "Omega", languageCode: "hi", accent: "Hindi"),
        Speaker(id: 28, name: "Dora", languageCode: "es", accent: "Spanish"),
        Speaker(id: 30, name: "Siwis", languageCode: "fr", accent: "French"),
        Speaker(id: 35, name: "Sara", languageCode: "it", accent: "Italian"),
        Speaker(id: 37, name: "Alpha", languageCode: "ja", accent: "Japanese"),
        Speaker(id: 42, name: "Dora", languageCode: "pt", accent: "Portuguese"),
        Speaker(id: 45, name: "Xiaobei", languageCode: "zh", accent: "Mandarin"),
    ]

    /// The speaker for the reply language: the one picked if it speaks it, else the language's
    /// first; nil when Kokoro doesn't speak the language.
    nonisolated static func speaker(forLanguage languageCode: String, picked: Int?) -> Speaker? {
        let forLanguage = speakers.filter { $0.languageCode == languageCode }
        return forLanguage.first(where: { $0.id == picked }) ?? forLanguage.first
    }

    /// Kokoro's language hint for espeak (sherpa-onnx's `lang`); English and Mandarin use the
    /// model's own lexicons instead.
    nonisolated static func languageHint(for languageCode: String) -> String {
        switch languageCode {
        case "en": return "en-us"
        case "zh": return "zh"
        case "pt": return "pt-br"
        default: return languageCode
        }
    }

    // MARK: Speaking

    /// `text` in Kokoro's voice, as WAV bytes. The first call loads the model (about 3 s).
    func audio(for text: String, languageCode: String = ReplyLanguage.currentCode) async throws -> Data {
        guard Self.isInstalled else { throw KokoroError.notInstalled }
        guard let speaker = Self.speaker(forLanguage: languageCode, picked: OpenClickyConfiguration.settings.kokoroSpeaker) else {
            throw KokoroError.languageNotSpoken
        }
        let request = KokoroEngine.Request(text: text, speakerID: speaker.id, languageHint: Self.languageHint(for: languageCode),
                                           libraryFolder: Self.libraryFolder, modelFolder: Self.modelFolder)
        return try await engine.audio(for: request)
    }

    // MARK: Download

    /// Downloads, checks and unpacks Kokoro; does nothing while a download runs or once installed.
    func download() {
        guard downloadTask == nil, !Self.isInstalled else {
            if Self.isInstalled { state = .installed }
            return
        }
        state = .downloading(fraction: 0)
        downloadTask = Task { [weak self] in
            do {
                try FileManager.default.createDirectory(at: Self.folder, withIntermediateDirectories: true)
                let downloads = [Self.runtimeDownload, Self.modelDownload]
                let totalBytes = Double(downloads.reduce(0) { $0 + $1.bytes })
                var bytesBefore: Int64 = 0
                var archives: [URL] = []
                for download in downloads {
                    let before = Double(bytesBefore)
                    let archive = try await Self.fetch(download) { written in
                        Task { @MainActor in self?.state = .downloading(fraction: min(1, (before + Double(written)) / totalBytes)) }
                    }
                    archives.append(archive)
                    bytesBefore += download.bytes
                }
                self?.state = .unpacking
                for archive in archives {
                    try await Self.unpack(archive)
                    try? FileManager.default.removeItem(at: archive)
                }
                guard Self.isInstalled else { throw KokoroError.unpackFailed("the files weren't where they should be") }
                AppLog.append("kokoro: installed")
                self?.state = .installed
            } catch is CancellationError {
                self?.state = .notInstalled
            } catch {
                AppLog.append("kokoro: download failed: \(error.localizedDescription)")
                self?.state = .failed(error.localizedDescription)
            }
            self?.downloadTask = nil
        }
    }

    func cancelDownload() {
        downloadTask?.cancel()
    }

    /// Deletes the download and unloads the model.
    func remove() {
        downloadTask?.cancel()
        engine.unload()
        try? FileManager.default.removeItem(at: Self.folder)
        state = .notInstalled
    }

    /// One archive into the Kokoro folder, checked against its SHA-256 (a resumable download is
    /// not worth it: a failed one is retried whole, and GitHub serves both quickly).
    private static func fetch(_ download: Download, progress: @escaping @Sendable (Int64) -> Void) async throws -> URL {
        let progressDelegate = DownloadProgressDelegate(progress: progress)
        let (temporaryURL, response) = try await URLSession.shared.download(from: download.url, delegate: progressDelegate)
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw KokoroError.downloadFailed("the server answered \((response as? HTTPURLResponse)?.statusCode ?? 0)")
        }
        let destination = folder.appendingPathComponent(download.url.lastPathComponent)
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: temporaryURL, to: destination)
        guard try sha256(of: destination) == download.sha256 else {
            try? FileManager.default.removeItem(at: destination)
            throw KokoroError.downloadFailed("the download didn't match its checksum")
        }
        return destination
    }

    nonisolated static func sha256(of fileURL: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 4 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    nonisolated private static func unpack(_ archive: URL) async throws {
        try await Task.detached {
            let tar = Process()
            tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
            tar.arguments = ["-xjf", archive.path, "-C", folder.path]
            try tar.run()
            tar.waitUntilExit()
            guard tar.terminationStatus == 0 else { throw KokoroError.unpackFailed("tar exited with \(tar.terminationStatus)") }
        }.value
    }
}

enum KokoroError: Error, LocalizedError, Equatable {
    case notInstalled
    case languageNotSpoken
    case downloadFailed(String)
    case unpackFailed(String)
    case libraryNotLoaded(String)
    case modelNotLoaded
    case nothingGenerated

    var errorDescription: String? {
        switch self {
        case .notInstalled: return "Kokoro isn't downloaded yet."
        case .languageNotSpoken: return "Kokoro doesn't speak this language."
        case let .downloadFailed(reason): return "Kokoro couldn't be downloaded: \(reason)."
        case let .unpackFailed(reason): return "Kokoro couldn't be unpacked: \(reason)."
        case let .libraryNotLoaded(reason): return "Kokoro's library didn't load: \(reason)"
        case .modelNotLoaded: return "Kokoro's model didn't load."
        case .nothingGenerated: return "Kokoro said nothing."
        }
    }
}

/// Reports bytes written for one download.
private final class DownloadProgressDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    let progress: @Sendable (Int64) -> Void
    init(progress: @escaping @Sendable (Int64) -> Void) { self.progress = progress }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        progress(totalBytesWritten)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}
}
