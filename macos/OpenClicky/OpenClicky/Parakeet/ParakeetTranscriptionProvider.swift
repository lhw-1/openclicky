//
//  ParakeetTranscriptionProvider.swift
//  OpenClicky
//
//  The Parakeet engine as a transcription provider. Parakeet is not a streaming model, so the take
//  is collected as 16 kHz PCM16 and, while the key is held, the audio so far is read again about
//  once a second for the orb's live words (a few tenths of a second each on an M-series CPU); on
//  release the whole take is read once more for the final words.
//

import AVFoundation
import Foundation

struct ParakeetTranscriptionProvider: BuddyTranscriptionProvider {
    let displayName = "Parakeet (on this Mac)"
    let requiresSpeechRecognitionPermission = false
    var isConfigured: Bool { ParakeetDictation.isInstalled }
    var unavailableExplanation: String? { ParakeetDictation.isInstalled ? nil : ParakeetError.notInstalled.localizedDescription }

    func startStreamingSession(
        keyterms: [String],
        onTranscriptUpdate: @escaping (String) -> Void,
        onFinalTranscriptReady: @escaping (String) -> Void,
        onError: @escaping (Error) -> Void
    ) async throws -> any BuddyStreamingTranscriptionSession {
        guard ParakeetDictation.isInstalled else { throw ParakeetError.notInstalled }
        ParakeetDictation.shared.prepareForTake()
        return ParakeetTranscriptionSession(onTranscriptUpdate: onTranscriptUpdate, onFinalTranscriptReady: onFinalTranscriptReady, onError: onError)
    }
}

/// Audio arrives on the CoreAudio render thread: the converter is touched only there, everything
/// else only on `stateQueue`.
final class ParakeetTranscriptionSession: BuddyStreamingTranscriptionSession, @unchecked Sendable {
    /// A cold start on an older Mac loads the model (a few seconds) before it reads the take.
    let finalTranscriptFallbackDelaySeconds: TimeInterval = 20

    private static let sampleRate = 16_000
    /// How often the audio so far is read again for the live words.
    private static let partialIntervalNanoseconds: UInt64 = 1_000_000_000
    /// New audio needed before another live read is worth it: half a second.
    private static let partialMinimumNewBytes = sampleRate

    private let onTranscriptUpdate: (String) -> Void
    private let onFinalTranscriptReady: (String) -> Void
    private let onError: (Error) -> Void
    /// Injectable for tests; the live one goes through the helper.
    private let transcribe: @Sendable (Data) async throws -> String

    private let converter = BuddyPCM16AudioConverter(targetSampleRate: Double(sampleRate))
    private let stateQueue = DispatchQueue(label: "org.openclicky.parakeet.session")
    // Touched only on `stateQueue`.
    private var pcm16 = Data()
    private var bytesAtLastPartial = 0
    private var hasRequestedFinal = false
    private var isCancelled = false
    private var partialTask: Task<Void, Never>?

    init(onTranscriptUpdate: @escaping (String) -> Void,
         onFinalTranscriptReady: @escaping (String) -> Void,
         onError: @escaping (Error) -> Void,
         transcribe: @escaping @Sendable (Data) async throws -> String = { try await ParakeetDictation.shared.transcribe(pcm16: $0) }) {
        self.onTranscriptUpdate = onTranscriptUpdate
        self.onFinalTranscriptReady = onFinalTranscriptReady
        self.onError = onError
        self.transcribe = transcribe
        partialTask = Task { [weak self] in await self?.readPartialsUntilReleased() }
    }

    func appendAudioBuffer(_ audioBuffer: AVAudioPCMBuffer) {
        guard let converted = converter.convertToPCM16Data(from: audioBuffer), !converted.isEmpty else { return }
        appendPCM16(converted)
    }

    /// The take's audio, already 16 kHz PCM16 (the converter's output; tests feed it directly).
    func appendPCM16(_ converted: Data) {
        stateQueue.async {
            guard !self.hasRequestedFinal, !self.isCancelled else { return }
            self.pcm16.append(converted)
        }
    }

    func requestFinalTranscript() {
        stateQueue.async {
            guard !self.hasRequestedFinal, !self.isCancelled else { return }
            self.hasRequestedFinal = true
            self.partialTask?.cancel()
            let audio = self.pcm16
            Task { [weak self] in
                guard let self else { return }
                do {
                    let text = audio.isEmpty ? "" : try await self.transcribe(audio)
                    if !self.cancelled { self.onFinalTranscriptReady(text) }
                } catch {
                    AppLog.append("transcription (parakeet): \(error.localizedDescription)")
                    if !self.cancelled { self.onError(error) }
                }
            }
        }
    }

    func cancel() {
        stateQueue.async {
            self.isCancelled = true
            self.partialTask?.cancel()
            self.pcm16 = Data()
        }
    }

    private var cancelled: Bool { stateQueue.sync { isCancelled } }

    /// Reads the audio so far about once a second while the key is held; a read still running
    /// when the next is due simply delays it (the helper answers one request at a time).
    private func readPartialsUntilReleased() async {
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: Self.partialIntervalNanoseconds)
            let snapshot: Data? = stateQueue.sync {
                guard !hasRequestedFinal, !isCancelled, pcm16.count - bytesAtLastPartial >= Self.partialMinimumNewBytes else { return nil }
                bytesAtLastPartial = pcm16.count
                return pcm16
            }
            guard let snapshot, !Task.isCancelled else { continue }
            guard let text = try? await transcribe(snapshot), !Task.isCancelled else { continue }
            let stillListening = stateQueue.sync { !hasRequestedFinal && !isCancelled }
            if stillListening, !text.isEmpty { onTranscriptUpdate(text) }
        }
    }
}
