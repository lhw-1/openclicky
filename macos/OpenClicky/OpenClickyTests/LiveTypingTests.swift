//
//  LiveTypingTests.swift
//  OpenClickyTests
//
//  The pure parts of live typing: which words of a revising partial transcript have settled, how a
//  settled phrase is formatted and spaced, and how the final transcript is lined up against what
//  was already typed.
//

import CoreGraphics
import Foundation
import Testing
@testable import OpenClicky

struct StableWordCommitterTests {
    private let start = Date(timeIntervalSince1970: 1_000)
    private func at(_ seconds: Double) -> Date { start.addingTimeInterval(seconds) }

    @Test func nothingCommitsBeforeTheWordsHaveBeenStableLongEnough() {
        var committer = StableWordCommitter(timing: .algorithmTests)
        #expect(committer.observe(partial: "hello there my friend", at: at(0)).isEmpty)
        #expect(committer.observe(partial: "hello there my friend", at: at(0.3)).isEmpty)
        #expect(committer.committedWords.isEmpty)
    }

    @Test func onlyWordsOlderThanTheVolatileTailCommit() {
        var committer = StableWordCommitter(timing: .algorithmTests)
        _ = committer.observe(partial: "hello there my friend", at: at(0))
        let committed = committer.observe(partial: "hello there my friend", at: at(0.7))
        // The last two words of the partial can still be revised; they wait.
        #expect(committed == ["hello", "there"])
        #expect(committer.committedWords == ["hello", "there"])
        #expect(committer.uncommittedTail(of: "hello there my friend") == "my friend")
    }

    @Test func aRevisedWordRestartsItsClock() {
        var committer = StableWordCommitter(timing: .algorithmTests)
        _ = committer.observe(partial: "the whether is nice today", at: at(0))
        // "whether" is revised to "weather" at 0.5 s: only "the" has been stable for 0.6 s at 0.7 s.
        _ = committer.observe(partial: "the weather is nice today", at: at(0.5))
        #expect(committer.observe(partial: "the weather is nice today", at: at(0.7)) == ["the"])
        #expect(committer.observe(partial: "the weather is nice today", at: at(1.2)) == ["weather", "is"])
    }

    @Test func committedWordsAreNeverRetracted() {
        var committer = StableWordCommitter(timing: .algorithmTests)
        _ = committer.observe(partial: "send it to bob now please", at: at(0))
        _ = committer.observe(partial: "send it to bob now please", at: at(0.7))
        #expect(committer.committedWords == ["send", "it", "to", "bob"])
        // The engine revises an already committed word: the commit stands, and nothing more commits
        // while the partial no longer lines up with what was typed.
        #expect(committer.observe(partial: "send it to rob now please and thanks", at: at(0.8)).isEmpty)
        #expect(committer.committedWords == ["send", "it", "to", "bob"])
        // Once it lines up again, the settled words after it carry on.
        let more = committer.observe(partial: "send it to bob now please and thanks", at: at(1.5))
        #expect(more == ["now", "please"])
        #expect(committer.committedWords == ["send", "it", "to", "bob", "now", "please"])
    }

    @Test func aShorterPartialDoesNotLoseCommittedWords() {
        var committer = StableWordCommitter(timing: .algorithmTests)
        _ = committer.observe(partial: "one two three four", at: at(0))
        _ = committer.observe(partial: "one two three four", at: at(0.7))
        #expect(committer.observe(partial: "one", at: at(0.9)).isEmpty)
        #expect(committer.committedWords == ["one", "two"])
    }

    @Test func aMultiWordDictionaryAliasIsNotSplitAcrossPhrases() {
        var committer = StableWordCommitter(protectedPhrases: [["aditya", "shatriya"]], timing: .algorithmTests)
        _ = committer.observe(partial: "ask aditya shatriya about it", at: at(0))
        // "ask aditya shatriya" are stable and past the tail, so all three commit together.
        #expect(committer.observe(partial: "ask aditya shatriya about it", at: at(0.7)) == ["ask", "aditya", "shatriya"])

        var holding = StableWordCommitter(protectedPhrases: [["aditya", "shatriya"]], timing: .algorithmTests)
        _ = holding.observe(partial: "ask aditya shatriya now", at: at(0))
        // Only "ask aditya" is past the tail; "aditya" might begin the alias, so it waits.
        #expect(holding.observe(partial: "ask aditya shatriya now", at: at(0.7)) == ["ask"])
    }

