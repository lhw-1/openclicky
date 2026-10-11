//
//  DictationWindowLayoutTests.swift
//  OpenClickyTests
//
//  The window's layout rules that can be checked without drawing it: when the sidebar's list
//  fades at an edge to say there is more (F-45 of the 2026-10-11 deep test), and that every window
//  (main and onboarding) follows the "appearance" setting (F-47).
//

import AppKit
import Combine
import Foundation
import Testing
@testable import OpenClicky

@MainActor
struct DictationWindowLayoutTests {
    // MARK: sidebar list overflow

    @Test func aListThatFitsFadesNeitherEdge() {
        let edges = SidebarListOverflow(contentTop: 0, contentHeight: 400, visibleHeight: 480)
        #expect(!edges.hasMoreAbove)
        #expect(!edges.hasMoreBelow)
    }

    @Test func aListTallerThanTheWindowFadesItsBottomAtTheStart() {
        // 900 × 600: the list is taller than the space between the pinned header and footer.
        let edges = SidebarListOverflow(contentTop: 0, contentHeight: 480, visibleHeight: 400)
        #expect(!edges.hasMoreAbove)
        #expect(edges.hasMoreBelow)
    }

    @Test func aListScrolledToItsEndFadesOnlyItsTop() {
        let edges = SidebarListOverflow(contentTop: -80, contentHeight: 480, visibleHeight: 400)
        #expect(edges.hasMoreAbove)
        #expect(!edges.hasMoreBelow)
    }

    @Test func aListHalfwayFadesBothEdges() {
        let edges = SidebarListOverflow(contentTop: -40, contentHeight: 480, visibleHeight: 400)
        #expect(edges.hasMoreAbove)
        #expect(edges.hasMoreBelow)
    }

    @Test func aFractionOfAPointIsNotMore() {
        // Rounding in layout must not leave a fade on a list that fits.
        let edges = SidebarListOverflow(contentTop: -0.4, contentHeight: 400.6, visibleHeight: 400)
        #expect(!edges.hasMoreAbove)
        #expect(!edges.hasMoreBelow)
    }

    @Test func aRowUnderTheBottomFadeDoesNotShowInFull() {
        // "voice" at 900 × 600: on screen, but half under the fade — opening it must scroll.
        let edges = SidebarListOverflow(contentTop: 0, contentHeight: 480, visibleHeight: 400)
        let rowUnderFade = CGRect(x: 0, y: 380, width: 196, height: 32)
        #expect(!edges.showsInFull(rowUnderFade, visibleHeight: 400))
        let rowOutOfSight = CGRect(x: 0, y: 440, width: 196, height: 32)
        #expect(!edges.showsInFull(rowOutOfSight, visibleHeight: 400))
    }

    @Test func aRowInPlainViewShowsInFullSoAClickDoesNotMoveTheList() {
        let edges = SidebarListOverflow(contentTop: 0, contentHeight: 480, visibleHeight: 400)
        #expect(edges.showsInFull(CGRect(x: 0, y: 0, width: 196, height: 32), visibleHeight: 400))
        #expect(edges.showsInFull(CGRect(x: 0, y: 330, width: 196, height: 32), visibleHeight: 400))
    }

    @Test func theLastRowAtTheEndOfTheListShowsInFullWithNoFadeBelow() {
        let edges = SidebarListOverflow(contentTop: -80, contentHeight: 480, visibleHeight: 400)
        #expect(edges.showsInFull(CGRect(x: 0, y: 360, width: 196, height: 32), visibleHeight: 400))
        // …but the top fade now covers the first rows.
        #expect(!edges.showsInFull(CGRect(x: 0, y: 2, width: 196, height: 32), visibleHeight: 400))
    }

    // MARK: appearance

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
