import Foundation
import Testing
@testable import OpenClicky

@MainActor
struct SpeechQueueTests {
    private struct FetchFailed: Error {}

    @Test func piecesPlayInOrderAndTheFirstAudioIsReportedOnce() async throws {
        var played: [String] = []
        var firstAudioCount = 0
        let queue = SpeechQueue(
            fetchAudio: { text in
                // The second piece arrives first: order must still follow the text.
                if text == "one" { try await Task.sleep(nanoseconds: 30_000_000) }
                return Data(text.utf8)
            },
            playAudio: { data in played.append(String(decoding: data, as: UTF8.self)) }
        )
        let playback = Task { try await queue.run(onFirstAudio: { firstAudioCount += 1 }) }
        queue.enqueue("one")
        queue.enqueue("two")
        queue.finish()
        try await playback.value
        #expect(played == ["one", "two"])
        #expect(firstAudioCount == 1)
    }

    @Test func runWaitsForPiecesThatArriveLater() async throws {
        var played: [String] = []
        let queue = SpeechQueue(fetchAudio: { Data($0.utf8) }, playAudio: { played.append(String(decoding: $0, as: UTF8.self)) })
        let playback = Task { try await queue.run(onFirstAudio: {}) }
        try await Task.sleep(nanoseconds: 20_000_000)
        queue.enqueue("late")
        queue.finish()
        try await playback.value
        #expect(played == ["late"])
    }

    @Test func aFailedPieceReportsWhatWasNotSpoken() async {
        var played: [String] = []
        let queue = SpeechQueue(
            fetchAudio: { text in
                if text == "two" { throw FetchFailed() }
                return Data(text.utf8)
            },
            playAudio: { played.append(String(decoding: $0, as: UTF8.self)) }
        )
        let playback = Task { try await queue.run(onFirstAudio: {}) }
        queue.enqueue("one")
        queue.enqueue("two")
        queue.enqueue("three")
        queue.finish()
        do {
            try await playback.value
            Issue.record("expected the failure to surface")
        } catch let failure as SpeechQueue.Failure {
            #expect(failure.unspokenText == ["two", "three"])
        } catch {
            Issue.record("unexpected error \(error)")
        }
        #expect(played == ["one"])
    }

    @Test func anEmptyQueueFinishesWithoutAudio() async throws {
        var firstAudioCount = 0
        let queue = SpeechQueue(fetchAudio: { Data($0.utf8) }, playAudio: { _ in })
        let playback = Task { try await queue.run(onFirstAudio: { firstAudioCount += 1 }) }
        queue.finish()
        try await playback.value
        #expect(firstAudioCount == 0)
    }
}
