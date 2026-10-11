//
//  DictationWindowLayoutTests.swift
//  OpenClickyTests
//
//  The window's layout rules that can be checked without drawing it: every window (main and
//  onboarding) follows the "appearance" setting (F-47 of the 2026-10-11 deep test).
//

import AppKit
import Combine
import Foundation
import Testing
@testable import OpenClicky

@MainActor
struct DictationWindowLayoutTests {
    @Test func aWindowFollowsTheAppearanceSettingNowAndWhenItChanges() async {
        let defaults = UserDefaults(suiteName: "DictationWindowLayoutTests.\(UUID().uuidString)")!
        let settings = DictationSettings(defaults: defaults)
        settings.appearance = .dark
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100), styleMask: [.titled], backing: .buffered, defer: true)
        let subscription = window.followAppearanceSetting(of: settings)
        #expect(window.appearance?.name == .darkAqua)

        settings.appearance = .light
        await waitUntil { window.appearance?.name == .aqua }
        #expect(window.appearance?.name == .aqua)

        settings.appearance = .system
        await waitUntil { window.appearance == nil }
        #expect(window.appearance == nil)
        subscription.cancel()
    }

    private func waitUntil(_ condition: () -> Bool) async {
        for _ in 0..<50 where !condition() {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }
}
