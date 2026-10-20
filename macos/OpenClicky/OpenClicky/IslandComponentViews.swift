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

    /// True when a material view is in the hierarchy at all.
    var hasGlassLayer: Bool { isOpen && glassLevel > 0 }

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
