//
//  SettingsPluginsPage.swift
//  OpenClicky
//
//  Settings → Plugins: the island's optional extras, built for the Mac, one row with a switch
//  each (what it reads, what macOS may ask), and under them how the island picks between the
//  components it has: the default and the capsule's order.
//

import AppKit
import Combine
import SwiftUI

extension SettingsCatalog {
    func pluginsItems() -> [SettingsItem] {
        let pluginRows = IslandPluginRegistry.all.map { plugin in
            SettingsItem(
                id: "plugins.\(plugin.id)", page: .plugins, section: "",
                title: plugin.title, detail: plugin.settingsDetail ?? "",
                keywords: ["plugin", "plugins", "island", "extra", plugin.title.lowercased(), plugin.id],
                view: AnyView(IslandPluginRow(plugin: plugin)))
        }
        return pluginRows + [
            SettingsItem(
                id: "plugins.islandDefault", page: .plugins, section: "On the island",
                title: "Default component", detail: "What the open island shows when nothing else is going on.",
                keywords: ["island", "component", "panel", "shortcuts", "transcript", "agent", "default", "slot"],
                view: AnyView(IslandDefaultComponentRow())),
            SettingsItem(
                id: "plugins.islandOrder", page: .plugins, section: "On the island",
                title: "Component order", detail: "The order of the island's capsule when there is more than one to flip to.",
                keywords: ["island", "component", "order", "capsule", "arrange", "reorder"],
                view: AnyView(IslandComponentOrderRow())),
        ]
    }
}

// MARK: - one plugin

/// A plugin's switch, with its name and what it does on the left like every other row.
private struct IslandPluginRow: View {
    let plugin: any IslandComponent
    @State private var isOn = false

    var body: some View {
        SettingsRow(title: plugin.title, detail: plugin.settingsDetail ?? "") {
            SettingsSwitch(isOn: Binding(
                get: { isOn },
                set: { newValue in
                    isOn = newValue
                    var settings = IslandComponentSettings(defaults: .standard)
                    var enabled = settings.enabledPlugins.filter { $0 != plugin.id }
                    if newValue { enabled.append(plugin.id) }
                    settings.enabledPlugins = enabled
                }
            ))
            .accessibilityLabel(plugin.title)
        }
        .onAppear { isOn = IslandComponentSettings(defaults: .standard).enabledPlugins.contains(plugin.id) }
        .onReceive(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification).receive(on: DispatchQueue.main)) { _ in
            let next = IslandComponentSettings(defaults: .standard).enabledPlugins.contains(plugin.id)
            if next != isOn { isOn = next }
        }
    }
}

// MARK: - the island's pick

struct IslandDefaultComponentRow: View {
    @State private var defaultID = IslandComponentSettings(defaults: .standard).resolvedDefaultID(in: IslandComponentRegistry.all)
    @State private var choices = IslandDefaultComponentRow.choices()

    /// The built-ins and the extras that are on.
    @MainActor private static func choices() -> [any IslandComponent] {
        let settings = IslandComponentSettings(defaults: .standard)
        return IslandComponentRegistry.all.filter { settings.isEnabled($0.id, in: IslandComponentRegistry.all) }
    }

    var body: some View {
        SettingsRow(title: "Default component", detail: "What the open island shows when nothing else is going on.") {
            Picker("", selection: Binding(get: { defaultID }, set: { newValue in
                defaultID = newValue
                var settings = IslandComponentSettings(defaults: .standard)
                settings.defaultID = newValue
            })) {
                ForEach(choices, id: \.id) { component in Text(component.title).tag(component.id) }
            }
            .labelsHidden()
            .fixedSize()
            .pointerCursor()
        }
        // A switch flipped in the row below changes what can be the default: follow it.
        .onReceive(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification).receive(on: DispatchQueue.main)) { _ in
            let resolved = IslandComponentSettings(defaults: .standard).resolvedDefaultID(in: IslandComponentRegistry.all)
            if resolved != defaultID { defaultID = resolved }
            let next = Self.choices()
            if next.map(\.id) != choices.map(\.id) { choices = next }
        }
    }
}

/// The capsule's order: one row per component with up and down arrows.

struct IslandComponentOrderRow: View {
    @State private var order: [String] = IslandComponentOrderRow.resolvedOrder()

    /// The stored order, with unknown ids dropped and missing ones appended in registration order.
    @MainActor private static func resolvedOrder() -> [String] {
        let known = IslandComponentRegistry.all.map(\.id)
        let stored = IslandComponentSettings(defaults: .standard).order.filter { known.contains($0) }
        return stored + known.filter { !stored.contains($0) }
    }

    @State private var enabledPlugins = IslandComponentSettings(defaults: .standard).enabledPlugins

    var body: some View {
        SettingsRow(title: "Component order", detail: "The order of the island's capsule when there is more than one to flip to.") {
            VStack(alignment: .trailing, spacing: 4) {
                ForEach(Array(order.enumerated()), id: \.element) { index, id in
                    HStack(spacing: 6) {
                        Text(IslandComponentRegistry.all.first { $0.id == id }?.title ?? id)
                            .font(SettingsLook.caption)
                            .opacity(IslandComponentRegistry.all.first { $0.id == id }?.isPlugin == true && !enabledPlugins.contains(id) ? 0.5 : 1)
                        Button(action: { move(index, by: -1) }) { Image(systemName: "chevron.up") }
                            .disabled(index == 0)
                        Button(action: { move(index, by: 1) }) { Image(systemName: "chevron.down") }
                            .disabled(index == order.count - 1)
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification).receive(on: DispatchQueue.main)) { _ in
            let next = IslandComponentSettings(defaults: .standard).enabledPlugins
            if next != enabledPlugins { enabledPlugins = next }
        }
    }

    private func move(_ index: Int, by offset: Int) {
        let target = index + offset
        guard order.indices.contains(target) else { return }
        order.swapAt(index, target)
        var settings = IslandComponentSettings(defaults: .standard)
        settings.order = order
    }
}
