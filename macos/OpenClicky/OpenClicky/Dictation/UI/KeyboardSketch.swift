//
//  KeyboardSketch.swift
//  OpenClicky
//
//  A MacBook keyboard, sketched, with a fingertip pressing and holding the dictation key: "right
//  option" read as the left keys to some people, and a MacBook's own keyboard has no right
//  control at all. The onboarding's key chapter and Settings → Keyboard show it under the choice.
//

import SwiftUI

struct KeyboardSketch: View {
    let key: DictationHotkey
    var accent: Color = SettingsLook.accent

    /// Key widths in key units, each row 14.5 units wide like a MacBook's.
    private static let upperRows: [[CGFloat]] = [
        Array(repeating: 1, count: 13) + [1.5],
        [1.5] + Array(repeating: 1, count: 13),
        [1.75] + Array(repeating: 1, count: 11) + [1.75],
        [2.25] + Array(repeating: 1, count: 10) + [2.25],
    ]
    /// fn, ⌃, ⌥, ⌘, space, ⌘, ⌥, then the arrow cluster.
    private static let bottomRow: [(width: CGFloat, label: String)] = [
        (1, "fn"), (1, "⌃"), (1, "⌥"), (1.25, "⌘"), (5, ""), (1.25, "⌘"), (1, "⌥"), (1, "◀"), (1, "▲▼"), (1, "▶"),
    ]

    /// Which bottom-row key is the dictation key; nil when a MacBook has no such key.
    private var pressedIndex: Int? {
        switch key {
        case .fn: return 0
        case .rightCommand: return 5
        case .rightOption: return 6
        case .rightControl: return nil
        }
    }

    var caption: String {
        switch key {
        case .fn: return "fn sits in the bottom-left corner."
        case .rightCommand: return "Right ⌘ is the key just right of the space bar."
        case .rightOption: return "Right ⌥ is two keys right of the space bar, after ⌘."
        case .rightControl: return "A MacBook’s own keyboard has no right ⌃. Choose it for an external keyboard."
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TimelineView(.animation) { timeline in
                let press = Self.pressAmount(at: timeline.date.timeIntervalSinceReferenceDate)
                Canvas { context, size in
                    draw(in: &context, size: size, press: press)
                }
            }
            .aspectRatio(14.5 / 5.6, contentMode: .fit)
            .frame(maxWidth: 460)
            .accessibilityElement()
            .accessibilityLabel("Keyboard sketch: \(caption)")
            Text(caption)
                .font(.system(size: 11))
                .foregroundStyle(key == .rightControl ? Color(nsColor: .systemOrange) : .secondary)
        }
    }

    /// 0 → 1 → hold → 0 over a 2.4 s loop: the fingertip comes down, holds the key like a take,
    /// and lifts.
    static func pressAmount(at time: TimeInterval) -> CGFloat {
        let phase = time.truncatingRemainder(dividingBy: 2.4)
        switch phase {
        case ..<0.5: return 0
        case ..<0.75: return CGFloat((phase - 0.5) / 0.25)
        case ..<1.75: return 1
        case ..<2.0: return CGFloat(1 - (phase - 1.75) / 0.25)
        default: return 0
        }
    }

    private func draw(in context: inout GraphicsContext, size: CGSize, press: CGFloat) {
        let gap: CGFloat = max(2, size.width * 0.006)
        let rowCount = CGFloat(Self.upperRows.count + 1)
        let keyHeight = (size.height - gap * (rowCount - 1)) / rowCount
        let quietFill = Color.primary.opacity(0.06)
        let quietStroke = Color.primary.opacity(0.14)

        func unitWidth(keys: Int) -> CGFloat { (size.width - gap * CGFloat(keys - 1)) / 14.5 }

        // The upper rows: shapes only, for where the bottom row sits.
        for (rowIndex, row) in Self.upperRows.enumerated() {
            let unit = unitWidth(keys: row.count)
            var x: CGFloat = 0
            let y = CGFloat(rowIndex) * (keyHeight + gap)
            for width in row {
                let rect = CGRect(x: x, y: y, width: width * unit, height: keyHeight)
                let path = Path(roundedRect: rect, cornerRadius: keyHeight * 0.18)
                context.fill(path, with: .color(quietFill))
                context.stroke(path, with: .color(quietStroke), lineWidth: 0.5)
                x += width * unit + gap
            }
        }

        // The bottom row, labelled, with the dictation key pressed.
        let unit = unitWidth(keys: Self.bottomRow.count)
        var x: CGFloat = 0
        let y = CGFloat(Self.upperRows.count) * (keyHeight + gap)
        for (index, bottomKey) in Self.bottomRow.enumerated() {
            let width = bottomKey.width * unit
            let isPressed = index == pressedIndex
            let sink = isPressed ? press * keyHeight * 0.06 : 0
            let rect = CGRect(x: x, y: y + sink, width: width, height: keyHeight - sink)
            let path = Path(roundedRect: rect, cornerRadius: keyHeight * 0.18)
            if isPressed {
                context.fill(path, with: .color(accent.opacity(0.35 + 0.65 * Double(press))))
                context.stroke(path, with: .color(accent), lineWidth: 1.5)
            } else {
                context.fill(path, with: .color(Color.primary.opacity(0.09)))
                context.stroke(path, with: .color(quietStroke), lineWidth: 0.5)
            }
            if !bottomKey.label.isEmpty {
                let label = Text(bottomKey.label)
                    .font(.system(size: keyHeight * 0.36, weight: isPressed ? .bold : .regular))
                    .foregroundColor(isPressed ? .white : .secondary)
                context.draw(label, at: CGPoint(x: rect.midX, y: rect.midY))
            }
            if isPressed {
                // The fingertip: comes down onto the key and rests there while it is held.
                let lift = (1 - press) * keyHeight * 0.9
                let diameter = keyHeight * 0.95
                let finger = CGRect(x: rect.midX - diameter / 2, y: rect.midY - diameter / 2 - lift - keyHeight * 0.15,
                                    width: diameter, height: diameter)
                context.fill(Path(ellipseIn: finger), with: .color(Color(red: 0.93, green: 0.78, blue: 0.66).opacity(0.85)))
                context.stroke(Path(ellipseIn: finger), with: .color(Color.black.opacity(0.18)), lineWidth: 0.8)
            }
            x += width + gap
        }
    }
}
