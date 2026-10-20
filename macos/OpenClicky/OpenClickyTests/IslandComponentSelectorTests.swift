//
//  IslandComponentSelectorTests.swift
//  OpenClickyTests
//
//  Which component fills the island's slot: the moment first, then the user's choice.
//

import Foundation
import SwiftUI
import Testing
@testable import OpenClicky

struct IslandComponentSelectorTests {
    struct Stub: IslandComponent {
        let id: String
        var title: String { id }
        var symbolName: String { "circle" }
        var preferredHeight: CGFloat { 45 }
        let available: (IslandContext) -> Bool
        func isAvailable(in context: IslandContext) -> Bool { available(context) }
        @MainActor func makeView(companionManager: CompanionManager, model: NotchHUDModel) -> AnyView { AnyView(EmptyView()) }
    }
    let shortcuts = Stub(id: "shortcuts") { _ in true }
    let transcript = Stub(id: "transcript") { $0.contextualKey == "transcript" }
    let agent = Stub(id: "agent") { $0.contextualKey == "agent" }
    var registry: [any IslandComponent] { [shortcuts, transcript, agent] }
    let now = Date(timeIntervalSince1970: 1_000_000)

    @Test func idleShowsTheDefaultAloneSoNoCapsule() {
        let s = IslandComponentSelector.select(registry: registry, order: [], defaultID: "shortcuts", override: nil, context: .idle)
        #expect(s == IslandComponentSelection(active: "shortcuts", available: ["shortcuts"]))
    }

    @Test func aLiveTakeMakesTheTranscriptActiveAndKeepsItEightSecondsAfterLanding() {
        var context = IslandContext.idle
        context.now = now
        context.isTakeLive = true
        #expect(IslandComponentSelector.select(registry: registry, order: [], defaultID: "shortcuts", override: nil, context: context).active == "transcript")
        context.isTakeLive = false
        context.takeLandedAt = now.addingTimeInterval(-7.9)
        #expect(context.contextualKey == "transcript")
        context.takeLandedAt = now.addingTimeInterval(-8.1)
        #expect(context.contextualKey == nil)
    }

    @Test func anAgentOutranksTheDefaultButNotALiveTake() {
        var context = IslandContext.idle
        context.agentActivityText = "editing Hero.swift"
        #expect(context.contextualKey == "agent")
        context.isTakeLive = true
        #expect(context.contextualKey == "transcript")
        context.isTakeLive = false
        context.agentActivityText = nil
        context.isResultCardUp = true
        #expect(context.contextualKey == "agent")
    }

    @Test func theOverrideWinsWhileAvailableAndTheOrderIsTheUsers() {
        var context = IslandContext.idle
        context.agentActivityText = "working"
        let s = IslandComponentSelector.select(registry: registry, order: ["agent", "bogus", "shortcuts"], defaultID: "shortcuts", override: "shortcuts", context: context)
        #expect(s == IslandComponentSelection(active: "shortcuts", available: ["agent", "shortcuts"]))
        let gone = IslandComponentSelector.select(registry: registry, order: [], defaultID: "shortcuts", override: "transcript", context: context)
        #expect(gone.active == "agent")
    }

    @Test func anUnknownOrUnavailableDefaultFallsBackToTheFirstAvailable() {
        let s = IslandComponentSelector.select(registry: registry, order: ["transcript", "shortcuts"], defaultID: "nope", override: nil, context: .idle)
        #expect(s.active == "shortcuts")
        let t = IslandComponentSelector.select(registry: registry, order: [], defaultID: "transcript", override: nil, context: .idle)
        #expect(t.active == "shortcuts")
    }

    @MainActor
    @Test func theRealRegistryHasTheThreeBuiltInsInOrder() {
        #expect(IslandComponentRegistry.all.map(\.id) == ["shortcuts", "transcript", "agent"])
        #expect(ShortcutsIslandComponent().preferredHeight == 45)
        #expect(TranscriptIslandComponent().preferredHeight == 52)
        #expect(AgentIslandComponent().preferredHeight == 52)
    }

    @Test func theContextIsBuiltFromWhatTheAppAlreadyPublishes() {
        let now = Date()
        let c = IslandContext.make(takeState: .listening, lastTake: nil, liveTranscript: "hi", agentActivityText: nil, isResultCardUp: false, engineCanRun: true, placement: .notch, now: now)
        #expect(c.isTakeLive)
        #expect(c.contextualKey == "transcript")
        #expect(c.liveTranscript == "hi")
        let d = IslandContext.make(takeState: .idle, lastTake: nil, liveTranscript: "", agentActivityText: nil, isResultCardUp: true, engineCanRun: true, placement: .notch, now: now)
        #expect(d.contextualKey == "agent")
    }

    @Test func settingsRoundTripWithDefaults() {
        let defaults = UserDefaults(suiteName: "IslandComponentSelectorTests")!
        defaults.removePersistentDomain(forName: "IslandComponentSelectorTests")
        var settings = IslandComponentSettings(defaults: defaults)
        #expect(settings.defaultID == "shortcuts")
        #expect(settings.order == [])
        settings.defaultID = "agent"
        settings.order = ["agent", "shortcuts"]
        let again = IslandComponentSettings(defaults: defaults)
        #expect(again.defaultID == "agent")
        #expect(again.order == ["agent", "shortcuts"])
    }
}
