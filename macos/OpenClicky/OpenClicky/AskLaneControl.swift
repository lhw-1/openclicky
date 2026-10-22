//
//  AskLaneControl.swift
//  OpenClicky
//
//  The person stays in charge of the ask lane. Esc stops it at any time: a press still listening,
//  a question on its way, an answer being said, or a guide waiting for a click. A dictation take
//  keeps esc to itself, as it always has. The rules are pure, so they are unit-tested without
//  events; CompanionManager.stopAskLane does the stopping.
//

import Foundation

/// Where one press of esc goes.
enum EscapeTarget: Equatable {
    /// A dictation take is in progress: esc cancels the take, and nothing else.
    case dictationTake
    /// The ask lane has something under way: esc stops it.
    case askLane
    case nothing
}

enum AskLaneEscape {
    static func target(dictationTakeInProgress: Bool, askLaneCanBeStopped: Bool) -> EscapeTarget {
        if dictationTakeInProgress { return .dictationTake }
        return askLaneCanBeStopped ? .askLane : .nothing
    }

    /// Whether the ask lane has anything to stop: a ⌃⌥ press not yet settled (listening or
    /// transcribing), a question on its way or being answered, or a guide (waiting for a click, or
    /// fetching its next step).
    static func canStop(pressIsSettled: Bool, isAskInFlight: Bool, guideStep: Int?) -> Bool {
        !pressIsSettled || isAskInFlight || guideStep != nil
    }
}

/// The pause between a question and its screenshot. The question is heard, then for a moment the
/// pointer and the island say the screen is about to be sent, and esc or a click on the island
/// calls it off before anything is captured. Settings → Privacy turns it off.
enum AskSendPause {
    static let defaultSeconds: TimeInterval = 1.2
    static let caption = "sending your screen · esc to cancel"

    /// How long to wait before capturing the screen, or nil to capture at once. A guide's own
    /// "what's next?" after each click never waits: the task was already let go ahead.
    static func seconds(isEnabled: Bool, isGuidedStepContinuation: Bool, pauseSeconds: TimeInterval = defaultSeconds) -> TimeInterval? {
        guard isEnabled, !isGuidedStepContinuation, pauseSeconds > 0 else { return nil }
        return pauseSeconds
    }

    /// Waits out the pause; false when the task was cancelled meanwhile (esc, the island, a new
    /// question), in which case nothing may be captured or sent.
    static func waitOut(seconds: TimeInterval) async -> Bool {
        try? await Task.sleep(for: .seconds(seconds))
        return !Task.isCancelled
    }
}