    @Test func aTakeThatMightStillBeASpokenShortcutWaits() {
        var committer = StableWordCommitter(takeStartTriggers: [["my", "sign", "off", "please"]], timing: .algorithmTests)
        _ = committer.observe(partial: "my sign off", at: at(0))
        #expect(committer.observe(partial: "my sign off", at: at(0.7)).isEmpty)
        #expect(committer.observe(partial: "my sign off please", at: at(0.75)).isEmpty)
        // Longer than the trigger: no longer a shortcut, so the settled words go.
        #expect(committer.observe(partial: "my sign off please send", at: at(0.8)) == ["my", "sign", "off"])
        _ = committer.observe(partial: "my sign off please send it now", at: at(0.9))
        _ = committer.observe(partial: "my sign off please send it now", at: at(1.6))
        #expect(committer.committedWords == ["my", "sign", "off", "please", "send"])
    }
}

struct LivePhraseFormatterTests {
    private func context(style: DictationStyle? = nil, dictionary: [DictionaryTerm] = [], shortcuts: [SpokenShortcut] = []) -> TakeFormattingContext {
        TakeFormattingContext(
            style: style ?? DictationStyle.seeded().first { $0.id == "other" }!,
            dictionary: dictionary, shortcuts: shortcuts, appName: "Terminal", language: .auto, script: .native)
    }

    @Test func theFirstPhraseOfATakeIsCapitalisedLikeAFinishedTake() {
        let text = LivePhraseFormatter.textToType(phraseWords: ["git", "status"], context: context(), typedSoFar: "")
        #expect(text == "Git status")
    }

    @Test func laterPhrasesGetASpaceAndKeepTheirCase() {
        let text = LivePhraseFormatter.textToType(phraseWords: ["and", "then"], context: context(), typedSoFar: "Hello there")
        #expect(text == " and then")
    }

    @Test func aPhraseAfterASentenceEndIsCapitalised() {
        let text = LivePhraseFormatter.textToType(phraseWords: ["how", "are", "you"], context: context(), typedSoFar: "Hello there.")
        #expect(text == " How are you")
    }

    @Test func noSpaceIsAddedAfterExistingWhitespaceOrBeforePunctuation() {
        #expect(LivePhraseFormatter.textToType(phraseWords: ["next"], context: context(), typedSoFar: "Hello\n") == "Next")
        #expect(LivePhraseFormatter.textToType(phraseWords: [",", "then"], context: context(), typedSoFar: "Hello") == ", then")
    }

    @Test func dictionaryTermsAndFillersAreApplied() {
        let term = DictionaryTerm(written: "Aaditya Kshatriya", heardAs: ["aditya shatriya"])
        let text = LivePhraseFormatter.textToType(phraseWords: ["um", "ask", "aditya", "shatriya"], context: context(dictionary: [term]), typedSoFar: "")
        #expect(text == "Ask Aaditya Kshatriya")
    }

    @Test func aPhraseOfOnlyFillersTypesNothing() {
        #expect(LivePhraseFormatter.textToType(phraseWords: ["um"], context: context(), typedSoFar: "Hello") == "")
    }

    @Test func aSpokenShortcutIsNeverExpandedInATypedPhrase() {
        // Whole-take shortcuts always take the paste path; inside a typed take a trigger is words.
        let shortcut = SpokenShortcut(trigger: "my sign-off", replacement: "Warm regards,\nPrasanth")
        let inside = LivePhraseFormatter.textToType(phraseWords: ["my", "sign", "off"], context: context(shortcuts: [shortcut]), typedSoFar: "Add")
        #expect(inside == " my sign off")
    }

    @Test func controlCharactersAreDetected() {
        #expect(LivePhraseFormatter.containsControlCharacters("line one\nline two"))
        #expect(LivePhraseFormatter.containsControlCharacters("tab\there"))
        #expect(LivePhraseFormatter.containsControlCharacters("escape \u{1B}[A"))
        #expect(LivePhraseFormatter.containsControlCharacters("zero\u{200B}width"))
        #expect(!LivePhraseFormatter.containsControlCharacters(" Hello, there! 25 kg — ok"))
    }

