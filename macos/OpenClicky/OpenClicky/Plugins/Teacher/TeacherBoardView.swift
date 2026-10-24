//
//  TeacherBoardView.swift
//  OpenClicky
//
//  How a lesson is drawn: each stroke appears in order at a hand's pace (lines trace out, words
//  write a letter at a time), with a slight wobble so it reads as drawn, not plotted. The
//  animation clock runs only while strokes are still appearing; a finished board is static.
//

import AppKit
import SwiftUI

/// The colours for each ink role on each board style.
enum TeacherInkPalette {
    static func color(_ ink: TeacherInk, style: TeacherBoardStyle) -> Color {
        let isChalk = style == .chalkOnDarkPage
        switch ink {
        case .ink: return Color(hex: isChalk ? "#F5F6FA" : "#2D3436")
        case .red: return Color(hex: isChalk ? "#FF7675" : "#D63031")
        case .blue: return Color(hex: isChalk ? "#74B9FF" : "#0984E3")
        case .green: return Color(hex: isChalk ? "#55EFC4" : "#00A36C")
        case .orange: return Color(hex: isChalk ? "#FDCB6E" : "#E17055")
        case .purple: return Color(hex: isChalk ? "#A29BFE" : "#6C5CE7")
        case .grey: return Color(hex: isChalk ? "#B2BEC3" : "#8A8F94")
        }
    }

    /// The handwriting: Noteworthy ships with every Mac; Bradley Hand and Chalkboard are the fallbacks.
    static func handwritingFont(size: CGFloat) -> Font {
        for name in ["Noteworthy-Bold", "BradleyHandITCTT-Bold", "ChalkboardSE-Regular"] where NSFont(name: name, size: size) != nil {
            return .custom(name, size: size)
        }
        return .system(size: size, weight: .semibold, design: .rounded)
    }
}

struct TeacherBoardView: View {
    @ObservedObject var board: TeacherBoard

    var body: some View {
        ZStack {
            if let lesson = board.lesson {
                switch lesson.content {
                case .sketch(let sketch):
                    TeacherSketchView(sketch: sketch, style: lesson.style, startedAt: lesson.startedAt)
                        .padding(lesson.style == .paper ? 22 : 6)
                        .background(paperBackground(isShown: lesson.style == .paper))
                case .picture(let picture):
                    TeacherPictureView(picture: picture)
                        .padding(14)
                        .background(paperBackground(isShown: true))
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .transition(.opacity)
    }

    @ViewBuilder private func paperBackground(isShown: Bool) -> some View {
        if isShown {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(hex: "#FFFDF6"))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Color(hex: "#E8E2CF"), lineWidth: 1))
                .shadow(color: .black.opacity(0.18), radius: 14, y: 6)
        }
    }
}

struct TeacherPictureView: View {
    let picture: TeacherPicture

    var body: some View {
        VStack(spacing: 8) {
            Image(nsImage: picture.image)
                .resizable()
                .scaledToFit()
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            if !picture.caption.isEmpty {
                Text(picture.caption)
                    .font(TeacherInkPalette.handwritingFont(size: 20))
                    .foregroundStyle(Color(hex: "#2D3436"))
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
            }
            Text("from \(picture.credit)")
                .font(.system(size: 10))
                .foregroundStyle(Color(hex: "#8A8F94"))
        }
    }
}

struct TeacherSketchView: View {
    let sketch: TeacherSketch
    let style: TeacherBoardStyle
    let startedAt: Date
    /// Stops the animation clock once the last stroke is down (an idle board must cost nothing).
    @State private var isFinished = false

    var body: some View {
        let timeline = TeacherSketchTimeline.entries(for: sketch)
        let totalSeconds = TeacherSketchTimeline.totalSeconds(for: sketch)
        TimelineView(.animation(minimumInterval: 1.0 / 60, paused: isFinished)) { context in
            let elapsed = isFinished ? .infinity : context.date.timeIntervalSince(startedAt)
            Canvas { graphics, size in
                let layout = TeacherSketchLayout(sketch: sketch, viewSize: size)
                for (index, stroke) in sketch.strokes.enumerated() {
                    let entry = timeline[index]
                    guard elapsed >= entry.start else { break }
                    let progress = entry.duration <= 0 ? 1 : min(1, (elapsed - entry.start) / entry.duration)
                    TeacherStrokeRenderer.draw(stroke, progress: CGFloat(progress), seed: index, style: style,
                                               layout: layout, canvasSize: size, in: &graphics)
                }
            }
        }
        .task(id: startedAt) {
            isFinished = false
            let remaining = totalSeconds - Date().timeIntervalSince(startedAt)
            if remaining > 0 { try? await Task.sleep(nanoseconds: UInt64((remaining + 0.1) * 1_000_000_000)) }
            if !Task.isCancelled { isFinished = true }
        }
    }
}

