//
//  LiveTypingTests.swift
//  OpenClickyTests
//
//  The pure parts of live typing: which words of a revising partial transcript have settled, how a
//  settled phrase is formatted and spaced, and how the final transcript is lined up against what
//  was already typed.
//

import Foundation
import Testing
@testable import OpenClicky

struct StableWordCommitterTests {
    private let start = Date(timeIntervalSince1970: 1_000)
    private func at(_ seconds: Double) -> Date { start.addingTimeInterval(seconds) }

    @Test func nothingCommitsBeforeTheWordsHaveBeenStableLongEnough() {
        var committer = StableWordCommitter()
        #expect(committer.observe(partial: "hello there my friend", at: at(0)).isEmpty)
        #expect(committer.observe(partial: "hello there my friend", at: at(0.3)).isEmpty)
        #expect(committer.committedWords.isEmpty)
    }

    @Test func onlyWordsOlderThanTheVolatileTailCommit() {
        var committer = StableWordCommitter()
        _ = committer.observe(partial: "hello there my friend", at: at(0))
        let committed = committer.observe(partial: "hello there my friend", at: at(0.7))
        // The last two words of the partial can still be revised; they wait.
        #expect(committed == ["hello", "there"])
        #expect(committer.committedWords == ["hello", "there"])
        #expect(committer.uncommittedTail(of: "hello there my friend") == "my friend")
    }

    @Test func aRevisedWordRestartsItsClock() {
        var committer = StableWordCommitter()
        _ = committer.observe(partial: "the whether is nice today", at: at(0))
        // "whether" is revised to "weather" at 0.5 s: only "the" has been stable for 0.6 s at 0.7 s.
        _ = committer.observe(partial: "the weather is nice today", at: at(0.5))
        #expect(committer.observe(partial: "the weather is nice today", at: at(0.7)) == ["the"])
        #expect(committer.observe(partial: "the weather is nice today", at: at(1.2)) == ["weather", "is"])
    }

    @Test func committedWordsAreNeverRetracted() {
        var committer = StableWordCommitter()
        _ = committer.observe(partial: "send it to bob now please", at: at(0))
        _ = committer.observe(partial: "send it to bob now please", at: at(0.7))
        #expect(committer.committedWords == ["send", "it", "to", "bob"])
        // The engine revises an already committed word: the commit stands, and the words after it
        // ("now please", unchanged since 0 s and now clear of the tail) carry on after it.
        let more = committer.observe(partial: "send it to rob now please and thanks", at: at(0.8))
        #expect(more == ["now", "please"])
        #expect(committer.committedWords == ["send", "it", "to", "bob", "now", "please"])
        #expect(committer.uncommittedTail(of: "send it to rob now please and thanks") == "and thanks")
    }

    @Test func aShorterPartialDoesNotLoseCommittedWords() {
        var committer = StableWordCommitter()
        _ = committer.observe(partial: "one two three four", at: at(0))
        _ = committer.observe(partial: "one two three four", at: at(0.7))
        #expect(committer.observe(partial: "one", at: at(0.9)).isEmpty)
        #expect(committer.committedWords == ["one", "two"])
    }

    @Test func aMultiWordDictionaryAliasIsNotSplitAcrossPhrases() {
        var committer = StableWordCommitter(protectedPhrases: [["aditya", "shatriya"]])
        _ = committer.observe(partial: "ask aditya shatriya about it", at: at(0))
        // "ask aditya shatriya" are stable and past the tail, so all three commit together.
        #expect(committer.observe(partial: "ask aditya shatriya about it", at: at(0.7)) == ["ask", "aditya", "shatriya"])

        var holding = StableWordCommitter(protectedPhrases: [["aditya", "shatriya"]])
        _ = holding.observe(partial: "ask aditya shatriya now", at: at(0))
        // Only "ask aditya" is past the tail; "aditya" might begin the alias, so it waits.
        #expect(holding.observe(partial: "ask aditya shatriya now", at: at(0.7)) == ["ask"])
    }

    @Test func aTakeThatMightStillBeASpokenShortcutWaits() {
        var committer = StableWordCommitter(takeStartTriggers: [["my", "sign", "off", "please"]])
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
        let text = LivePhraseFormatter.textToType(phraseWords: ["git", "status"], context: context(), typedSoFar: "", isEntireTake: false)
        #expect(text == "Git status")
    }

    @Test func laterPhrasesGetASpaceAndKeepTheirCase() {
        let text = LivePhraseFormatter.textToType(phraseWords: ["and", "then"], context: context(), typedSoFar: "Hello there", isEntireTake: false)
        #expect(text == " and then")
    }

    @Test func aPhraseAfterASentenceEndIsCapitalised() {
        let text = LivePhraseFormatter.textToType(phraseWords: ["how", "are", "you"], context: context(), typedSoFar: "Hello there.", isEntireTake: false)
        #expect(text == " How are you")
    }

    @Test func noSpaceIsAddedAfterExistingWhitespaceOrBeforePunctuation() {
        #expect(LivePhraseFormatter.textToType(phraseWords: ["next"], context: context(), typedSoFar: "Hello\n", isEntireTake: false) == "Next")
        #expect(LivePhraseFormatter.textToType(phraseWords: [",", "then"], context: context(), typedSoFar: "Hello", isEntireTake: false) == ", then")
    }

    @Test func dictionaryTermsAndFillersAreApplied() {
        let term = DictionaryTerm(written: "Aaditya Kshatriya", heardAs: ["aditya shatriya"])
        let text = LivePhraseFormatter.textToType(phraseWords: ["um", "ask", "aditya", "shatriya"], context: context(dictionary: [term]), typedSoFar: "", isEntireTake: false)
        #expect(text == "Ask Aaditya Kshatriya")
    }

    @Test func aPhraseOfOnlyFillersTypesNothing() {
        #expect(LivePhraseFormatter.textToType(phraseWords: ["um"], context: context(), typedSoFar: "Hello", isEntireTake: false) == "")
    }

    @Test func aSpokenShortcutExpandsOnlyWhenItIsTheWholeTake() {
        let shortcut = SpokenShortcut(trigger: "my sign-off", replacement: "Warm regards,\nPrasanth")
        let whole = LivePhraseFormatter.textToType(phraseWords: ["my", "sign", "off."], context: context(shortcuts: [shortcut]), typedSoFar: "", isEntireTake: true)
        #expect(whole == "Warm regards,\nPrasanth")
        // Inside a longer take a trigger is just words, as in the finished-take formatter.
        let inside = LivePhraseFormatter.textToType(phraseWords: ["my", "sign", "off"], context: context(shortcuts: [shortcut]), typedSoFar: "Add", isEntireTake: false)
        #expect(inside == " my sign off")
    }

    @Test func theCasualStyleStaysLowercase() {
        let casual = DictationStyle.seeded().first { $0.id == "personal-messaging" }!
        #expect(LivePhraseFormatter.textToType(phraseWords: ["lemme", "know"], context: context(style: casual), typedSoFar: "", isEntireTake: false) == "lemme know")
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

    @Test func revisedCommittedWordsFallBackToTheCommittedCount() {
        let final = ["send", "it", "to", "rob", "now", "please"]
        let alignment = TranscriptAlignment.align(finalWords: final, committedWords: ["send", "it", "to", "bob"])
        #expect(!alignment.alignedByWords)
        #expect(alignment.remainingWords(of: final) == ["now", "please"])
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
