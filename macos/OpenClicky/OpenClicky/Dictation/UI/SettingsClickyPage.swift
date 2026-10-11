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
import AVFoundation
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
                id: "clicky.answerSource", page: .clicky, section: "Voice",
                title: "Answers come from", detail: "Automatic uses your own keys first, then plans you switched on, then the free credits.",
                keywords: ["provider", "model", "openai", "anthropic", "claude", "openrouter", "gemini", "groq", "mistral", "grok", "codex", "subscription", "plan", "answers"],
                view: AnyView(AnswerSourceRow())),
            SettingsItem(
                id: "clicky.speechVoice", page: .clicky, section: "Voice",
                title: "Voice", detail: "Who speaks the answers: the cloud voice, or this Mac’s own voice, free and offline.",
                keywords: ["voice", "speech", "tts", "text to speech", "elevenlabs", "eleven labs", "offline", "on device",
                           "mac voice", "premium voice", "siri", "credits", "allowance", "left"],
                view: AnyView(SpeechVoiceRows())),
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
                title: "Model", detail: "Which Claude answers, on the free credits or a Claude key.",
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

/// Who answers questions: automatic, or one source that is set up. Shows who is answering now.
private struct AnswerSourceRow: View {
    @ObservedObject private var shellSettingsRevision = ShellSettingsRevision.shared

    var body: some View {
        let _ = shellSettingsRevision.revision
        let credentials = ProviderRouter.currentCredentials()
        let available = credentials.answerSourcesInOrder
        let picked = OpenClickyConfiguration.settings.answerSource.flatMap(AnswerSource.init(rawValue:))
        SettingsRow(title: "Answers come from", detail: "Now: \(nowAnswering(credentials))") {
            Picker("", selection: Binding(
                get: { picked.map(\.rawValue) ?? "auto" },
                set: { choice in
                    OpenClickyConfiguration.update { $0.answerSource = choice == "auto" ? nil : choice }
                    ShellSettingsRevision.shared.noteChanged()
                }
            )) {
                Text("Automatic").tag("auto")
                if !available.isEmpty { Divider() }
                ForEach(available) { source in Text(source.displayName).tag(source.rawValue) }
                // A pick that is no longer set up stays visible, so the menu does not jump.
                if let picked, !available.contains(picked) { Text("\(picked.displayName) (not set up)").tag(picked.rawValue) }
            }
            .labelsHidden().fixedSize()
        }
    }

    private func nowAnswering(_ credentials: ProviderCredentials) -> String {
        switch ProviderRouter.route(for: .claude, credentials: credentials) {
        case .anthropicDirect: return AnswerSource.anthropic.displayName
        case .backend: return AnswerSource.openClickyAccount.displayName
        case .answerProvider(let source): return source.displayName
        case .openAIDirect: return AnswerSource.openAI.displayName
        case .unavailable: return "nothing set up yet"
        }
    }
}

/// Who speaks the answers (`speechVoice` in shell.json): the cloud voice, said by name with what is
/// left of the free allowance, or this Mac's own voice, with its own row to pick, preview and get
/// better voices. A group, so the form draws the Mac voice as its own row.
private struct SpeechVoiceRows: View {
    @ObservedObject private var shellSettingsRevision = ShellSettingsRevision.shared
    @StateObject private var billing = BillingStatusModel()

    var body: some View {
        let _ = shellSettingsRevision.revision
        let usesMac = MacVoice.isChosen()
        Group {
            SettingsRow(title: "Voice", detail: usesMac ? "Now: this Mac’s voice. Free, offline, nothing counted." : "Now: \(cloudVoiceSentence)") {
                Picker("", selection: Binding(
                    get: { usesMac ? "mac" : "cloud" },
                    set: { choice in
                        OpenClickyConfiguration.update { $0.speechVoice = choice == "mac" ? "mac" : nil }
                        ShellSettingsRevision.shared.noteChanged()
                    }
                )) {
                    Text("Cloud voice").tag("cloud")
                    Text("This Mac").tag("mac")
                }
                .labelsHidden().fixedSize()
            }
            .onAppear { billing.refresh() }
            if usesMac { MacVoiceRow() }
        }
    }

