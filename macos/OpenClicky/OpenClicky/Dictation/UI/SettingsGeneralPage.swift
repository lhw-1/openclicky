//
//  SettingsGeneralPage.swift
//  OpenClicky
//
//  Settings → General: how OpenClicky looks and starts. Appearance, where the island lives, the
//  menu bar icon (always on while the island is hidden), open at login, the walkthrough, reduce
//  motion. The quiet-take timeout moved to Dictation; version and help moved to About.
//

import AppKit
import Combine
import SwiftUI

extension SettingsCatalog {
    func generalItems() -> [SettingsItem] {
        let dictationKeyName = settings.dictationKey.keycapLabel
        return [
            SettingsItem(
                id: "general.appearance", page: .general, section: "",
                title: "Appearance", detail: "The orb and its transcript box follow this. The island stays black.",
                keywords: ["light", "dark", "auto", "match the mac", "theme", "mode", "colour", "color"],
                view: AnyView(AppearancePicker(settings: settings))),
            SettingsItem(
                id: "general.hudPlacement", page: .general, section: "",
                title: "Where OpenClicky lives", detail: "The notch, a drawer on the left or right edge, or hidden until you use a shortcut.",
                keywords: ["notch", "island", "hud", "side", "edge", "drawer", "hide", "hidden", "position", "placement", "shortcuts only"],
                view: AnyView(HUDPlacementRow(companionManager: companionManager))),
            SettingsItem(
                id: "general.menuBarIcon", page: .general, section: "",
                title: "Show in menu bar", detail: "Off is fine — the island is OpenClicky’s home.",
                keywords: ["menu bar", "status item", "icon", "tray"],
                view: AnyView(MenuBarIconRow(companionManager: companionManager))),
            SettingsItem(
                id: "general.openAtLogin", page: .general, section: "Startup",
                title: "Open at login", detail: "So \(dictationKeyName) always works.",
                keywords: ["startup", "launch", "restart", "login item", "boot"],
                view: AnyView(SettingsRow(title: "Open at login", detail: "So \(dictationKeyName) always works.") { LoginItemToggle() })),
            SettingsItem(
                id: "general.walkthrough", page: .general, section: "Startup",
                title: "Welcome walkthrough", detail: "Permissions, engine and a first take. About two minutes.",
                keywords: ["onboarding", "setup", "replay", "tour", "first run"],
                view: AnyView(SettingsRow(title: "Welcome walkthrough", detail: "Permissions, engine and a first take. About two minutes.") {
                    Button("Replay…") { companionManager.showDictationOnboarding(replay: true) }
                })),
            SettingsItem(
                id: "general.reduceMotion", page: .general, section: "Motion",
                title: "Reduce motion", detail: "The orb and the island appear and leave without animating.",
                keywords: ["animation", "motion", "accessibility", "calm"],
                view: AnyView(SettingsRow(title: "Reduce motion", detail: "The orb and the island appear and leave without animating.") {
                    SettingsToggle(settings: settings, keyPath: \.reduceAnimation)
                })),
        ]
    }
}

// MARK: - appearance

private struct AppearancePicker: View {
    @ObservedObject var settings: DictationSettings
    @Environment(\.settingsSearchQuery) private var searchQuery

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text(settingsHighlighted("Appearance", query: searchQuery)).font(SettingsLook.rowTitle)
                Text(settingsHighlighted("The orb and its transcript box follow this. The island stays black.", query: searchQuery))
                    .font(SettingsLook.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 16)
            HStack(spacing: 12) {
                ForEach(DictationAppearance.allCases) { appearance in
                    AppearanceTile(appearance: appearance, isSelected: settings.appearance == appearance) { settings.appearance = appearance }
                }
            }
        }
        .padding(.vertical, 4)
    }
}

private struct AppearanceTile: View {
    let appearance: DictationAppearance
    let isSelected: Bool
    let action: () -> Void

