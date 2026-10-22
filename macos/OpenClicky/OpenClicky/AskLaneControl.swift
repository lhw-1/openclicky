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
