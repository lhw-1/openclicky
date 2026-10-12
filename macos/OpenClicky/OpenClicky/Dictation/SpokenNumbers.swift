//
//  SpokenNumbers.swift
//  OpenClicky
//
//  Spoken English numbers written as digits, without a model: "three hundred and twenty five" →
//  "325", "fifty percent" → "50%". Some engines spell numbers out (Apple's recogniser writes digits
//  already). The usual style rule decides: one to nine stay words ("one of them", "two books"),
//  ten and up and anything counted in hundreds or more become digits. A run of numbers that can't
//  be one number ("two three four", a phone number read out) is left as it was said.
//

import Foundation

enum SpokenNumbers {
    private static let units: [String: Int] = [
        "zero": 0, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7, "eight": 8, "nine": 9,
    ]
    private static let teens: [String: Int] = [
        "ten": 10, "eleven": 11, "twelve": 12, "thirteen": 13, "fourteen": 14, "fifteen": 15,
        "sixteen": 16, "seventeen": 17, "eighteen": 18, "nineteen": 19,
    ]
    private static let tens: [String: Int] = [
        "twenty": 20, "thirty": 30, "forty": 40, "fifty": 50, "sixty": 60, "seventy": 70, "eighty": 80, "ninety": 90,
    ]
    private static let scales: [String: Int] = ["thousand": 1_000, "million": 1_000_000, "billion": 1_000_000_000]

    /// What a number word is, for which word may follow which.
    private enum Kind { case unit, teen, tens, hundred, scale }

    private static func kind(of word: String) -> Kind? {
        if units[word] != nil { return .unit }
        if teens[word] != nil { return .teen }
        if tens[word] != nil { return .tens }
        if word == "hundred" { return .hundred }
        if scales[word] != nil { return .scale }
        return nil
    }

    /// Whether `next` can carry on the number `previous` is part of ("twenty" "five" can; "two"
    /// "three" can't, it's two numbers).
    private static func canFollow(_ next: Kind, after previous: Kind) -> Bool {
        switch previous {
        case .unit, .teen: return next == .hundred || next == .scale
        case .tens: return next == .unit || next == .scale
        case .hundred: return next == .unit || next == .teen || next == .tens || next == .scale
        case .scale: return next == .unit || next == .teen || next == .tens
        }
    }

    /// `text` with its spoken numbers as digits.
    static func digitize(_ text: String) -> String {
        let tokens = text.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        var output: [String] = []
        var index = 0
        while index < tokens.count {
            if let run = numberRun(in: tokens, from: index) {
                output.append(run.written)
                index = run.end
            } else {
                output.append(tokens[index])
                index += 1
            }
        }
        return output.joined(separator: " ")
    }

    /// The number starting at `start`, if one does and it should be written as digits.
    private static func numberRun(in tokens: [String], from start: Int) -> (written: String, end: Int)? {
        var words: [String] = []
        var previousKind: Kind?
        var index = start
        var trailing = ""
        var leading = ""
        while index < tokens.count {
            let (lead, core, trail) = split(tokens[index])
            let pieces = core.lowercased().split(separator: "-").map(String.init) // "twenty-five"
            let kinds = pieces.map(kind(of:))
            // "and" joins only inside a number: "three hundred and twenty".
            if core.lowercased() == "and", previousKind == .hundred || previousKind == .scale, lead.isEmpty, trail.isEmpty,
               index + 1 < tokens.count, let nextKind = kind(of: split(tokens[index + 1]).core.lowercased()),
               nextKind != .hundred, nextKind != .scale {
                index += 1
                continue
            }
            guard !pieces.isEmpty, kinds.allSatisfy({ $0 != nil }), lead.isEmpty || words.isEmpty else { break }
            var fits = true
            var kindAfter = previousKind
            for pieceKind in kinds.compactMap({ $0 }) {
                if let kindAfter, !canFollow(pieceKind, after: kindAfter) { fits = false; break }
                kindAfter = pieceKind
            }
            guard fits else { break }
            if words.isEmpty { leading = lead }
            words.append(contentsOf: pieces)
            previousKind = kindAfter
            index += 1
            // Punctuation ends the number: "twenty, thirty" is two.
            if !trail.isEmpty { trailing = trail; break }
        }
        guard !words.isEmpty, let value = value(of: words) else { return nil }
        // A lone "hundred" or "thousand" ("a hundred people") keeps its words, and so does one to nine.
        let startsWithScale = kind(of: words[0]) == .hundred || kind(of: words[0]) == .scale
        let isCounted = words.contains { kind(of: $0) == .hundred || kind(of: $0) == .scale }
        guard !startsWithScale, value >= 10 || isCounted else { return nil }

        var written = String(value)
        // "fifty percent" → "50%".
        if trailing.isEmpty, index < tokens.count {
            let (_, nextCore, nextTrail) = split(tokens[index])
            if nextCore.lowercased() == "percent" {
                written += "%"
                trailing = nextTrail
                index += 1
            }
        }
        return (leading + written + trailing, index)
    }

    private static func value(of words: [String]) -> Int? {
        var total = 0
        var current = 0
        for word in words {
            if let number = units[word] ?? teens[word] ?? tens[word] {
                current += number
            } else if word == "hundred" {
                current = max(current, 1) * 100
            } else if let scale = scales[word] {
                total += max(current, 1) * scale
                current = 0
            } else {
                return nil
            }
        }
        return total + current
    }

    /// A token's leading punctuation, its letters, and its trailing punctuation.
    private static func split(_ token: String) -> (lead: String, core: String, trail: String) {
        let characters = Array(token)
        var start = 0
        var end = characters.count
        while start < end, !characters[start].isLetter, !characters[start].isNumber { start += 1 }
        while end > start, !characters[end - 1].isLetter, !characters[end - 1].isNumber { end -= 1 }
        return (String(characters[..<start]), String(characters[start..<end]), String(characters[end...]))
    }
}
