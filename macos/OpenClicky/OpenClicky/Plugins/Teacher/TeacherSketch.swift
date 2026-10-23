//
//  TeacherSketch.swift
//  OpenClicky
//
//  The Teacher plugin's drawing language: what a model writes when it draws a lesson on the
//  screen ("shape 80 240 320 240 80 60", "text 200 268 \"b\" blue big"), and the parser that turns
//  it into strokes. A small line language instead of nested JSON because every lane can carry a
//  string (a Realtime tool argument, a Claude tool argument, a plan's [ACTION:] line) and models
//  write it more reliably and in fewer tokens than arrays of objects. Pure: unit-tested.
//

import CoreGraphics
import Foundation

/// The colours a sketch may name. How each looks depends on the board's style (dark ink on a
/// white page, chalk on a dark one), so the sketch names roles, not hex values.
enum TeacherInk: String, CaseIterable, Equatable, Sendable {
    case ink, red, blue, green, orange, purple, grey

    static func named(_ word: String) -> TeacherInk? {
        switch word {
        case "ink", "black", "pen", "white", "chalk": return .ink
        case "red": return .red
        case "blue": return .blue
        case "green": return .green
        case "orange", "yellow": return .orange
        case "purple", "violet", "pink": return .purple
        case "grey", "gray": return .grey
        default: return nil
        }
    }
}

/// One thing drawn on the board, in board units (origin top-left, y down).
struct TeacherStroke: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        /// Straight segments through `points` (two for a line).
        case line
        /// A line with an arrowhead at its last point.
        case arrow
        /// A smooth freehand curve through `points`.
        case curve
        /// A closed outline through `points` (a triangle, a prism, a block of glass).
        case shape
        /// `points[0]` is the centre; `radius`.
        case circle(radius: CGFloat)
        /// Part of a circle around `points[0]`, angles in degrees, 0 = right, 90 = down.
        case arc(radius: CGFloat, startDegrees: CGFloat, endDegrees: CGFloat)
        /// `points[0]` is the top-left corner, `points[1]` the size.
        case box
        /// The little square in a right angle: `points` = vertex, a point on each arm.
        case rightAngle
        /// The arc marking an angle: `points` = vertex, a point on each arm.
        case angle
        /// A filled dot at `points[0]`.
        case dot
        /// Handwriting centred on `points[0]`.
        case text(String)
        /// Nothing drawn: the pen rests for `seconds` (time to talk about what is there).
        case pause(seconds: Double)
    }

    var kind: Kind
    var points: [CGPoint]
    var ink: TeacherInk = .ink
    var isDashed = false
    var isFilled = false
    /// Text only: the words start at the point instead of being centred on it (worked solutions).
    var isLeftAligned = false
    /// 1 normal, 0.6 thin, 1.6 thick; for text, the size.
    var weight: CGFloat = 1
}

/// A whole drawing: the board the model drew on and what is on it, in order.
struct TeacherSketch: Equatable, Sendable {
    var boardWidth: CGFloat
    var boardHeight: CGFloat
    var strokes: [TeacherStroke]

    static let defaultBoardSize = CGSize(width: 400, height: 300)
    static let maximumStrokes = 80
}

enum TeacherSketchParser {
    /// What the parser made of the text: the sketch, or nil when nothing drawable came out, plus
    /// the lines it could not read (logged, never shown).
    struct Result: Equatable {
        let sketch: TeacherSketch?
        let skippedLines: [String]
    }