enum TeacherStrokeRenderer {
    static func draw(_ stroke: TeacherStroke, progress: CGFloat, seed: Int, style: TeacherBoardStyle,
                     layout: TeacherSketchLayout, canvasSize: CGSize, in graphics: inout GraphicsContext) {
        let color = TeacherInkPalette.color(stroke.ink, style: style)
        let lineWidth = (style == .chalkOnDarkPage ? 3.4 : 3.0) * stroke.weight
        let strokeStyle = StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round, dash: stroke.isDashed ? [9, 7] : [])
        let viewPoints = stroke.points.map(layout.viewPoint)

        switch stroke.kind {
        case .pause:
            return
        case .text(let words):
            guard let anchor = viewPoints.first else { return }
            let fontSize = layout.fontSize(weight: stroke.weight)
            let full = graphics.resolve(Text(words).font(TeacherInkPalette.handwritingFont(size: fontSize)))
            let fullSize = full.measure(in: CGSize(width: 2000, height: 400))
            let shownCount = Int((CGFloat(words.count) * progress).rounded(.up))
            let shown = graphics.resolve(Text(String(words.prefix(shownCount))).font(TeacherInkPalette.handwritingFont(size: fontSize)).foregroundColor(color))
            // Written from the left so the letters already down never move; centred as a whole,
            // and never past the board's edge (the estimate that sized the board can be short).
            let wantedLeft = stroke.isLeftAligned ? anchor.x : anchor.x - fullSize.width / 2
            let left = min(max(wantedLeft, 0), max(canvasSize.width - fullSize.width, 0))
            let middle = min(max(anchor.y, fullSize.height / 2), canvasSize.height - fullSize.height / 2)
            graphics.draw(shown, at: CGPoint(x: left, y: middle), anchor: .leading)
            return
        case .dot:
            guard let centre = viewPoints.first else { return }
            let radius = 3.6 * stroke.weight * progress
            graphics.fill(Path(ellipseIn: CGRect(x: centre.x - radius, y: centre.y - radius, width: radius * 2, height: radius * 2)), with: .color(color))
            return
        default:
            break
        }

