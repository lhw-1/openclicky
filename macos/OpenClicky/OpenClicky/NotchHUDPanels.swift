//
//  NotchHUDPanels.swift
//  OpenClicky
//
//  The open island, one short panel (the pointer, the shortcuts, Settings and quit; no tabs), and
//  the floating result card (top-right) with "Follow up with agent". Drawn with the refinement
//  sheet's HUD tokens (`DS.HUD`).
//

import AppKit
import Combine
import SwiftUI

// MARK: - Full panel

/// The open island, one short panel (Claude Design, "one compact panel"): the band beside the
/// camera holds what the pointer is doing and the three round buttons (voice, Settings, quit); the
/// body is one row — dock or release the pointer, (i), and the four shortcuts as a 2 × 2 grid. A
/// side drawer has no camera to sit beside, so it stacks the same pieces. Hand-drawn throughout:
/// the island never becomes key, and system controls grey out in a panel that isn't.
struct NotchFullPanelView: View {
    @ObservedObject var model: NotchHUDModel
    @ObservedObject var companionManager: CompanionManager

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            NotchBandRow(model: model, companionManager: companionManager)
                .padding(.top, 6)
                .frame(height: model.bandRowHeight)
            NotchPanelBody(model: model, companionManager: companionManager)
                .padding(.top, model.placement.isSideDrawer ? 6 : 2)
                .padding(.horizontal, DS.HUD.bodySidePadding)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }
}

// MARK: - Band

/// The band: the pointer's status on the left of the camera, the voice pill, Settings and quit on
/// the right. On a notch screen each side only has what the notch leaves free.
struct NotchBandRow: View {
    @ObservedObject var model: NotchHUDModel
    @ObservedObject var companionManager: CompanionManager

    private var sideWidth: CGFloat {
        guard model.geometry.hasHardwareNotch, !model.placement.isSideDrawer else { return .infinity }
        return max(0, (model.fullWidth - model.geometry.notchWidth) / 2 - 12)
    }

    var body: some View {
        HStack(spacing: 8) {
            NotchPointerStatus(model: model, companionManager: companionManager)
                .frame(maxWidth: sideWidth, alignment: .leading)
            Spacer(minLength: 8)
            HStack(spacing: 6) {
                VoiceDestinationPill(companionManager: companionManager, settings: companionManager.dictationSettings, length: .glyphOnly)
                // Settings live in the window only: an island page of switches was a second,
                // smaller settings that stayed open behind the pointer.
                bandIconButton(systemImage: "gearshape.fill", help: "settings") {
                    model.dismiss()
                    companionManager.showSettings()
                }
                bandIconButton(systemImage: "power", help: "quit openclicky") {
                    companionManager.quitWithFarewell()
                }
            }
            .frame(maxWidth: sideWidth, alignment: .trailing)
        }
        .padding(.horizontal, 16)
    }

    private func bandIconButton(systemImage: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(DS.HUD.text2)
                .frame(width: DS.HUD.pillHeight, height: DS.HUD.pillHeight)
                .background(Circle().fill(DS.HUD.bandControl))
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .help(help)
        .accessibilityLabel(help)
    }
}

/// One line saying what the pointer is doing right now, short enough for the side of the notch.
struct NotchPointerStatus: View {
    @ObservedObject var model: NotchHUDModel
    @ObservedObject var companionManager: CompanionManager

