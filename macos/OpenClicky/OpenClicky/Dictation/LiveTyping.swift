//
//  LiveTyping.swift
//  OpenClicky
//
//  Live typing: when a take will not be polished by a model, its words are typed into the app in
//  front while the person is still speaking, instead of being pasted after the key comes up. The
//  partial transcript keeps revising its last words, so only settled words are typed, and typed
//  words are never taken back (deleting in a terminal is unsafe). Three pure pieces live here —
//  which words have settled, how a settled phrase is formatted, and how the final transcript is
//  lined up against what was already typed — plus the per-take bookkeeping the controller keeps.
//

import Foundation

/// Decides which words of a revising partial transcript have settled enough to type.
///
/// A word commits when it is not among the last `volatileTailWordCount` words of the latest
/// partial (the engines revise those most) and has stood unchanged at its position for at least
/// `requiredStableSeconds` of partial updates. Committed words are never retracted: when the engine
/// later revises one, the commit stands and new words carry on after it.
struct StableWordCommitter {
    /// The last words of a partial are still being heard; they never commit from a partial.
    static let volatileTailWordCount = 2
    /// How long a word must stay the same at its position before it is typed. Long enough for the
    /// engines' usual revisions ("whether" → "weather") to land, short enough to feel live.
    static let requiredStableSeconds: TimeInterval = 0.6

    /// Word sequences (normalised) that must not be split across two typed phrases, because the
    /// formatting that rewrites them (a multi-word dictionary alias) only sees one phrase at a time.
    var protectedPhrases: [[String]] = []
    /// Spoken shortcut triggers (normalised). A shortcut expands only when it is the whole take,
    /// so while everything said so far could still be one, nothing is typed.
    var takeStartTriggers: [[String]] = []

    /// The words committed so far, as the engine heard them.
    private(set) var committedWords: [String] = []

    private struct TrackedWord {
        var word: String
        var unchangedSince: Date
    }
    /// The words after the committed ones, in partial order, with when each last changed.
    private var trackedWords: [TrackedWord] = []

    init(protectedPhrases: [[String]] = [], takeStartTriggers: [[String]] = []) {
        self.protectedPhrases = protectedPhrases.filter { $0.count > 1 }
        self.takeStartTriggers = takeStartTriggers.filter { !$0.isEmpty }
    }

    /// Feeds one partial transcript; returns the words that settled with it (possibly none).
    mutating func observe(partial: String, at now: Date) -> [String] {
        let partialWords = Self.words(of: partial)
        let alignment = TranscriptAlignment.align(finalWords: partialWords, committedWords: committedWords)
        let uncommittedWords = alignment.remainingWords(of: partialWords)

        // Each position keeps its clock while it holds the same word; a revision restarts it.
        var updatedTrackedWords: [TrackedWord] = []
        for (position, word) in uncommittedWords.enumerated() {
            if position < trackedWords.count, trackedWords[position].word == word {
                updatedTrackedWords.append(trackedWords[position])
            } else {
                updatedTrackedWords.append(TrackedWord(word: word, unchangedSince: now))
            }
        }
        trackedWords = updatedTrackedWords

        if committedWords.isEmpty, couldStillBeASpokenShortcut(partialWords) { return [] }

        let positionsPastTheTail = max(0, uncommittedWords.count - Self.volatileTailWordCount)
        var settledCount = 0
        while settledCount < positionsPastTheTail,
              now.timeIntervalSince(trackedWords[settledCount].unchangedSince) >= Self.requiredStableSeconds {
            settledCount += 1
        }
        settledCount = shrinkSoNoProtectedPhraseIsSplit(settledCount: settledCount, uncommittedWords: uncommittedWords)
        guard settledCount > 0 else { return [] }

        let newlyCommittedWords = Array(uncommittedWords.prefix(settledCount))
        committedWords.append(contentsOf: newlyCommittedWords)
        trackedWords.removeFirst(settledCount)
        return newlyCommittedWords
    }

    /// The words of a partial that are not committed yet (what the orb still shows).
    func uncommittedTail(of partial: String) -> String {
        let partialWords = Self.words(of: partial)
        let alignment = TranscriptAlignment.align(finalWords: partialWords, committedWords: committedWords)
        return alignment.remainingWords(of: partialWords).joined(separator: " ")
    }

    static func words(of text: String) -> [String] {
        text.split(whereSeparator: { $0.isWhitespace }).map(String.init)
    }

    /// Everything said so far is a beginning (or all) of some trigger.
    private func couldStillBeASpokenShortcut(_ partialWords: [String]) -> Bool {
        let spoken = partialWords.map { TranscriptAlignment.normalizedWord($0) }
        return takeStartTriggers.contains { trigger in
            spoken.count <= trigger.count && Array(trigger.prefix(spoken.count)) == spoken
        }
    }

    /// Steps the commit back while its last words are the beginning, but not the whole, of a
    /// protected phrase: "aditya" waits for a possible "shatriya" so the alias is replaced whole.
    private func shrinkSoNoProtectedPhraseIsSplit(settledCount: Int, uncommittedWords: [String]) -> Int {
        var count = settledCount
        while count > 0 {
            let wouldBeCommitted = (committedWords + uncommittedWords.prefix(count)).map { TranscriptAlignment.normalizedWord($0) }
            let endsInsideAProtectedPhrase = protectedPhrases.contains { phrase in
                (1..<phrase.count).contains { prefixLength in
                    wouldBeCommitted.count >= prefixLength
                        && Array(wouldBeCommitted.suffix(prefixLength)) == Array(phrase.prefix(prefixLength))
                }
            }
            guard endsInsideAProtectedPhrase else { break }
            count -= 1
        }
        return count
    }
}

