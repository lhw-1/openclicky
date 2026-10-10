import CoreGraphics
import Testing
@testable import OpenClicky

struct SpokenChunkerTests {
    @Test func theFirstSentenceIsReadyAsSoonAsItEnds() {
        var chunker = SpokenChunker()
        #expect(chunker.feed(accumulated: "that number is your") == [])
        #expect(chunker.feed(accumulated: "that number is your sign-in code. it works") == ["that number is your sign-in code."])
        #expect(chunker.finish() == ["it works"])
    }

    @Test func laterSentencesAreGroupedSoTheVoiceMakesFewerRequests() {
        var chunker = SpokenChunker(laterChunkMinimum: 40)
        _ = chunker.feed(accumulated: "first one here. ")
        #expect(chunker.feed(accumulated: "first one here. short. also short. ") == [])
        #expect(chunker.feed(accumulated: "first one here. short. also short. now this makes it long enough. tail") == ["short. also short. now this makes it long enough."])
        #expect(chunker.finish() == ["tail"])
    }

    @Test func aLeadingPointTagIsHeldBackAndNeverSpoken() {
        var chunker = SpokenChunker()
        #expect(chunker.feed(accumulated: "[POINT:120,4") == [])
        #expect(chunker.pointTag == nil)
        #expect(chunker.feed(accumulated: "[POINT:120,40:code] that's your code. more") == ["that's your code."])
        #expect(chunker.pointTag == "[POINT:120,40:code]")
        #expect(chunker.finish() == ["more"])
    }

    @Test func aTrailingPointTagIsFoundAtTheEndAndNotSpoken() {
        var chunker = SpokenChunker()
        _ = chunker.feed(accumulated: "see the save button. click it. [POINT:5,6:save]")
        #expect(chunker.finish() == ["click it."])
        #expect(chunker.pointTag == "[POINT:5,6:save]")
    }

    @Test func decimalsAndAnswersWithoutTagsStayWhole() {
        var chunker = SpokenChunker()
        #expect(chunker.feed(accumulated: "it costs 3.5 dollars") == [])
        #expect(chunker.finish() == ["it costs 3.5 dollars"])
        #expect(chunker.pointTag == nil)
    }
}

@MainActor
struct PointTagPositionTests {
    @Test func aLeadingTagIsReadLikeATrailingOne() {
        let leading = CompanionManager.parsePointingCoordinates(from: "[POINT:120,40:code] that's your sign-in code.")
        #expect(leading.coordinate == CGPoint(x: 120, y: 40))
        #expect(leading.elementLabel == "code")
        #expect(leading.spokenText == "that's your sign-in code.")
        let trailing = CompanionManager.parsePointingCoordinates(from: "that's your sign-in code. [POINT:120,40:code]")
        #expect(trailing.coordinate == leading.coordinate)
        #expect(trailing.spokenText == leading.spokenText)
        #expect(CompanionManager.parsePointingCoordinates(from: "[POINT:none] html is markup.").spokenText == "html is markup.")
    }
}