    static func parse(_ source: String) -> Result {
        var boardWidth = TeacherSketch.defaultBoardSize.width
        var boardHeight = TeacherSketch.defaultBoardSize.height
        var strokes: [TeacherStroke] = []
        var skippedLines: [String] = []

        for rawLine in commandLines(in: source) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") || line.hasPrefix("//") { continue }
            let (quotedText, words) = splitQuotedText(from: line)
            guard let commandWord = words.first?.lowercased() else { continue }
            let rest = Array(words.dropFirst())
            let numbers = rest.compactMap(number(from:))
            let options = rest.filter { number(from: $0) == nil }.map { $0.lowercased() }

            if commandWord == "board" || commandWord == "size" {
                if numbers.count >= 2, numbers[0] >= 50, numbers[1] >= 50 {
                    boardWidth = min(numbers[0], 2000)
                    boardHeight = min(numbers[1], 2000)
                }
                continue
            }
            guard strokes.count < TeacherSketch.maximumStrokes else {
                skippedLines.append(line)
                continue
            }
            guard var stroke = stroke(command: commandWord, numbers: numbers, options: options, quotedText: quotedText) else {
                skippedLines.append(line)
                continue
            }
            for option in options {
                if let ink = TeacherInk.named(option) { stroke.ink = ink }
                switch option {
                case "dashed", "dotted": stroke.isDashed = true
                case "fill", "filled", "shaded": stroke.isFilled = true
                case "left": stroke.isLeftAligned = true
                case "thick", "big", "large", "bold": stroke.weight = 1.6
                case "thin", "small", "tiny": stroke.weight = 0.65
                default: break
                }
            }
            strokes.append(stroke)
        }

        // Points far outside the board are a typo, not a drawing: pull them back onto it.
        let marginX = boardWidth * 0.1
        let marginY = boardHeight * 0.1
        strokes = strokes.map { stroke in
            var clamped = stroke
            if case .box = stroke.kind {
                // The second point of a box is its size, not a place.
                if let corner = stroke.points.first {
                    clamped.points[0] = CGPoint(x: min(max(corner.x, -marginX), boardWidth + marginX),
                                                y: min(max(corner.y, -marginY), boardHeight + marginY))
                }
                return clamped
            }
            clamped.points = stroke.points.map {
                CGPoint(x: min(max($0.x, -marginX), boardWidth + marginX), y: min(max($0.y, -marginY), boardHeight + marginY))
            }
            return clamped
        }

