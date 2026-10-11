//
//  MenuBarPanelManager.swift
//  OpenClicky
//
//  Manages the NSStatusItem (menu bar icon) and its menu: what OpenClicky is doing, agent mode,
//  docking the pointer, the windows, and quit. The custom borderless panel (CompanionPanelView)
//  is left only for a first run's intro and the permission card's gear; it is non-activating, so
//  it does not steal focus, and auto-dismisses when the user clicks outside.
//

import AppKit
import Combine
import SwiftUI

extension Notification.Name {
    static let clickyDismissPanel = Notification.Name("clickyDismissPanel")
    /// The gear on a permission card: open the menu bar panel (settings, Quit).
    static let clickyShowPanel = Notification.Name("clickyShowPanel")
}

/// Custom NSPanel subclass that can become the key window even with
/// .nonactivatingPanel style, allowing text fields to receive focus.
private class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

@MainActor
final class MenuBarPanelManager: NSObject {
    private var statusItem: NSStatusItem?
    private var panel: NSPanel?
    private var clickOutsideMonitor: Any?
    private var dismissPanelObserver: NSObjectProtocol?
    private var showPanelObserver: NSObjectProtocol?
    private var iconVisibilityCancellable: AnyCancellable?

    private let companionManager: CompanionManager
    private let panelWidth: CGFloat = 320
    private let panelHeight: CGFloat = 380

    init(companionManager: CompanionManager) {
        self.companionManager = companionManager
        super.init()
        if companionManager.isMenuBarIconVisible { createStatusItem() }
        iconVisibilityCancellable = companionManager.$isMenuBarIconVisible
            .dropFirst()
            .removeDuplicates()
            .sink { [weak self] visible in
                if visible { self?.createStatusItem() } else { self?.removeStatusItem() }
            }

        dismissPanelObserver = NotificationCenter.default.addObserver(
            forName: .clickyDismissPanel,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.hidePanel()
        }

        showPanelObserver = NotificationCenter.default.addObserver(
            forName: .clickyShowPanel,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.showPanel()
        }
    }

