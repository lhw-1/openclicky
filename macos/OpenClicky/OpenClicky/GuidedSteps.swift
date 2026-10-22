//
//  GuidedSteps.swift
//  OpenClicky
//
//  Step by step guidance in the ask lane. Asked how to do something that takes several steps on
//  screen ("how do i send an email with an attachment"), Clicky says and points at only the first
//  step and ends its reply with the [NEXT] marker. OpenClicky then waits for the person to do it:
//  a click, or Return or Tab after typing. A moment later (so a menu or a dialog has time to open) it asks
//  again on its own with a fresh screenshot, and the reply is the next step, until a reply comes
//  without the marker. A wall of instructions is no use to someone who has to look away from it
//  after every step; this way the screen they are looking at is the one being described.
//
//  The click that finishes a step is checked against where the pointer pointed for it. One far
//  from it ("off target") gets a caption at once and a different "what's next?", asking the model
//  to check the new screen and point back if need be. It is a hint, never a block: the pointed spot
//  is approximate. Return and Tab have no position, so they count as unknown.
//
//  Clicks and keys are watched only while a guide waits for a step, through a listen-only global
//  monitor (Accessibility is already granted for dictation). Clicks in OpenClicky's own windows
//  are never seen by a global monitor, which is what we want. Esc, a new question, the island's
//  stop button, two minutes of nothing, or the step limit end the guide.
//

import AppKit
import Foundation

/// The [NEXT] marker that ends a reply which is one step of a guide.
enum GuidedStepMarker {
    static let marker = "[NEXT]"

    /// Matches the marker however a model spaces or cases it ("[next]", "[ NEXT ]").
    private static let markerPattern = #"\[\s*next\s*\]"#

    static func containsMarker(_ text: String) -> Bool {
        text.range(of: markerPattern, options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// The text without any marker, trimmed: what is spoken and kept in the conversation.
    static func removingMarkers(from text: String) -> String {
        text.replacingOccurrences(of: markerPattern, with: "", options: [.regularExpression, .caseInsensitive])
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// What the person did while a step was waiting, as the watcher reads an event.
enum GuidedStepInput: Equatable {
    case click
    /// Return or Tab: what ends typing into a field.
    case stepKey
    case escapeKey
    case otherKey
}

/// What the watcher does about one input. Pure, so the rules are unit-tested without events.
enum GuidedStepReaction: Equatable {
    /// The step looks done: ask for the next one once the screen has had `settleSeconds` to change.
    case askForNextStep(settleSeconds: TimeInterval)
    /// The person is still busy (typing after a click): wait longer before asking.
    case postponePendingAsk(settleSeconds: TimeInterval)
    /// Esc: the person wants Clicky to stop.
    case endGuide
    case ignore
}

struct GuidedStepRules {
    /// A menu, sheet or dialog opened by the click needs a moment before the screenshot shows it.
    static let settleSecondsAfterClick: TimeInterval = 1.5
    static let settleSecondsAfterStepKey: TimeInterval = 1.2
    /// Typing after a click (into the field it opened) waits for this much quiet, so a slow typist's
    /// pause in the middle of an address is not taken for the end of the step.
    static let settleSecondsWhileTyping: TimeInterval = 4
    /// No click or Return for this long and the guide is over (they gave up or went elsewhere).
    static let idleSecondsBeforeGivingUp: TimeInterval = 120
    /// A runaway guide (a model that always says there is more) stops here.
    static let maximumSteps = 15

    static func reaction(to input: GuidedStepInput, askIsPending: Bool) -> GuidedStepReaction {
        switch input {
        case .click:
            return .askForNextStep(settleSeconds: settleSecondsAfterClick)
        case .stepKey:
            return .askForNextStep(settleSeconds: settleSecondsAfterStepKey)
        case .escapeKey:
            return .endGuide
        case .otherKey:
            // Typing on its own is not a finished step ("type the address" ends with a click, Return
            // or Tab), but typing right after a click means the click only put the cursor in a field.
            return askIsPending ? .postponePendingAsk(settleSeconds: settleSecondsWhileTyping) : .ignore
        }
    }

    /// How OpenClicky's own question starts, as the ask prompt describes it.
    static let nextStepRequestOpening = "(i did that step. this is my screen now. what's next?"
    /// How it starts instead when the click landed far from where the pointer pointed.
    static let offTargetRequestOpening = "(i clicked about"

    /// The question OpenClicky asks for the person once they did a step. Kept in the conversation
    /// like anything they said. It repeats what they first asked, because the conversation keeps
    /// only the last ten exchanges and a long guide would otherwise lose its goal. A click that was
    /// off target says how far off, so the model checks the new screen before going on.
    static func nextStepRequest(forGoal guideGoal: String, clickCheck: GuidedStepClickCheck.Verdict = .unknown) -> String {
        if case .offTarget(let pointsAway) = clickCheck {
            return offTargetRequestOpening + " \(pointsAway) points away from where you pointed. this is my screen now. "
                + "check whether that was the right thing; if not, gently point me back. what i asked was: " + guideGoal + ")"
        }
        return nextStepRequestOpening + " what i asked was: " + guideGoal + ")"
    }
}

/// Was the click that finished a step where the pointer pointed? Pointing is 30 to 100 points off
/// at times (see ScreenTextLocator), so only a click well beyond that counts as off target, and
/// even then it is only a hint to the model.
enum GuidedStepClickCheck {
    /// Farther than this from the pointed spot (screen points) is off target.
    static let offTargetDistance: CGFloat = 120
    static let offTargetCaption = "that wasn't the spot i pointed at, let me look"

    enum Verdict: Equatable {
        /// No click (Return or Tab finished the step) or nothing was pointed at.
        case unknown
        case onTarget
        /// About this many points away, rounded to ten.
        case offTarget(pointsAway: Int)
    }

    /// Both points in the same space: AppKit global screen coordinates.
    static func verdict(pointedAt: CGPoint?, clickedAt: CGPoint?, threshold: CGFloat = offTargetDistance) -> Verdict {
        guard let pointedAt, let clickedAt else { return .unknown }
        let distance = hypot(clickedAt.x - pointedAt.x, clickedAt.y - pointedAt.y)
        guard distance > threshold else { return .onTarget }
        return .offTarget(pointsAway: Int((distance / 10).rounded()) * 10)
    }
}

/// Watches for the person doing the step Clicky just gave. One watcher per waiting step.
@MainActor
final class GuidedStepWatcher {
    enum EndReason: String {
        case escape
        case gaveUp = "gave up"
    }

    /// Called with where the click that finished the step landed (AppKit global screen
    /// coordinates), or nil when Return or Tab finished it.
    private let onStepDone: (CGPoint?) -> Void
    private let onEnded: (EndReason) -> Void
    private var eventMonitor: Any?
    private var pendingAsk: Task<Void, Never>?
    private var idleTimeout: Task<Void, Never>?
    /// The last click while this step waited; Return or Tab after it clears it (no position).
    private var lastClickLocation: CGPoint?

    init(onStepDone: @escaping (CGPoint?) -> Void, onEnded: @escaping (EndReason) -> Void) {
        self.onStepDone = onStepDone
        self.onEnded = onEnded
    }

    func start() {
        eventMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseUp, .rightMouseUp, .keyDown]) { [weak self] event in
            let input = Self.input(for: event)
            // A global monitor's event has no window, so its location is already on the screen.
            let clickLocation: CGPoint? = input == .click ? event.locationInWindow : nil
            Task { @MainActor in self?.handle(input, clickLocation: clickLocation) }
        }
        idleTimeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(GuidedStepRules.idleSecondsBeforeGivingUp))
            guard !Task.isCancelled else { return }
            self?.finish(reportingEnd: .gaveUp)
        }
    }