/// Formats one settled phrase with the parts of `TakeFormatter`'s local pass that do not need the
/// whole take — fillers, dictionary terms, sentence case — and spaces it against what was typed.
enum LivePhraseFormatter {
    /// The exact text to type for a phrase: its leading space (when one is needed) included.
    /// `isEntireTake` is true only when these words are everything that was said: a spoken shortcut
    /// expands then and only then, as in `TakeFormatter.formatLocally`.
    static func textToType(phraseWords: [String], context: TakeFormattingContext, typedSoFar: String, isEntireTake: Bool) -> String {
        let phrase = TakeFormatter.collapseWhitespace(phraseWords.joined(separator: " "))
        guard !phrase.isEmpty else { return "" }

        var text: String
        if isEntireTake, typedSoFar.isEmpty, let shortcut = TakeFormatter.matchingShortcut(for: phrase, in: context.shortcuts) {
            text = shortcut.replacement
        } else {
            text = phrase
            if context.style.removeFillers { text = TakeFormatter.removeFillers(from: text) }
            text = TakeFormatter.applyDictionary(to: text, terms: context.dictionary)
            if context.style.sentenceCase {
                text = TakeFormatter.sentenceCased(text, startingAtSentenceStart: typedSoFarEndsASentence(typedSoFar))
            }
        }
        guard !text.isEmpty else { return "" }
        return needsSeparatingSpace(typedSoFar: typedSoFar, next: text) ? " " + text : text
    }

    /// The take's start, or after ".", "!", "?" or a new line: where `TakeFormatter.sentenceCased`
    /// would capitalise.
    static func typedSoFarEndsASentence(_ typedSoFar: String) -> Bool {
        let trimmed = typedSoFar.trimmingCharacters(in: CharacterSet(charactersIn: " \t"))
        guard let last = trimmed.last else { return true }
        return ".!?\n".contains(last)
    }

    /// One space between phrases, none at the start of the take, after whitespace already typed,
    /// or before punctuation that attaches to the previous word.
    static func needsSeparatingSpace(typedSoFar: String, next: String) -> Bool {
        guard let lastTyped = typedSoFar.last, let firstNext = next.first else { return false }
        if lastTyped.isWhitespace || firstNext.isWhitespace { return false }
        return !",.;:!?)]}".contains(firstNext)
    }
}

/// Lines a transcript up against the words already committed, to find what is left to type.
struct TranscriptAlignment: Equatable {
    /// Where the not-yet-typed words begin in the transcript.
    let remainderStartIndex: Int
    /// The committed words were found in the transcript; false when the engine revised them and
    /// the remainder simply starts after as many words as were committed.
    let alignedByWords: Bool

    /// How many committed words at the end are searched for when the start no longer matches.
    static let trailingRunLength = 3

    func remainingWords(of words: [String]) -> [String] {
        guard remainderStartIndex < words.count else { return [] }
        return Array(words[remainderStartIndex...])
    }

    /// Case and punctuation do not count: "Hello," lines up with "hello".
    static func normalizedWord(_ word: String) -> String {
        TakeFormatter.normalizedForMatching(word)
    }

    static func align(finalWords: [String], committedWords: [String]) -> TranscriptAlignment {
        guard !committedWords.isEmpty else { return TranscriptAlignment(remainderStartIndex: 0, alignedByWords: true) }
        let finalNormalized = finalWords.map { normalizedWord($0) }
        let committedNormalized = committedWords.map { normalizedWord($0) }

        // The usual case: the transcript starts with exactly the committed words.
        if finalNormalized.count >= committedNormalized.count,
           Array(finalNormalized.prefix(committedNormalized.count)) == committedNormalized {
            return TranscriptAlignment(remainderStartIndex: committedNormalized.count, alignedByWords: true)
        }

        // A word was added or dropped earlier on: find the committed words' last few in the
        // transcript, nearest to where they would have been.
        let runLength = min(trailingRunLength, committedNormalized.count)
        let trailingRun = Array(committedNormalized.suffix(runLength))
        if runLength > 0, finalNormalized.count >= runLength {
            let candidateEnds = (runLength...finalNormalized.count).filter { end in
                Array(finalNormalized[(end - runLength)..<end]) == trailingRun
            }
            if let nearestEnd = candidateEnds.min(by: { abs($0 - committedNormalized.count) < abs($1 - committedNormalized.count) }) {
                return TranscriptAlignment(remainderStartIndex: nearestEnd, alignedByWords: true)
            }
        }

        // The engine revised words that were already typed. Never retype or delete: carry on after
        // as many words as were committed.
        return TranscriptAlignment(remainderStartIndex: min(committedNormalized.count, finalWords.count), alignedByWords: false)
    }
}

/// One take's live typing, as the controller keeps it.
struct LiveTypingSession {
    var committer: StableWordCommitter
    /// The app the take began in; nothing is typed anywhere else.
    let appBundleID: String
    /// The take's style, dictionary and shortcuts, read at press.
    let formattingContext: TakeFormattingContext
    /// Everything typed so far, exactly as typed.
    var typedText = ""
    /// The engine's words behind `typedText` (what the final transcript is lined up against).
    var typedRawWords: [String] = []
    var typedPhraseCount = 0
    /// Why typing stopped before the take ended (the app changed, secure input came on, keystrokes
    /// could not be posted); nil while it may continue.
    var stoppedReason: String?

    /// Anything reached the app: from here on the take finishes by typing, not by pasting.
    var hasTyped: Bool { typedPhraseCount > 0 }
}
