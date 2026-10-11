//
//  HUDPlacementTests.swift
//  OpenClickyTests
//
//  Where the island sits for each placement, and the goodbye lines.
//

import Testing
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

    @Test func everyGoodbyeSaysHowToComeBackOrIsShort() {
        for farewell in Farewell.all {
            #expect(farewell.text.contains("openclicky") || farewell.text.contains("⌘ space"))
            #expect(!farewell.spoken.contains("⌘") && !farewell.spoken.contains("→"))
            #expect(farewell.text.count <= 90)
        }
    }
}