    var body: some View {
        HStack(spacing: 8) {
            NotchPointerMark(isDimmed: companionManager.isCursorDocked)
            Text(statusText)
                .font(.system(size: 12))
                .foregroundColor(DS.HUD.text2)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .accessibilityElement(children: .combine)
    }

    /// From the dock state, the "show the pointer" switch and the "the pointer shows" setting.
    private var statusText: String {
        if companionManager.isCursorDocked { return model.placement.isSideDrawer ? "pointer is docked in the drawer" : "pointer is docked" }
        if !companionManager.isClickyCursorEnabled { return "pointer shows while you talk" }
        switch companionManager.pointerPresence {
        case .always: return "pointer follows your mouse"
        case .whileMoving: return "pointer follows while moving"
        case .onShake: return companionManager.isPointerAwake ? "pointer follows your mouse" : "shake the mouse for the pointer"
        }
    }
}

/// Where dictated words go, as the band's pill says it: "voice stays on this mac", "sarvam hears
/// you", "openai hears you", "assemblyai hears you". When the chosen engine cannot run it says what
/// is missing in orange instead ("set up backend ›", "add sarvam key ›"). A tap opens the voice
/// settings, or what the blocked engine needs.
private struct VoiceDestinationPill: View {
    enum Length { case full, short, glyphOnly }

    @ObservedObject var companionManager: CompanionManager
    @ObservedObject var settings: DictationSettings
    let length: Length

    var body: some View {
        let engine = settings.engine
        let blockedLabel = NotchVoiceDestination.blockedPillLabel(for: engine)
        return Button(action: { NotchVoiceDestination.openSetup(for: engine, companionManager: companionManager) }) {
            HStack(spacing: 5) {
                if let blockedLabel {
                    if length == .glyphOnly {
                        Image(systemName: "exclamationmark").font(.system(size: 10, weight: .bold))
                    } else {
                        Text(blockedLabel).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                    }
                } else {
                    Image(systemName: "mic.fill")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundColor(DS.HUD.live)
                    if length != .glyphOnly {
                        Text(length == .full ? NotchVoiceDestination.pillLabel(for: engine) : NotchVoiceDestination.shortPillLabel(for: engine))
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(Color(hex: "#E5E5E5"))
                            .lineLimit(1)
                    }
                }
            }
            .foregroundColor(blockedLabel == nil ? DS.HUD.text : .black)
            .padding(.horizontal, length == .glyphOnly ? 0 : 10)
            .frame(minWidth: DS.HUD.pillHeight, minHeight: DS.HUD.pillHeight, maxHeight: DS.HUD.pillHeight)
            .background(Capsule().fill(blockedLabel == nil ? DS.HUD.bandControl : DS.HUD.pointer))
            .fixedSize()
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .help(blockedLabel == nil
              ? "dictation is heard by \(engine.displayName.lowercased()). click to change."
              : DictationEngineResolver.unavailableReason(for: engine) ?? "")
    }
}

/// The words the HUD uses for where the voice goes, shared by the pill, the Home warning card and
/// the Settings summary.
enum NotchVoiceDestination {
    static func pillLabel(for engine: DictationEngineChoice) -> String {
        switch engine {
        case .offline, .parakeet: return "voice stays on this mac"
        case .sarvam: return "sarvam hears you"
        case .openclicky: return "openai hears you"
        case .assemblyai: return "assemblyai hears you"
        }
    }

    static func shortPillLabel(for engine: DictationEngineChoice) -> String {
        switch engine {
        case .offline, .parakeet: return "on this mac"
        case .sarvam: return "sarvam"
        case .openclicky: return "openai"
        case .assemblyai: return "assemblyai"
        }
    }

    /// Who hears the voice, for the Settings summary ("hears you: this mac").
    static func listenerName(for engine: DictationEngineChoice) -> String {
        switch engine {
        case .offline, .parakeet: return "this mac"
        case .sarvam: return "sarvam"
        case .openclicky: return "openai"
        case .assemblyai: return "assemblyai"
        }
    }

    /// The speech-to-text model behind the engine, for the Settings summary.
    static func speechToTextName(for engine: DictationEngineChoice) -> String {
        switch engine {
        case .offline: return "apple"
        case .parakeet: return "parakeet"
        case .sarvam: return "saaras v4"
        case .openclicky: return "openai, via openclicky"
        case .assemblyai: return "assemblyai streaming"
        }
    }

