//
//  SettingsPages.swift
//  OpenClicky
//
//  The settings pages of OpenClicky's one window (DictationWindow.swift), drawn from the Claude
//  Design "OpenClicky Settings Proposal": eight pages with coloured sidebar icons, each a grouped
//  form, and the native look they share. Every row comes from `SettingsCatalog`, so a page and a
//  search result draw the same control.
//

import AppKit
import Combine
import SwiftUI

/// The eight pages, in sidebar order. Your two pages (Your words, How it writes) sit among them,
/// after the pages that say `showsBeforeYourPages`.
enum DictationSettingsPage: String, CaseIterable, Identifiable {
    case general, dictation, clicky, orb, keyboard, privacy, account, about
    var id: String { rawValue }

    /// True for the pages the sidebar lists above your two pages: what you set up first (General,
    /// Dictation, Clicky) comes before what you dictated; the rest follows it.
    var showsBeforeYourPages: Bool {
        switch self {
        case .general, .dictation, .clicky: return true
        case .orb, .keyboard, .privacy, .account, .about: return false
        }
    }

    /// The settings pages above your two pages in the sidebar, in order.
    static var pagesBeforeYourPages: [DictationSettingsPage] { allCases.filter(\.showsBeforeYourPages) }

    /// The settings pages below your two pages in the sidebar, in order.
    static var pagesAfterYourPages: [DictationSettingsPage] { allCases.filter { !$0.showsBeforeYourPages } }

    var title: String {
        switch self {
        case .general: return "General"
        case .dictation: return "Dictation"
        case .keyboard: return "Keyboard"
        case .clicky: return "Clicky"
        case .orb: return "The Orb"
        case .privacy: return "Privacy & Security"
        case .account: return "Account"
        case .about: return "About"
        }
    }

    /// The sidebar icon, white on `tint`.
    var symbol: String {
        switch self {
        case .general: return "gearshape.fill"
        case .dictation: return "waveform"
        case .keyboard: return "command"
        case .clicky: return "cursorarrow"
        case .orb: return "capsule.fill"
        case .privacy: return "hand.raised.fill"
        case .account: return "person.crop.circle.fill"
        case .about: return "info"
        }
    }

    var tint: Color {
        switch self {
        case .general: return Color(red: 0.557, green: 0.557, blue: 0.576)
        case .dictation: return Color(red: 1.0, green: 0.231, blue: 0.188)
        case .keyboard: return Color(red: 0.388, green: 0.388, blue: 0.4)
        case .clicky: return Color(red: 1.0, green: 0.584, blue: 0.0)
        case .orb: return Color(red: 0.11, green: 0.11, blue: 0.118)
        case .privacy: return Color(red: 0.0, green: 0.478, blue: 1.0)
        case .account: return Color(red: 0.204, green: 0.78, blue: 0.349)
        case .about: return Color(red: 0.682, green: 0.682, blue: 0.698)
        }
    }
}

/// One page (or the search results) as a grouped form: a section per group, its footer under it.
struct SettingsFormView: View {
    let groups: [SettingsSectionGroup]

    var body: some View {
        Form {
            ForEach(groups) { group in
                Section {
                    ForEach(group.items) { item in item.view }
                } header: {
                    if !group.title.isEmpty { Text(group.title) }
                } footer: {
                    if !group.footers.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(group.footers) { footer in footer.view }
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Look

/// The settings window's colours and type: the system's own, so the window reads as part of
/// macOS in light and dark.
enum SettingsLook {
    /// The proposal's orange accent: #D24E2A in light, #E8653F in dark.
    static let accent = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 0.91, green: 0.396, blue: 0.247, alpha: 1)
            : NSColor(srgbRed: 0.824, green: 0.306, blue: 0.165, alpha: 1)
    })

    static let rowTitle = Font.system(size: 13)
    static let caption = Font.system(size: 11)
    static let micro = Font.system(size: 10)
    static let key = Font.system(size: 12, design: .monospaced)
    static func body(_ size: CGFloat, weight: Font.Weight = .regular) -> Font { .system(size: size, weight: weight) }

    static let inkTertiary = Color(nsColor: .tertiaryLabelColor)
    static let success = Color(nsColor: .systemGreen)
    static let danger = Color(nsColor: .systemRed)
    static let selection = accent.opacity(0.12)
    static let highlighter = Color.yellow.opacity(0.35)
    static let hairline = Color(nsColor: .separatorColor)
    static let warning = Color(nsColor: .systemOrange)

    enum Metric {
        /// The form gives every row its horizontal insets; rows add only this vertical breathing room.
        static let rowVertical: CGFloat = 2
        static let controlRadius: CGFloat = 5
    }
}

/// A native switch, small like System Settings' own. It carries the pointer cursor itself, so every
/// switch in the window shows it without each row having to remember.
struct SettingsSwitch: View {
    @Binding var isOn: Bool

    var body: some View {
        Toggle("", isOn: $isOn)
            .toggleStyle(.switch)
            .controlSize(.small)
            .labelsHidden()
            .tint(SettingsLook.accent)
            .pointerCursor()
    }
}

/// Keycaps for a shortcut row ("⌃ ⌥ hold"): one cap per key and the gesture beside them.
struct SettingsKeys: View {
    let keys: [String]
    var gesture: String?

    var body: some View {
        HStack(spacing: 4) {
            ForEach(Array(keys.enumerated()), id: \.offset) { _, key in
                Text(key)
                    .font(.system(size: 12))
                    .frame(minWidth: 22, minHeight: 20)
                    .padding(.horizontal, 5)
                    .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Color(nsColor: .controlColor)))
                    .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(Color(nsColor: .separatorColor)))
            }
            if let gesture {
                Text(gesture).font(.system(size: 12)).foregroundStyle(.secondary).padding(.leading, 4)
            }
        }
        .accessibilityElement(children: .combine)
    }
}
