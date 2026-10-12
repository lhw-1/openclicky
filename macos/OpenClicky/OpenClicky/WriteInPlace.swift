//
//  WriteInPlace.swift
//  OpenClicky
//
//  "Can you rephrase this?" about an email being drafted: Clicky rewrites the text and puts the new
//  version where the old one was. The text is what the person highlighted, or else everything in
//  the text box the cursor is in (Gmail's message body, a Notes page, a form field). It is read
//  through Accessibility when the question is asked, so the model gets the exact words and not
//  what it can read off a screenshot, and the ask lane offers the `write_in_place` tool only then.
//
//  The tool's text replaces the old text straight away (the person asked for that; ⌘Z undoes it),
//  but only if the same box still has focus with the same text in it: a reply that arrives after
//  they clicked elsewhere is spoken, never pasted somewhere new. The original stays on the
//  clipboard afterwards. Password fields and OpenClicky's own windows are never targets.
//

import AppKit
import ApplicationServices
import Foundation

/// The text a rewrite would replace, captured when the question was asked.
struct WritingTarget: Equatable {
    enum Scope: Equatable {
        /// What the person highlighted: the paste replaces just that.
        case selection
        /// Everything in the focused text box: it is selected first, then replaced.
        case wholeField
    }

    let scope: Scope
    let text: String
    let appBundleID: String?
    let appName: String?

    /// The most text sent along for a rewrite: a long email, not a whole document.
    static let maximumCharacters = 6_000

    /// The target in a snapshot of the focused element, or nil when there is nothing to rewrite.
    static func target(in snapshot: FocusedFieldSnapshot, ownBundleID: String? = Bundle.main.bundleIdentifier) -> WritingTarget? {
        guard snapshot.isEditable, !snapshot.isSecure, snapshot.appBundleID != ownBundleID else { return nil }
        if let selectedText = snapshot.selectedText, !selectedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            guard selectedText.count <= maximumCharacters else { return nil }
            return WritingTarget(scope: .selection, text: selectedText, appBundleID: snapshot.appBundleID, appName: snapshot.appName)
        }
        guard let value = snapshot.value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              value.count <= maximumCharacters else { return nil }
        return WritingTarget(scope: .wholeField, text: value, appBundleID: snapshot.appBundleID, appName: snapshot.appName)
    }

    /// Whether `snapshot` (read just before pasting) is still this target: the same app, an editable
    /// box, and the same words selected or in the box. Anything else and the rewrite is not pasted.
    func stillMatches(_ snapshot: FocusedFieldSnapshot) -> Bool {
        guard snapshot.appBundleID == appBundleID, snapshot.isEditable, !snapshot.isSecure else { return false }
        switch scope {
        case .selection: return snapshot.selectedText == text
        case .wholeField: return snapshot.value == text
        }
    }

    /// Added to the question, so the model has the exact words.
    var contextLine: String {
        let place = appName.map { " in \($0)" } ?? ""
        switch scope {
        case .selection:
            return "The user has highlighted this text\(place): «\(text)». If they ask to rephrase, rewrite, shorten, fix, polish or translate it, call write_in_place with the complete new text."
        case .wholeField:
            return "The text box the user's cursor is in\(place) holds this text: «\(text)». If they ask to rephrase, rewrite, shorten, fix, polish or translate it (\"this email\", \"this\", \"what i wrote\"), call write_in_place with the complete new text."
        }
    }

    /// Reads the target from the app in front. Right after the typed composer closes, OpenClicky
    /// is still in front for a moment while the previous app comes back, so this waits for it.
    @MainActor
    static func captureFromFrontApp() async -> WritingTarget? {
        let ownProcessID = ProcessInfo.processInfo.processIdentifier
        for _ in 0..<6 {
            if NSWorkspace.shared.frontmostApplication?.processIdentifier != ownProcessID { break }
            try? await Task.sleep(for: .milliseconds(100))
        }
        var snapshot = FocusedFieldReader.snapshot()
        // A browser builds a page's accessibility tree on the first request, which comes back with
        // nothing focused (Safari, a freshly opened compose window): asked again a moment later, it
        // answers with the text box.
        for _ in 0..<2 where snapshot.role == nil && snapshot.appBundleID != nil {
            try? await Task.sleep(for: .milliseconds(250))
            snapshot = FocusedFieldReader.snapshot()
        }
        let capturedTarget = target(in: snapshot)
        // What the text box looked like, never its words: enough to see why nothing was offered.
        AppLog.append("write in place: \(capturedTarget.map { "\($0.scope == .selection ? "highlight" : "whole box") of \($0.text.count) chars" } ?? "no target") in \(snapshot.appName ?? "?"), role \(snapshot.role ?? "none"), editable \(snapshot.isEditable), value \(snapshot.value?.count ?? -1) chars")
        return capturedTarget
    }
}