    /// Nil when the engine can run; otherwise the pill's orange call to action.
    static func blockedPillLabel(for engine: DictationEngineChoice) -> String? {
        guard DictationEngineResolver.unavailableReason(for: engine) != nil else { return nil }
        switch engine {
        case .sarvam: return "add sarvam key ›"
        case .parakeet: return "download parakeet ›"
        default: return "set up backend ›"
        }
    }

    /// Where the pill (and the Home warning card) sends the user: Settings → Account when the
    /// engine still needs a key or a sign-in, Settings → Dictation when nothing is missing.
    @MainActor
    static func openSetup(for engine: DictationEngineChoice, companionManager: CompanionManager) {
        let isMissingSomething = DictationEngineResolver.unavailableReason(for: engine) != nil
        // Parakeet's download lives on the Dictation page, next to the engine.
        companionManager.showSettings(isMissingSomething && engine != .parakeet ? .account : .dictation)
    }
}

// MARK: - Body

/// The body's one row: dock or release the pointer, (i) "what can you do?", and the shortcuts (or,
/// when the dictation engine can't run, what is missing).
struct NotchPanelBody: View {
    @ObservedObject var model: NotchHUDModel
    @ObservedObject var companionManager: CompanionManager

    /// The body row's height: the buttons, and the grid's two 14 pt rows.
    static let rowHeight: CGFloat = 30

    var body: some View {
        if model.placement.isSideDrawer {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) { dockButton; infoButton }
                shortcutsOrWarning
            }
        } else {
            HStack(alignment: .center, spacing: 10) {
                dockButton.frame(width: 128)
                infoButton
                shortcutsOrWarning.padding(.leading, 2)
            }
        }
    }

    private var dockButton: some View {
        let isDocked = companionManager.isCursorDocked
        let isIdle = companionManager.voiceState == .idle
        return Button(action: { companionManager.setCursorDocked(!isDocked) }) {
            Text(isDocked ? "release pointer" : (model.placement.isSideDrawer ? "dock in the drawer" : "dock in the notch"))
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.black)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
                .frame(maxWidth: .infinity)
                .frame(height: Self.rowHeight)
                .background(RoundedRectangle(cornerRadius: DS.HUD.tileRadius, style: .continuous).fill(isDocked ? DS.HUD.pointer : DS.HUD.text))
                .contentShape(RoundedRectangle(cornerRadius: DS.HUD.tileRadius, style: .continuous))
        }
        .buttonStyle(.plain)
        .pointerCursor(isEnabled: isIdle)
        .disabled(!isIdle)
        .opacity(isIdle ? 1 : 0.5)
        .help(isDocked ? "talk still works while docked" : "park the pointer until Clicky needs it")
    }

    /// (i): the buddy types out what OpenClicky does, next to itself (or in this island while it
    /// is docked). The panel closes so the buddy is in view.
    private var infoButton: some View {
        Button(action: {
            model.close()
            companionManager.explainWhatOpenClickyDoes()
        }) {
            Text("i")
                .font(.system(size: 17, design: .serif).italic())
                .foregroundColor(DS.HUD.text)
                .frame(width: Self.rowHeight, height: Self.rowHeight)
                .background(RoundedRectangle(cornerRadius: DS.HUD.tileRadius, style: .continuous).fill(DS.HUD.surfaceRaisedSoft))
                .contentShape(RoundedRectangle(cornerRadius: DS.HUD.tileRadius, style: .continuous))
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .help("what can you do?")
        .accessibilityLabel("what can you do?")
    }

    @ViewBuilder
    private var shortcutsOrWarning: some View {
        if let engineWarning = NotchEngineWarning(engine: companionManager.dictationSettings.engine) {
            NotchEngineWarningView(warning: engineWarning, companionManager: companionManager)
        } else {
            NotchShortcutGrid(companionManager: companionManager, settings: companionManager.dictationSettings)
        }
    }
}

/// CALL CLICKY as a 2 × 2 grid with no heading: the four shortcuts `CompanionShortcutRecognizer` knows.
struct NotchShortcutGrid: View {
    @ObservedObject var companionManager: CompanionManager
    @ObservedObject var settings: DictationSettings

