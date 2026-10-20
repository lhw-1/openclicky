//
//  NotchHUDModelTests.swift
//  OpenClickyTests
//
//  Hovering the island only peeks; a click opens the panel; cards and setup outrank both.
//

import CoreGraphics
import Testing
@testable import OpenClicky

@MainActor
struct NotchHUDModelTests {
    private func notchModel() -> NotchHUDModel {
        NotchHUDModel(geometry: NotchGeometry(screenFrame: CGRect(x: 0, y: 0, width: 1512, height: 982), hasHardwareNotch: true, notchWidth: 190, notchHeight: 33, visibleFrame: CGRect(x: 0, y: 0, width: 1512, height: 949)))
    }

    /// The busy strip opens after the island's 0.4 s grace period; a busy CI runner can take longer.
    private func waitFor(_ model: NotchHUDModel, _ expansion: NotchHUDExpansion) async throws {
        for _ in 0..<150 where model.expansion != expansion {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    @Test func hoveringPeeksAndNeverOpensThePanel() {
        let model = notchModel()
        model.setHovering(true)
        #expect(model.expansion == .peek)
        #expect(model.width == 230)   // 190 notch + 20 a side
        #expect(model.height == 57)   // 33 notch + 24 line
    }

    @Test func aClickOpensThePanelAndAnotherClickCloses() {
        let model = notchModel()
        model.setHovering(true)
        model.islandClicked()
        #expect(model.expansion == .full)
        model.islandClicked()
        #expect(model.expansion == .peek)   // still hovering
        model.setHovering(false)
        model.close()
        #expect(model.expansion == .collapsed)
    }

    @Test func aClickOnTheBusyStripOpensThePanelButNotWhileSpeakingOrInAGuide() async throws {
        let model = notchModel()
        model.setBusy(true)
        try await waitFor(model, .compact)
        #expect(model.expansion == .compact)
        model.islandClicked()
        #expect(model.expansion == .full)
        model.close()
        #expect(model.expansion == .compact)
        model.setSpeaking(true)
        model.islandClicked()
        #expect(model.expansion == .compact)
        model.setSpeaking(false)
        model.setGuideStep(1)
        model.islandClicked()
        #expect(model.expansion == .compact)
    }

    @Test func setupAndCardsOutrankThePeek() {
        let model = notchModel()
        model.setPermissionPrompt(PermissionPrompt(step: .accessibility, status: PermissionStatus()))
        model.setHovering(true)
        #expect(model.expansion == .permission)
        model.setPermissionPrompt(nil)
        model.setConnectPrompt(AppConnectPrompt(skillId: "youtube", appName: "YouTube", integration: "youtube", frontBundleIdentifier: nil, examplePrompts: []))
        #expect(model.expansion == .connect)
    }

    @Test func aDisplayWithoutAMenuBarBandStillHasRoomForThePeekLine() {
        let screenFrame = CGRect(x: -173, y: 982, width: 1920, height: 1080)
        let model = NotchHUDModel(geometry: NotchGeometry.virtualNotch(screenFrame: screenFrame, visibleFrame: screenFrame))
        model.setHovering(true)
        #expect(model.peekHeight == 58)   // 34 band + 24 line
        model.setBusy(true)
        #expect(model.compactHeight == 42)   // 34 band + 8 lip
    }

    @Test func sideDrawersStillOpenOnHover() {
        let model = notchModel()
        model.placement = .left
        model.setHovering(true)
        #expect(model.expansion == .full)
    }

    @Test func theSlotFollowsTheContextAndTheUsersOverrideSurvivesPartialTranscripts() {
        let model = notchModel()
        model.registry = IslandComponentSelectorTests().registry
        #expect(model.selection.active == "shortcuts")
        #expect(!model.showsCapsule)
        #expect(model.fullHeight == model.bandRowHeight + 45)
        var context = IslandContext.idle
        context.isTakeLive = true
        context.liveTranscript = "hello"
        model.setContext(context)
        #expect(model.selection.active == "transcript")
        #expect(model.showsCapsule)
        #expect(model.fullHeight == model.bandRowHeight + 45 + 36)
        model.selectComponent("shortcuts")
        context.liveTranscript = "hello there"
        model.setContext(context)
        #expect(model.selection.active == "shortcuts")      // override survives a partial
        context.isTakeLive = false
        context.takeLandedAt = nil
        model.setContext(context)
        #expect(model.selection.active == "shortcuts")      // contextual key changed: override cleared, default wins
        context.agentActivityText = "working"
        model.setContext(context)
        #expect(model.selection.active == "agent")          // a fresh contextual key is followed again
    }

    @Test func pressIsAFlagTheViewScalesOn() {
        let model = notchModel()
        model.setPressed(true)
        #expect(model.isPressed)
        model.setPressed(false)
        #expect(!model.isPressed)
    }
}
