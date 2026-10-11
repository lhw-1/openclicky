//
//  SettingsDictationPage.swift
//  OpenClicky
//
//  Settings → Dictation: who hears you, through which microphone, and when a quiet take ends.
//  Each engine says where the audio goes; its key lives under Account → Your keys. Language,
//  script and AI clean-up live in Styles, next to the rules the model reads.
//

import AVFoundation
import SwiftUI

extension SettingsCatalog {
    func dictationItems() -> [SettingsItem] {
        let engineItems = DictationEngineChoice.allCases.map { choice in
            SettingsItem(
                id: "dictation.engine.\(choice.rawValue)", page: .dictation, section: "Who hears you",
                title: VoiceProviderCopy.title(for: choice), detail: VoiceProviderCopy.detail(for: choice),
                keywords: VoiceProviderCopy.keywords(for: choice),
                view: AnyView(VoiceProviderOption(choice: choice, settings: settings, companionManager: companionManager)))
        }
        return engineItems + [
            SettingsItem(
                id: "dictation.movedToStyles", page: .dictation, section: "Who hears you",
                title: "Language, script and AI clean-up", detail: "They live in Styles, next to the rules the model reads.",
                keywords: ["polish", "language", "script", "model", "cleanup", "clean-up", "styles", "offline takes"],
                chrome: .footer,
                view: AnyView(MovedToStylesNote(companionManager: companionManager))),
            SettingsItem(
                id: "dictation.input", page: .dictation, section: "Microphone",
                title: "Input", detail: "Follows the Mac’s default unless you pick one.",
                keywords: ["microphone", "mic", "device", "input", "headset", "airpods"],
                view: AnyView(MicrophoneInputRow(settings: settings))),
            SettingsItem(
                id: "dictation.micTest", page: .dictation, section: "Microphone",
                title: "Test your microphone", detail: "Hear whether the chosen input picks you up.",
                keywords: ["microphone", "mic", "level", "test"],
                view: AnyView(MicrophoneTestRow(settings: settings))),
            SettingsItem(
                id: "dictation.inactivityTimeout", page: .dictation, section: "Takes",
                title: "End a quiet take after", detail: "A tapped take finishes on its own after this much silence.",
                keywords: ["inactivity", "timeout", "silence", "minutes", "quiet"],
                view: AnyView(SettingsRow(title: "End a quiet take after", detail: "A tapped take finishes on its own after this much silence.") {
                    InactivityTimeoutPicker(settings: settings)
                })),
        ]
    }
}

/// What each engine is called and where its audio goes.
enum VoiceProviderCopy {
    static func title(for choice: DictationEngineChoice) -> String {
        switch choice {
        case .offline: return "This Mac"
        case .sarvam: return "Sarvam"
        case .openclicky: return "OpenAI, via OpenClicky"
        case .assemblyai: return "AssemblyAI, via OpenClicky"
        }
    }

    static func tag(for choice: DictationEngineChoice) -> String {
        switch choice {
        case .offline: return "Private · offline"
        case .sarvam: return "Audio goes to Sarvam"
        case .openclicky: return "Audio goes to OpenAI"
        case .assemblyai: return "Audio goes to AssemblyAI"
        }
    }

    static func detail(for choice: DictationEngineChoice) -> String {
        switch choice {
        case .offline: return "Apple’s on-device recogniser. Nothing leaves this Mac. No key, no account."
        case .sarvam: return "Saaras hears eleven Indian languages. Billed by Sarvam to your key."
        case .openclicky: return "Needs an OpenClicky account or your own OpenAI key."
        case .assemblyai: return "Words appear as you speak. Needs the OpenClicky backend."
        }
    }

    /// The short note on the right while the engine can't be used yet.
    static func unavailableBadge(for choice: DictationEngineChoice) -> String {
        switch choice {
        case .offline: return ""
        case .sarvam: return "Needs a key"
        case .openclicky: return "Needs account"
        case .assemblyai: return "Needs backend"
        }
    }

