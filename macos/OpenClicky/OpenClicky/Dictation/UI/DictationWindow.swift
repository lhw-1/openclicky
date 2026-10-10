//
//  DictationWindow.swift
//  OpenClicky
//
//  The main window: one sidebar on the left (record, history; how it writes: dictionary,
//  shortcuts, styles; settings: a search field and the six settings pages; incognito and the
//  account pinned at the foot) and a page on the right. Settings used to be a separate mode that
//  swapped the sidebar for its own rail behind a small "settings ⌘," row, which people missed;
//  now every page is one click away in the same list. One window, reopened from the menu bar,
//  the orb's menu or the Dock, remembering its frame.
//

import AppKit
import Combine
import SwiftUI

enum DictationSection: String, CaseIterable, Identifiable {
    case record, history, dictionary, shortcuts, styles, settings
    var id: String { rawValue }

    var title: String { rawValue }

    var symbol: String {
        switch self {
        case .record: return "mic"
        case .history: return "clock"
        case .dictionary: return "sparkles"
        case .shortcuts: return "bolt"
        case .styles: return "pencil.line"
        case .settings: return "gearshape"
        }
    }
}

/// Six pages, each answering one question. `voice` was engine + microphone; `privacy` took in
/// permissions; `account` took in plan & usage; `general` took in about.
enum DictationSettingsPage: String, CaseIterable, Identifiable {
    case general, shortcuts, orb, voice, privacy, account
    var id: String { rawValue }

    var title: String {
        switch self {
        case .orb: return "the orb"
        // The sidebar also lists the spoken "shortcuts" (phrases that expand as you dictate) under
        // "how it writes"; two rows both called "shortcuts" would read as a duplicate. This page
        // is the keyboard: the dictation key, cancel, hands-free.
        case .shortcuts: return "keys & shortcuts"
        default: return rawValue
        }
    }
}

/// One row of the window's sidebar: a main page or one of the settings pages.
enum DictationSidebarRow: Hashable {
    case section(DictationSection)
    case settingsPage(DictationSettingsPage)
}

@MainActor
final class DictationWindowModel: ObservableObject {
    @Published var section: DictationSection = .record
    @Published var settingsPage: DictationSettingsPage = .general
    @Published var pendingHistorySearch: String?
    @Published var isRailCollapsed = false
    /// What is typed in the sidebar's "search settings" field. While it holds words the main area
    /// shows matching settings from every page, whatever row is selected; empty shows that row's page.
    @Published var settingsSearchText = ""

    var trimmedSettingsSearchText: String {
        settingsSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var isSearchingSettings: Bool { !trimmedSettingsSearchText.isEmpty }

    /// The row drawn as selected. None while searching: the results span every page, so
    /// highlighting one row would claim they belong to it.
    var selectedSidebarRow: DictationSidebarRow? {
        guard !isSearchingSettings else { return nil }
        return section == .settings ? .settingsPage(settingsPage) : .section(section)
    }

    /// A click on a sidebar row. Clears any search so the chosen page is what shows.
    func select(_ row: DictationSidebarRow) {
        settingsSearchText = ""
        switch row {
        case .section(let chosenSection):
            section = chosenSection
        case .settingsPage(let chosenPage):
            section = .settings
            settingsPage = chosenPage
        }
    }

    /// Every way into the window (menu bar, HUD, links on the pages) comes through here. A settings
    /// page wins over a section, and a leftover search is cleared, or it would hide the page asked for.
    /// With neither, the window just comes forward as it was.
    func open(section requestedSection: DictationSection? = nil, settingsPage requestedPage: DictationSettingsPage? = nil) {
        if let requestedPage {
            select(.settingsPage(requestedPage))
        } else if let requestedSection {
            select(.section(requestedSection))
        }
    }
}

@MainActor
final class DictationWindowController: NSWindowController, NSWindowDelegate {
    let model = DictationWindowModel()
    private let companionManager: CompanionManager
    private var appearanceCancellable: AnyCancellable?