    deinit {
        if let monitor = clickOutsideMonitor {
            NSEvent.removeMonitor(monitor)
        }
        if let observer = dismissPanelObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let observer = showPanelObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    // MARK: - Status Item

    private func removeStatusItem() {
        if let statusItem { NSStatusBar.system.removeStatusItem(statusItem) }
        statusItem = nil
    }

    private func createStatusItem() {
        guard statusItem == nil else { return }
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

        guard let button = statusItem?.button else { return }

        button.image = makeClickyMenuBarIcon()
        button.image?.isTemplate = true
        button.action = #selector(statusItemClicked)
        button.target = self
        // Either click opens the menu.
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
    }

    /// The status item's menu, for either click: what OpenClicky is doing, its two quick
    /// switches, the windows, and quit. A plain menu with checkmarks, like any Mac menu bar app.
    private func showStatusMenu() {
        guard let statusItem else { return }
        let menu = NSMenu()
        let header = NSMenuItem()
        let headerView = NSHostingView(rootView: StatusMenuHeader(statusText: statusText, dictationKey: companionManager.dictationSettings.dictationKey.keycapLabel))
        headerView.frame = NSRect(x: 0, y: 0, width: 280, height: 46)
        header.view = headerView
        menu.addItem(header)
        menu.addItem(.separator())
        addItem(to: menu, title: "Agent Mode", action: #selector(toggleAgentMode), isOn: companionManager.isAgentModeEnabled)
        addItem(to: menu, title: companionManager.hudPlacement.isSideDrawer ? "Dock Pointer in the Drawer" : "Dock Pointer in the Island",
                action: #selector(toggleDock), isOn: companionManager.isCursorDocked)
        menu.addItem(.separator())
        addItem(to: menu, title: "Open OpenClicky", action: #selector(openWindow))
        addItem(to: menu, title: "Open the Island", action: #selector(openIsland))
        addItem(to: menu, title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        addItem(to: menu, title: "Replay Welcome…", action: #selector(replayWelcome))
        menu.addItem(.separator())
        addItem(to: menu, title: "Quit OpenClicky", action: #selector(quit), keyEquivalent: "q")
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        // The menu is attached only for the click, or AppKit would keep it attached for good.
        DispatchQueue.main.async { statusItem.menu = nil }
    }

    private func addItem(to menu: NSMenu, title: String, action: Selector, keyEquivalent: String = "", isOn: Bool? = nil) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: keyEquivalent)
        item.target = self
        if let isOn { item.state = isOn ? .on : .off }
        menu.addItem(item)
    }

    /// "Ready", or what OpenClicky is busy with.
    private var statusText: String {
        switch companionManager.voiceState {
        case .idle: return companionManager.agentActivityText == nil ? "Ready" : "Agent working"
        case .listening: return "Listening"
        case .processing: return "Thinking"
        case .responding: return "Speaking"
        }
    }

    @objc private func toggleAgentMode() { companionManager.setAgentModeEnabled(!companionManager.isAgentModeEnabled) }
    @objc private func toggleDock() { companionManager.setCursorDocked(!companionManager.isCursorDocked) }
    @objc private func openWindow() { companionManager.showDictationWindow(section: .record) }
    @objc private func openIsland() { companionManager.notchHUDManager.openPanel() }
    @objc private func openSettings() { companionManager.showSettings() }
    @objc private func replayWelcome() { companionManager.showDictationOnboarding(replay: true) }
    @objc private func quit() { companionManager.quitWithFarewell() }

    /// The mark, as a template image: the ring and its pointer, matching the app icon.
    private func makeClickyMenuBarIcon() -> NSImage {
        let iconSize: CGFloat = 18
        let image = NSImage(size: NSSize(width: iconSize, height: iconSize), flipped: true) { rect in
            let path = OpenClickyMark.bezierPath(in: rect.insetBy(dx: 1.5, dy: 1.5))
            NSColor.black.setFill()
            path.fill()
            return true
        }
        image.isTemplate = true
        return image
    }

    /// Opens the panel automatically on a first launch so the user sees the intro and the
    /// Start button right away.
    func showPanelOnLaunch() {
        // Small delay so the status item has time to appear in the menu bar
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            self.showPanel()
        }
    }

    @objc private func statusItemClicked() {
        hidePanel()
        showStatusMenu()
    }

    // MARK: - Panel Lifecycle

    private func showPanel() {
        if panel == nil {
            createPanel()
        }

        positionPanelBelowStatusItem()

        panel?.makeKeyAndOrderFront(nil)
        panel?.orderFrontRegardless()
        installClickOutsideMonitor()
    }

    private func hidePanel() {
        panel?.orderOut(nil)
        removeClickOutsideMonitor()
    }

    private func createPanel() {
        let companionPanelView = CompanionPanelView(companionManager: companionManager)
            .frame(width: panelWidth)

        let hostingView = NSHostingView(rootView: companionPanelView)
        hostingView.frame = NSRect(x: 0, y: 0, width: panelWidth, height: panelHeight)
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = .clear

        let menuBarPanel = KeyablePanel(
            contentRect: NSRect(x: 0, y: 0, width: panelWidth, height: panelHeight),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        menuBarPanel.isFloatingPanel = true
        menuBarPanel.level = .floating
        menuBarPanel.isOpaque = false
        menuBarPanel.backgroundColor = .clear
        menuBarPanel.hasShadow = false
        menuBarPanel.hidesOnDeactivate = false
        menuBarPanel.isExcludedFromWindowsMenu = true
        menuBarPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        menuBarPanel.isMovableByWindowBackground = false
        menuBarPanel.titleVisibility = .hidden
        menuBarPanel.titlebarAppearsTransparent = true

        menuBarPanel.contentView = hostingView
        panel = menuBarPanel
    }

    private func positionPanelBelowStatusItem() {
        guard let panel else { return }
        let gapBelowMenuBar: CGFloat = 4
        // Without a status item (the default), the panel hangs from the top-right of the screen.
        let statusItemFrame: NSRect
        if let buttonWindow = statusItem?.button?.window {
            statusItemFrame = buttonWindow.frame
        } else {
            let screen = NSScreen.main ?? NSScreen.screens.first
            let visibleFrame = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
            statusItemFrame = NSRect(x: visibleFrame.maxX - 24 - panelWidth / 2, y: visibleFrame.maxY, width: 24, height: 24)
        }

        // Calculate the panel's content height from the hosting view's fitting size
        // so the panel snugly wraps the SwiftUI content instead of using a fixed height.
        let fittingSize = panel.contentView?.fittingSize ?? CGSize(width: panelWidth, height: panelHeight)
        let actualPanelHeight = fittingSize.height

        // Horizontally center the panel beneath the status item icon
        let panelOriginX = statusItemFrame.midX - (panelWidth / 2)
        let panelOriginY = statusItemFrame.minY - actualPanelHeight - gapBelowMenuBar

        panel.setFrame(
            NSRect(x: panelOriginX, y: panelOriginY, width: panelWidth, height: actualPanelHeight),
            display: true
        )
    }

    // MARK: - Click Outside Dismissal

    /// Installs a global event monitor that hides the panel when the user clicks
    /// anywhere outside it — the same transient dismissal behavior as NSPopover.
    /// Uses a short delay so that system permission dialogs (triggered by Grant
    /// buttons in the panel) don't immediately dismiss the panel when they appear.
    private func installClickOutsideMonitor() {
        removeClickOutsideMonitor()

        clickOutsideMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] event in
            guard let self, let panel = self.panel else { return }

            // Check if the click is inside the status item button — if so, the
            // statusItemClicked handler will toggle the panel, so don't also hide.
            let clickLocation = NSEvent.mouseLocation
            if panel.frame.contains(clickLocation) {
                return
            }

            // Delay dismissal slightly so the panel doesn't vanish the instant a system
            // dialog opened from inside it takes focus.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                guard panel.isVisible else { return }
                self.hidePanel()
            }
        }
    }

    private func removeClickOutsideMonitor() {
        if let monitor = clickOutsideMonitor {
            NSEvent.removeMonitor(monitor)
            clickOutsideMonitor = nil
        }
    }
}

/// The menu's first row: a status dot, the name, what it is doing, and the two keys to remember.
private struct StatusMenuHeader: View {
    let statusText: String
    let dictationKey: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                Circle().fill(statusText == "Ready" ? Color(nsColor: .systemGreen) : Color(nsColor: .systemOrange)).frame(width: 8, height: 8)
                Text("OpenClicky").font(.system(size: 13, weight: .bold))
                Spacer()
                Text(statusText).font(.system(size: 13)).foregroundStyle(.secondary)
            }
            Text("Hold ⌃⌥ to talk · hold \(dictationKey) to dictate").font(.system(size: 12)).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .frame(width: 280, alignment: .leading)
    }
}
