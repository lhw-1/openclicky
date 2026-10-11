//
//  SettingsClickyPage.swift
//  OpenClicky
//
//  Settings → Clicky: the companion. The pointer (shown or not, how visible, docked in the
//  island), the language Clicky speaks and listens in, fast voice and hands-free, and agent mode
//  with its model and workspace. These used to live only on the island or in the menu bar panel.
//

import AppKit
import Combine
import SwiftUI

extension SettingsCatalog {
    func clickyItems() -> [SettingsItem] {
        let usesRealtime = AccountCapabilities.current().usesRealtime
        var items: [SettingsItem] = [
            SettingsItem(
                id: "clicky.showPointer", page: .clicky, section: "Pointer",
                title: "Show the pointer", detail: "Off: it appears only while you talk.",
                keywords: ["pointer", "cursor", "buddy", "orange", "visible", "hide"],
                view: AnyView(CompanionSwitchRow(
                    title: "Show the pointer", detail: "Off: it appears only while you talk.",
                    publisher: companionManager.$isClickyCursorEnabled.eraseToAnyPublisher(),
                    initialValue: companionManager.isClickyCursorEnabled,
                    set: { [companionManager] in companionManager.setClickyCursorEnabled($0) }))),
            SettingsItem(
                id: "clicky.pointerPresence", page: .clicky, section: "Pointer",
                title: "The pointer shows", detail: "Always, while the mouse moves, or after a shake.",
                keywords: ["pointer", "cursor", "always", "while the mouse moves", "after a shake", "shake", "hide"],
                view: AnyView(PointerPresenceOptions(companionManager: companionManager))),
            SettingsItem(
                id: "clicky.dock", page: .clicky, section: "Pointer",
                title: "Dock the pointer in the island", detail: "It waits under the notch or in the drawer until Clicky needs it.",
                keywords: ["dock", "notch", "island", "drawer", "pointer", "park"],
                view: AnyView(CompanionSwitchRow(
                    title: "Dock the pointer in the island", detail: "It waits under the notch or in the drawer until Clicky needs it.",
                    publisher: companionManager.$isCursorDocked.eraseToAnyPublisher(),
                    initialValue: companionManager.isCursorDocked,
                    set: { [companionManager] in companionManager.setCursorDocked($0) }))),
            SettingsItem(
                id: "clicky.language", page: .clicky, section: "Voice",
                title: "Language", detail: "Clicky speaks and listens in this.",
                keywords: ["language", "english", "hindi", "tamil", "speak", "reply"],
                view: AnyView(ReplyLanguageRow())),
        ]
        // Fast voice and hands-free run on OpenAI Realtime, which only an own OpenAI key can use;
        // a free account would see switches that do nothing, so it gets the way to a key instead.
        if usesRealtime {
            items += [
                SettingsItem(
                    id: "clicky.fastVoice", page: .clicky, section: "Voice",
                    title: "Fast voice", detail: "Talks back instantly, over OpenAI Realtime.",
                    keywords: ["realtime", "voice", "fast", "openai"],
                    view: AnyView(CompanionSwitchRow(
                        title: "Fast voice", detail: "Talks back instantly, over OpenAI Realtime.",
                        publisher: companionManager.$isRealtimeVoiceEnabled.eraseToAnyPublisher(),
                        initialValue: companionManager.isRealtimeVoiceEnabled,
                        set: { [companionManager] in companionManager.setRealtimeVoiceEnabled($0) }))),
                SettingsItem(
                    id: "clicky.alwaysListening", page: .clicky, section: "Voice",
                    title: "Always listening", detail: "Hands-free: just talk, no keys. Needs fast voice.",
                    keywords: ["hands-free", "hands free", "always on", "listening"],
                    view: AnyView(CompanionSwitchRow(
                        title: "Always listening", detail: "Hands-free: just talk, no keys. Needs fast voice.",
                        publisher: companionManager.$isAlwaysListening.eraseToAnyPublisher(),
                        initialValue: companionManager.isAlwaysListening,
                        set: { [companionManager] in companionManager.setAlwaysListening($0) }))),
            ]
        } else {
            items.append(SettingsItem(
                id: "clicky.fastVoiceNeedsKey", page: .clicky, section: "Voice",
                title: "Fast voice and hands-free", detail: "Needs your own OpenAI key. A free account uses the standard voice.",
                keywords: ["realtime", "voice", "fast", "hands-free", "always listening", "openai", "key"],
                view: AnyView(SettingsRow(title: "Fast voice and hands-free", detail: "Needs your own OpenAI key. A free account uses the standard voice.") {
                    Button("Add Key…") { companionManager.showSettings(.account) }
                })))
        }
        items += [
            SettingsItem(
                id: "clicky.agentMode", page: .clicky, section: "Agent",
                title: "Agent mode", detail: "Clicky can hand work to Codex.",
                keywords: ["agent", "codex", "tasks", "automation"],
                view: AnyView(CompanionSwitchRow(
                    title: "Agent mode", detail: "Clicky can hand work to Codex.",
                    publisher: companionManager.$isAgentModeEnabled.eraseToAnyPublisher(),
                    initialValue: companionManager.isAgentModeEnabled,
                    set: { [companionManager] in companionManager.setAgentModeEnabled($0) }))),
            SettingsItem(
                id: "clicky.model", page: .clicky, section: "Agent",
                title: "Model", detail: "Which Claude answers your questions.",
                keywords: ["model", "claude", "sonnet", "opus"],
                view: AnyView(ClaudeModelRow(companionManager: companionManager))),
            SettingsItem(
                id: "clicky.workspace", page: .clicky, section: "Agent",
                title: "Workspace", detail: "Where agents keep their files.",
                keywords: ["workspace", "folder", "codex", "files", "directory"],
                view: AnyView(AgentWorkspaceRow())),
        ]
        return items
    }
}

