//
//  DictationSettingsView.swift
//  OpenClicky
//
//  Settings' main area: one page at a time, or search results across every page. The pages and
//  the "search settings" field live in the window's one sidebar (`DictationRailView`), in its
//  "settings" group; the search text is on `DictationWindowModel`. Every setting is a `SettingsItem`
//  in `SettingsCatalog` — title, copy, page, section and the control itself — so a page and a
//  search result draw the very same row, and a control found by search can be changed right
//  there. The pages' items live in the SettingsPage*.swift files beside this one.
//

import AppKit
import Combine
import SwiftUI

struct DictationSettingsView: View {
    @ObservedObject var model: DictationWindowModel
    let companionManager: CompanionManager
    @ObservedObject private var settings: DictationSettings
    // Observed so items whose relevance depends on them (the fn banner, the sign-in rows) are
    // re-filtered when they change.
    @ObservedObject private var fnKeyState = FnKeyState.shared
    @ObservedObject private var authSession = OpenClickyAuthSession.shared

    init(model: DictationWindowModel, companionManager: CompanionManager) {
        self.model = model
        self.companionManager = companionManager
        self.settings = companionManager.dictationSettings
    }

    private var catalog: SettingsCatalog {
        SettingsCatalog(settings: settings, companionManager: companionManager, windowModel: model)
    }

    var body: some View {
        let query = model.trimmedSettingsSearchText
        Group {
            if query.isEmpty {
                SettingsPageView(page: model.settingsPage, catalog: catalog)
                    .id(model.settingsPage)
            } else {
                SettingsSearchResultsView(
                    query: query,
                    results: catalog.allItems.filter { $0.isRelevant() && $0.matches(query) },
                    onSuggestion: { model.settingsSearchText = $0 })
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { fnKeyState.refresh() }
    }
}

/// "openclicky 0.6.0 (151)", from the bundle.
enum AppVersion {
    static var shortVersion: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "" }
    static var buildNumber: String { Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "" }
    static var displayString: String { "openclicky \(shortVersion) (\(buildNumber))" }
}

// MARK: - The catalog

/// One setting: what it is called, what it says, where it lives, and the row that changes it.
struct SettingsItem: Identifiable {
    enum Chrome {
        /// A row inside the section's card, divided from its neighbours.
        case card
        /// Drawn on its own, outside any card (the fn banner, a footer note).
        case bare
    }

    let id: String
    let page: DictationSettingsPage
    /// The label above the card ("behavior"); empty for a page's unlabelled first card.
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
    let windowModel: DictationWindowModel

    var allItems: [SettingsItem] {
        DictationSettingsPage.allCases.flatMap { items(for: $0) }
    }

    func items(for page: DictationSettingsPage) -> [SettingsItem] {
        switch page {
        case .general: return generalItems()
        case .shortcuts: return shortcutsItems()
        case .orb: return orbItems()
        case .voice: return voiceItems()
        case .privacy: return privacyItems()
        case .account: return accountItems()
        }
    }

    /// The page's "reset page" action, when it has one.
    func resetAction(for page: DictationSettingsPage) -> (() -> Void)? {
        switch page {
        case .general: return { settings.resetGeneralToDefaults() }
        case .shortcuts: return { settings.resetShortcutsToDefaults() }
        case .orb: return { settings.resetOrbToDefaults() }
        case .voice, .privacy, .account: return nil
        }
    }
}

/// Items of one section, in the order the catalog lists them.
struct SettingsSectionGroup: Identifiable {
    let id: String
    let title: String
    let chrome: SettingsItem.Chrome
    let items: [SettingsItem]

    /// Consecutive items with the same section and chrome form one group.
    static func groups(_ items: [SettingsItem], title: (SettingsItem) -> String = { $0.section }) -> [SettingsSectionGroup] {
        var groups: [SettingsSectionGroup] = []
        for item in items {
            let groupTitle = title(item)
            if let last = groups.last, last.title == groupTitle, last.chrome == item.chrome {
                groups[groups.count - 1] = SettingsSectionGroup(id: last.id, title: last.title, chrome: last.chrome, items: last.items + [item])
            } else {
                groups.append(SettingsSectionGroup(id: "\(groups.count)-\(groupTitle)", title: groupTitle, chrome: item.chrome, items: [item]))
            }
        }
        return groups
    }
}

/// Section labels and cards for a run of items.
struct SettingsSectionsView: View {
    let groups: [SettingsSectionGroup]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(groups.enumerated()), id: \.element.id) { index, group in
                // A label only where the section changes: a bare note under a card belongs to it.
                let previousTitle = index > 0 ? groups[index - 1].title : nil
                if !group.title.isEmpty && group.title != previousTitle {
                    SettingsSectionLabel(text: group.title)
                }
                switch group.chrome {
                case .card:
                    PaperCard {
                        VStack(spacing: 0) {
                            ForEach(Array(group.items.enumerated()), id: \.element.id) { itemIndex, item in
                                if itemIndex > 0 { Rectangle().fill(Paper.lineSoft).frame(height: 1) }
                                item.view
                            }
                        }
                    }
                case .bare:
                    ForEach(group.items) { item in item.view }
                }
            }
        }
    }
}

