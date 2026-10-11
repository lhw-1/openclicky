//
//  HUDPlacement.swift
//  OpenClicky
//
//  Where the island lives: hanging from the notch (the default), tucked against the left or right
//  edge of the screen as a drawer, or nowhere at all while idle (shortcuts only: the busy strip,
//  the composer and the permission cards still open under the notch, and the menu bar icon is
//  how the panel opens).
//

import Foundation

enum HUDPlacement: String, CaseIterable, Identifiable {
    case notch, left, right, hidden

    var id: String { rawValue }

    static let defaultsKey = "openclicky.hudPlacement"

    static var stored: HUDPlacement {
        UserDefaults.standard.string(forKey: defaultsKey).flatMap(HUDPlacement.init(rawValue:)) ?? .notch
    }

    var title: String {
        switch self {
        case .notch: return "notch"
        case .left: return "left edge"
        case .right: return "right edge"
        case .hidden: return "hidden"
        }
    }

    var detail: String {
        switch self {
        case .notch: return "hangs from the notch; hover it to open."
        case .left: return "a drawer on the left edge of every screen; hover the handle to open."
        case .right: return "a drawer on the right edge of every screen; hover the handle to open."
        case .hidden: return "nothing on screen until you use a shortcut. the menu bar icon opens the panel."
        }
    }

    /// True for the two drawer placements, whose island hangs from a screen edge instead of the top.
    var isSideDrawer: Bool { self == .left || self == .right }
}

/// How tall the open island is. The regular panel is sized for a 14-inch MacBook; on a smaller or
/// zoomed display ("Larger Text" in Displays) it covers a big share of the screen, so Automatic
/// switches to the short panel below 940 pt of screen height (a 13-inch 1440 × 900 display and down).
enum HUDSize: String, CaseIterable, Identifiable {
    case automatic, regular, compact

    var id: String { rawValue }

    static let defaultsKey = "openclicky.hudSize"
    static let automaticCompactBelowScreenHeight: CGFloat = 940

    static var stored: HUDSize {
        UserDefaults.standard.string(forKey: defaultsKey).flatMap(HUDSize.init(rawValue:)) ?? .automatic
    }

    /// Whether the island uses its short layout on a screen this tall (points).
    func usesCompactLayout(screenHeight: CGFloat) -> Bool {
        switch self {
        case .automatic: return screenHeight > 0 && screenHeight < Self.automaticCompactBelowScreenHeight
        case .regular: return false
        case .compact: return true
        }
    }
}
