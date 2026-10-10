//
//  SpokenChunker.swift
//  OpenClicky
//
//  Cuts Claude's streamed answer into pieces the voice can start on before the answer is finished.
//  The first sentence goes out the moment it ends, so the voice starts within a second or two of
//  the first words; later sentences are grouped (at least `laterChunkMinimum` characters) so a long
//  answer costs a handful of speech requests, not one per sentence.
//
//  The [POINT:…] tag is never spoken. The ask prompt puts it first, so the chunker holds the text
//  back until the tag is complete and records it in `pointTag`; a tag at the end (older prompts,
//  or a model that ignores the instruction) is found when the stream finishes.
//

import Foundation

struct SpokenChunker {
    /// The [POINT:…] tag, once it has been seen in full (leading, or trailing at `finish()`).
    private(set) var pointTag: String?

    private let laterChunkMinimum: Int
    /// How many characters of the accumulated answer have already been handed out (or skipped as the tag).
    private var consumedCharacterCount = 0
    private var hasEmittedFirstChunk = false
    private var leadingTagResolved = false
    private var latestAccumulatedText = ""

    init(laterChunkMinimum: Int = 120) {
        self.laterChunkMinimum = laterChunkMinimum
    }

    /// Takes the whole answer so far (ClaudeAPI reports accumulated text) and returns the pieces
    /// that are now ready to speak, in order.
    mutating func feed(accumulated accumulatedText: String) -> [String] {
        latestAccumulatedText = accumulatedText
        guard resolveLeadingTag(in: accumulatedText) else { return [] }

        var readyChunks: [String] = []
        while let chunk = nextCompleteChunk(in: accumulatedText) {
            readyChunks.append(chunk)
        }
        return readyChunks
    }

    /// The stream ended: whatever is left (minus a trailing tag) is the last piece.
    mutating func finish() -> [String] {
        let accumulatedText = latestAccumulatedText
        if !leadingTagResolved {
            // The answer ended while still looking like an unfinished tag: speak it as text.
            leadingTagResolved = true
        }
        var remainingText = String(accumulatedText.dropFirst(consumedCharacterCount))
        consumedCharacterCount = accumulatedText.count

        if pointTag == nil, let trailingTagRange = remainingText.range(of: Self.trailingTagPattern, options: .regularExpression) {
            pointTag = String(remainingText[trailingTagRange]).trimmingCharacters(in: .whitespacesAndNewlines)
            remainingText.removeSubrange(trailingTagRange)
        }
        let lastChunk = remainingText.trimmingCharacters(in: .whitespacesAndNewlines)
        return lastChunk.isEmpty ? [] : [lastChunk]
    }

    // MARK: - Private

    private static let completeLeadingTagPattern = #"^\s*\[POINT:[^\]]*\]"#
    private static let trailingTagPattern = #"\[POINT:[^\]]*\]\s*$"#

    /// True once speech may start: either the answer does not open with a tag, or the tag is complete.
    private mutating func resolveLeadingTag(in accumulatedText: String) -> Bool {
        if leadingTagResolved { return true }
        let trimmedStart = accumulatedText.drop { $0.isWhitespace }
        if trimmedStart.isEmpty { return false }
        // "[" or "[POI…" could still become a tag: wait for more text before deciding.
        if "[POINT:".hasPrefix(String(trimmedStart.prefix(7))) || trimmedStart.hasPrefix("[POINT:") {
            guard let tagRange = accumulatedText.range(of: Self.completeLeadingTagPattern, options: .regularExpression) else {
                return false
            }
            pointTag = String(accumulatedText[tagRange]).trimmingCharacters(in: .whitespacesAndNewlines)
            consumedCharacterCount = accumulatedText.distance(from: accumulatedText.startIndex, to: tagRange.upperBound)
        }
        leadingTagResolved = true
        return true
    }

    /// The next run of whole sentences long enough to send, or nil when the text so far has none.
    private mutating func nextCompleteChunk(in accumulatedText: String) -> String? {
        let unconsumedText = accumulatedText.dropFirst(consumedCharacterCount)
        let minimumLength = hasEmittedFirstChunk ? laterChunkMinimum : 1

        var searchStart = unconsumedText.startIndex
        while let boundary = Self.sentenceBoundary(in: unconsumedText, from: searchStart) {
            let candidate = unconsumedText[unconsumedText.startIndex..<boundary]
            let trimmedCandidate = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmedCandidate.count >= minimumLength {
                consumedCharacterCount += unconsumedText.distance(from: unconsumedText.startIndex, to: boundary)
                hasEmittedFirstChunk = true
                return trimmedCandidate
            }
            searchStart = boundary
        }
        return nil
    }

    /// The index just after a sentence end: ".", "!" or "?" followed by whitespace. A "." inside a
    /// number ("3.5") or at the very end of the text so far (more may follow) is not a boundary.
    private static func sentenceBoundary(in text: Substring, from startIndex: Substring.Index) -> Substring.Index? {
        var index = startIndex
        while index < text.endIndex {
            let character = text[index]
            let nextIndex = text.index(after: index)
            if ".!?".contains(character), nextIndex < text.endIndex, text[nextIndex].isWhitespace {
                return nextIndex
            }
            index = nextIndex
        }
        return nil
    }
}
