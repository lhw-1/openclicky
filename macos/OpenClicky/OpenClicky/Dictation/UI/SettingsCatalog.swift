//
//  SettingsCatalog.swift
//  OpenClicky
//
//  Every setting is a `SettingsItem` in `SettingsCatalog`: title, copy, page, section and the
//  control itself, so a page and a search result in the window (SettingsPages.swift)
//  draw the very same row, and a control found by search can be changed right there. The pages'
//  items live in the Settings*Page.swift files beside this one; the rows here are drawn with
//  the system's own controls and type (`SettingsLook`).
//

import AppKit
import Combine
import SwiftUI

/// "OpenClicky 0.8.1 (285)", from the bundle.
enum AppVersion {
    static var shortVersion: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "" }
    static var buildNumber: String { Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "" }
    static var displayString: String { "OpenClicky \(shortVersion) (\(buildNumber))" }
}

// MARK: - The catalog

/// One setting: what it is called, what it says, where it lives, and the row that changes it.
struct SettingsItem: Identifiable {
    enum Chrome {
        /// A row inside the section's group, divided from its neighbours.
        case card
        /// A note under the section's group (the privacy summary, "language moved to styles").
        case footer
    }

    let id: String
    let page: DictationSettingsPage
    /// The label above the group ("Startup"); empty for a page's unlabelled first group.
    let section: String
    let title: String
    var detail: String = ""
    /// Other words someone might search for ("startup" for open at login).
    var keywords: [String] = []
    var chrome: Chrome = .card
    /// False hides the item from its page and from search (the fn banner once fn is free).
    var isRelevant: @MainActor () -> Bool = { true }
    let view: AnyView

    func matches(_ query: String) -> Bool {
        let searchableText = ([title, detail, section, page.title] + keywords).joined(separator: " ")
        return query
            .lowercased()
            .split(separator: " ")
            .allSatisfy { searchableText.localizedCaseInsensitiveContains($0) }
    }
}

/// Every setting on every page, built against the live settings so the rows are operable.
@MainActor
struct SettingsCatalog {
    let settings: DictationSettings
    let companionManager: CompanionManager

    /// In page order; within a page, in the order the page shows them.
    var allItems: [SettingsItem] {
        DictationSettingsPage.allCases.flatMap { items(for: $0) }
    }

    func items(for page: DictationSettingsPage) -> [SettingsItem] {
        switch page {
        case .general: return generalItems()
        case .dictation: return dictationItems()
        case .keyboard: return keyboardItems()
        case .clicky: return clickyItems()
        case .orb: return orbItems()
        case .privacy: return privacyItems()
        case .account: return accountItems()
        case .about: return aboutItems()
        }
    }
}

/// One section of a page: its rows, and the notes under it.
struct SettingsSectionGroup: Identifiable {
    let id: String
    let title: String
    let items: [SettingsItem]
    var footers: [SettingsItem] = []

    /// Consecutive items with the same section form one group; a footer item joins the group
    /// before it.
    static func groups(_ items: [SettingsItem], title: (SettingsItem) -> String = { $0.section }) -> [SettingsSectionGroup] {
        var groups: [SettingsSectionGroup] = []
        for item in items {
            let groupTitle = title(item)
            if let last = groups.last, last.title == groupTitle {
                var merged = last
                if item.chrome == .footer {
                    merged.footers.append(item)
                } else {
                    merged = SettingsSectionGroup(id: last.id, title: last.title, items: last.items + [item], footers: last.footers)
                }
                groups[groups.count - 1] = merged
            } else if item.chrome == .footer {
                groups.append(SettingsSectionGroup(id: "\(groups.count)-\(groupTitle)", title: groupTitle, items: [], footers: [item]))
            } else {
                groups.append(SettingsSectionGroup(id: "\(groups.count)-\(groupTitle)", title: groupTitle, items: [item]))
            }
        }
        return groups
    }
}

private struct SettingsSearchQueryKey: EnvironmentKey {
    static let defaultValue = ""
}

extension EnvironmentValues {
    /// The search the row is shown for; its title and copy mark the matched words.
    var settingsSearchQuery: String {
        get { self[SettingsSearchQueryKey.self] }
        set { self[SettingsSearchQueryKey.self] = newValue }
    }
}

/// `text` with every word of `query` marked with the highlighter.
func settingsHighlighted(_ text: String, query: String) -> AttributedString {
    var attributed = AttributedString(text)
    for word in query.split(separator: " ") where !word.isEmpty {
        var searchStart = attributed.startIndex
        while searchStart < attributed.endIndex,
              let range = attributed[searchStart...].range(of: String(word), options: [.caseInsensitive, .diacriticInsensitive]) {
            attributed[range].backgroundColor = SettingsLook.highlighter
            searchStart = range.upperBound
        }
    }
    return attributed
}

// MARK: - Rows and small controls

/// A settings row: title, a line of copy, and the control on the right.
struct SettingsRow<Trailing: View>: View {
    let title: String
    var detail: String?
    @ViewBuilder var trailing: Trailing
    @Environment(\.settingsSearchQuery) private var searchQuery

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text(settingsHighlighted(title, query: searchQuery)).font(SettingsLook.rowTitle)
                if let detail, !detail.isEmpty {
                    Text(settingsHighlighted(detail, query: searchQuery))
                        .font(SettingsLook.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 16)
            trailing
        }
        .padding(.vertical, SettingsLook.Metric.rowVertical)
        .accessibilityElement(children: .contain)
        .accessibilityHint(detail ?? "")
    }
}

/// A switch bound to one of the dictation settings, observing them itself so it stays live
/// wherever it is drawn (a page or a search result).
struct SettingsToggle: View {
    @ObservedObject var settings: DictationSettings
    let keyPath: ReferenceWritableKeyPath<DictationSettings, Bool>

    var body: some View {
        SettingsSwitch(isOn: Binding(get: { settings[keyPath: keyPath] }, set: { settings[keyPath: keyPath] = $0 }))
    }
}

/// A small tag beside a title ("Private · offline", "Audio goes to Sarvam").
struct SettingsTag: View {
    let text: String
    var isPositive = false

    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(isPositive ? Color(nsColor: .systemGreen) : .secondary)
            .padding(.horizontal, 6).padding(.vertical, 1)
            .background(RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(isPositive ? Color(nsColor: .systemGreen).opacity(0.15) : Color.primary.opacity(0.07)))
    }
}

/// A note under a section ("Keys are sent to the OpenClicky backend…").
struct SettingsFootnote: View {
    let text: String
    @Environment(\.settingsSearchQuery) private var searchQuery

    var body: some View {
        Text(settingsHighlighted(text, query: searchQuery))
            .font(SettingsLook.caption).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

func openExternalLink(_ address: String) {
    if let url = URL(string: address) { NSWorkspace.shared.open(url) }
}

/// Bumps whenever shell.json changes — from these pages or edited by hand — so rows that read
/// it (the sarvam key, the provider badges, the account's backend and token) redraw.
@MainActor
final class ShellSettingsRevision: ObservableObject {
    static let shared = ShellSettingsRevision()

    @Published private(set) var revision = 0
    private var credentialsObserver: NSObjectProtocol?

    private init() {
        credentialsObserver = NotificationCenter.default.addObserver(
            forName: OpenClickyConfiguration.credentialsChangedNotification, object: nil, queue: .main
        ) { _ in
            Task { @MainActor in ShellSettingsRevision.shared.noteChanged() }
        }
    }

    /// Call after writing shell.json through `OpenClickyConfiguration.update`.
    func noteChanged() { revision += 1 }
}
