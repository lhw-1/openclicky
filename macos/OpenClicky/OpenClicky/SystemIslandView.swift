//
//  SystemIslandView.swift
//  OpenClicky
//
//  The System component: a ring per figure (CPU, memory, disk, battery) with a caption under it,
//  fed by the HUD manager's one `SystemStatsStore`, which samples only while this row is on screen.
//

import SwiftUI

/// An extra the user turns on in Settings: a glance at the Mac.
struct SystemIslandComponent: IslandComponent {
    let id = IslandComponentRegistry.systemID
    let title = "System"
    let symbolName = "gauge.with.dots.needle.33percent"
    let preferredHeight: CGFloat = 70
    let isOptional = true
    func isAvailable(in context: IslandContext) -> Bool { true }
    @MainActor func makeView(companionManager: CompanionManager, model: NotchHUDModel) -> AnyView {
        AnyView(SystemIslandView(store: companionManager.notchHUDManager.systemStats))
    }
}

/// One ring's worth: the fraction it fills, the figure inside it, the long figure for the caption
/// on hover, and whether it warns.
struct SystemTile: Equatable, Identifiable {
    let id: String
    let caption: String
    let fraction: Double
    let short: String
    let long: String
    let isWarning: Bool
}

struct SystemIslandView: View {
    @ObservedObject var store: SystemStatsStore
    @State private var hoveredID: String?

    /// CPU, memory and disk always; the battery when the Mac has one.
    static func tiles(for snapshot: SystemStatsSnapshot) -> [SystemTile] {
        let memoryFraction = snapshot.memoryTotal > 0 ? Double(snapshot.memoryUsed) / Double(snapshot.memoryTotal) : 0
        let diskFraction = snapshot.diskTotal > 0 ? 1 - Double(snapshot.diskFree) / Double(snapshot.diskTotal) : 0
        var tiles = [
            SystemTile(id: "cpu", caption: "cpu", fraction: snapshot.cpu, short: SystemStatsFormatter.percent(snapshot.cpu), long: SystemStatsFormatter.percent(snapshot.cpu), isWarning: SystemStatsTone.isWarning(fraction: snapshot.cpu)),
            SystemTile(id: "memory", caption: "memory", fraction: memoryFraction, short: SystemStatsFormatter.percent(memoryFraction), long: SystemStatsFormatter.memory(used: snapshot.memoryUsed, total: snapshot.memoryTotal), isWarning: SystemStatsTone.isWarning(fraction: memoryFraction)),
            SystemTile(id: "disk", caption: "disk", fraction: diskFraction, short: SystemStatsFormatter.percent(diskFraction), long: SystemStatsFormatter.disk(free: snapshot.diskFree), isWarning: SystemStatsTone.isWarning(fraction: diskFraction)),
        ]
        if let battery = snapshot.battery {
            tiles.append(SystemTile(id: "battery", caption: "battery", fraction: battery.level, short: SystemStatsFormatter.percent(battery.level), long: SystemStatsFormatter.battery(level: battery.level, isCharging: battery.isCharging), isWarning: SystemStatsTone.isWarning(batteryLevel: battery.level)))
        }
        return tiles
    }

    var body: some View {
        HStack(spacing: 12) {
            ForEach(Self.tiles(for: store.snapshot)) { tile in
                SystemTileView(tile: tile, isHovered: hoveredID == tile.id)
                    .onHover { hovering in
                        if hovering { hoveredID = tile.id } else if hoveredID == tile.id { hoveredID = nil }
                    }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { store.beginWatching() }
        .onDisappear { store.endWatching() }
    }
}

/// One tile: the ring with its figure inside and the caption (the long figure while hovered).
private struct SystemTileView: View {
    let tile: SystemTile
    let isHovered: Bool

    private var ringColor: Color { tile.isWarning ? DS.Colors.warning : DS.HUD.text }
    private var fill: CGFloat { CGFloat(min(max(tile.fraction, 0), 1)) }

    var body: some View {
        VStack(spacing: 5) {
            ring
                .frame(width: 28, height: 28)
            Text(isHovered ? tile.long : tile.caption)
                .font(.system(size: 10))
                .foregroundColor(DS.HUD.text3)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(width: 56)
        .contentShape(Rectangle())
        .help(tile.long)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(tile.caption) \(tile.long)")
    }

    private var ring: some View {
        ZStack {
            Circle()
                .stroke(Color.white.opacity(0.12), lineWidth: 3)
            Circle()
                .trim(from: 0, to: fill)
                .stroke(ringColor, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.easeInOut(duration: 0.4), value: fill)
            Text(tile.short)
                .font(.system(size: 9, weight: .semibold))
                .foregroundColor(DS.HUD.text)
                .minimumScaleFactor(0.7)
        }
    }
}