    private var label: String {
        switch appearance {
        case .light: return "Light"
        case .dark: return "Dark"
        case .system: return "Auto"
        }
    }

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                ZStack {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(appearance == .dark ? Color(white: 0.17) : Color(white: 0.95))
                    if appearance == .system {
                        Path { path in path.move(to: CGPoint(x: 68, y: 0)); path.addLine(to: CGPoint(x: 68, y: 46)); path.addLine(to: CGPoint(x: 0, y: 46)); path.closeSubpath() }
                            .fill(Color(white: 0.17))
                            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                    }
                    Capsule().fill(SettingsLook.accent).frame(width: 28, height: 18)
                }
                .frame(width: 68, height: 46)
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(isSelected ? SettingsLook.accent : Color(nsColor: .separatorColor), lineWidth: isSelected ? 2 : 0.5)
                )
                Text(label)
                    .font(.system(size: 11, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(isSelected ? .primary : .secondary)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

// MARK: - the island and the menu bar

extension HUDPlacement {
    /// The pop-up's label in the Settings window ("Left edge").
    var settingsTitle: String {
        switch self {
        case .notch: return "Notch"
        case .left: return "Left edge"
        case .right: return "Right edge"
        case .hidden: return "Hidden"
        }
    }

    var settingsDetail: String {
        switch self {
        case .notch: return "Hangs from the notch. Hover it to open."
        case .left: return "A drawer on the left edge of every screen. Hover the handle to open."
        case .right: return "A drawer on the right edge of every screen. Hover the handle to open."
        case .hidden: return "Nothing on screen until you use a shortcut. The menu bar icon opens the panel."
        }
    }
}

/// Follows `hudPlacement` on its own instead of observing the whole companion manager, which
/// republishes on every audio level.
private struct HUDPlacementRow: View {
    let companionManager: CompanionManager
    @State private var placement: HUDPlacement

    init(companionManager: CompanionManager) {
        self.companionManager = companionManager
        _placement = State(initialValue: companionManager.hudPlacement)
    }

    var body: some View {
        SettingsRow(title: "Where OpenClicky lives", detail: placement.settingsDetail) {
            Picker("", selection: Binding(get: { placement }, set: { companionManager.setHUDPlacement($0) })) {
                ForEach(HUDPlacement.allCases) { placement in Text(placement.settingsTitle).tag(placement) }
            }
            .labelsHidden()
            .fixedSize()
        }
        .onReceive(companionManager.$hudPlacement) { placement = $0 }
    }
}

/// Forced on while the island is hidden: the menu bar icon is then the only way into the panel.
private struct MenuBarIconRow: View {
    let companionManager: CompanionManager
    @State private var isVisible: Bool
    @State private var placement: HUDPlacement

    init(companionManager: CompanionManager) {
        self.companionManager = companionManager
        _isVisible = State(initialValue: companionManager.isMenuBarIconVisible)
        _placement = State(initialValue: companionManager.hudPlacement)
    }

    var body: some View {
        let isForcedOn = placement == .hidden
        SettingsRow(title: "Show in menu bar",
                    detail: isForcedOn ? "Always on while OpenClicky is hidden, so you can still reach it." : "Off is fine — the island is OpenClicky’s home.") {
            SettingsSwitch(isOn: Binding(get: { isVisible || isForcedOn }, set: { companionManager.setMenuBarIconVisible($0) }))
                .disabled(isForcedOn)
        }
        .onReceive(companionManager.$isMenuBarIconVisible) { isVisible = $0 }
        .onReceive(companionManager.$hudPlacement) { placement = $0 }
    }
}

// MARK: - startup

/// The login item, through SMAppService.
enum LoginItem {
    static var isEnabled: Bool { SMAppServiceBridge.isEnabled }
    @discardableResult
    static func set(enabled: Bool) -> Bool { SMAppServiceBridge.set(enabled: enabled) }
}

private struct LoginItemToggle: View {
    @State private var launchesAtLogin = LoginItem.isEnabled

    var body: some View {
        SettingsSwitch(isOn: Binding(get: { launchesAtLogin }, set: { isOn in launchesAtLogin = LoginItem.set(enabled: isOn) }))
            .onAppear { launchesAtLogin = LoginItem.isEnabled }
    }
}
