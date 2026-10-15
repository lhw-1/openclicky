//
//  AskPointerContext.swift
//  OpenClicky
//
//  "What is this?" with the mouse on something. The ask lane used to send the screenshots and the
//  highlighted text but never where the mouse was, so the model answered about the window with
//  focus (a tester pointed at a desktop item and heard about the Outlook window behind it,
//  2026-10-15). Now the question carries the pointer's place in the screenshot, a close-up of the
//  area around it rides along as one more image, and the same question asked again straight
//  after is flagged as "the last answer was probably not what they meant".
//

import AppKit
import Foundation
import ImageIO

/// Where the mouse pointer is in the screenshot it is on, in that screenshot's pixels from the
/// top-left (the space the model's [POINT:x,y] tags use).
struct PointerInCapture: Equatable {
    let x: Int
    let y: Int
    /// The label of the capture the pointer is on ("screen1"), as the model sees it.
    let screenLabel: String

    /// The pointer placed in the capture whose display holds the mouse; nil when none does.
    static func locate(mouse: CGPoint, in captures: [CompanionScreenCapture]) -> PointerInCapture? {
        guard let capture = captures.first(where: { $0.displayFrame.contains(mouse) }) else { return nil }
        let scaleX = CGFloat(capture.screenshotWidthInPixels) / max(capture.displayFrame.width, 1)
        let scaleY = CGFloat(capture.screenshotHeightInPixels) / max(capture.displayFrame.height, 1)
        // AppKit's y grows upwards from the bottom of the display; the screenshot's grows downwards.
        return PointerInCapture(x: Int((mouse.x - capture.displayFrame.minX) * scaleX),
                                y: Int((capture.displayFrame.maxY - mouse.y) * scaleY),
                                screenLabel: capture.label)
    }

    /// Added to the question, in brackets like the highlight line.
    var promptLine: String {
        "The mouse pointer is at (\(x), \(y)) from the top-left of the screenshot labelled \(screenLabel). When the user asks what \"this\" or \"that\" is, or what they are pointing at, they mean what is under the pointer or right next to it, not the window with keyboard focus. Name the element you are describing."
    }
}

/// The square around the pointer, cut from the screenshot it is on, so small things (a desktop
/// icon, a toolbar glyph) are readable at full size.
enum PointerCloseUp {
    static let defaultSideInPixels = 480

    static func jpeg(from imageData: Data, around pointer: PointerInCapture, sideInPixels: Int = defaultSideInPixels) -> Data? {
        guard let source = CGImageSourceCreateWithData(imageData as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        let side = min(sideInPixels, image.width, image.height)
        guard side > 0 else { return nil }
        // Centred on the pointer, pushed back inside the image near an edge.
        let originX = min(max(pointer.x - side / 2, 0), image.width - side)
        let originY = min(max(pointer.y - side / 2, 0), image.height - side)
        guard let cropped = image.cropping(to: CGRect(x: originX, y: originY, width: side, height: side)) else { return nil }
        return NSBitmapImageRep(cgImage: cropped).representation(using: .jpeg, properties: [.compressionFactor: 0.85])
    }

    /// The image's label: what it is, and that its pixels are not a screen to point in.
    static func label(sideInPixels: Int = defaultSideInPixels) -> String {
        "Close-up: the \(sideInPixels)x\(sideInPixels) pixel area around the mouse pointer, cut from the screenshot the pointer is on (the pointer is at its centre unless it is near an edge). For looking only: never use this image's coordinates in a [POINT:x,y] tag."
    }
}

/// The same question asked again right after an answer: the first answer was probably about the
/// wrong thing (the focused window, not the pointer), so the model is told to look again.
enum RepeatedQuestion {
    /// How soon after the previous question a near-identical one counts as asking again.
    static let withinSeconds: TimeInterval = 180
    /// How different the words may be (edit distance over the longer length) and still be the
    /// same question: "what is this" / "what's that" are one question, "open my mail" is not.
    static let maximumDifference = 0.25

    static let promptLine = "The user just asked nearly the same question again. The previous answer was probably not about what they meant: this time answer about what is under the mouse pointer, and say which element you are describing."

    static func isRepeat(_ transcript: String, of previous: String?, secondsSincePrevious: TimeInterval) -> Bool {
        guard secondsSincePrevious <= withinSeconds, let previous else { return false }
        let currentWords = Array(normalized(transcript))
        let previousWords = Array(normalized(previous))
        guard !currentWords.isEmpty, !previousWords.isEmpty else { return false }
        let distance = editDistance(currentWords, previousWords)
        return Double(distance) / Double(max(currentWords.count, previousWords.count)) <= maximumDifference
    }

    /// Lowercase letters, digits and single spaces: punctuation and apostrophes do not make a new question.
    static func normalized(_ text: String) -> String {
        let kept = text.lowercased().map { character -> Character in
            (character.isLetter || character.isNumber || character == " ") ? character : (character == "'" || character == "’" ? "\u{0}" : " ")
        }
        return String(kept).replacingOccurrences(of: "\u{0}", with: "")
            .split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
    }

    private static func editDistance(_ left: [Character], _ right: [Character]) -> Int {
        var previousRow = Array(0...right.count)
        for (leftIndex, leftCharacter) in left.enumerated() {
            var currentRow = [leftIndex + 1]
            for (rightIndex, rightCharacter) in right.enumerated() {
                let substitution = previousRow[rightIndex] + (leftCharacter == rightCharacter ? 0 : 1)
                currentRow.append(min(previousRow[rightIndex + 1] + 1, currentRow[rightIndex] + 1, substitution))
            }
            previousRow = currentRow
        }
        return previousRow[right.count]
    }
}