    var body: some View {
        let dictationKey = settings.dictationKey.keycapLabel
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 2) {
            GridRow {
                shortcut(title: "talk", keys: ["⌃", "⌥"], gesture: "hold", isLive: false)
                shortcut(title: "type", keys: ["⌃"], gesture: "tap ×2", isLive: false)
            }
            GridRow {
                shortcut(title: "dictate", keys: [dictationKey], gesture: "hold", isLive: false)
                shortcut(title: "hands-free", keys: [dictationKey, "⌃"], gesture: "tap ×2", isLive: companionManager.isAlwaysListening)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func shortcut(title: String, keys: [String], gesture: String, isLive: Bool) -> some View {
        HStack(spacing: 4) {
            Text(title).font(.system(size: 12)).foregroundColor(DS.HUD.text).lineLimit(1).fixedSize()
            if isLive {
                Circle().fill(DS.HUD.live).frame(width: 6, height: 6).help("hands-free is on")
            }
            Spacer(minLength: 4)
            HStack(spacing: 3) {
                ForEach(keys, id: \.self) { key in NotchKeycap(text: key, isSmall: true) }
                Text(gesture)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(DS.HUD.text3)
                    .lineLimit(1)
                    .fixedSize()
            }
        }
        .frame(height: 14)
        .accessibilityElement(children: .combine)
    }
}

/// A key as the HUD draws it: SF Mono 11 on a raised 5 pt keycap.
struct NotchKeycap: View {
    let text: String
    /// The panel's shortcut grid: smaller, so a row fits 14 pt.
    var isSmall = false

    var body: some View {
        Text(text)
            .font(.system(size: isSmall ? 9.5 : 11, design: .monospaced))
            .foregroundColor(DS.HUD.text)
            .fixedSize()
            .padding(.horizontal, isSmall ? 4 : 6)
            .padding(.vertical, isSmall ? 1 : 2)
            .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(DS.HUD.surfaceRaised))
    }
}

struct NotchEngineWarning: Equatable {
    let heading: String
    let message: String
    let buttonTitle: String
    let engine: DictationEngineChoice

    init?(engine: DictationEngineChoice) {
        guard DictationEngineResolver.unavailableReason(for: engine) != nil else { return nil }
        self.engine = engine
        if engine == .sarvam {
            heading = "SARVAM NEEDS A KEY"
            message = "you picked sarvam to hear you, but no key is saved. dictation stays off until it is."
            buttonTitle = "add key in settings"
        } else {
            let listener = NotchVoiceDestination.listenerName(for: engine)
            heading = "\(listener.uppercased()) NEEDS THE BACKEND"
            message = "you picked \(listener) to hear you, which goes through openclicky. sign in or add your own key."
            buttonTitle = "open shell.json"
        }
    }
}

struct NotchEngineWarningView: View {
    let warning: NotchEngineWarning
    @ObservedObject var companionManager: CompanionManager

    /// Fits the body's one row: the message in two lines at most, the way to fix it beside it.
    var body: some View {
        HStack(spacing: 10) {
            Text(warning.message)
                .font(.system(size: 11))
                .foregroundColor(DS.HUD.text2)
                .lineLimit(2)
                .help(warning.message)
            Button(action: { NotchVoiceDestination.openSetup(for: warning.engine, companionManager: companionManager) }) {
                Text(warning.buttonTitle)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(DS.HUD.text)
                    .padding(.horizontal, 10)
                    .frame(height: 26)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(DS.HUD.surfaceRaised))
                    .fixedSize()
            }
            .buttonStyle(.plain)
            .pointerCursor()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityLabel(warning.heading)
    }
}

/// The microphone menu the island and the first-run tour open: the Mac's default, then every
/// input, the chosen one ticked.
@MainActor
enum MicrophoneMenu {
    static func currentName(settings: DictationSettings) -> String {
        if let uid = settings.preferredMicrophoneUID,
           let device = MicrophoneDevices.available().first(where: { $0.uid == uid }) {
            return device.name
        }
        return "automatic · \(MicrophoneDevices.effectiveInputName(preferredUID: nil) ?? "none found")"
    }