/// A switch for one of the companion's own settings. It follows the one published value instead
/// of observing the whole companion manager, which republishes on every audio level.
private struct CompanionSwitchRow: View {
    let title: String
    let detail: String
    let publisher: AnyPublisher<Bool, Never>
    let set: (Bool) -> Void
    @State private var isOn: Bool

    init(title: String, detail: String, publisher: AnyPublisher<Bool, Never>, initialValue: Bool, set: @escaping (Bool) -> Void) {
        self.title = title
        self.detail = detail
        self.publisher = publisher
        self.set = set
        _isOn = State(initialValue: initialValue)
    }

    var body: some View {
        SettingsRow(title: title, detail: detail) {
            SettingsSwitch(isOn: Binding(get: { isOn }, set: { set($0) }))
        }
        .onReceive(publisher) { isOn = $0 }
    }
}

/// Always / while the mouse moves / after a shake, as radio options under "Show the pointer".
private struct PointerPresenceOptions: View {
    let companionManager: CompanionManager
    @State private var presence: PointerPresence
    @State private var isPointerShown: Bool
    @Environment(\.settingsSearchQuery) private var searchQuery

    init(companionManager: CompanionManager) {
        self.companionManager = companionManager
        _presence = State(initialValue: companionManager.pointerPresence)
        _isPointerShown = State(initialValue: companionManager.isClickyCursorEnabled)
    }

    private func title(for option: PointerPresence) -> String {
        switch option {
        case .always: return "Always"
        case .whileMoving: return "While the mouse moves"
        case .onShake: return "After a shake"
        }
    }

    private func detail(for option: PointerPresence) -> String {
        switch option {
        case .always: return "Follows the mouse everywhere."
        case .whileMoving: return "Fades a few seconds after the mouse rests."
        case .onShake: return "Hidden until you shake. A shake also releases a docked pointer."
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(PointerPresence.allCases) { option in
                Button(action: { companionManager.setPointerPresence(option) }) {
                    HStack(alignment: .top, spacing: 10) {
                        SettingsRadioDot(isSelected: presence == option).padding(.top, 1)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(settingsHighlighted(title(for: option), query: searchQuery)).font(SettingsLook.rowTitle)
                            Text(settingsHighlighted(detail(for: option), query: searchQuery))
                                .font(SettingsLook.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(title(for: option))
                .accessibilityHint(detail(for: option))
                .accessibilityAddTraits(presence == option ? .isSelected : [])
            }
        }
        .padding(.vertical, 4)
        .disabled(!isPointerShown)
        .opacity(isPointerShown ? 1 : 0.45)
        .onReceive(companionManager.$pointerPresence) { presence = $0 }
        .onReceive(companionManager.$isClickyCursorEnabled) { isPointerShown = $0 }
    }
}

/// The one language OpenClicky speaks and listens in (`language` in shell.json).
private struct ReplyLanguageRow: View {
    @State private var languageCode = ReplyLanguage.currentCode

    var body: some View {
        SettingsRow(title: "Language", detail: "Clicky speaks and listens in this.") {
            Picker("", selection: Binding(
                get: { languageCode },
                set: { chosenCode in
                    languageCode = chosenCode
                    OpenClickyConfiguration.update { $0.language = chosenCode }
                }
            )) {
                ForEach(ReplyLanguage.choices) { choice in Text(choice.name).tag(choice.code) }
            }
            .labelsHidden().fixedSize()
        }
    }
}

private struct ClaudeModelRow: View {
    let companionManager: CompanionManager
    @State private var model: String

    init(companionManager: CompanionManager) {
        self.companionManager = companionManager
        _model = State(initialValue: companionManager.selectedModel)
    }

    var body: some View {
        SettingsRow(title: "Model", detail: "Which Claude answers your questions.") {
            Picker("", selection: Binding(get: { model }, set: { companionManager.setSelectedModel($0) })) {
                Text("Sonnet").tag("claude-sonnet-4-6")
                Text("Opus").tag("claude-opus-4-6")
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
        }
        .onReceive(companionManager.$selectedModel) { model = $0 }
    }
}

/// The agents' workspace folder (`workspace` in shell.json), with a folder picker.
private struct AgentWorkspaceRow: View {
    @ObservedObject private var shellSettingsRevision = ShellSettingsRevision.shared

    var body: some View {
        let _ = shellSettingsRevision.revision
        SettingsRow(title: "Workspace", detail: OpenClickyConfiguration.workspacePath.replacingOccurrences(of: NSHomeDirectory(), with: "~")) {
            HStack(spacing: 8) {
                Button("Show in Finder") { NSWorkspace.shared.open(URL(fileURLWithPath: OpenClickyConfiguration.workspacePath)) }
                Button("Change…", action: chooseFolder)
            }
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = URL(fileURLWithPath: OpenClickyConfiguration.workspacePath)
        panel.prompt = "Use Folder"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        OpenClickyConfiguration.update { $0.workspace = url.path }
        ShellSettingsRevision.shared.noteChanged()
    }
}
