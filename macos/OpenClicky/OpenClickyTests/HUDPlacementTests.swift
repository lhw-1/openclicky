//
//  HUDPlacementTests.swift
//  OpenClickyTests
//
//  Where the island sits for each placement, and the goodbye lines.
//

import Testing
import Foundation
import CoreGraphics
@testable import OpenClicky

@MainActor
struct HUDPlacementTests {
    private let screenFrame = CGRect(x: 0, y: 0, width: 1512, height: 982)
    private let visibleFrame = CGRect(x: 0, y: 80, width: 1512, height: 865)

    private func model(_ placement: HUDPlacement) -> NotchHUDModel {
        let geometry = placement.isSideDrawer
            ? NotchGeometry(screenFrame: screenFrame, hasHardwareNotch: false, notchWidth: 190, notchHeight: 0, visibleFrame: visibleFrame)
            : NotchGeometry(screenFrame: screenFrame, hasHardwareNotch: true, notchWidth: 185, notchHeight: 37, visibleFrame: visibleFrame)
        let model = NotchHUDModel(geometry: geometry)
        model.placement = placement
        return model
    }

    @Test func theOpenPanelUnderTheNotchIsAtMost88PointsTall() {
        let island = model(.notch)
        island.openPinned()
        #expect(island.height <= 88)
        #expect(island.width == 512)
    }

    @Test func notchIslandHangsCentredFromTheTop() {
        let island = model(.notch).islandFrame
        #expect(island.midX == screenFrame.midX)
        #expect(island.maxY == screenFrame.maxY)
        #expect(island.width == 185)
    }

    @Test func rightDrawerCollapsesToAHandleOnTheRightEdge() {
        let drawer = model(.right)
        let island = drawer.islandFrame
        #expect(island.maxX == visibleFrame.maxX)
        #expect(island.width == drawer.handleStripHeight)
        #expect(island.height == drawer.sideHandleLength)
        // The window's margin is on the three sides away from the edge.
        #expect(drawer.windowFrame.maxX == visibleFrame.maxX)
        #expect(drawer.windowFrame.minX == island.minX - drawer.windowMargin)
        #expect(drawer.dockPoint.x < island.minX)
    }

    @Test func leftDrawerHangsFromTheLeftEdgeAndStaysOnScreen() {
        let drawer = model(.left)
        drawer.openPinned()
        let island = drawer.islandFrame
        #expect(island.minX == visibleFrame.minX)
        #expect(island.minY >= visibleFrame.minY)
        #expect(island.maxY <= visibleFrame.maxY)
    }

    @Test func hiddenIslandIsNothingWhileIdle() {
        let hidden = model(.hidden)
        #expect(hidden.isInvisible)
        #expect(hidden.width == 0 && hidden.height == 0)
        hidden.openPinned()
        #expect(!hidden.isInvisible)
    }

    @Test func goodbyeTakesTheIslandOverEvenWhileBusy() {
        let island = model(.notch)
        island.setBusy(true)
        island.openPinned()
        island.beginGoodbye()
        island.setCaption("bye")
        #expect(island.expansion == .compact)
        #expect(island.isShowingCaption)
        island.setHovering(true)
        #expect(island.expansion == .compact)
    }

    /// While the tour (or a permission card) is up, the pointer drifting onto the island, the
    /// busy strip under a question, or a click must never open the panel over the setup.
    @Test func setupKeepsThePanelClosed() async throws {
        let island = model(.notch)
        island.setTourCard(FirstRunTourCard(step: .talk, title: "t", detail: "d", secondaryTitle: "skip"))
        island.setHovering(true)
        #expect(island.expansion == .tour)
        // The card gives way to the busy strip after the island's 0.4 s grace period.
        island.setBusy(true)
        try await Task.sleep(nanoseconds: 600_000_000)
        #expect(island.expansion == .compact)
        island.togglePinned()
        island.setHovering(true)
        try await Task.sleep(nanoseconds: 600_000_000)
        #expect(island.expansion == .compact)
        island.setBusy(false)
        #expect(island.expansion == .tour)
    }

    @Test func everyGoodbyeSaysHowToComeBackOrIsShort() {
        for farewell in Farewell.all {
            #expect(farewell.text.contains("openclicky") || farewell.text.contains("⌘ space"))
            #expect(farewell.text.count <= 90)
        }
    }
}