        let outline = path(for: stroke, viewPoints: viewPoints, scale: layout.scale, seed: seed)
        if stroke.isFilled, progress >= 1 {
            graphics.fill(outline, with: .color(color.opacity(0.14)))
        }
        graphics.stroke(outline.trimmedPath(from: 0, to: progress), with: .color(color), style: strokeStyle)
        if case .arrow = stroke.kind, progress >= 0.98, viewPoints.count >= 2 {
            let tip = viewPoints[viewPoints.count - 1]
            let tail = viewPoints[viewPoints.count - 2]
            graphics.stroke(arrowHead(tip: tip, from: tail, size: 12 + 3 * stroke.weight), with: .color(color),
                            style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round))
        }
    }

    static func path(for stroke: TeacherStroke, viewPoints: [CGPoint], scale: CGFloat, seed: Int) -> Path {
        var random = WobbleRandom(seed: seed)
        switch stroke.kind {
        case .line, .arrow:
            return wobblyPolyline(viewPoints, closed: false, random: &random)
        case .shape:
            return wobblyPolyline(viewPoints, closed: true, random: &random)
        case .curve:
            return smoothCurve(through: viewPoints)
        case .box:
            guard viewPoints.count >= 1, stroke.points.count >= 2 else { return Path() }
            let origin = viewPoints[0]
            let size = CGSize(width: stroke.points[1].x * scale, height: stroke.points[1].y * scale)
            let corners = [origin, CGPoint(x: origin.x + size.width, y: origin.y),
                           CGPoint(x: origin.x + size.width, y: origin.y + size.height), CGPoint(x: origin.x, y: origin.y + size.height)]
            return wobblyPolyline(corners, closed: true, random: &random)
        case .circle(let radius):
            guard let centre = viewPoints.first else { return Path() }
            // A hand closes a circle a little past where it began.
            return wobblyArc(centre: centre, radius: radius * scale, fromDegrees: -100, toDegrees: 270, random: &random)
        case .arc(let radius, let start, let end):
            guard let centre = viewPoints.first else { return Path() }
            return wobblyArc(centre: centre, radius: radius * scale, fromDegrees: start, toDegrees: end, random: &random)
        case .rightAngle:
            guard viewPoints.count == 3 else { return Path() }
            let vertex = viewPoints[0]
            let towardsFirst = unit(from: vertex, to: viewPoints[1])
            let towardsSecond = unit(from: vertex, to: viewPoints[2])
            let side = min(16, 0.3 * min(distance(vertex, viewPoints[1]), distance(vertex, viewPoints[2])))
            var path = Path()
            path.move(to: CGPoint(x: vertex.x + towardsFirst.x * side, y: vertex.y + towardsFirst.y * side))
            path.addLine(to: CGPoint(x: vertex.x + (towardsFirst.x + towardsSecond.x) * side, y: vertex.y + (towardsFirst.y + towardsSecond.y) * side))
            path.addLine(to: CGPoint(x: vertex.x + towardsSecond.x * side, y: vertex.y + towardsSecond.y * side))
            return path
        case .angle:
            guard viewPoints.count == 3 else { return Path() }
            let vertex = viewPoints[0]
            let firstDegrees = atan2(viewPoints[1].y - vertex.y, viewPoints[1].x - vertex.x) * 180 / .pi
            var secondDegrees = atan2(viewPoints[2].y - vertex.y, viewPoints[2].x - vertex.x) * 180 / .pi
            // The inside of the angle: the short way round.
            if secondDegrees - firstDegrees > 180 { secondDegrees -= 360 }
            if secondDegrees - firstDegrees < -180 { secondDegrees += 360 }
            let radius = min(26, 0.35 * min(distance(vertex, viewPoints[1]), distance(vertex, viewPoints[2])))
            return wobblyArc(centre: vertex, radius: radius, fromDegrees: firstDegrees, toDegrees: secondDegrees, random: &random, wobble: 0.3)
        case .dot, .text, .pause:
            return Path()
        }
    }

    // MARK: - hand-drawn geometry

    /// Each segment cut into short pieces nudged sideways by a pixel or so.
    static func wobblyPolyline(_ points: [CGPoint], closed: Bool, random: inout WobbleRandom) -> Path {
        guard let first = points.first else { return Path() }
        var path = Path()
        path.move(to: first)
        let route = closed ? points + [first] : points
        for index in 1..<max(route.count, 1) {
            let start = route[index - 1]
            let end = route[index]
            let length = distance(start, end)
            let pieces = max(Int(length / 14), 1)
            let normal = CGPoint(x: -(end.y - start.y) / max(length, 0.001), y: (end.x - start.x) / max(length, 0.001))
            for piece in 1...pieces {
                let fraction = CGFloat(piece) / CGFloat(pieces)
                // No nudge at the corners, so shapes still meet.
                let nudge = piece == pieces ? 0 : random.next(amplitude: 1.1)
                path.addLine(to: CGPoint(x: start.x + (end.x - start.x) * fraction + normal.x * nudge,
                                         y: start.y + (end.y - start.y) * fraction + normal.y * nudge))
            }
        }
        return path
    }

    static func wobblyArc(centre: CGPoint, radius: CGFloat, fromDegrees: CGFloat, toDegrees: CGFloat, random: inout WobbleRandom, wobble: CGFloat = 1.0) -> Path {
        var path = Path()
        let sweep = toDegrees - fromDegrees
        let steps = max(Int(abs(sweep) / 6), 2)
        for step in 0...steps {
            let degrees = fromDegrees + sweep * CGFloat(step) / CGFloat(steps)
            let wobbledRadius = radius + random.next(amplitude: wobble)
            let point = CGPoint(x: centre.x + cos(degrees * .pi / 180) * wobbledRadius, y: centre.y + sin(degrees * .pi / 180) * wobbledRadius)
            if step == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        return path
    }

    /// Catmull-Rom through the points, as cubic Béziers.
    static func smoothCurve(through points: [CGPoint]) -> Path {
        var path = Path()
        guard points.count >= 2 else { return path }
        path.move(to: points[0])
        for index in 0..<(points.count - 1) {
            let previous = points[max(index - 1, 0)]
            let start = points[index]
            let end = points[index + 1]
            let next = points[min(index + 2, points.count - 1)]
            let control1 = CGPoint(x: start.x + (end.x - previous.x) / 6, y: start.y + (end.y - previous.y) / 6)
            let control2 = CGPoint(x: end.x - (next.x - start.x) / 6, y: end.y - (next.y - start.y) / 6)
            path.addCurve(to: end, control1: control1, control2: control2)
        }
        return path
    }

    static func arrowHead(tip: CGPoint, from tail: CGPoint, size: CGFloat) -> Path {
        let direction = unit(from: tail, to: tip)
        let back = CGPoint(x: tip.x - direction.x * size, y: tip.y - direction.y * size)
        let side = CGPoint(x: -direction.y * size * 0.55, y: direction.x * size * 0.55)
        var path = Path()
        path.move(to: CGPoint(x: back.x + side.x, y: back.y + side.y))
        path.addLine(to: tip)
        path.addLine(to: CGPoint(x: back.x - side.x, y: back.y - side.y))
        return path
    }

    static func distance(_ first: CGPoint, _ second: CGPoint) -> CGFloat { hypot(second.x - first.x, second.y - first.y) }

    static func unit(from start: CGPoint, to end: CGPoint) -> CGPoint {
        let length = max(distance(start, end), 0.001)
        return CGPoint(x: (end.x - start.x) / length, y: (end.y - start.y) / length)
    }
}

/// The same wobble every frame for a stroke (a fresh random each frame would make lines shiver).
struct WobbleRandom {
    private var state: UInt64

    init(seed: Int) { state = UInt64(truncatingIfNeeded: seed &* 2_654_435_761 &+ 0x9E37_79B9) | 1 }

    mutating func next(amplitude: CGFloat) -> CGFloat {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return (CGFloat(state % 10_000) / 10_000 * 2 - 1) * amplitude
    }
}
