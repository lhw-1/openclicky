//
//  IslandPlugins.swift
//  OpenClicky
//
//  The island's plugins: optional extras, built for the Mac, each off until the user turns it on
//  in Settings → General → Plugins. Everything a plugin needs lives in its own folder under
//  `Plugins/` (its store, its view, its component), so the rest of the app, and the Windows and
//  Linux clients in their own trees, never depend on it. A plugin is an `IslandComponent` whose
//  `isPlugin` is true; the registry below is the only place that lists them.
//

import Foundation

enum IslandPluginRegistry {
    static let systemID = "system"
    static let shelfID = "shelf"
    static let agentsID = "agents"

    /// In the order the capsule and Settings show them.
    @MainActor static var all: [any IslandComponent] {
        [SystemIslandComponent(), ShelfIslandComponent(), AgentsIslandComponent()]
    }
}