    /// Just the device's name ("External Microphone"), for a line with no room for more.
    static func deviceName(settings: DictationSettings) -> String {
        if let uid = settings.preferredMicrophoneUID,
           let device = MicrophoneDevices.available().first(where: { $0.uid == uid }) {
            return device.name
        }
        return MicrophoneDevices.effectiveInputName(preferredUID: nil) ?? "no microphone"
    }

    static func present(settings: DictationSettings) {
        let target = MicrophoneMenuTarget(settings: settings)
        let menu = NSMenu()
        let defaultItem = NSMenuItem(title: "Automatic (\(MicrophoneDevices.effectiveInputName(preferredUID: nil) ?? "none"))", action: #selector(MicrophoneMenuTarget.choose(_:)), keyEquivalent: "")
        defaultItem.target = target
        defaultItem.representedObject = ""
        defaultItem.state = settings.preferredMicrophoneUID == nil ? .on : .off
        menu.addItem(defaultItem)
        menu.addItem(.separator())
        for device in MicrophoneDevices.available() {
            let item = NSMenuItem(title: device.name, action: #selector(MicrophoneMenuTarget.choose(_:)), keyEquivalent: "")
            item.target = target
            item.representedObject = device.uid
            item.state = settings.preferredMicrophoneUID == device.uid ? .on : .off
            menu.addItem(item)
        }
        // popUp runs the menu to completion, so the target lives long enough.
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
        withExtendedLifetime(target) {}
    }
}

private final class MicrophoneMenuTarget: NSObject {
    let settings: DictationSettings

    init(settings: DictationSettings) { self.settings = settings }

    @MainActor @objc func choose(_ item: NSMenuItem) {
        let uid = item.representedObject as? String ?? ""
        settings.preferredMicrophoneUID = uid.isEmpty ? nil : uid
    }
}

// MARK: - Agent result card (top-right)

private final class AgentResultPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

/// The floating card HeyClicky shows top-right when an agent finishes or you open one:
/// title, status, the agent's summary, Copy, and a "Follow up with agent" field.
@MainActor
final class AgentResultPanelManager {
    private var panel: AgentResultPanel?
    private let state = AgentResultPanelState()
    private let agentClient = OpenClickyAgentClient()

    func show(threadId: String, companionManager: CompanionManager) {
        state.threadId = threadId
        state.title = "Agent"
        state.summary = ""
        state.status = "loading"
        state.isLoading = true
        presentPanel(companionManager: companionManager)
        Task {
            do {
                let detail = try await agentClient.readThread(threadId)
                // Opening agent A then agent B starts two reads; if A's answer lands last it must
                // not overwrite the card that now shows B.
                guard state.threadId == threadId else { return }
                state.title = detail.thread.preview.split(separator: "\n").first.map(String.init) ?? "Agent"
                state.summary = detail.lastAgentMessage ?? "(no reply yet)"
                state.status = detail.turns.last?.status ?? "done"
            } catch {
                guard state.threadId == threadId else { return }
                state.summary = "Couldn't load this agent: \(error.localizedDescription)"
                state.status = "error"
            }
            state.isLoading = false
        }
    }

    func hide() {
        panel?.orderOut(nil)
    }

    private func presentPanel(companionManager: CompanionManager) {
        if panel == nil {
            let newPanel = AgentResultPanel(
                contentRect: NSRect(x: 0, y: 0, width: 400, height: 240),
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            newPanel.isOpaque = false
            newPanel.backgroundColor = .clear
            newPanel.hasShadow = true
            newPanel.level = .floating
            newPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            newPanel.isReleasedWhenClosed = false
            newPanel.hidesOnDeactivate = false
            newPanel.contentView = NSHostingView(rootView: AgentResultView(state: state, companionManager: companionManager, onClose: { [weak self] in self?.hide() }))
            panel = newPanel
        }
        guard let panel, let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let visibleFrame = screen.visibleFrame
        let origin = NSPoint(x: visibleFrame.maxX - panel.frame.width - 20, y: visibleFrame.maxY - panel.frame.height - 12)
        panel.setFrameOrigin(origin)
        panel.makeKeyAndOrderFront(nil)
    }
}

@MainActor
final class AgentResultPanelState: ObservableObject {
    @Published var threadId: String = ""
    @Published var title: String = ""
    @Published var summary: String = ""
    @Published var status: String = ""
    @Published var isLoading = false
}

struct AgentResultView: View {
    @ObservedObject var state: AgentResultPanelState
    @ObservedObject var companionManager: CompanionManager
    var onClose: () -> Void
    @State private var followUpText = ""
    @State private var didCopy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text(state.title)
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(.white)
                    .lineLimit(1)
                Spacer()
                Text(statusLabel)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(statusColor))
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(Color.white.opacity(0.7))
                        .frame(width: 18, height: 18)
                        .background(Circle().fill(Color.white.opacity(0.12)))
                }
                .buttonStyle(.plain)
                .pointerCursor()
            }

