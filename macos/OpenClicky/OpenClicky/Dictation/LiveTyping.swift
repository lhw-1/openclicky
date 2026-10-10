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

import CoreGraphics
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
        // The partial no longer lines up with what was committed (the engine rewrote typed words):
        // nothing more is committed blind; the final transcript decides at release.
        guard alignment.alignedByWords else { return [] }
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
    /// Spoken shortcuts are not applied: a shortcut expands only when it is the whole take, and a
    /// take that could still be one is held back (`StableWordCommitter.takeStartTriggers`) until it
    /// either grows past every trigger or ends, when it takes the paste path, which expands it.
    static func textToType(phraseWords: [String], context: TakeFormattingContext, typedSoFar: String) -> String {
        var text = TakeFormatter.collapseWhitespace(phraseWords.joined(separator: " "))
        guard !text.isEmpty else { return "" }
        if context.style.removeFillers { text = TakeFormatter.removeFillers(from: text) }
        text = TakeFormatter.applyDictionary(to: text, terms: context.dictionary)
        if context.style.sentenceCase {
            text = TakeFormatter.sentenceCased(text, startingAtSentenceStart: typedSoFarEndsASentence(typedSoFar))
        }
        guard !text.isEmpty else { return "" }
        return needsSeparatingSpace(typedSoFar: typedSoFar, next: text) ? " " + text : text
    }

    /// A line break, tab, escape or any other control (Cc) or format (Cf) character. Typed as a
    /// keystroke in a terminal a new line runs the command line, so such text is never typed; it
    /// goes to the pasteboard instead. A dictionary term's written form can carry one.
    static func containsControlCharacters(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            scalar.properties.generalCategory == .control || scalar.properties.generalCategory == .format
        }
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

    /// The longest run of committed words at the end that is searched for when the start no
    /// longer matches; shorter runs (2, then 1) are tried after it.
    static let longestTrailingRunLength = 3
    /// A run counts only if it ends this close to where the committed words would end: "go" nine
    /// words further on is another "go", not the one that was typed.
    static let maximumDistanceFromExpectedEnd = 3

    func remainingWords(of words: [String]) -> [String] {
        guard remainderStartIndex < words.count else { return [] }
        return Array(words[remainderStartIndex...])
    }

    /// Case and punctuation do not count: "Hello," lines up with "hello".
    static func normalizedWord(_ word: String) -> String {
        TakeFormatter.normalizedForMatching(word)
    }

    /// Where the not-yet-typed words of `finalWords` begin. When the committed words cannot be
    /// found (`alignedByWords` false), `remainderStartIndex` is the end of the longest common
    /// start: nothing after it can be typed safely (some of it may be typed words, rewritten), so
    /// the caller hands it to the person instead of skipping or repeating words.
    static func align(finalWords: [String], committedWords: [String]) -> TranscriptAlignment {
        guard !committedWords.isEmpty else { return TranscriptAlignment(remainderStartIndex: 0, alignedByWords: true) }
        let finalNormalized = finalWords.map { normalizedWord($0) }
        let committedNormalized = committedWords.map { normalizedWord($0) }
        let expectedEnd = committedNormalized.count

        // The usual case: the transcript starts with exactly the committed words.
        if finalNormalized.count >= expectedEnd, Array(finalNormalized.prefix(expectedEnd)) == committedNormalized {
            return TranscriptAlignment(remainderStartIndex: expectedEnd, alignedByWords: true)
        }

        // The engine rewrote words on the way ("twenty five" → "25", "gonna" → "going to"): find
        // the committed words' last 3, then 2, then 1 near where they should end.
        for runLength in stride(from: min(longestTrailingRunLength, expectedEnd), through: 1, by: -1) {
            let trailingRun = Array(committedNormalized.suffix(runLength))
            guard finalNormalized.count >= runLength else { continue }
            let nearbyEnds = (runLength...finalNormalized.count).filter { end in
                abs(end - expectedEnd) <= maximumDistanceFromExpectedEnd
                    && Array(finalNormalized[(end - runLength)..<end]) == trailingRun
            }
            if let nearestEnd = nearbyEnds.min(by: { abs($0 - expectedEnd) < abs($1 - expectedEnd) }) {
                return TranscriptAlignment(remainderStartIndex: nearestEnd, alignedByWords: true)
            }
        }

        // Nothing lines up: never retype, never delete, never skip. Everything after the last word
        // that still matches from the start is left for the person.
        var commonStartCount = 0
        while commonStartCount < min(finalNormalized.count, expectedEnd),
              finalNormalized[commonStartCount] == committedNormalized[commonStartCount] {
            commonStartCount += 1
        }
        return TranscriptAlignment(remainderStartIndex: commonStartCount, alignedByWords: false)
    }
}

/// Keystrokes posted while a modifier is physically held can merge with it: with right ⌃ as the
/// dictation key "m" became ⌃M (Return), with fn the A key became fn+A. Typing waits while any
/// modifier other than the dictation key's own is held.
enum LiveTypingModifierGuard {
    static let modifiersThatChangeKeystrokes: CGEventFlags = [.maskShift, .maskControl, .maskAlternate, .maskCommand, .maskSecondaryFn]

    static func ownModifier(of dictationKey: DictationHotkey) -> CGEventFlags {
        switch dictationKey {
        case .fn: return .maskSecondaryFn
        case .rightOption: return .maskAlternate
        case .rightCommand: return .maskCommand
        case .rightControl: return .maskControl
        }
    }

    static func allowsTyping(heldFlags: CGEventFlags, dictationKey: DictationHotkey) -> Bool {
        let heldModifiers = heldFlags.intersection(modifiersThatChangeKeystrokes)
        return heldModifiers.subtracting(ownModifier(of: dictationKey)).isEmpty
    }
}

/// One take's live typing, as the controller keeps it.
struct LiveTypingSession {
    var committer: StableWordCommitter
    /// The text field that had focus at press (element and pid, through Accessibility); nothing is
    /// typed anywhere else.
    let focusedTargetAtPress: FocusedTextTarget
    /// The take's style, dictionary and shortcuts, read at press.
    let formattingContext: TakeFormattingContext
    /// Everything typed so far, exactly as typed.
    var typedText = ""
    /// The engine's words behind `typedText` (what the final transcript is lined up against).
    var typedRawWords: [String] = []
    var typedPhraseCount = 0
    /// The latest partial transcript: what was heard, for the pasteboard if the take fails.
    var latestPartial = ""
    /// Why typing stopped before the take ended (the app changed, secure input came on, keystrokes
    /// could not be posted); nil while it may continue.
    var stoppedReason: String?

    /// Anything reached the app: from here on the take finishes by typing, not by pasting.
    var hasTyped: Bool { typedPhraseCount > 0 }
}
