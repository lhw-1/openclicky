//
//  SpeechQueue.swift
//  OpenClicky
//
//  Speaks an answer piece by piece while the rest is still being written. Each piece's audio is
//  requested the moment the piece is enqueued, so the next piece is usually ready by the time the
//  current one finishes; playback always follows the order of the text. The fetch and play steps
//  are injected, so the ordering, the first-audio signal and the failure hand-off are tested
//  without the network or a speaker.
//

import Foundation

@MainActor
final class SpeechQueue {
    /// A piece's audio could not be fetched or played. `unspokenText` is that piece and every one
    /// after it (including pieces enqueued later), so the caller can say them another way.
    struct Failure: Error {
        let unspokenText: [String]
        let underlyingError: Error
    }

    private let fetchAudio: (String) async throws -> Data
    private let playAudio: (Data) async throws -> Void

    private var pieceTexts: [String] = []
    private var pieceFetches: [Task<Data, Error>] = []
    private var isFinished = false
    /// After a failure, later pieces are only collected (for the caller's fallback), never fetched.
    private var hasFailed = false
    /// Resumed when a piece is enqueued or the queue is finished, so `run` can stop waiting.
    private var waitingForMorePieces: CheckedContinuation<Void, Never>?

    init(fetchAudio: @escaping (String) async throws -> Data, playAudio: @escaping (Data) async throws -> Void) {
        self.fetchAudio = fetchAudio
        self.playAudio = playAudio
    }

    func enqueue(_ pieceText: String) {
        guard !isFinished else { return }
        pieceTexts.append(pieceText)
        if hasFailed { wakeRunLoop(); return }
        let fetchAudio = self.fetchAudio
        // At most two requests at once (ElevenLabs caps concurrent requests on smaller plans): a
        // piece waits for the fetch two places ahead of it before starting its own.
        let fetchTwoPlacesAhead = pieceFetches.count >= 2 ? pieceFetches[pieceFetches.count - 2] : nil
        pieceFetches.append(Task {
            _ = try? await fetchTwoPlacesAhead?.value
            try Task.checkCancellation()
            return try await fetchAudio(pieceText)
        })
        wakeRunLoop()
    }

    /// No more pieces will come: `run` returns once the last one has played.
    func finish() {
        isFinished = true
        wakeRunLoop()
    }

    /// Plays every piece in order until `finish()` and the last piece are done. `onFirstAudio` runs
    /// once, right before the first piece starts playing.
    func run(onFirstAudio: () -> Void) async throws {
        var nextPieceIndex = 0
        while true {
            try Task.checkCancellation()
            if nextPieceIndex < pieceFetches.count {
                do {
                    let audioData = try await pieceFetches[nextPieceIndex].value
                    try Task.checkCancellation()
                    if nextPieceIndex == 0 { onFirstAudio() }
                    try await playAudio(audioData)
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    // Wait for the rest of the answer, then hand back everything not yet spoken.
                    hasFailed = true
                    cancelPendingFetches()
                    while !isFinished {
                        await withCheckedContinuation { waitingForMorePieces = $0 }
                    }
                    cancelPendingFetches()
                    throw Failure(unspokenText: Array(pieceTexts[nextPieceIndex...]), underlyingError: error)
                }
                nextPieceIndex += 1
                continue
            }
            if isFinished { return }
            await withCheckedContinuation { waitingForMorePieces = $0 }
        }
    }

    /// Stops fetching: used when the person speaks again or the answer is abandoned.
    func cancel() {
        isFinished = true
        cancelPendingFetches()
        wakeRunLoop()
    }

    private func cancelPendingFetches() {
        pieceFetches.forEach { $0.cancel() }
    }

    private func wakeRunLoop() {
        let continuation = waitingForMorePieces
        waitingForMorePieces = nil
        continuation?.resume()
    }
}

/// One ask-lane answer being spoken as it streams: the chunker cuts the text, the queue fetches and
/// plays each piece, and the pointer is moved when the voice starts (or, when the tag only shows up
/// at the end, as soon as it is known).
@MainActor
final class StreamingAnswerSpeaker {
    private var chunker = SpokenChunker()
    private let speechQueue: SpeechQueue
    private let onVoiceStarts: () -> Void
    private let onPointTag: (String) -> Void
    private var hasVoiceStarted = false
    private var hasHandledPointTag = false
    private var enqueuedPieceCount = 0

    init(speechQueue: SpeechQueue, onVoiceStarts: @escaping () -> Void, onPointTag: @escaping (String) -> Void) {
        self.speechQueue = speechQueue
        self.onVoiceStarts = onVoiceStarts
        self.onPointTag = onPointTag
    }

    /// Plays the pieces as they come; throws `SpeechQueue.Failure` with what was left unsaid.
    func play() async throws {
        try await speechQueue.run(onFirstAudio: { [weak self] in self?.voiceDidStart() })
    }

    /// The whole answer so far, from the stream.
    func receive(accumulatedAnswer: String) {
        chunker.feed(accumulated: accumulatedAnswer).forEach(enqueue)
    }

    /// The stream is over. `closingSentences` (what a quick action did) are spoken after the answer.
    func finish(closingSentences: [String]) {
        chunker.finish().forEach(enqueue)
        closingSentences.filter { !$0.isEmpty }.forEach(enqueue)
        speechQueue.finish()
        // A trailing tag is only known now; with nothing to say there is no voice to wait for.
        if hasVoiceStarted || enqueuedPieceCount == 0 { handlePointTagIfKnown() }
    }

    /// The voice could not be used: the caller speaks another way and points now.
    func voiceFellBack() {
        handlePointTagIfKnown()
    }

    func cancel() {
        speechQueue.cancel()
    }

    private func enqueue(_ pieceText: String) {
        enqueuedPieceCount += 1
        speechQueue.enqueue(pieceText)
    }

    private func voiceDidStart() {
        hasVoiceStarted = true
        onVoiceStarts()
        handlePointTagIfKnown()
    }

    private func handlePointTagIfKnown() {
        guard !hasHandledPointTag, let pointTag = chunker.pointTag else { return }
        hasHandledPointTag = true
        onPointTag(pointTag)
    }
}