    /// Who the cloud voice is now and what it costs.
    private var cloudVoiceSentence: String {
        let route = ProviderRouter.route(for: .speech, credentials: ProviderRouter.currentCredentials())
        if case .openAIDirect = route { return "OpenAI, on your own key." }
        // Same order as ElevenLabsTTSClient.fetchAudio: a Sarvam key comes before the account.
        if ElevenLabsTTSClient.sarvamVoice() != nil { return "Sarvam, on your own key." }
        switch route {
        case .openAIDirect:
            return "OpenAI, on your own key."
        case .unavailable:
            return "nobody yet. The cloud voice needs a free account, or an OpenAI or Sarvam key; this Mac’s voice works now."
        case .backend, .anthropicDirect, .answerProvider:
            guard let summary = billing.summary, summary.isMetered, !summary.byok else { return "ElevenLabs, through OpenClicky." }
            if summary.isSwitchedOff { return "ElevenLabs, on the free credits, which are used up for now. This Mac’s voice works meanwhile." }
            // The voice has its own allowance in spoken characters, apart from the money one: it
            // can run out while most of the money is left.
            if summary.isUnconfirmed { return "ElevenLabs, on the starter voice allowance. Add your email under Account to keep it." }
            guard summary.ttsCharsLimit > 0 else { return "ElevenLabs, on the free credits." }
            let left = max(0, 100 - Int((Double(summary.ttsCharsMonth) / Double(summary.ttsCharsLimit) * 100).rounded()))
            if left == 0 { return "ElevenLabs, on the free credits. This month’s voice allowance is used, so this Mac speaks until it comes back." }
            return "ElevenLabs, on the free credits. \(left)% of this month’s voice allowance is left."
        }
    }
}

/// The Mac voice: which one, a preview, and where to download the better ones.
private struct MacVoiceRow: View {
    @State private var choices = MacVoice.choices()
    @State private var pickedID = MacVoice.currentVoice()?.identifier ?? ""

    var body: some View {
        Group {
            SettingsRow(title: "Mac voice", detail: "Picking one says a line in it.") {
                HStack(spacing: 8) {
                    Picker("", selection: Binding(
                        get: { pickedID },
                        set: { identifier in
                            pickedID = identifier
                            OpenClickyConfiguration.update { $0.macVoiceIdentifier = identifier }
                            MacVoicePreview.shared.play()
                        }
                    )) {
                        ForEach(choices) { Text($0.label).tag($0.id) }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 220)
                    Button("Preview") { MacVoicePreview.shared.play() }.fixedSize()
                }
            }
            SettingsRow(title: "Better voices", detail: "Premium and Enhanced voices are small models macOS downloads once, then they run offline. Get Voices opens Read & Speak (Spoken Content on older macOS): System voice, Manage Voices.") {
                Button("Get Voices…") {
                    openExternalLink("x-apple.systempreferences:com.apple.Accessibility-Settings.extension?SpokenContent")
                }
                .fixedSize()
            }
        }
        // A voice downloaded in System Settings shows up when the window comes back.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            choices = MacVoice.choices()
        }
    }
}

/// Says one line in the current Mac voice, for the Preview button.
@MainActor
private final class MacVoicePreview {
    static let shared = MacVoicePreview()
    private var player: AVAudioPlayer?

    func play() {
        Task {
            guard let data = try? await MacVoice.shared.audio(for: "hi, i'm clicky. this is how i sound on this mac.") else { return }
            player = try? AVAudioPlayer(data: data)
            player?.play()
        }
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
        SettingsRow(title: "Model", detail: "Which Claude answers, on the free credits or a Claude key.") {
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
