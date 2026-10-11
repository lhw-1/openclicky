//
//  MacVoice.swift
//  OpenClicky
//
//  This Mac's own voice for spoken answers: free, offline, no account. AVSpeechSynthesizer renders
//  each piece of an answer to audio (not straight to the speakers), so it goes through the same
//  SpeechQueue and player as the cloud voice: the next sentence renders while this one plays, and
//  the island's stop button stops it the same way. The Premium and Enhanced voices are small
//  neural models macOS downloads once (System Settings → Accessibility → Spoken Content → System
//  voice → Manage Voices); the best one installed for the reply language is used unless one is
//  picked in Settings → Clicky.
//

import AVFoundation
import Foundation

@MainActor
final class MacVoice {
    static let shared = MacVoice()

    private let synthesizer = AVSpeechSynthesizer()

    /// A voice in Settings → Clicky's list.
    struct Choice: Identifiable, Equatable {
        let id: String
        let name: String
        /// "United Kingdom" for en-GB: several voices share a name across regions.
        let region: String?
        let quality: AVSpeechSynthesisVoiceQuality

        var label: String {
            let place = region.map { "\(name), \($0)" } ?? name
            switch quality {
            case .premium: return "\(place) (Premium)"
            case .enhanced: return "\(place) (Enhanced)"
            default: return place
            }
        }
    }

    /// The voices installed for `languageCode` ("en", "hi", …), best quality first. Novelty voices
    /// (Bells, Zarvox and friends) are left out.
    static func choices(forLanguage languageCode: String = ReplyLanguage.currentCode) -> [Choice] {
        AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.hasPrefix(languageCode) && !$0.voiceTraits.contains(.isNoveltyVoice) }
            .map { voice in
                let regionCode = voice.language.split(separator: "-").dropFirst().first.map(String.init)
                return Choice(id: voice.identifier, name: voice.name,
                              region: regionCode.flatMap { Locale.current.localizedString(forRegionCode: $0) }, quality: voice.quality)
            }
            .sorted { ($0.quality.rawValue, $1.name) > ($1.quality.rawValue, $0.name) }
    }

    /// The voice answers are spoken in: the one picked, if still installed, else the best for the language.
    static func currentVoice(settings: OpenClickyShellSettings = OpenClickyConfiguration.settings) -> AVSpeechSynthesisVoice? {
        if let picked = settings.macVoiceIdentifier, let voice = AVSpeechSynthesisVoice(identifier: picked) { return voice }
        if let best = choices().first { return AVSpeechSynthesisVoice(identifier: best.id) }
        return AVSpeechSynthesisVoice(language: ReplyLanguage.currentCode)
    }

    /// Whether answers are spoken by this Mac (shell.json `speechVoice` = "mac").
    static func isChosen(settings: OpenClickyShellSettings = OpenClickyConfiguration.settings) -> Bool {
        settings.speechVoice == "mac"
    }

    /// `text` spoken by the current voice, as audio an AVAudioPlayer can play (a CAF file's bytes).
    func audio(for text: String) async throws -> Data {
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = Self.currentVoice()
        let fileURL = FileManager.default.temporaryDirectory.appendingPathComponent("openclicky-voice-\(UUID().uuidString).caf")
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let render = Render(fileURL: fileURL)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            render.continuation = continuation
            synthesizer.write(utterance) { buffer in render.receive(buffer) }
        }
        return try Data(contentsOf: fileURL)
    }

    /// Collects the rendered buffers into a file. The write callback arrives on AVFoundation's own
    /// queue and isn't @Sendable, so everything it touches is behind the lock.
    private final class Render: @unchecked Sendable {
        let fileURL: URL
        var continuation: CheckedContinuation<Void, Error>?
        private var file: AVAudioFile?
        private let lock = NSLock()

        init(fileURL: URL) { self.fileURL = fileURL }

        func receive(_ buffer: AVAudioBuffer) {
            lock.lock()
            defer { lock.unlock() }
            guard let continuation else { return }
            guard let pcm = buffer as? AVAudioPCMBuffer, pcm.frameLength > 0 else {
                // An empty buffer is the end. Closing the file (dropping it) flushes it to disk.
                let wroteAnything = file != nil
                file = nil
                self.continuation = nil
                if wroteAnything { continuation.resume() } else { continuation.resume(throwing: MacVoiceError.nothingRendered) }
                return
            }
            do {
                if file == nil {
                    file = try AVAudioFile(forWriting: fileURL, settings: pcm.format.settings,
                                           commonFormat: pcm.format.commonFormat, interleaved: pcm.format.isInterleaved)
                }
                try file?.write(from: pcm)
            } catch {
                file = nil
                self.continuation = nil
                continuation.resume(throwing: error)
            }
        }
    }
}

enum MacVoiceError: LocalizedError {
    case nothingRendered
    var errorDescription: String? { "this mac's voice didn't say anything" }
}
