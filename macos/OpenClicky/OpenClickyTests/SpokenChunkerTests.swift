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

    @Test func aSecondTagAfterTheLeadingOneIsNeverSpoken() {
        var chunker = SpokenChunker()
        #expect(chunker.feed(accumulated: "[POINT:none] [POINT:10,20:x]") == [])
        #expect(chunker.finish() == [])
        #expect(chunker.pointTag == "[POINT:none]")

        var twoPoints = SpokenChunker()
        _ = twoPoints.feed(accumulated: "[POINT:10,20:x]\n[POINT:30,40:y]")
        #expect(twoPoints.finish() == [])
        #expect(twoPoints.pointTag == "[POINT:10,20:x]")
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

    @Test func aTagOnItsOwnIsRead() {
        // The answer speaker hands over just the tag when the voice starts. This once recursed
        // forever (the moved tag was still "leading") and crashed the app.
        let tagAlone = CompanionManager.parsePointingCoordinates(from: "[POINT:120,40:code]")
        #expect(tagAlone.coordinate == CGPoint(x: 120, y: 40))
        #expect(tagAlone.elementLabel == "code")
        #expect(tagAlone.spokenText == "")
        #expect(CompanionManager.parsePointingCoordinates(from: "  [POINT:none]  ").coordinate == nil)
    }

    // Two tags with nothing else between them once recursed forever and crashed the app at the end
    // of an answer. The first tag that reads as a tag wins; neither is ever spoken.
    @Test func twoTagsWithNothingElseDoNotRecurse() {
        let pointThenNone = CompanionManager.parsePointingCoordinates(from: "[POINT:120,40:code] [POINT:none]")
        #expect(pointThenNone.coordinate == CGPoint(x: 120, y: 40))
        #expect(pointThenNone.elementLabel == "code")
        #expect(pointThenNone.spokenText == "")

        let noneThenPoint = CompanionManager.parsePointingCoordinates(from: "[POINT:none] [POINT:10,20:x]")
        #expect(noneThenPoint.coordinate == nil)
        #expect(noneThenPoint.elementLabel == "none")
        #expect(noneThenPoint.spokenText == "")

        let twoPoints = CompanionManager.parsePointingCoordinates(from: "[POINT:10,20:x]\n[POINT:30,40:y]")
        #expect(twoPoints.coordinate == CGPoint(x: 10, y: 20))
        #expect(twoPoints.spokenText == "")

        let twoNones = CompanionManager.parsePointingCoordinates(from: "[POINT:none] [POINT:none]")
        #expect(twoNones.coordinate == nil)
        #expect(twoNones.spokenText == "")
    }

    @Test func aLeadingAndATrailingTagAroundTextKeepTheTextAndTheFirstTag() {
        let both = CompanionManager.parsePointingCoordinates(from: "[POINT:10,20:save] click save. [POINT:30,40:other]")
        #expect(both.coordinate == CGPoint(x: 10, y: 20))
        #expect(both.spokenText == "click save.")
    }

    @Test func aTagInTheMiddleOrAnUnclosedTagIsLeftAsText() {
        let middle = CompanionManager.parsePointingCoordinates(from: "click [POINT:10,20:x] there.")
        #expect(middle.coordinate == nil)
        #expect(middle.spokenText == "click [POINT:10,20:x] there.")
        let unclosed = CompanionManager.parsePointingCoordinates(from: "[POINT:10,20:x")
        #expect(unclosed.coordinate == nil)
        #expect(unclosed.spokenText == "[POINT:10,20:x")
    }
}
