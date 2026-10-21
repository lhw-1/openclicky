//
//  MediaStore.swift
//  OpenClicky
//
//  One per app: asks the player what is playing, every 2 s while a Now playing row is on screen,
//  every 5 s while the plugin is merely on (so the island can switch to it and the peek line can
//  name the track), never while off. Artwork is fetched once per track. Commands go straight to
//  the player and the next read follows at once.
//

import AppKit
import Combine
import Foundation

enum MediaCommand: Equatable, Sendable {
    case playPause
    case next
    case previous
    case seek(TimeInterval)
}

/// Where the track comes from: the players' scripting interfaces, or a test double.
protocol MediaSourcing: Sendable {
    func readNowPlaying() async -> MediaSnapshot?
    func perform(_ command: MediaCommand, on player: MediaPlayer) async
    func loadArtwork(for snapshot: MediaSnapshot) async -> NSImage?
}

@MainActor
final class MediaStore: ObservableObject {
    static let watchedInterval: TimeInterval = 2
    static let backgroundInterval: TimeInterval = 5

    @Published private(set) var snapshot: MediaSnapshot?
    @Published private(set) var artwork: NSImage?

    private let source: any MediaSourcing
    private let now: () -> Date
    private var isEnabled = false
    private var watchers = 0
    private var timer: Timer?
    private var generation = 0
    private var artworkKey: String?

    init(source: any MediaSourcing, now: @escaping () -> Date = Date.init) {
        self.source = source
        self.now = now
    }

    var isPlaying: Bool { snapshot?.isPlaying ?? false }

    /// "♪ title · artist" while playing, for the island's peek line.
    var nowPlayingLine: String? {
        guard let snapshot, snapshot.isPlaying else { return nil }
        return snapshot.artist.isEmpty ? "♪ \(snapshot.title)" : "♪ \(snapshot.title) · \(snapshot.artist)"
    }

    var isPolling: Bool { timer != nil }
    var pollInterval: TimeInterval { watchers > 0 ? Self.watchedInterval : Self.backgroundInterval }

    /// The plugin's switch: off forgets the track and stops asking.
    func setEnabled(_ enabled: Bool) {
        guard isEnabled != enabled else { return }
        isEnabled = enabled
        if enabled {
            Task { await refreshNow() }
        } else {
            generation += 1
            snapshot = nil
            artwork = nil
            artworkKey = nil
        }
        rebuildTimer()
    }

    func beginWatching() {
        watchers += 1
        if watchers == 1 {
            if isEnabled { Task { await refreshNow() } }
            rebuildTimer()
        }
    }

    func endWatching() {
        watchers = max(0, watchers - 1)
        if watchers == 0 { rebuildTimer() }
    }

    /// One read; a read that started before a newer one (or before the switch went off) is dropped.
    func refreshNow() async {
        guard isEnabled else { return }
        #if DEBUG
        if let debugSnapshot {
            if snapshot != debugSnapshot { snapshot = debugSnapshot }
            return
        }
        #endif
        generation += 1
        let mine = generation
        let next = await source.readNowPlaying()
        guard mine == generation, isEnabled else { return }
        if next != snapshot { snapshot = next }
        guard let next else {
            artwork = nil
            artworkKey = nil
            return
        }
        if next.artworkKey != artworkKey {
            artworkKey = next.artworkKey
            let image = await source.loadArtwork(for: next)
            guard mine == generation, artworkKey == next.artworkKey else { return }
            artwork = image
        }
    }

    func playPause() async { await perform(.playPause) }
    func next() async { await perform(.next) }
    func previous() async { await perform(.previous) }

    /// Seeks to a fraction of the track.
    func seek(to fraction: Double) async {
        guard let snapshot, snapshot.duration > 0 else { return }
        await perform(.seek(min(max(fraction, 0), 1) * snapshot.duration))
    }

    private func perform(_ command: MediaCommand) async {
        guard let player = snapshot?.player else { return }
        await source.perform(command, on: player)
        await refreshNow()
    }

    private func rebuildTimer() {
        timer?.invalidate()
        timer = nil
        guard isEnabled else { return }
        let timer = Timer(timeInterval: pollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.refreshNow() }
        }
        timer.tolerance = 0.5
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    #if DEBUG
    /// The UI tour's track, shown in place of the player's until cleared with nil.
    private var debugSnapshot: MediaSnapshot?
    func debugSetSnapshot(_ snapshot: MediaSnapshot?, artwork: NSImage?) {
        generation += 1
        debugSnapshot = snapshot
        self.snapshot = snapshot
        self.artwork = artwork
        artworkKey = snapshot?.artworkKey
    }
    #endif
}
