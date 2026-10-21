//
//  MediaIslandView.swift
//  OpenClicky
//
//  The Now playing plugin: artwork, title and artist, a bar that runs with the track (a click
//  seeks), and previous / play-pause / next.
//

import AppKit
import SwiftUI

/// A plugin: what Music or Spotify is playing, with controls.
struct MediaIslandComponent: IslandComponent {
    let id = IslandPluginRegistry.mediaID
    let title = "Now playing"
    let symbolName = "music.note"
    let preferredHeight: CGFloat = 84
    let isPlugin = true
    let settingsDetail: String? = "Shows what Music or Spotify is playing, with artwork, progress and controls. macOS asks once per player to let OpenClicky control it."
    func isAvailable(in context: IslandContext) -> Bool { true }
    @MainActor func makeView(companionManager: CompanionManager, model: NotchHUDModel) -> AnyView {
        AnyView(MediaIslandView(media: companionManager.notchHUDManager.media))
    }
}

struct MediaIslandView: View {
    @ObservedObject var media: MediaStore

    var body: some View {
        Group {
            if let snapshot = media.snapshot {
                track(snapshot)
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    Text("nothing playing")
                        .font(.system(size: 13))
                        .foregroundColor(DS.HUD.text)
                    Text("play something in music or spotify")
                        .font(.system(size: 11))
                        .foregroundColor(DS.HUD.text3)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .onAppear { media.beginWatching() }
        .onDisappear { media.endWatching() }
    }

    private func track(_ snapshot: MediaSnapshot) -> some View {
        HStack(alignment: .center, spacing: 12) {
            artwork
                .frame(width: 56, height: 56)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                Text(snapshot.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(DS.HUD.text)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(snapshot.artist.isEmpty ? snapshot.player.displayName : snapshot.artist)
                    .font(.system(size: 11))
                    .foregroundColor(DS.HUD.text2)
                    .lineLimit(1)
                MediaProgressBar(media: media, snapshot: snapshot)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 6) {
                control("backward.fill", help: "previous track") { Task { await media.previous() } }
                control(snapshot.isPlaying ? "pause.fill" : "play.fill", help: snapshot.isPlaying ? "pause" : "play") { Task { await media.playPause() } }
                control("forward.fill", help: "next track") { Task { await media.next() } }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    @ViewBuilder private var artwork: some View {
        if let image = media.artwork {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
        } else {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous).fill(DS.HUD.bandControl)
                Image(systemName: "music.note")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundColor(DS.HUD.text2)
            }
        }
    }

    private func control(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(DS.HUD.text)
                .frame(width: DS.HUD.pillHeight, height: DS.HUD.pillHeight)
                .background(Circle().fill(DS.HUD.bandControl))
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .help(help)
        .accessibilityLabel(help)
    }
}

/// The bar runs once a second while playing; a click seeks to that point of the track.
private struct MediaProgressBar: View {
    @ObservedObject var media: MediaStore
    let snapshot: MediaSnapshot

    var body: some View {
        TimelineView(.periodic(from: .now, by: snapshot.isPlaying ? 1 : 3600)) { timeline in
            let position = snapshot.position(at: timeline.date)
            let fraction = snapshot.duration > 0 ? position / snapshot.duration : 0
            HStack(spacing: 6) {
                Text(MediaFormatter.clock(position))
                    .font(.system(size: 9).monospacedDigit())
                    .foregroundColor(DS.HUD.text3)
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.white.opacity(0.12))
                        Capsule().fill(DS.HUD.text).frame(width: max(3, proxy.size.width * CGFloat(min(max(fraction, 0), 1))))
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { location in
                        let target = Double(location.x / max(proxy.size.width, 1))
                        Task { await media.seek(to: target) }
                    }
                }
                .frame(height: 3)
                Text(MediaFormatter.clock(snapshot.duration))
                    .font(.system(size: 9).monospacedDigit())
                    .foregroundColor(DS.HUD.text3)
            }
        }
        .frame(height: 12)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(MediaFormatter.clock(snapshot.position)) of \(MediaFormatter.clock(snapshot.duration))")
    }
}
