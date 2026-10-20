//
//  IslandComponents.swift
//  OpenClicky
//
//  The island's slot: what the open panel shows under its band. A component declares when it is
//  available; the selector picks one for the moment (a live take, a working agent) or by the
//  user's choice (a default, an order, and a flip in the capsule). Pure: the views live in
//  `IslandComponentViews.swift`.
//

import Foundation
import SwiftUI

/// What the island knows about the moment, built by the HUD manager from what the app already
/// publishes.
struct IslandContext: Equatable {
    var isTakeLive = false
    var takeLandedAt: Date?
    var liveTranscript = ""
    var agentActivityText: String?
    var isResultCardUp = false
    var engineCanRun = true
    var placement: HUDPlacement = .notch
    var now = Date()

    static let idle = IslandContext(now: Date(timeIntervalSince1970: 0))

    /// How long a landed take keeps its transcript in front.
    static let landedTranscriptWindow: TimeInterval = 8

    /// The component the moment asks for: the transcript while a take is live or just landed,
    /// the agent while one works or its result card is up, else nothing.
    var contextualKey: String? {
        if isTakeLive { return IslandComponentRegistry.transcriptID }
        if let takeLandedAt, now.timeIntervalSince(takeLandedAt) < Self.landedTranscriptWindow { return IslandComponentRegistry.transcriptID }
        if agentActivityText != nil || isResultCardUp { return IslandComponentRegistry.agentID }
        return nil
    }
}

/// One thing the island's slot can show.
protocol IslandComponent {
    /// Stable; stored in Settings.
    var id: String { get }
    /// For Settings and the capsule's help text.
    var title: String { get }
    /// The capsule's icon (an SF Symbol name).
    var symbolName: String { get }
    /// The slot's height for this component in the notch placement.
    var preferredHeight: CGFloat { get }
    func isAvailable(in context: IslandContext) -> Bool
    @MainActor func makeView(companionManager: CompanionManager, model: NotchHUDModel) -> AnyView
}

/// The selector's answer: the active component and every one the capsule may flip to.
struct IslandComponentSelection: Equatable {
    let active: String
    let available: [String]
}

enum IslandComponentSelector {
    /// The override wins while it is available; else the moment's component; else the user's
    /// default; else the first available in the user's order. `available` is the registry filtered
    /// by availability, in the user's order (unknown ids ignored, missing ids appended in
    /// registration order).
    static func select(registry: [any IslandComponent], order: [String], defaultID: String, override: String?, context: IslandContext) -> IslandComponentSelection {
        precondition(!registry.isEmpty, "the island needs at least one component")
        let availableIDs = registry.filter { $0.isAvailable(in: context) }.map(\.id)
        let ordered = order.filter { availableIDs.contains($0) } + availableIDs.filter { !order.contains($0) }
        let candidates = [override, context.contextualKey, defaultID].compactMap { $0 }
        let active = candidates.first { ordered.contains($0) } ?? ordered.first ?? registry[0].id
        return IslandComponentSelection(active: active, available: ordered)
    }
}

/// The user's default component and order, in UserDefaults.
struct IslandComponentSettings {
    static let defaultKey = "openclicky.island.defaultComponent"
    static let orderKey = "openclicky.island.componentOrder"

    private let defaults: UserDefaults

    init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    var defaultID: String {
        get { defaults.string(forKey: Self.defaultKey) ?? IslandComponentRegistry.shortcutsID }
        set { defaults.set(newValue, forKey: Self.defaultKey) }
    }

    var order: [String] {
        get { defaults.stringArray(forKey: Self.orderKey) ?? [] }
        set { defaults.set(newValue, forKey: Self.orderKey) }
    }
}

/// The built-in components, in registration order.
enum IslandComponentRegistry {
    static let shortcutsID = "shortcuts"
    static let transcriptID = "transcript"
    static let agentID = "agent"

    @MainActor static var all: [any IslandComponent] {
        [ShortcutsIslandComponent(), TranscriptIslandComponent(), AgentIslandComponent()]
    }
}

/// Today's body row: dock or release the pointer, (i), and the shortcuts (or the engine warning).
struct ShortcutsIslandComponent: IslandComponent {
    let id = IslandComponentRegistry.shortcutsID
    let title = "Shortcuts"
    let symbolName = "keyboard"
    let preferredHeight: CGFloat = 45
    func isAvailable(in context: IslandContext) -> Bool { true }
    @MainActor func makeView(companionManager: CompanionManager, model: NotchHUDModel) -> AnyView { AnyView(EmptyView()) }
}

/// The take's words so far, while a take is live and for a moment after it lands.
struct TranscriptIslandComponent: IslandComponent {
    let id = IslandComponentRegistry.transcriptID
    let title = "Transcript"
    let symbolName = "text.quote"
    let preferredHeight: CGFloat = 45
    func isAvailable(in context: IslandContext) -> Bool { context.contextualKey == IslandComponentRegistry.transcriptID }
    @MainActor func makeView(companionManager: CompanionManager, model: NotchHUDModel) -> AnyView { AnyView(EmptyView()) }
}

/// The working agent's latest line, and its result card's follow-up.
struct AgentIslandComponent: IslandComponent {
    let id = IslandComponentRegistry.agentID
    let title = "Agent"
    let symbolName = "wand.and.sparkles"
    let preferredHeight: CGFloat = 45
    func isAvailable(in context: IslandContext) -> Bool { context.agentActivityText != nil || context.isResultCardUp }
    @MainActor func makeView(companionManager: CompanionManager, model: NotchHUDModel) -> AnyView { AnyView(EmptyView()) }
}