enum WriteInPlace {
    static let toolName = "write_in_place"

    /// The ask lane's tool, in Anthropic's shape (plans get it through PlanToolProtocol's list).
    static func anthropicToolDefinition() -> [String: Any] {
        [
            "name": toolName,
            "description": "Replace the text the user is working on (the highlighted text, or the text box their cursor is in, quoted in the question) with your rewritten version. Use it when they ask you to rephrase, rewrite, shorten, fix, polish or translate that text. It replaces the old text straight away.",
            "input_schema": [
                "type": "object",
                "properties": [
                    "text": ["type": "string", "description": "The complete new text, exactly as it should appear. Keep their meaning, names and greeting style, and the same language unless they asked for another. Plain text with line breaks, no quotes around it, no em dashes."],
                ],
                "required": ["text"],
            ] as [String: Any],
        ]
    }

    /// Added to the ask prompt when the tool is offered.
    static let promptInstruction = """
    writing in place: when the user asks you to rephrase, rewrite, shorten, fix or translate the text quoted as highlighted or in their text box, call write_in_place with the complete new text, and say only a few words about what you changed (for example "made it warmer and shorter."). openclicky puts it in their email and tells them how to undo it. never read the new text out.
    """

    enum Outcome: Equatable {
        case replaced
        /// Pasted, but the box could not be read back to confirm it.
        case probablyReplaced
        /// Focus moved, or the text changed, since the question: nothing was pasted.
        case targetGone
        /// Nothing editable had focus after the paste: the new version is left on the clipboard.
        case leftOnClipboard
        case noAccessibility
        case emptyText

        var didReplace: Bool { self == .replaced || self == .probablyReplaced }

        var spokenSentence: String {
            switch self {
            case .replaced, .probablyReplaced:
                return "it's in place. press command z if you want yours back."
            case .targetGone:
                return "you moved on before i finished, so i didn't change anything. click back into the text and ask again."
            case .leftOnClipboard:
                return "i couldn't put it in, so the new version is on your clipboard. press command v where you want it."
            case .noAccessibility:
                return "i need accessibility permission to write it in. it's in system settings, privacy and security, accessibility."
            case .emptyText:
                return "i didn't get a new version to put in. please ask again."
            }
        }
    }

    /// Replaces the target with `newText`: selects the box's text when the whole box is the target,
    /// pastes, checks it landed, and leaves the original on the clipboard.
    @MainActor
    static func replace(_ target: WritingTarget, with newText: String) async -> Outcome {
        guard !newText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return .emptyText }
        let trimmedNewText = keepingSurroundingSpace(of: target.text, around: newText)
        guard AXIsProcessTrusted() else { return .noAccessibility }
        let before = FocusedFieldReader.snapshot()
        guard target.stillMatches(before) else {
            AppLog.append("write in place: the target moved, nothing pasted")
            return .targetGone
        }
        if target.scope == .wholeField {
            // ⌘A in a focused text box selects only that box (in Gmail, the message body).
            postSelectAll()
            try? await Task.sleep(for: .milliseconds(120))
        }
        _ = FrontAppTextInserter.insert(trimmedNewText)
        let landing = await PasteLanding.verify(text: trimmedNewText, before: before)
        if landing == .noTarget {
            FrontAppTextInserter.copyToPasteboard(trimmedNewText)
            AppLog.append("write in place: nothing editable after the paste, the new text is on the clipboard")
            return .leftOnClipboard
        }
        // The person's own words stay one ⌘V away, after the paste has read the clipboard.
        try? await Task.sleep(for: .milliseconds(400))
        FrontAppTextInserter.copyToPasteboard(target.text)
        AppLog.append("write in place: \(target.scope == .selection ? "selection" : "whole box") in \(target.appName ?? "an app"), \(landing)")
        switch landing {
        case .verified: return .replaced
        case .posted, .noTarget: return .probablyReplaced
        case .leftOnPasteboard: return .noAccessibility
        }
    }

    /// The new text with the spaces and line breaks the old text had at its ends: a triple-clicked
    /// paragraph comes with its line break, and a rewrite without it ran into the next line.
    nonisolated static func keepingSurroundingSpace(of originalText: String, around newText: String) -> String {
        let leading = originalText.prefix { $0.isWhitespace }
        let trailing = String(originalText.reversed().prefix { $0.isWhitespace }.reversed())
        return leading + newText.trimmingCharacters(in: .whitespacesAndNewlines) + trailing
    }

    private static func postSelectAll() {
        let virtualKeyCodeA: CGKeyCode = 0
        guard let eventSource = CGEventSource(stateID: .combinedSessionState),
              let keyDown = CGEvent(keyboardEventSource: eventSource, virtualKey: virtualKeyCodeA, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: eventSource, virtualKey: virtualKeyCodeA, keyDown: false) else { return }
        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
    }
}