    @Test func theCasualStyleStaysLowercase() {
        let casual = DictationStyle.seeded().first { $0.id == "personal-messaging" }!
        #expect(LivePhraseFormatter.textToType(phraseWords: ["lemme", "know"], context: context(style: casual), typedSoFar: "") == "lemme know")
    }
}

struct TranscriptAlignmentTests {
    @Test func theRemainderIsWhatFollowsTheCommittedWords() {
        let alignment = TranscriptAlignment.align(finalWords: ["Hello,", "there", "my", "friend."], committedWords: ["hello", "there"])
        #expect(alignment.remainderStartIndex == 2)
        #expect(alignment.alignedByWords)
        #expect(alignment.remainingWords(of: ["Hello,", "there", "my", "friend."]) == ["my", "friend."])
    }

    @Test func nothingCommittedMeansEverythingRemains() {
        let alignment = TranscriptAlignment.align(finalWords: ["a", "b"], committedWords: [])
        #expect(alignment.remainderStartIndex == 0)
    }

    @Test func aWordInsertedBeforeTheCommittedEndIsFoundByTheTrailingRun() {
        // The engine added "oh" at the start; the committed words still end at "the meeting".
        let final = ["oh", "move", "the", "meeting", "to", "friday"]
        let alignment = TranscriptAlignment.align(finalWords: final, committedWords: ["move", "the", "meeting"])
        #expect(alignment.remainderStartIndex == 4)
        #expect(alignment.remainingWords(of: final) == ["to", "friday"])
    }

    @Test func revisedCommittedWordsLeaveEverythingAfterTheLastMatchForThePasteboard() {
        // "bob" became "rob": nothing lines up, so nothing is typed blind; the words after the
        // last matching one are what the person gets to paste.
        let final = ["send", "it", "to", "rob", "now", "please"]
        let alignment = TranscriptAlignment.align(finalWords: final, committedWords: ["send", "it", "to", "bob"])
        #expect(!alignment.alignedByWords)
        #expect(alignment.remainingWords(of: final) == ["rob", "now", "please"])
    }

    @Test func numbersRewrittenAtTheTailLoseNoWords() {
        let final = ["I", "have", "25", "apples", "and", "three", "oranges."]
        let alignment = TranscriptAlignment.align(finalWords: final, committedWords: ["I", "have", "twenty", "five", "apples", "and"])
        #expect(alignment.alignedByWords)
        #expect(alignment.remainingWords(of: final) == ["three", "oranges."])
    }

    @Test func gonnaWrittenOutAsGoingToLosesNoWords() {
        let final = ["I'm", "going", "to", "go", "home", "now"]
        let alignment = TranscriptAlignment.align(finalWords: final, committedWords: ["I'm", "gonna", "go"])
        #expect(alignment.alignedByWords)
        #expect(alignment.remainingWords(of: final) == ["home", "now"])
    }

    @Test func aMatchFarFromWhereTheWordsShouldBeIsNotTrusted() {
        // "go" appears, but nine words past where the committed words end: not a match.
        let final = ["we", "will", "see", "a", "b", "c", "d", "e", "f", "g", "h", "go"]
        let alignment = TranscriptAlignment.align(finalWords: final, committedWords: ["I'm", "gonna", "go"])
        #expect(!alignment.alignedByWords)
        #expect(alignment.remainingWords(of: final) == final)
    }

    @Test func aFinalShorterThanTheCommittedWordsLeavesNothing() {
        let final = ["send", "it"]
        let alignment = TranscriptAlignment.align(finalWords: final, committedWords: ["send", "it", "to", "bob"])
        #expect(alignment.remainingWords(of: final).isEmpty)
    }
}

struct KeyboardTextChunkingTests {
    @Test func textIsCutIntoChunksOfAtMostTwentyUTF16Units() {
        let text = String(repeating: "abcde", count: 9)
        let chunks = FrontAppTextInserter.keyboardChunks(of: text)
        #expect(chunks.joined() == text)
        #expect(chunks.allSatisfy { $0.utf16.count <= 20 })
        #expect(chunks.count == 3)
    }

