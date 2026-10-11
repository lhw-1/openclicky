//
//  PlanToolProtocol.swift
//  OpenClicky
//
//  Quick actions for the plan CLIs. `claude -p --tools ""` and `codex exec` run with no tools of
//  their own, so the request's quick-action tools cannot be offered the way an API offers them.
//  Instead the system prompt gets a block listing each tool (name, description, compact JSON
//  schema) and asking for a line of its own after the spoken words:
//
//    [ACTION: create_folder {"name":"test","location":"desktop"}]
//
//  `PlanToolProtocol.parse` takes those lines out of the finished answer and turns them into the
//  same `ClaudeToolCall`s an API returns, so `MacAction.parse` runs them unchanged. Models are not
//  exact about the format, so the parser tolerates a missing colon or space, a code fence around
//  the line, a missing closing bracket and punctuation after it; an unknown tool name or arguments
//  that are not a JSON object drop that action, never the answer. At most two actions are kept,
//  as the ask lane runs at most two.
//
//  `PlanActionLineFilter` does the same for streamed text before it reaches the voice: text from
//  a "[" is held back until it is clearly not an action tag, and a tag is dropped, so the voice
//  never reads one out. (SpokenChunker only knows the [POINT:…] tag.)
//

import Foundation

nonisolated enum PlanToolProtocol {
    static let maximumActionCount = 2
    static let actionTagOpening = "[ACTION"

    /// The block appended to the system prompt when the request offers tools; empty for none.
    static func instructionBlock(for tools: [AnswerRequest.Tool]) -> String {
        guard !tools.isEmpty else { return "" }
        var lines = [
            "Quick actions: you can do these things on the person's Mac yourself.",
            "To do one, write your spoken words first, then put the action on a line of its own:",
            "[ACTION: <action name> <arguments as one JSON object>]",
            "For example: [ACTION: some_action {\"argument\":\"value\"}]",
            "Use at most \(maximumActionCount) actions, only the ones listed below, with arguments that match their schema.",
            "Never explain, mention or read out the action line; say in plain words what you are doing.",
            "If no action fits, write no action line.",
            "Actions:",
        ]
        for tool in tools {
            lines.append("- \(tool.name): \(tool.description) Arguments: \(compactSchemaText(from: tool.inputSchemaJSON))")
        }
        return lines.joined(separator: "\n")
    }

    /// The system prompt the CLI gets: the request's own, then the actions block when there is one.
    static func systemPrompt(_ systemPrompt: String, offering tools: [AnswerRequest.Tool]) -> String {
        let block = instructionBlock(for: tools)
        guard !block.isEmpty else { return systemPrompt }
        let trimmedSystemPrompt = systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedSystemPrompt.isEmpty ? block : trimmedSystemPrompt + "\n\n" + block
    }

    /// The schema re-serialized with sorted keys and no spaces, so the prompt stays short and the
    /// same tools always give the same prompt. A schema that does not parse is passed as it is.
    static func compactSchemaText(from inputSchemaJSON: Data) -> String {
        guard let schemaObject = try? JSONSerialization.jsonObject(with: inputSchemaJSON),
              let compactData = try? JSONSerialization.data(withJSONObject: schemaObject, options: [.sortedKeys, .withoutEscapingSlashes]) else {
            return String(decoding: inputSchemaJSON, as: UTF8.self)
        }
        return String(decoding: compactData, as: UTF8.self)
    }

    /// The answer with every action tag taken out (and trimmed), and the actions it asked for.
    static func parse(answerText: String, knownToolNames: Set<String>) -> (text: String, toolCalls: [ClaudeToolCall]) {
        var remainingText = answerText
        var toolCalls: [ClaudeToolCall] = []
        var searchStart = remainingText.startIndex
        while let openingRange = remainingText.range(of: actionTagOpening, options: [.caseInsensitive], range: searchStart..<remainingText.endIndex) {
            let tagEnd = scanActionTag(in: remainingText, openingAt: openingRange.lowerBound).end
            let tagText = String(remainingText[openingRange.upperBound..<tagEnd])
            if toolCalls.count < maximumActionCount,
               let toolCall = toolCall(fromTagContent: tagText, knownToolNames: knownToolNames, callIndex: toolCalls.count) {
                toolCalls.append(toolCall)
            }
            // Punctuation right after the tag ("…}]." ) belonged to the tag, not to the answer.
            var removalEnd = tagEnd
            while removalEnd < remainingText.endIndex, ".,;!".contains(remainingText[removalEnd]) {
                removalEnd = remainingText.index(after: removalEnd)
            }
            let removalStart = openingRange.lowerBound
            remainingText.removeSubrange(removalStart..<removalEnd)
            searchStart = removalStart
        }
        return (text: cleanedText(afterRemovingTagsFrom: remainingText), toolCalls: toolCalls)
    }

    /// How a tag ended: its own "]", the end of its line (the model left the bracket off), or the
    /// end of the text so far (a streamed tag that may still be arriving).
    enum ActionTagEnding: Equatable {
        case closingBracket, lineBreak, endOfText
    }

    /// Where a tag that opens at `openingIndex` ends (exclusive) and how: just after the "]" that
    /// closes it outside the JSON (a "]" inside a JSON string or array does not count), else at the
    /// line break when the model left the bracket off.
    static func scanActionTag(in text: String, openingAt openingIndex: String.Index) -> (end: String.Index, ending: ActionTagEnding) {
        var braceDepth = 0
        var bracketDepthInsideJSON = 0
        var isInsideJSONString = false
        var previousCharacterWasEscape = false
        var currentIndex = text.index(openingIndex, offsetBy: actionTagOpening.count, limitedBy: text.endIndex) ?? text.endIndex
        while currentIndex < text.endIndex {
            let character = text[currentIndex]
            if character == "\n" {
                // A tag never spans lines; an unclosed quote or brace must not swallow the answer.
                return (currentIndex, .lineBreak)
            }
            if isInsideJSONString {
                if previousCharacterWasEscape {
                    previousCharacterWasEscape = false
                } else if character == "\\" {
                    previousCharacterWasEscape = true
                } else if character == "\"" {
                    isInsideJSONString = false
                }
            } else {
                switch character {
                case "\"" where braceDepth > 0: isInsideJSONString = true
                case "{": braceDepth += 1
                case "}": braceDepth = max(0, braceDepth - 1)
                case "[" where braceDepth > 0: bracketDepthInsideJSON += 1
                case "]":
                    if braceDepth > 0 && bracketDepthInsideJSON > 0 {
                        bracketDepthInsideJSON -= 1
                    } else if braceDepth == 0 {
                        return (text.index(after: currentIndex), .closingBracket)
                    }
                default: break
                }
            }
            currentIndex = text.index(after: currentIndex)
        }
        return (text.endIndex, .endOfText)
    }

    /// One call from what follows "[ACTION" in a tag: an optional ":", the tool name, then a JSON
    /// object (or nothing, for a tool without arguments). Nil when the name is unknown or the
    /// arguments are not a JSON object.
    static func toolCall(fromTagContent tagContent: String, knownToolNames: Set<String>, callIndex: Int) -> ClaudeToolCall? {
        var content = Substring(tagContent)
        if content.hasSuffix("]") { content = content.dropLast() }
        content = content.drop { $0 == ":" || $0.isWhitespace }
        let toolName = String(content.prefix { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" })
        guard !toolName.isEmpty, knownToolNames.contains(toolName) else { return nil }
        let argumentsText = content.dropFirst(toolName.count)
        let argumentsObject: [String: Any]
        if let firstBrace = argumentsText.firstIndex(of: "{"), let lastBrace = argumentsText.lastIndex(of: "}"), firstBrace < lastBrace {
            let jsonText = argumentsText[firstBrace...lastBrace]
            guard let decodedObject = (try? JSONSerialization.jsonObject(with: Data(jsonText.utf8))) as? [String: Any] else { return nil }
            argumentsObject = decodedObject
        } else if argumentsText.allSatisfy({ $0.isWhitespace || ".,;:)".contains($0) }) {
            argumentsObject = [:]
        } else {
            return nil
        }
        return ClaudeToolCall(
            id: "plan-action-\(callIndex + 1)",
            name: toolName,
            arguments: AnswerProviderHTTPSupport.toolArguments(fromJSONObject: argumentsObject)
        )
    }

    /// The answer once its tags are gone: a code fence that only held a tag goes too, lines that
    /// were only a tag leave no run of blank lines behind, and the ends are trimmed.
    static func cleanedText(afterRemovingTagsFrom text: String) -> String {
        var cleaned = text.replacingOccurrences(of: #"```[A-Za-z]*\s*```"#, with: "", options: .regularExpression)
        cleaned = cleaned.replacingOccurrences(of: #"[ \t]+\n"#, with: "\n", options: .regularExpression)
        cleaned = cleaned.replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
        return cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Holds action tags back from streamed text. Each `consume` returns the text that is safe to hand
/// on now; `finish` returns whatever was still held and is not a tag. Text from a "[" is held until
/// it can no longer become "[ACTION"; a tag is then dropped up to its closing "]" (or the end of
/// its line), with any punctuation right after it. A line that is only a code fence ("```json") is
/// dropped as well: the voice has nothing to say for it and a fenced tag would leave it behind.
nonisolated final class PlanActionLineFilter: @unchecked Sendable {
    private enum State {
        /// Text flows through.
        case passing
        /// Holding from a "[" that might open a tag.
        case holdingPossibleTag
        /// Inside a tag: everything is dropped until it ends.
        case droppingTag
        /// Just after a tag: punctuation is dropped, anything else flows.
        case droppingPunctuationAfterTag
        /// Holding a line that starts with a backtick until it ends.
        case holdingPossibleFenceLine
    }

    private let lock = NSLock()
    private var state = State.passing
    private var heldText = ""
    private var isAtLineStart = true

    func consume(_ chunk: String) -> String {
        lock.lock(); defer { lock.unlock() }
        var safeText = ""
        for character in chunk { handle(character, appendingTo: &safeText) }
        return safeText
    }

    func finish() -> String {
        lock.lock(); defer { lock.unlock() }
        var safeText = ""
        switch state {
        case .holdingPossibleTag:
            safeText = heldText
        case .holdingPossibleFenceLine:
            if !Self.isFenceOnlyLine(heldText) { safeText = heldText }
        case .passing, .droppingTag, .droppingPunctuationAfterTag:
            break
        }
        heldText = ""
        state = .passing
        return safeText
    }

    private func handle(_ character: Character, appendingTo safeText: inout String) {
        switch state {
        case .passing:
            pass(character, appendingTo: &safeText)
        case .droppingPunctuationAfterTag:
            if ".,;!".contains(character) { return }
            state = .passing
            pass(character, appendingTo: &safeText)
        case .holdingPossibleTag:
            heldText.append(character)
            let uppercasedHeldText = heldText.uppercased()
            if uppercasedHeldText.hasPrefix(PlanToolProtocol.actionTagOpening) {
                state = .droppingTag
                checkWhetherTagEnded(appendingTo: &safeText)
            } else if !PlanToolProtocol.actionTagOpening.hasPrefix(uppercasedHeldText) {
                // Not a tag after all ("[POINT:…" or a bracket in prose): let it through.
                // The "[" goes out as it is; what followed it may itself open a tag ("[[ACTION").
                let textAfterBracket = heldText.dropFirst()
                heldText = ""
                state = .passing
                safeText.append("[")
                isAtLineStart = false
                for releasedCharacter in textAfterBracket { handle(releasedCharacter, appendingTo: &safeText) }
            }
        case .droppingTag:
            heldText.append(character)
            checkWhetherTagEnded(appendingTo: &safeText)
        case .holdingPossibleFenceLine:
            heldText.append(character)
            if character == "\n" {
                if !Self.isFenceOnlyLine(heldText) { safeText += heldText }
                heldText = ""
                state = .passing
                isAtLineStart = true
            } else if heldText.count == 2 && !heldText.hasPrefix("``") {
                // One backtick then something else: inline code, not a fence.
                safeText += heldText
                heldText = ""
                state = .passing
                isAtLineStart = false
            }
        }
    }

    private func pass(_ character: Character, appendingTo safeText: inout String) {
        if character == "[" {
            heldText = "["
            state = .holdingPossibleTag
            return
        }
        if character == "`" && isAtLineStart {
            heldText = "`"
            state = .holdingPossibleFenceLine
            return
        }
        safeText.append(character)
        if character == "\n" {
            isAtLineStart = true
        } else if !(character == " " || character == "\t") {
            isAtLineStart = false
        }
    }

    /// Ends the tag held in `heldText` once it is complete: after its "]" any punctuation is
    /// dropped too; when its line ended first, the line break itself still goes out.
    private func checkWhetherTagEnded(appendingTo safeText: inout String) {
        switch PlanToolProtocol.scanActionTag(in: heldText, openingAt: heldText.startIndex).ending {
        case .closingBracket:
            heldText = ""
            state = .droppingPunctuationAfterTag
        case .lineBreak:
            heldText = ""
            state = .passing
            pass("\n", appendingTo: &safeText)
        case .endOfText:
            break
        }
    }

    private static func isFenceOnlyLine(_ line: String) -> Bool {
        line.trimmingCharacters(in: .whitespacesAndNewlines).range(of: #"^```[A-Za-z]*$"#, options: .regularExpression) != nil
    }
}