            if state.isLoading {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Loading…").font(.system(size: 11)).foregroundColor(Color.white.opacity(0.6))
                }
            } else {
                ScrollView(showsIndicators: false) {
                    Text(liveSummary)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.white)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 90)

                Button(action: copySummary) {
                    HStack(spacing: 5) {
                        Image(systemName: didCopy ? "checkmark" : "doc.on.doc").font(.system(size: 10, weight: .semibold))
                        Text(didCopy ? "Copied" : "Copy").font(.system(size: 11, weight: .semibold))
                    }
                    .foregroundColor(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(Color.white.opacity(0.14)))
                }
                .buttonStyle(.plain)
                .pointerCursor()
            }

            HStack(spacing: 8) {
                Image(systemName: "mic.fill").font(.system(size: 11)).foregroundColor(Color.white.opacity(0.7))
                TextField("Follow up with agent", text: $followUpText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.white)
                    .onSubmit(sendFollowUp)
                    .disabled(companionManager.voiceState != .idle)
                Image(systemName: "keyboard").font(.system(size: 11)).foregroundColor(Color.white.opacity(0.35))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.white.opacity(0.10)))

            if let agentActivityText = companionManager.agentActivityText, companionManager.voiceState == .processing {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text(agentActivityText).font(.system(size: 10)).foregroundColor(Color.white.opacity(0.6)).lineLimit(1)
                }
            }
        }
        .padding(16)
        .frame(width: 400)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color(hex: "#2B2D31").opacity(0.96)))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color.white.opacity(0.12), lineWidth: 1))
    }

    /// Prefer the freshest result for this thread over the loaded history.
    private var liveSummary: String {
        if let lastResult = companionManager.lastAgentResult, lastResult.threadId == state.threadId, lastResult.finishedAt > Date().addingTimeInterval(-3600) {
            return lastResult.text.isEmpty ? state.summary : lastResult.text
        }
        return state.summary
    }

    private var statusLabel: String {
        if companionManager.voiceState == .processing { return "Working" }
        switch state.status {
        case "completed", "done": return "Done"
        case "loading": return "…"
        case "error": return "Error"
        default: return state.status.capitalized
        }
    }

    private var statusColor: Color {
        if companionManager.voiceState == .processing { return DS.Colors.warning.opacity(0.8) }
        return state.status == "error" ? DS.Colors.overlayCursorColor.opacity(0.8) : DS.Colors.accent.opacity(0.8)
    }

    private func copySummary() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(liveSummary, forType: .string)
        didCopy = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { didCopy = false }
    }

    private func sendFollowUp() {
        let text = followUpText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        followUpText = ""
        companionManager.submitTextToAgent(text, threadId: state.threadId)
    }
}
