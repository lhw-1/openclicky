//
//  IslandComponentViews.swift
//  OpenClicky
//
//  How the island is drawn: the surface (black around the camera melting into glass below) and,
//  later in this file, the components that fill its slot and the capsule that flips them.
//

import AppKit
import SwiftUI

// MARK: - Glass

/// The glass under the open panel: the system's Liquid Glass on macOS 26, a frosted material
/// before it. Kept "active" by hand, because the island is a non-key panel of a background app
/// and the system would otherwise grey it out.
struct IslandGlassBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView()
            glass.cornerRadius = 0
            glass.style = .regular
            glass.tintColor = NSColor.black.withAlphaComponent(0.2)
            return glass
        }
        let frosted = NSVisualEffectView()
        frosted.material = .hudWindow
        frosted.blendingMode = .behindWindow
        frosted.state = .active
        return frosted
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

// MARK: - Surface

/// The island's body for a state: a glass layer (only when a panel or card is open and the glass
/// level is above zero) under a black layer whose bottom fades away, both cut to the island's
/// outline, with a shadow once open. Collapsed, peek and compact are plain black: the notch itself.
struct IslandSurface: View {
    let expansion: NotchHUDExpansion
    let width: CGFloat
    let height: CGFloat
    /// Where the band ends: the melt may begin under it.
    let bandBottom: CGFloat
    let glassLevel: Double
    let isSideDrawer: Bool
    /// Which edge a drawer hangs from (ignored under the notch).
    var drawerSide: HUDPlacement = .notch

    private var isOpen: Bool {
        switch expansion {
        case .full, .connect, .permission, .tour, .composer: return true
        case .collapsed, .peek, .compact: return false
        }
    }

    /// True when a material view is in the hierarchy at all: only the open panel melts. Cards
    /// (permission, connect, the tour, the composer) are mostly dim text and show on any
    /// wallpaper, so they stay solid black for contrast.
    var hasGlassLayer: Bool { expansion == .full && glassLevel > 0 }

    private var stops: IslandGlassStops? {
        guard hasGlassLayer else { return nil }
        return IslandGlass.stops(level: glassLevel, bandBottom: bandBottom, panelHeight: height)
    }

    private var bottomRadius: CGFloat { IslandCorners.bottomRadius(for: expansion, width: width) }
    private var topFlare: CGFloat { IslandCorners.topFlare(for: expansion, isSideDrawer: isSideDrawer) }

    var body: some View {
        ZStack {
            if hasGlassLayer {
                IslandGlassBackground()
                    .overlay(Color.black.opacity(IslandGlass.wash))
                    .transition(.opacity)
            }
            if let stops {
                DS.HUD.island
                    .mask(
                        LinearGradient(
                            stops: [
                                .init(color: .black, location: stops.start),
                                .init(color: .clear, location: stops.end),
                            ],
                            startPoint: .top, endPoint: .bottom
                        )
                    )
            } else {
                DS.HUD.island
            }
        }
        .clipShape(outline)
        .shadow(color: .black.opacity(isOpen ? DS.HUD.shadow.opacity : 0), radius: isOpen ? DS.HUD.shadow.radius : 0, y: isOpen ? DS.HUD.shadow.y : 0)
    }

    /// The notch outline, or a drawer whose screen-side corners are square.
    private var outline: AnyShape {
        if isSideDrawer {
            let isLeft = drawerSide == .left
            return AnyShape(UnevenRoundedRectangle(
                topLeadingRadius: isLeft ? 0 : bottomRadius,
                bottomLeadingRadius: isLeft ? 0 : bottomRadius,
                bottomTrailingRadius: isLeft ? bottomRadius : 0,
                topTrailingRadius: isLeft ? bottomRadius : 0,
                style: .continuous
            ))
        }
        return AnyShape(NotchIslandShape(bottomCornerRadius: bottomRadius, topCornerFlare: topFlare))
    }
}

// MARK: - Components

/// The take's words so far: the engine's name on the left, the words on the right, dim while
/// the take is still live and white once it has landed.
struct TranscriptIslandView: View {
    @ObservedObject var model: NotchHUDModel
    @ObservedObject var companionManager: CompanionManager
    @ObservedObject var orb: OrbModel
    @ObservedObject var settings: DictationSettings

