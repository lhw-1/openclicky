//
//  AskLaneControlTests.swift
//  OpenClickyTests
//
//  Esc stops the ask lane at any time, except that a dictation take in progress keeps esc to itself.
//  A question pauses before its screen is sent, unless the pause is off or a guide asks for itself.
//

import Foundation
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

    @Test func aQuestionPausesBeforeItsScreenIsSent() {
        #expect(AskSendPause.seconds(isEnabled: true, isGuidedStepContinuation: false) == AskSendPause.defaultSeconds)
        #expect(AskSendPause.defaultSeconds == 1.2)
    }

    @Test func noPauseWhenTheSettingIsOff() {
        #expect(AskSendPause.seconds(isEnabled: false, isGuidedStepContinuation: false) == nil)
    }

    /// The person already let the task go ahead: a pause after every click would only slow it down.
    @Test func aGuidesOwnNextStepNeverPauses() {
        #expect(AskSendPause.seconds(isEnabled: true, isGuidedStepContinuation: true) == nil)
    }

    @Test func thePauseSaysEscCancels() {
        #expect(AskSendPause.caption.contains("esc to cancel"))
        #expect(!AskSendPause.caption.contains("—"))
    }

    @Test func aPauseThatRunsOutLetsTheQuestionGo() async {
        #expect(await AskSendPause.waitOut(seconds: 0.01))
    }

    @Test func aCancelledPauseSendsNothing() async {
        let pause = Task { await AskSendPause.waitOut(seconds: 5) }
        pause.cancel()
        #expect(await pause.value == false)
    }

    /// On by default, and kept once turned off, like its neighbours on the privacy page.
    @Test @MainActor func pauseBeforeSendingIsOnByDefaultAndRemembered() throws {
        let defaults = try #require(UserDefaults(suiteName: "openclicky-tests-\(UUID().uuidString)"))
        #expect(DictationSettings(defaults: defaults).pauseBeforeSendingScreen)
        DictationSettings(defaults: defaults).pauseBeforeSendingScreen = false
        #expect(!DictationSettings(defaults: defaults).pauseBeforeSendingScreen)
    }
}