    /// Stops watching without reporting anything (a new question or the stop button).
    func stop() {
        if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
        eventMonitor = nil
        pendingAsk?.cancel()
        pendingAsk = nil
        idleTimeout?.cancel()
        idleTimeout = nil
    }

    /// A right click is a click too: "right-click the clip" is a step, and the menu it opens is
    /// what the next step points into.
    nonisolated static func input(for event: NSEvent) -> GuidedStepInput {
        if event.type == .leftMouseUp || event.type == .rightMouseUp { return .click }
        switch event.keyCode {
        case 36, 76, 48: return .stepKey  // Return, keypad Enter, Tab
        case 53: return .escapeKey
        default: return .otherKey
        }
    }

    private func handle(_ input: GuidedStepInput, clickLocation: CGPoint?) {
        guard eventMonitor != nil else { return }
        switch input {
        case .click: lastClickLocation = clickLocation
        case .stepKey: lastClickLocation = nil
        case .escapeKey, .otherKey: break
        }
        switch GuidedStepRules.reaction(to: input, askIsPending: pendingAsk != nil) {
        case .askForNextStep(let settleSeconds), .postponePendingAsk(let settleSeconds):
            // Another click or key restarts the wait, so a double click or a quick second click
            // (a menu, then its item) is one step.
            pendingAsk?.cancel()
            pendingAsk = Task { [weak self] in
                try? await Task.sleep(for: .seconds(settleSeconds))
                guard !Task.isCancelled, let self else { return }
                self.stop()
                self.onStepDone(self.lastClickLocation)
            }
        case .endGuide:
            finish(reportingEnd: .escape)
        case .ignore:
            break
        }
    }

    private func finish(reportingEnd reason: EndReason) {
        guard eventMonitor != nil else { return }
        stop()
        onEnded(reason)
    }
}