    /// The context carries the words (the HUD manager copies them from the orb); the orb itself
    /// is the fallback so a word never lags the orb.
    private var words: String {
        let live = model.context.liveTranscript.isEmpty ? orb.liveTranscript : model.context.liveTranscript
        if model.context.isTakeLive { return live.isEmpty ? "listening…" : live }
        // Landed: the take's own words as pasted (the orb clears its live buffer on landing).
        return model.context.landedTranscript.isEmpty ? live : model.context.landedTranscript
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text(settings.engine.listenerName)
                .font(.system(size: 11))
                .foregroundColor(DS.HUD.text3)
                .lineLimit(1)
                .fixedSize()
                .padding(.top, 2)
            Text(words)
                .font(.system(size: 13))
                .foregroundColor(model.context.isTakeLive ? DS.HUD.text2 : DS.HUD.text)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
    }
}

/// The working agent's latest line over a thin progress bar while it runs, and a "follow up"
/// pill that opens the text composer on its thread once a result card is up.
struct AgentIslandView: View {
    @ObservedObject var model: NotchHUDModel
    @ObservedObject var companionManager: CompanionManager
    @ObservedObject var result: AgentResultPanelState

    private var activity: String? { model.context.agentActivityText ?? companionManager.agentActivityText }
    private var isRunning: Bool { activity != nil }
    private var line: String { activity ?? (result.title.isEmpty ? "agent" : result.title) }

    /// The follow-up pill: only while a result card is up and no agent is running. A typed
    /// follow-up interrupts whatever agent is working, and the card's thread is the only one the
    /// island knows, so mid-run there is nothing safe to offer.
    static func showsFollowUp(isRunning: Bool, isResultCardUp: Bool) -> Bool {
        isResultCardUp && !isRunning
    }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Text(line)
                    .font(.system(size: 13))
                    .foregroundColor(DS.HUD.text)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if isRunning {
                    IslandIndeterminateBar()
                        .frame(height: 2)
                } else if !result.status.isEmpty {
                    Text(result.status)
                        .font(.system(size: 11))
                        .foregroundColor(DS.HUD.text3)
                        .lineLimit(1)
                }
            }
            if Self.showsFollowUp(isRunning: isRunning, isResultCardUp: result.isVisible || model.context.isResultCardUp), !result.threadId.isEmpty {
                Button(action: {
                    let threadId = result.threadId
                    model.close()
                    companionManager.notchHUDManager.openTextComposer(threadId: threadId.isEmpty ? nil : threadId)
                }) {
                    Text("follow up")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(DS.HUD.text)
                        .padding(.horizontal, 12)
                        .frame(height: DS.HUD.pillHeight)
                        .background(Capsule().fill(model.glassLevel > 0 ? DS.HUD.glassTile : DS.HUD.bandControl))
                }
                .buttonStyle(.plain)
                .pointerCursor()
                .help("type a follow-up for this agent")
            }
        }
    }
}

/// A 2 pt bar whose highlight slides back and forth while an agent works.
struct IslandIndeterminateBar: View {
    @State private var phase: CGFloat = 0

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.12))
                Capsule()
                    .fill(DS.HUD.pointer)
                    .frame(width: proxy.size.width * 0.3)
                    .offset(x: phase * proxy.size.width * 0.7)
            }
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) { phase = 1 }
        }
    }
}

// MARK: - Capsule

/// The row under the open panel: one round button per component the slot can show right now,
/// the active one on a lighter disc. A click shows that component until the moment changes.
struct IslandNavigationCapsule: View {
    @ObservedObject var model: NotchHUDModel

    private var components: [any IslandComponent] {
        model.selection.available.compactMap { id in model.registry.first { $0.id == id } }
    }

    var body: some View {
        HStack(spacing: 4) {
            ForEach(components, id: \.id) { component in
                let isActive = component.id == model.selection.active
                Button(action: { model.selectComponent(component.id) }) {
                    Image(systemName: component.symbolName)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(isActive ? DS.HUD.text : DS.HUD.text2)
                        .frame(width: 24, height: 24)
                        .background(Circle().fill(isActive ? DS.HUD.capsuleActive : Color.clear))
                }
                .buttonStyle(.plain)
                .pointerCursor()
                .help(component.title)
                .accessibilityLabel(component.title)
                .accessibilityAddTraits(isActive ? .isSelected : [])
            }
        }
        .padding(.horizontal, 4)
        .frame(height: 28)
        .background(Capsule().fill(DS.HUD.capsule))
    }
}
