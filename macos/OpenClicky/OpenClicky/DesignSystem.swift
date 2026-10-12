//
//  DesignSystem.swift
//  OpenClicky
//
//  The shared tokens the companion UI draws with: the overlay pointer and agent card colours, the
//  notch island's always-dark palette and sizes, the pointer cursor every button shows, and
//  `Color(hex:)`.
//

import SwiftUI
import AppKit

// MARK: - Design System Namespace

/// The top-level namespace for the design tokens.
/// Usage: `DS.Colors.overlayCursorColor`, `DS.HUD.text`, etc.
enum DS {

    // MARK: - Color Tokens

    enum Colors {

        /// The agent result card's status dot once the agent has answered.
        static let accent = Color(hex: "#2563eb")             // Tailwind Blue 600

        /// The agent result card's status dot while the companion is still working.
        static let warning = Color(hex: "#FFB224")            // Radix Amber 9

        // ── Overlay Cursor ───────────────────────────────────────────

        /// The cursor/bubble color used in OverlayWindow.
        /// Kept distinct from the accent since it serves a different purpose
        /// (screen overlay vs in-app UI).
        // OpenClicky: the buddy is red-orange like the current HeyClicky cursor (upstream was blue #3380FF).
        static let overlayCursorColor = Color(hex: "#F0452B")
    }

    // MARK: - HUD (the notch island, always dark)

    /// The refinement sheet's "HUD · always dark" palette and control sizes. The island does not
    /// follow the system appearance: it is part of the notch.
    enum HUD {
        static let island = Color(hex: "#000000")
        /// Pills and the gear in the band, a step lighter than the island.
        static let bandControl = Color(hex: "#1A1A1A")
        static let surfaceRaised = Color(hex: "#262626")
        /// The (i) button and other secondary squares on a surface.
        static let surfaceRaisedSoft = Color(hex: "#2A2A2A")
        static let text = Color(hex: "#FFFFFF")
        static let text2 = Color(hex: "#A3A3A3")
        static let text3 = Color(hex: "#8A8A8A")
        static let pointer = Color(hex: "#FF5A3C")
        /// The "!" disc behind a permission card's mark.
        static let pointerTint = Color(hex: "#2A1A14")
        static let live = Color(hex: "#34C77B")

        static let pillHeight: CGFloat = 24
        static let tileSize: CGFloat = 40
        static let minimumHitSize: CGFloat = 22
        static let tileRadius: CGFloat = 10
        static let islandRadius: CGFloat = 22
        static let bodySidePadding: CGFloat = 16
        static let stripWidth: CGFloat = 380
        static let stripHeight: CGFloat = 37
    }
}

// MARK: - Pointer Cursor

extension View {
    /// Attaches the shared pointing-hand cursor treatment used across interactive controls.
    /// Disabled controls can opt out so they keep the default arrow cursor.
    func pointerCursor(isEnabled: Bool = true) -> some View {
        self.overlay {
            if isEnabled {
                PointerCursorView()
            }
        }
    }
}

// MARK: - Pointer Cursor (AppKit Bridge)

/// Uses AppKit's cursor rect system to reliably show a pointing hand cursor.
/// More reliable than NSCursor.push()/pop() inside SwiftUI's .onHover because
/// cursor rects are managed at the window level and don't conflict with
/// SwiftUI's internal cursor handling.
private class PointerCursorNSView: NSView {
    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .pointingHand)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        return nil
    }
}

private struct PointerCursorView: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        return PointerCursorNSView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        // Invalidate cursor rects when the view updates (e.g., resizes)
        // so AppKit recalculates the cursor area.
        nsView.window?.invalidateCursorRects(for: nsView)
    }
}

// MARK: - Color Utilities

extension Color {
    /// Create a Color from a hex string like "#FF5733" or "FF5733".
    init(hex: String) {
        let hexSanitized = hex.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "#", with: "")

        var rgbValue: UInt64 = 0
        Scanner(string: hexSanitized).scanHexInt64(&rgbValue)

        let red = Double((rgbValue & 0xFF0000) >> 16) / 255.0
        let green = Double((rgbValue & 0x00FF00) >> 8) / 255.0
        let blue = Double(rgbValue & 0x0000FF) / 255.0

        self.init(red: red, green: green, blue: blue)
    }
}
