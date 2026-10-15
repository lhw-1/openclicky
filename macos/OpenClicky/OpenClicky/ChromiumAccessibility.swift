//
//  ChromiumAccessibility.swift
//  OpenClicky
//
//  Chrome, Edge, Brave, Arc and every Electron app keep their web accessibility tree switched off
//  until an assistive client announces itself. Until then Accessibility reports nothing focused in
//  them at all: no text box for a dictation, no email for "rephrase this" (a tester's Gmail compose
//  box on a fresh Mac, 2026-10-15: every query came back with no element, the rewrite tool was
//  never offered, Clicky only spoke). The announcement is the application attribute
//  AXEnhancedUserInterface, the one VoiceOver sets: Chromium builds its tree about two seconds
//  after seeing it, although the write itself comes back as an error. Electron apps take
//  AXManualAccessibility as well. On a Mac where another assistive tool had already set it the
//  problem never showed, which is why it hid for so long.
//
//  Only Chromium-based apps get the write. On a native AppKit app AXEnhancedUserInterface is a
//  real switch (window animations and other VoiceOver-era behaviour change under it), so it is
//  never set there. An app is Chromium-based when its bundle carries a "… Helper (Renderer).app"
//  under Contents/Frameworks: Chrome keeps it inside its framework's Versions, Electron and CEF
//  apps next to the framework.
//

import AppKit
import ApplicationServices
import Foundation

nonisolated enum ChromiumAccessibility {
    private static let lock = NSLock()
    private static var isChromiumByBundlePath: [String: Bool] = [:]
    private static var wokenProcessIDs: Set<pid_t> = []
    private static var activationObserver: NSObjectProtocol?

    /// From now on, every Chromium-based app is woken as it comes to the front (and the one in
    /// front now), so its tree is ready long before a question or a take.
    static func startWakingFrontApps() {
        lock.lock()
        let alreadyStarted = activationObserver != nil
        lock.unlock()
        guard !alreadyStarted else { return }
        let observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: nil
        ) { notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            wake(app)
        }
        lock.lock()
        activationObserver = observer
        lock.unlock()
        wakeFrontApp()
    }

    /// Wakes the app in front when it is Chromium-based. Cheap enough for every press: a few
    /// cached file checks, and two attribute writes that Chromium answers in under a millisecond.
    /// Off the main thread, because a hung browser would hold each write for the 0.25 s timeout.
    static func wakeFrontApp() {
        guard let app = NSWorkspace.shared.frontmostApplication else { return }
        wake(app)
    }

    static func wake(_ app: NSRunningApplication) {
        guard AXIsProcessTrusted(), isChromiumBased(app) else { return }
        let processID = app.processIdentifier
        let appName = app.localizedName ?? "a Chromium app"
        DispatchQueue.global(qos: .utility).async {
            let application = AXUIElementCreateApplication(processID)
            AXUIElementSetMessagingTimeout(application, 0.25)
            // Chromium answers both writes with an error and acts on them anyway, so the results
            // say nothing worth checking. Written on every wake, not once: Chromium can drop the
            // state again (tab switches, a long time in the background).
            AXUIElementSetAttributeValue(application, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
            AXUIElementSetAttributeValue(application, "AXManualAccessibility" as CFString, kCFBooleanTrue)
            lock.lock()
            let firstTime = wokenProcessIDs.insert(processID).inserted
            lock.unlock()
            if firstTime { AppLog.append("accessibility: asked \(appName) (pid \(processID)) to switch its web accessibility tree on") }
        }
    }

    static func isChromiumBased(_ app: NSRunningApplication) -> Bool {
        guard let bundleURL = app.bundleURL else { return false }
        return isChromiumBased(bundleURL: bundleURL)
    }

    /// Whether the bundle carries a Chromium renderer helper; remembered per bundle path.
    static func isChromiumBased(bundleURL: URL) -> Bool {
        let bundlePath = bundleURL.standardizedFileURL.path
        lock.lock()
        let known = isChromiumByBundlePath[bundlePath]
        lock.unlock()
        if let known { return known }
        let answer = bundleCarriesRendererHelper(bundleURL: bundleURL)
        lock.lock()
        isChromiumByBundlePath[bundlePath] = answer
        lock.unlock()
        return answer
    }

    private static let rendererHelperSuffix = "Helper (Renderer).app"

    /// Looks exactly where the Chromium family keeps the renderer helper, nowhere else:
    /// Contents/Frameworks/<x> Helper (Renderer).app (Electron, CEF) and
    /// Contents/Frameworks/<x> Framework.framework/Versions/<v>/Helpers/<x> Helper (Renderer).app (Chrome, Edge, Brave).
    private static func bundleCarriesRendererHelper(bundleURL: URL) -> Bool {
        let fileManager = FileManager.default
        let frameworksURL = bundleURL.appendingPathComponent("Contents/Frameworks", isDirectory: true)
        guard let frameworkEntries = try? fileManager.contentsOfDirectory(atPath: frameworksURL.path) else { return false }
        for entry in frameworkEntries {
            if entry.hasSuffix(rendererHelperSuffix) { return true }
            guard entry.hasSuffix(".framework") else { continue }
            let versionsURL = frameworksURL.appendingPathComponent(entry).appendingPathComponent("Versions", isDirectory: true)
            guard let versions = try? fileManager.contentsOfDirectory(atPath: versionsURL.path) else { continue }
            for version in versions where version != "Current" {
                let helpersURL = versionsURL.appendingPathComponent(version).appendingPathComponent("Helpers", isDirectory: true)
                guard let helpers = try? fileManager.contentsOfDirectory(atPath: helpersURL.path) else { continue }
                if helpers.contains(where: { $0.hasSuffix(rendererHelperSuffix) }) { return true }
            }
        }
        return false
    }
}