        let drawsSomething = strokes.contains { stroke in
            if case .pause = stroke.kind { return false }
            return true
        }
        return Result(sketch: drawsSomething ? TeacherSketch(boardWidth: boardWidth, boardHeight: boardHeight, strokes: strokes) : nil,
                      skippedLines: skippedLines)
    }

    private static func stroke(command: String, numbers: [CGFloat], options: [String], quotedText: String?) -> TeacherStroke? {
        func pairs(_ values: [CGFloat]) -> [CGPoint] {
            stride(from: 0, to: values.count - 1, by: 2).map { CGPoint(x: values[$0], y: values[$0 + 1]) }
        }
        switch command {
        case "line", "segment":
            let points = pairs(numbers)
            return points.count >= 2 ? TeacherStroke(kind: .line, points: points) : nil
        case "arrow", "pointer":
            let points = pairs(numbers)
            return points.count >= 2 ? TeacherStroke(kind: .arrow, points: points) : nil
        case "curve", "path", "freehand", "wave":
            let points = pairs(numbers)
            return points.count >= 2 ? TeacherStroke(kind: .curve, points: points) : nil
        case "shape", "polygon", "triangle", "poly":
            let points = pairs(numbers)
            return points.count >= 3 ? TeacherStroke(kind: .shape, points: points) : nil
        case "circle":
            guard numbers.count >= 3, numbers[2] > 0 else { return nil }
            return TeacherStroke(kind: .circle(radius: numbers[2]), points: [CGPoint(x: numbers[0], y: numbers[1])])
        case "arc":
            guard numbers.count >= 5, numbers[2] > 0 else { return nil }
            return TeacherStroke(kind: .arc(radius: numbers[2], startDegrees: numbers[3], endDegrees: numbers[4]),
                                 points: [CGPoint(x: numbers[0], y: numbers[1])])
        case "box", "rect", "rectangle":
            guard numbers.count >= 4, numbers[2] > 0, numbers[3] > 0 else { return nil }
            return TeacherStroke(kind: .box, points: [CGPoint(x: numbers[0], y: numbers[1]), CGPoint(x: numbers[2], y: numbers[3])])
        case "right_angle", "rightangle", "square_corner":
            let points = pairs(numbers)
            return points.count >= 3 ? TeacherStroke(kind: .rightAngle, points: Array(points.prefix(3))) : nil
        case "angle":
            let points = pairs(numbers)
            return points.count >= 3 ? TeacherStroke(kind: .angle, points: Array(points.prefix(3))) : nil
        case "dot", "point":
            guard numbers.count >= 2 else { return nil }
            return TeacherStroke(kind: .dot, points: [CGPoint(x: numbers[0], y: numbers[1])])
        case "text", "label", "write", "note":
            guard numbers.count >= 2 else { return nil }
            // Unquoted words are accepted too, minus the option words (colours, sizes).
            let unquoted = options.filter { TeacherInk.named($0) == nil && !optionWords.contains($0) }.joined(separator: " ")
            let words = (quotedText ?? unquoted).trimmingCharacters(in: .whitespaces)
            guard !words.isEmpty else { return nil }
            return TeacherStroke(kind: .text(String(words.prefix(80))), points: [CGPoint(x: numbers[0], y: numbers[1])])
        case "pause", "wait":
            let seconds = Double(numbers.first ?? 1)
            return TeacherStroke(kind: .pause(seconds: min(max(seconds, 0.1), 4)), points: [])
        default:
            return nil
        }
    }

    private static let optionWords: Set<String> = ["left", "dashed", "dotted", "fill", "filled", "shaded", "thick", "big", "large", "bold", "thin", "small", "tiny"]

    /// Commands are one per line; a model that wrote everything on one line may separate them with
    /// ";" instead. A ";" inside quotes is part of the words.
    static func commandLines(in source: String) -> [String] {
        var lines: [String] = []
        var current = ""
        var insideQuotes = false
        for character in source {
            if character == "\"" || character == "“" || character == "”" { insideQuotes.toggle() }
            if character.isNewline || (character == ";" && !insideQuotes) {
                lines.append(current)
                current = ""
                insideQuotes = false
            } else {
                current.append(character)
            }
        }
        lines.append(current)
        return lines
    }

    /// The words in quotes (straight or curly) taken out, and the rest split on spaces and commas.
    private static func splitQuotedText(from line: String) -> (String?, [String]) {
        let normalized = line.replacingOccurrences(of: "“", with: "\"").replacingOccurrences(of: "”", with: "\"")
        var quotedText: String?
        var remainder = normalized
        if let open = normalized.firstIndex(of: "\""),
           let close = normalized[normalized.index(after: open)...].firstIndex(of: "\"") {
            quotedText = String(normalized[normalized.index(after: open)..<close])
            remainder = String(normalized[..<open]) + " " + String(normalized[normalized.index(after: close)...])
        }
        let words = remainder.split(whereSeparator: { $0 == " " || $0 == "," || $0 == "\t" || $0 == "(" || $0 == ")" }).map(String.init)
        return (quotedText, words)
    }

    private static func number(from word: String) -> CGFloat? {
        guard let value = Double(word), value.isFinite else { return nil }
        return CGFloat(value)
    }
}

/// When each stroke starts and how long it takes to draw: lines at a steady hand's pace, words a
/// letter at a time, so the drawing builds up while the voice explains it.
enum TeacherSketchTimeline {
    struct Entry: Equatable {
        let start: Double
        let duration: Double
    }

    static let gapBetweenStrokes = 0.18

    static func entries(for sketch: TeacherSketch) -> [Entry] {
        let boardDiagonal = max(hypot(sketch.boardWidth, sketch.boardHeight), 1)
        var clock = 0.0
        var entries: [Entry] = []
        for stroke in sketch.strokes {
            let duration = drawingSeconds(for: stroke, boardDiagonal: boardDiagonal)
            entries.append(Entry(start: clock, duration: duration))
            clock += duration + gapBetweenStrokes
        }
        return entries
    }

    static func totalSeconds(for sketch: TeacherSketch) -> Double {
        guard let last = entries(for: sketch).last else { return 0 }
        return last.start + last.duration
    }

    static func drawingSeconds(for stroke: TeacherStroke, boardDiagonal: CGFloat) -> Double {
        switch stroke.kind {
        case .text(let words):
            return min(max(Double(words.count) * 0.07, 0.3), 2.2)
        case .pause(let seconds):
            return seconds
        case .dot:
            return 0.15
        case .rightAngle, .angle:
            return 0.3
        default:
            let length = TeacherSketchGeometry.approximateLength(of: stroke)
            return min(max(Double(length / boardDiagonal) * 1.6, 0.35), 1.6)
        }
    }
}