// MARK: - A page

struct SettingsPageView: View {
    let page: DictationSettingsPage
    let catalog: SettingsCatalog

    var body: some View {
        let groups = SettingsSectionGroup.groups(catalog.items(for: page).filter { $0.isRelevant() })
        if page == .orb {
            // The orb's page keeps its live preview beside the settings when there is room.
            GeometryReader { proxy in
                if proxy.size.width >= 900 {
                    HStack(alignment: .top, spacing: 0) {
                        scrollingPage(groups: groups, includesPreview: false)
                        OrbLivePreviewPanel(settings: catalog.settings)
                            .frame(width: 300)
                            .padding(.top, 44 + 52)
                            .padding(.trailing, Paper.Metric.windowSides)
                    }
                } else {
                    scrollingPage(groups: groups, includesPreview: true)
                }
            }
        } else {
            scrollingPage(groups: groups, includesPreview: false)
        }
    }

    private func scrollingPage(groups: [SettingsSectionGroup], includesPreview: Bool) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                SettingsPageHeader(title: page.title, onReset: catalog.resetAction(for: page))
                if includesPreview { OrbLivePreviewPanel(settings: catalog.settings) }
                SettingsSectionsView(groups: groups)
            }
            .padding(.top, 44)
            .padding(.horizontal, Paper.Metric.windowSides)
            .padding(.bottom, 40)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct SettingsPageHeader: View {
    let title: String
    var onReset: (() -> Void)?

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).font(Paper.pageTitle).foregroundStyle(Paper.ink)
                .accessibilityAddTraits(.isHeader)
            Spacer()
            if let onReset {
                Button("reset page", action: onReset).buttonStyle(PaperPillButtonStyle())
                    .help("puts this page back the way a fresh install has it")
            }
        }
        .padding(.bottom, 4)
    }
}

/// The small label above a card ("appearance", "behavior").
struct SettingsSectionLabel: View {
    let text: String
    var body: some View {
        Text(text)
            .font(Paper.body(12, weight: .semibold))
            .foregroundStyle(Paper.inkSecondary)
            .padding(.top, 12)
            .padding(.leading, 2)
            .accessibilityAddTraits(.isHeader)
    }
}

// MARK: - Search results

struct SettingsSearchResultsView: View {
    let query: String
    let results: [SettingsItem]
    let onSuggestion: (String) -> Void

    private let suggestions = ["key", "paste", "orb", "microphone", "sarvam", "history"]

    var body: some View {
        let groups = SettingsSectionGroup.groups(results) { item in
            item.section.isEmpty ? item.page.title : "\(item.page.title) › \(item.section)"
        }
        let pagesWithHits = Set(results.map(\.page))
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text(results.isEmpty ? "nothing mentions “\(query)”" : "\(results.count) \(results.count == 1 ? "setting mentions" : "settings mention") “\(query)”")
                    .font(Paper.pageTitle).foregroundStyle(Paper.ink)
                    .padding(.bottom, 4)
                SettingsSectionsView(groups: groups)
                    .environment(\.settingsSearchQuery, query)
                if pagesWithHits.count < DictationSettingsPage.allCases.count {
                    HStack(spacing: 4) {
                        Text(results.isEmpty ? "try" : "no match on other pages. try")
                        ForEach(suggestions.filter { $0 != query.lowercased() }.prefix(3), id: \.self) { suggestion in
                            Button("“\(suggestion)”") { onSuggestion(suggestion) }
                                .buttonStyle(.plain).foregroundStyle(Paper.accentFill).pointerCursor()
                        }
                    }
                    .font(Paper.caption).foregroundStyle(Paper.inkSecondary)
                    .padding(.top, 8)
                }
            }
            .padding(.top, 44)
            .padding(.horizontal, Paper.Metric.windowSides)
            .padding(.bottom, 40)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
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
            attributed[range].backgroundColor = Paper.highlighter
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
            VStack(alignment: .leading, spacing: 3) {
                Text(settingsHighlighted(title, query: searchQuery)).font(Paper.rowTitle).foregroundStyle(Paper.ink)
                if let detail, !detail.isEmpty {
                    Text(settingsHighlighted(detail, query: searchQuery))
                        .font(Paper.caption).foregroundStyle(Paper.inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 16)
            trailing
        }
        .padding(.horizontal, Paper.Metric.rowHorizontal)
        .padding(.vertical, Paper.Metric.rowVertical)
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
        PaperToggle(isOn: Binding(get: { settings[keyPath: keyPath] }, set: { settings[keyPath: keyPath] = $0 }))
    }
}

/// A small tag beside a title ("private · offline", "audio goes to sarvam").
struct SettingsTag: View {
    let text: String
    var tint: Color = Paper.inkSecondary

    var body: some View {
        Text(text)
            .font(Paper.micro)
            .foregroundStyle(tint)
            .padding(.horizontal, 6).padding(.vertical, 1)
            .background(Capsule().fill(Paper.highlighter.opacity(0.6)))
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