    static func keywords(for choice: DictationEngineChoice) -> [String] {
        let common = ["engine", "provider", "transcription", "speech", "who hears you", tag(for: choice)]
        switch choice {
        case .offline: return common + ["offline", "local", "apple", "private", "on device"]
        case .sarvam: return common + ["sarvam", "saaras", "key", "api key", "indian", "hindi"]
        case .openclicky: return common + ["openai", "openclicky", "account", "backend", "cloud"]
        case .assemblyai: return common + ["assemblyai", "streaming", "backend", "cloud"]
        }
    }
}

// MARK: - who hears you

/// One engine as a radio option: the button, its name and tag, what it does, and on the right
/// what it still needs. The chosen engine that can't run yet says why, with the way to fix it.
private struct VoiceProviderOption: View {
    let choice: DictationEngineChoice
    @ObservedObject var settings: DictationSettings
    let companionManager: CompanionManager
    @ObservedObject private var shellSettingsRevision = ShellSettingsRevision.shared
    @Environment(\.settingsSearchQuery) private var searchQuery

    private var isSelected: Bool { settings.engine == choice }

    var body: some View {
        // Read so the note redraws once a key or a sign-in lands in shell.json.
        let _ = shellSettingsRevision.revision
        let unavailableReason = DictationEngineResolver.unavailableReason(for: choice)
        VStack(alignment: .leading, spacing: 6) {
            Button(action: { settings.engine = choice }) {
                HStack(alignment: .top, spacing: 10) {
                    SettingsRadioDot(isSelected: isSelected).padding(.top, 1)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 8) {
                            Text(settingsHighlighted(VoiceProviderCopy.title(for: choice), query: searchQuery)).font(SettingsLook.rowTitle)
                            SettingsTag(text: VoiceProviderCopy.tag(for: choice), isPositive: choice == .offline)
                        }
                        Text(settingsHighlighted(VoiceProviderCopy.detail(for: choice), query: searchQuery))
                            .font(SettingsLook.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 12)
                    if unavailableReason != nil {
                        Text(VoiceProviderCopy.unavailableBadge(for: choice))
                            .font(SettingsLook.caption).foregroundStyle(isSelected ? SettingsLook.danger : .secondary)
                            .help(unavailableReason ?? "")
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(VoiceProviderCopy.title(for: choice)), \(VoiceProviderCopy.tag(for: choice))")
            .accessibilityHint(unavailableReason ?? VoiceProviderCopy.detail(for: choice))
            .accessibilityAddTraits(isSelected ? .isSelected : [])

            if isSelected, let unavailableReason {
                HStack(spacing: 8) {
                    Text(unavailableReason).font(SettingsLook.caption).foregroundStyle(SettingsLook.danger)
                        .fixedSize(horizontal: false, vertical: true)
                    Button(choice == .sarvam ? "Add Key…" : "Sign In…") { companionManager.showSettings(.account) }
                        .controlSize(.small)
                }
                .padding(.leading, 24)
            }
        }
        .padding(.vertical, 2)
    }
}

/// A radio button drawn like the system's, in the window's accent.
struct SettingsRadioDot: View {
    let isSelected: Bool

    var body: some View {
        ZStack {
            Circle().fill(isSelected ? SettingsLook.accent : Color(nsColor: .controlColor))
            Circle().strokeBorder(isSelected ? Color.clear : Color(nsColor: .separatorColor), lineWidth: 0.5)
            if isSelected { Circle().fill(Color.white).frame(width: 6, height: 6) }
        }
        .frame(width: 14, height: 14)
        .accessibilityHidden(true)
    }
}

private struct InactivityTimeoutPicker: View {
    @ObservedObject var settings: DictationSettings

    var body: some View {
        Picker("", selection: $settings.inactivityTimeoutMinutes) {
            Text("1 minute").tag(1); Text("3 minutes").tag(3); Text("5 minutes").tag(5); Text("10 minutes").tag(10); Text("Never").tag(0)
        }
        .labelsHidden().fixedSize()
    }
}

// MARK: - microphone

private struct MicrophoneInputRow: View {
    @ObservedObject var settings: DictationSettings
    @State private var devices = MicrophoneDevices.available()

    var body: some View {
        SettingsRow(title: "Input", detail: "Follows the Mac’s default unless you pick one. Now: \(currentName).") {
            Picker("", selection: Binding(get: { settings.preferredMicrophoneUID ?? "" }, set: { settings.preferredMicrophoneUID = $0.isEmpty ? nil : $0 })) {
                Text("Mac default (\(MicrophoneDevices.defaultInputName() ?? "none"))").tag("")
                ForEach(devices) { device in Text(device.name).tag(device.uid) }
            }
            .labelsHidden().frame(maxWidth: 260)
        }
        .onAppear { devices = MicrophoneDevices.available() }
    }

    private var currentName: String {
        if let uid = settings.preferredMicrophoneUID, let device = devices.first(where: { $0.uid == uid }) { return device.name }
        return MicrophoneDevices.defaultInputName() ?? "no microphone found"
    }
}

private struct MicrophoneTestRow: View {
    @ObservedObject var settings: DictationSettings
    @State private var isTesting = false
    @State private var testLevel: CGFloat = 0
    @State private var testEngine: AVAudioEngine?

    var body: some View {
        SettingsRow(title: "Test your microphone", detail: isTesting ? "Speak — the bars should follow your voice." : "Hear whether the chosen input picks you up.") {
            HStack(spacing: 12) {
                if isTesting { OrbLevelBars(level: testLevel, color: SettingsLook.success).frame(width: 40, height: 16) }
                Button(isTesting ? "Stop" : "Speak to Test") { isTesting ? stopTest() : startTest() }
            }
        }
        .onDisappear(perform: stopTest)
    }

    private func startTest() {
        let engine = AVAudioEngine()
        MicrophoneDevices.apply(preferredUID: settings.preferredMicrophoneUID, to: engine)
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0 else { return }
        let testLevelBinding = $testLevel
        input.installTap(onBus: 0, bufferSize: 1024, format: format, block: Self.makeLevelTap { level in
            DispatchQueue.main.async { testLevelBinding.wrappedValue = level }
        })
        engine.prepare()
        if (try? engine.start()) != nil {
            testEngine = engine
            isTesting = true
        }
    }

    /// The tap runs on the CoreAudio render thread, so it is built outside the view's main-actor
    /// isolation and touches nothing but the buffer and the callback it was given.
    nonisolated private static func makeLevelTap(onLevel: @escaping @Sendable (CGFloat) -> Void) -> AVAudioNodeTapBlock {
        return { buffer, _ in
            guard let channel = buffer.floatChannelData?[0] else { return }
            var sum: Float = 0
            for index in 0..<Int(buffer.frameLength) { sum += channel[index] * channel[index] }
            let rms = sqrt(sum / Float(max(1, buffer.frameLength)))
            onLevel(CGFloat(min(1, rms * 10)))
        }
    }

    private func stopTest() {
        testEngine?.inputNode.removeTap(onBus: 0)
        testEngine?.stop()
        testEngine = nil
        isTesting = false
    }
}

private struct MovedToStylesNote: View {
    let companionManager: CompanionManager
    @Environment(\.settingsSearchQuery) private var searchQuery

    var body: some View {
        HStack(spacing: 3) {
            Text(settingsHighlighted("Language, script and AI clean-up live in", query: searchQuery))
            Button("Styles") { companionManager.showDictationWindow(section: .styles) }
                .buttonStyle(.link)
                .accessibilityHint("opens Styles")
            Text(settingsHighlighted(", next to the rules the model reads.", query: searchQuery))
        }
        .font(SettingsLook.caption).foregroundStyle(.secondary)
    }
}