    init(companionManager: CompanionManager) {
        self.companionManager = companionManager
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1180, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        window.title = "openclicky"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.minSize = NSSize(width: 900, height: 600)
        window.setFrameAutosaveName("OpenClickyDictationWindow")
        window.isReleasedWhenClosed = false
        window.backgroundColor = NSColor(Paper.background)
        super.init(window: window)
        window.delegate = self
        let hosting = NSHostingView(rootView: DictationRootView(model: model, companionManager: companionManager))
        // The window keeps its own size; the view fills it (SwiftUI would otherwise grow the window to its ideal height).
        hosting.sizingOptions = []
        window.contentView = hosting
        applyAppearance()
        appearanceCancellable = companionManager.dictationSettings.$appearance.sink { [weak self] _ in
            DispatchQueue.main.async { self?.applyAppearance() }
        }
        if window.frame.origin == .zero { window.center() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    private func applyAppearance() {
        window?.appearance = companionManager.dictationSettings.appearance.nsAppearance
    }

    func show(section: DictationSection? = nil, settingsPage: DictationSettingsPage? = nil) {
        model.open(section: section, settingsPage: settingsPage)
        // The sidebar may have been hidden with its toggle; a request for a page should show where it is.
        if section != nil || settingsPage != nil { model.isRailCollapsed = false }
        // A menu-bar-only app is not active when the window opens from the status item.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        // Back to a menu-bar app: no Dock icon while the window is closed.
        DispatchQueue.main.async {
            if !(NSApp.windows.contains { $0.isVisible && !($0 is NSPanel) }) {
                NSApp.setActivationPolicy(.accessory)
            }
        }
    }
}

// MARK: - Root

struct DictationRootView: View {
    @ObservedObject var model: DictationWindowModel
    let companionManager: CompanionManager

    var body: some View {
        HStack(spacing: 0) {
            if !model.isRailCollapsed {
                DictationRailView(model: model, companionManager: companionManager)
                    .frame(width: Paper.Metric.mainRail)
                Rectangle().fill(Paper.hairline).frame(width: 1)
            }
            Group {
                if model.isSearchingSettings {
                    // Search results replace whatever page is open; clearing the field brings it back.
                    DictationSettingsView(model: model, companionManager: companionManager)
                } else {
                    switch model.section {
                    case .record: RecordPageView(model: model, companionManager: companionManager)
                    case .history: HistoryPageView(model: model, companionManager: companionManager)
                    case .dictionary: DictionaryPageView(spaceStore: companionManager.dictationSpaceStore)
                    case .shortcuts: ShortcutsPageView(spaceStore: companionManager.dictationSpaceStore)
                    case .styles: StylesPageView(companionManager: companionManager)
                    case .settings: DictationSettingsView(model: model, companionManager: companionManager)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Paper.background)
        // ⌘, opens general settings. It sits on the root, not on a sidebar row, so it still works
        // with the sidebar hidden; and AppKit offers a key equivalent to the key window before the
        // menu bar, whose Settings item would open the app's empty settings scene.
        .background(
            Button("settings") { model.select(.settingsPage(.general)) }
                .keyboardShortcut(",", modifiers: .command)
                .hidden()
                .accessibilityHidden(true)
        )
        // ⌃⌘S shows or hides the sidebar, the Mac's usual shortcut for it.
        .background(
            Button("toggle sidebar") { model.isRailCollapsed.toggle() }
                .keyboardShortcut("s", modifiers: [.control, .command])
                .hidden()
                .accessibilityHidden(true)
        )
        // With the sidebar hidden its own button goes with it, so the same button sits beside the
        // window's close/minimise/zoom buttons to bring it back.
        .overlay(alignment: .topLeading) {
            if model.isRailCollapsed {
                Button(action: { model.isRailCollapsed = false }) {
                    Image(systemName: "sidebar.left").font(.system(size: 13)).foregroundStyle(Paper.inkSecondary)
                        .frame(width: 26, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain).pointerCursor().help("Show Sidebar (⌃⌘S)")
                .accessibilityLabel("show sidebar")
                .padding(.leading, 84)
                .padding(.top, 9)
            }
        }
        .ignoresSafeArea()
    }
}

struct DictationRailView: View {
    @ObservedObject var model: DictationWindowModel
    let companionManager: CompanionManager
    @ObservedObject private var settings: DictationSettings
    @ObservedObject private var spaceStore: DictationSpaceStore
    @ObservedObject private var authSession = OpenClickyAuthSession.shared
    // Observed so the per-page hit counts follow items whose relevance depends on it (the fn banner).
    @ObservedObject private var fnKeyState = FnKeyState.shared
    @State private var historyCount = 0
    @FocusState private var isSettingsSearchFieldFocused: Bool

    init(model: DictationWindowModel, companionManager: CompanionManager) {
        self.model = model
        self.companionManager = companionManager
        self.settings = companionManager.dictationSettings
        self.spaceStore = companionManager.dictationSpaceStore
    }

    var body: some View {
        let settingsSearchResults = settingsSearchMatches
        VStack(alignment: .leading, spacing: 0) {
            // The list scrolls when it is taller than the window (it is, at the 600 pt minimum);
            // incognito and the account stay pinned below it.
            ScrollViewReader { sidebarScroller in
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        OpenClickyWordmark()
                        Spacer()
                        Button(action: { model.isRailCollapsed.toggle() }) {
                            Image(systemName: "sidebar.left").font(.system(size: 13)).foregroundStyle(Paper.inkSecondary)
                        }
                        .buttonStyle(.plain).pointerCursor().help("Hide Sidebar (⌃⌘S)")
                    }
                    .padding(.top, 44)
                    .padding(.horizontal, 10)
                    .padding(.bottom, 18)

                    railButton(.section(.record), title: DictationSection.record.title) { Keycap(text: settings.dictationKey.keycapLabel) }
                    railButton(.section(.history), title: DictationSection.history.title) { railCount(historyCount) }

                    railGroupLabel("how it writes")
                    railButton(.section(.dictionary), title: DictationSection.dictionary.title) { railCount(spaceStore.space.dictionary.count) }
                    railButton(.section(.shortcuts), title: DictationSection.shortcuts.title) { railCount(spaceStore.space.shortcuts.count) }
                    railButton(.section(.styles), title: DictationSection.styles.title) { railCount(spaceStore.space.styles.count) }

                    railGroupLabel("settings")
                    settingsSearchField(resultCount: settingsSearchResults.count)
                        .padding(.bottom, 6)
                    ForEach(DictationSettingsPage.allCases) { page in
                        settingsPageRow(page, hitCount: model.isSearchingSettings ? settingsSearchResults.filter { $0.page == page }.count : nil)
                    }
                }
                .padding(.bottom, 8)
            }
            // At the minimum height "privacy" and "account" sit below the fold; a page opened from
            // elsewhere (the HUD, the account footer, "change engine") scrolls its row into view.
            .onAppear { scrollSelectedRowIntoView(with: sidebarScroller) }
            .onChange(of: model.selectedSidebarRow) { _ in scrollSelectedRowIntoView(with: sidebarScroller) }
            }

            Toggle(isOn: $settings.incognito) {
                Text("incognito").font(Paper.body(13)).foregroundStyle(Paper.ink)
            }
            .toggleStyle(RailSwitchStyle())
            .help(settings.incognito ? "incognito is on — takes paste but are not saved" : "incognito is off — takes are saved to history on this mac")
            .overlay(alignment: .top) { Rectangle().fill(Paper.hairline).frame(height: 1) }
            .padding(.top, 2)

            Button(action: { model.select(.settingsPage(.account)) }) {
                HStack(spacing: 10) {
                    ZStack {
                        Circle().fill(Paper.accentSoft)
                        Text(accountInitial).font(Paper.body(13, weight: .semibold)).foregroundStyle(Paper.ink)
                    }
                    .frame(width: 30, height: 30)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(accountName).font(Paper.rowTitle).foregroundStyle(Paper.ink).lineLimit(1).truncationMode(.tail)
                        Text(accountState).font(Paper.micro).foregroundStyle(Paper.inkTertiary).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .padding(10)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain).pointerCursor()
            .help("account")
            .overlay(alignment: .top) { Rectangle().fill(Paper.hairline).frame(height: 1) }
            .padding(.top, 8)
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 12)
        .frame(maxHeight: .infinity)
        .background(Paper.rail)
        .onAppear(perform: reloadHistoryCount)
        .onReceive(companionManager.dictationTakeController.$historyVersion) { _ in reloadHistoryCount() }
    }

    private func scrollSelectedRowIntoView(with sidebarScroller: ScrollViewProxy) {
        guard let selectedRow = model.selectedSidebarRow else { return }
        withAnimation(.easeOut(duration: 0.15)) { sidebarScroller.scrollTo(selectedRow) }
    }

    /// Every relevant setting the search matches, for the result count and the per-page hit counts.
    private var settingsSearchMatches: [SettingsItem] {
        guard model.isSearchingSettings else { return [] }
        let query = model.trimmedSettingsSearchText
        return SettingsCatalog(settings: settings, companionManager: companionManager, windowModel: model)
            .allItems.filter { $0.isRelevant() && $0.matches(query) }
    }

    /// The small label above a group of rows ("how it writes", "settings").
    private func railGroupLabel(_ text: String) -> some View {
        Text(text)
            .font(Paper.micro).foregroundStyle(Paper.inkTertiary)
            .padding(.top, 16).padding(.bottom, 4).padding(.leading, 10)
            .accessibilityAddTraits(.isHeader)
    }

    private func settingsSearchField(resultCount: Int) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(Paper.inkTertiary)
            TextField("search settings", text: $model.settingsSearchText)
                .textFieldStyle(.plain)
                .font(Paper.body(13))
                .foregroundStyle(Paper.ink)
                .focused($isSettingsSearchFieldFocused)
                .onExitCommand { model.settingsSearchText = "" }
            if model.isSearchingSettings {
                Button(action: { model.settingsSearchText = "" }) {
                    Text("\(resultCount) · esc")
                        .font(Paper.micro).foregroundStyle(Paper.inkTertiary).monospacedDigit()
                }
                .buttonStyle(.plain).pointerCursor()
                .help("\(resultCount) \(resultCount == 1 ? "result" : "results") — clear the search")
            }
        }
        .padding(.horizontal, 10)
        .frame(height: Paper.Metric.fieldHeight)
        .background(RoundedRectangle(cornerRadius: Paper.Metric.controlRadius, style: .continuous).fill(Paper.cardRaised))
        .overlay(RoundedRectangle(cornerRadius: Paper.Metric.controlRadius, style: .continuous)
            .strokeBorder(isSettingsSearchFieldFocused ? Paper.accentFill : Paper.hairline, lineWidth: isSettingsSearchFieldFocused ? 2 : 1))
    }

    /// A settings page's row. "general" carries the ⌘, hint; while searching each row carries its
    /// hit count instead, and a page with no hits is dimmed.
    private func settingsPageRow(_ page: DictationSettingsPage, hitCount: Int?) -> some View {
        let isDimmed = hitCount == 0
        return railButton(.settingsPage(page), title: page.title, isDimmed: isDimmed) {
            if let hitCount {
                if hitCount > 0 { railCount(hitCount) }
            } else if page == .general {
                Text("⌘ ,").font(Paper.micro).foregroundStyle(Paper.inkTertiary)
            }
        }
        .accessibilityLabel(hitCount.map { "\(page.title), \($0) results" } ?? page.title)
    }

    /// "Prasanth S." — the first name and the initial of the last, or the signed-in address's name.
    private var accountName: String {
        if let email = authSession.accountEmail { return String(email.split(separator: "@").first ?? "") }
        let nameParts = NSFullUserName().split(separator: " ")
        guard let firstName = nameParts.first else { return "you" }
        if nameParts.count > 1, let lastInitial = nameParts.last?.first { return "\(firstName) \(lastInitial)." }
        return String(firstName)
    }

    private var accountState: String {
        authSession.accountEmail == nil ? "personal · no account" : "signed in · openclicky account"
    }

    private var accountInitial: String {
        String(accountName.prefix(1)).lowercased()
    }

    private func reloadHistoryCount() {
        historyCount = (try? companionManager.dictationTakeStore?.stats().allTimeTakes) ?? 0
    }

    private func railCount(_ count: Int) -> some View {
        Text("\(count)").font(Paper.caption).foregroundStyle(Paper.inkTertiary).monospacedDigit()
    }

    private func railButton<Trailing: View>(_ row: DictationSidebarRow, title: String, isDimmed: Bool = false, @ViewBuilder trailing: () -> Trailing) -> some View {
        let selected = model.selectedSidebarRow == row
        return Button(action: { model.select(row) }) {
            HStack(spacing: 8) {
                Text(title).font(Paper.body(13, weight: selected ? .semibold : .regular))
                    .foregroundStyle(isDimmed ? Paper.inkTertiary : Paper.ink)
                    .lineLimit(1)
                Spacer()
                trailing()
            }
            .padding(.horizontal, 10)
            .frame(height: Paper.Metric.railItemHeight)
            .background(RoundedRectangle(cornerRadius: Paper.Metric.railItemRadius, style: .continuous).fill(selected ? Paper.selection : Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .accessibilityAddTraits(selected ? .isSelected : [])
        .id(row)
    }
}

/// A labelled rail row with a small switch on the right ("incognito").
private struct RailSwitchStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button(action: { configuration.isOn.toggle() }) {
            HStack {
                configuration.label
                Spacer()
                Capsule()
                    .fill(configuration.isOn ? Paper.success : Paper.hairline)
                    .frame(width: 28, height: 16)
                    .overlay(alignment: configuration.isOn ? .trailing : .leading) {
                        Circle().fill(Color.white).frame(width: 12, height: 12).padding(2)
                    }
                    .animation(.easeOut(duration: 0.15), value: configuration.isOn)
            }
            .padding(.horizontal, 10)
            .frame(height: Paper.Metric.railItemHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .accessibilityValue(configuration.isOn ? "on" : "off")
    }
}

/// A page's scrolling body with the standard margins.
struct PageScaffold<Content: View>: View {
    let title: String
    var trailing: AnyView?
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView(showsIndicators: true) {
            VStack(alignment: .leading, spacing: 22) {
                HStack(alignment: .center) {
                    PaperHeading(text: title)
                    Spacer()
                    if let trailing { trailing }
                }
                .padding(.top, Paper.Metric.windowTop)
                content
            }
            .padding(.horizontal, Paper.Metric.windowSides)
            .padding(.bottom, 40)
            .frame(maxWidth: 900, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
