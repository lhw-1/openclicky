//
//  WriteInPlaceTests.swift
//  OpenClickyTests
//
//  "Rephrase this": which text a rewrite replaces, that it is never pasted once focus has moved,
//  and what the model is told.
//

import Testing
@testable import OpenClicky

struct WriteInPlaceTests {
    private func field(value: String? = nil, selected: String? = nil, editable: Bool = true, secure: Bool = false,
                       app: String = "com.google.Chrome") -> FocusedFieldSnapshot {
        FocusedFieldSnapshot(appBundleID: app, appName: "Google Chrome", role: "AXTextArea", isEditable: editable,
                             isSecure: secure, value: value, selectedText: selected)
    }

    @Test func aHighlightIsTheTarget() {
        let target = WritingTarget.target(in: field(value: "Hi Ravi, see you at 5. Amma", selected: "see you at 5."), ownBundleID: "org.openclicky.app")
        #expect(target?.scope == .selection)
        #expect(target?.text == "see you at 5.")
    }

    @Test func withoutAHighlightTheWholeBoxIsTheTarget() {
        let target = WritingTarget.target(in: field(value: "Hi Ravi,\nsee you at 5.\nAmma"), ownBundleID: "org.openclicky.app")
        #expect(target?.scope == .wholeField)
        #expect(target?.text == "Hi Ravi,\nsee you at 5.\nAmma")
    }

    @Test func nothingToRewriteMeansNoTarget() {
        #expect(WritingTarget.target(in: field(value: "   "), ownBundleID: "x") == nil)
        #expect(WritingTarget.target(in: field(value: "secret", secure: true), ownBundleID: "x") == nil)
        #expect(WritingTarget.target(in: field(value: "a page", editable: false), ownBundleID: "x") == nil)
        #expect(WritingTarget.target(in: field(value: "my own window", app: "org.openclicky.app"), ownBundleID: "org.openclicky.app") == nil)
        #expect(WritingTarget.target(in: field(value: String(repeating: "a", count: WritingTarget.maximumCharacters + 1)), ownBundleID: "x") == nil)
    }

    @Test func itIsOnlyPastedIntoTheSameTextStill() {
        let target = WritingTarget(scope: .wholeField, text: "Hi Ravi", appBundleID: "com.google.Chrome", appName: "Google Chrome")
        #expect(target.stillMatches(field(value: "Hi Ravi")))
        #expect(!target.stillMatches(field(value: "Hi Ravi, also")))
        #expect(!target.stillMatches(field(value: "Hi Ravi", app: "com.apple.mail")))
        #expect(!target.stillMatches(field(value: "Hi Ravi", editable: false)))
        let highlighted = WritingTarget(scope: .selection, text: "at 5", appBundleID: "com.google.Chrome", appName: nil)
        #expect(highlighted.stillMatches(field(value: "see you at 5", selected: "at 5")))
        #expect(!highlighted.stillMatches(field(value: "see you at 5", selected: nil)))
    }

    @Test @MainActor func theQuestionCarriesTheExactWords() {
        let target = WritingTarget(scope: .wholeField, text: "Hi Ravi,\nsee you at 5.", appBundleID: "com.google.Chrome", appName: "Google Chrome")
        let prompt = CompanionManager.askUserPrompt(transcript: "can you rephrase this email", writingTarget: target)
        #expect(prompt.hasPrefix("can you rephrase this email"))
        #expect(prompt.contains("Hi Ravi,\nsee you at 5."))
        #expect(prompt.contains("in Google Chrome"))
        #expect(prompt.contains(WriteInPlace.toolName))
    }

    @Test func theToolAsksForTheWholeNewText() {
        let definition = WriteInPlace.anthropicToolDefinition()
        #expect(definition["name"] as? String == "write_in_place")
        let schema = definition["input_schema"] as? [String: Any]
        #expect(schema?["required"] as? [String] == ["text"])
    }

    @Test func theRewriteKeepsTheSpacingAroundTheOldText() {
        #expect(WriteInPlace.keepingSurroundingSpace(of: "sorry it took long.\n", around: "Sorry for the delay.") == "Sorry for the delay.\n")
        #expect(WriteInPlace.keepingSurroundingSpace(of: " at 5", around: "\nat five\n") == " at five")
        #expect(WriteInPlace.keepingSurroundingSpace(of: "hi ravi", around: "Hi Ravi,") == "Hi Ravi,")
    }

    @Test func eachOutcomeSaysWhatHappened() {
        #expect(WriteInPlace.Outcome.replaced.spokenSentence.contains("command z"))
        #expect(WriteInPlace.Outcome.targetGone.spokenSentence.contains("didn't change anything"))
        #expect(!WriteInPlace.Outcome.targetGone.didReplace)
        for outcome in [WriteInPlace.Outcome.replaced, .probablyReplaced, .targetGone, .leftOnClipboard, .noAccessibility, .emptyText] {
            #expect(!outcome.spokenSentence.contains("—"))
        }
    }
}