    @Test func surrogatePairsAreNeverSplit() {
        let text = String(repeating: "a", count: 19) + "😀" + "b"
        let chunks = FrontAppTextInserter.keyboardChunks(of: text)
        #expect(chunks.joined() == text)
        #expect(chunks.allSatisfy { $0.utf16.count <= 20 })
        #expect(chunks.first == String(repeating: "a", count: 19))
    }
}

struct LiveTypingDecisionTests {
    @Test func onlyRealTextRolesAreTypedInto() {
        for role in ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField"] {
            #expect(FocusedTextTarget.isLiveTypingTextRole(role))
        }
        // A web page that has focus turns letters into single-key shortcuts (Gmail's e, #, !).
        for role in ["AXWebArea", "AXGroup", "AXStaticText", "AXUnknown"] {
            #expect(!FocusedTextTarget.isLiveTypingTextRole(role))
        }
        #expect(!FocusedTextTarget.isLiveTypingTextRole(nil))
    }

    @Test func onlyTheDictationKeysOwnModifierMayBeHeldWhileTyping() {
        #expect(LiveTypingModifierGuard.allowsTyping(heldFlags: [], dictationKey: .fn))
        #expect(LiveTypingModifierGuard.allowsTyping(heldFlags: .maskSecondaryFn, dictationKey: .fn))
        #expect(LiveTypingModifierGuard.allowsTyping(heldFlags: .maskControl, dictationKey: .rightControl))
        #expect(LiveTypingModifierGuard.allowsTyping(heldFlags: .maskCommand, dictationKey: .rightCommand))
        #expect(LiveTypingModifierGuard.allowsTyping(heldFlags: .maskAlternate, dictationKey: .rightOption))
        // Caps lock changes nothing about text posted as a unicode string.
        #expect(LiveTypingModifierGuard.allowsTyping(heldFlags: [.maskSecondaryFn, .maskAlphaShift], dictationKey: .fn))

        #expect(!LiveTypingModifierGuard.allowsTyping(heldFlags: [.maskSecondaryFn, .maskControl], dictationKey: .fn))
        #expect(!LiveTypingModifierGuard.allowsTyping(heldFlags: .maskCommand, dictationKey: .fn))
        #expect(!LiveTypingModifierGuard.allowsTyping(heldFlags: .maskShift, dictationKey: .rightControl))
        #expect(!LiveTypingModifierGuard.allowsTyping(heldFlags: .maskSecondaryFn, dictationKey: .rightCommand))
    }
}


extension StableWordCommitter.Timing {
    /// The values these algorithm tests were written against (two held-back words, 0.6 s).
    static let algorithmTests = StableWordCommitter.Timing(volatileTailWordCount: 2, requiredStableSeconds: 0.6, pauseSeconds: 60)
}

struct LiveTypingDefaultTimingTests {
    private let start = Date(timeIntervalSince1970: 1_000)

    @Test func theLiveTimingHoldsBackOneWordForAThirdOfASecond() {
        var committer = StableWordCommitter()
        _ = committer.observe(partial: "hello there friend", at: start)
        #expect(committer.observe(partial: "hello there friend", at: start.addingTimeInterval(0.2)).isEmpty)
        #expect(committer.observe(partial: "hello there friend", at: start.addingTimeInterval(0.35)) == ["hello", "there"])
    }
}

struct LiveTypingPauseTests {
    private let start = Date(timeIntervalSince1970: 1_000)

    @Test func afterAPauseTheLastWordIsReleasedToo() {
        var committer = StableWordCommitter()
        _ = committer.observe(partial: "this is a test message", at: start)
        #expect(committer.observe(partial: "this is a test message", at: start.addingTimeInterval(0.4)) == ["this", "is", "a", "test"])
        // No new words for a while: the person has paused, so "message" is settled.
        #expect(committer.observe(partial: "this is a test message", at: start.addingTimeInterval(1.0), personPaused: true) == ["message"])
    }

    @Test func aPauseStillWaitsForAWordThatJustChanged() {
        var committer = StableWordCommitter()
        _ = committer.observe(partial: "this is a test mess", at: start)
        _ = committer.observe(partial: "this is a test message", at: start.addingTimeInterval(0.9))
        #expect(committer.observe(partial: "this is a test message", at: start.addingTimeInterval(1.0), personPaused: true).isEmpty)
    }
}