enum TeacherSketchGeometry {
    static func approximateLength(of stroke: TeacherStroke) -> CGFloat {
        func polylineLength(_ points: [CGPoint], closed: Bool) -> CGFloat {
            guard points.count >= 2 else { return 0 }
            var total: CGFloat = 0
            for index in 1..<points.count { total += hypot(points[index].x - points[index - 1].x, points[index].y - points[index - 1].y) }
            if closed, let first = points.first, let last = points.last { total += hypot(first.x - last.x, first.y - last.y) }
            return total
        }
        switch stroke.kind {
        case .line, .arrow, .curve: return polylineLength(stroke.points, closed: false)
        case .shape: return polylineLength(stroke.points, closed: true)
        case .circle(let radius): return 2 * .pi * radius
        case .arc(let radius, let start, let end): return abs(end - start) / 180 * .pi * radius
        case .box: return stroke.points.count > 1 ? 2 * (stroke.points[1].x + stroke.points[1].y) : 0
        default: return 0
        }
    }
}

/// Where the drawing actually is. Models draw on part of their board and put words past its edge,
/// so the board is laid out around what was drawn (words estimated at their written size), not
/// around the size the model declared.
struct TeacherSketchLayout: Equatable {
    /// In board units.
    let drawingBounds: CGRect
    let scale: CGFloat
    /// Where board point (0, 0) lands in the view (origin top-left).
    let origin: CGPoint

    /// A word's estimated size in board units at weight 1 (Noteworthy at the board's base size).
    static let letterWidth: CGFloat = 11
    static let lineHeight: CGFloat = 30
    /// Kept around the drawing, in board units.
    static let margin: CGFloat = 10

    init(sketch: TeacherSketch, viewSize: CGSize) {
        let bounds = Self.drawingBounds(of: sketch)
        drawingBounds = bounds
        scale = min(viewSize.width / max(bounds.width, 1), viewSize.height / max(bounds.height, 1))
        origin = CGPoint(x: (viewSize.width - bounds.width * scale) / 2 - bounds.minX * scale,
                         y: (viewSize.height - bounds.height * scale) / 2 - bounds.minY * scale)
    }

    func viewPoint(_ boardPoint: CGPoint) -> CGPoint {
        CGPoint(x: origin.x + boardPoint.x * scale, y: origin.y + boardPoint.y * scale)
    }

    /// The text's written size in view points for a stroke weight.
    func fontSize(weight: CGFloat) -> CGFloat {
        max(12, min(Self.lineHeight * 0.75 * weight * scale, 48))
    }

    static func drawingBounds(of sketch: TeacherSketch) -> CGRect {
        var bounds = CGRect.null
        func include(_ rect: CGRect) { bounds = bounds.union(rect) }
        for stroke in sketch.strokes {
            switch stroke.kind {
            case .pause:
                continue
            case .text(let words):
                guard let anchor = stroke.points.first else { continue }
                let width = CGFloat(words.count) * letterWidth * stroke.weight
                let height = lineHeight * stroke.weight
                include(CGRect(x: stroke.isLeftAligned ? anchor.x : anchor.x - width / 2, y: anchor.y - height / 2, width: width, height: height))
            case .circle(let radius), .arc(let radius, _, _):
                guard let centre = stroke.points.first else { continue }
                include(CGRect(x: centre.x - radius, y: centre.y - radius, width: radius * 2, height: radius * 2))
            case .box:
                guard stroke.points.count >= 2 else { continue }
                include(CGRect(origin: stroke.points[0], size: CGSize(width: stroke.points[1].x, height: stroke.points[1].y)))
            default:
                for point in stroke.points { include(CGRect(origin: point, size: .zero)) }
            }
        }
        guard !bounds.isNull else { return CGRect(x: 0, y: 0, width: sketch.boardWidth, height: sketch.boardHeight) }
        // A drawing that is one short line still gets a board of some height.
        let minimumSide = max(sketch.boardWidth, sketch.boardHeight) * 0.25
        if bounds.width < minimumSide { bounds = bounds.insetBy(dx: -(minimumSide - bounds.width) / 2, dy: 0) }
        if bounds.height < minimumSide { bounds = bounds.insetBy(dx: 0, dy: -(minimumSide - bounds.height) / 2) }
        return bounds.insetBy(dx: -margin, dy: -margin)
    }
}
