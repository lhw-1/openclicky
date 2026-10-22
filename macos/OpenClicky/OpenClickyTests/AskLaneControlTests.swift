//
//  AskLaneControlTests.swift
//  OpenClickyTests
//
//  Esc stops the ask lane at any time, except that a dictation take in progress keeps esc to itself.
//

import Testing
@testable import OpenClicky

struct AskLaneControlTests {
    @Test func aDictationTakeKeepsEscToItself() {
        #expect(AskLaneEscape.target(dictationTakeInProgress: true, askLaneCanBeStopped: true) == .dictationTake)
        #expect(AskLaneEscape.target(dictationTakeInProgress: true, askLaneCanBeStopped: false) == .dictationTake)
    }

    @Test func escStopsTheAskLaneWhenItHasSomethingUnderWay() {
        #expect(AskLaneEscape.target(dictationTakeInProgress: false, askLaneCanBeStopped: true) == .askLane)
        #expect(AskLaneEscape.target(dictationTakeInProgress: false, askLaneCanBeStopped: false) == .nothing)
    }

    @Test func aPressStillListeningOrTranscribingCanBeStopped() {
        #expect(AskLaneEscape.canStop(pressIsSettled: false, isAskInFlight: false, guideStep: nil))
    }

    @Test func aQuestionOnItsWayCanBeStoppedBeforeAnyGuideStepIsKnown() {
        // The first step of a guide: no step number yet, but the question is in flight.
        #expect(AskLaneEscape.canStop(pressIsSettled: true, isAskInFlight: true, guideStep: nil))
    }

    @Test func aGuideWaitingForAClickCanBeStopped() {
        #expect(AskLaneEscape.canStop(pressIsSettled: true, isAskInFlight: false, guideStep: 2))
    }

    @Test func nothingUnderWayMeansEscIsLeftAlone() {
        #expect(!AskLaneEscape.canStop(pressIsSettled: true, isAskInFlight: false, guideStep: nil))
    }
}
