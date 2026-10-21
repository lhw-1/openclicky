//
//  AppleScriptMediaSource.swift
//  OpenClicky
//
//  Apple Music and Spotify through their scripting interfaces: one script per player returns the
//  track as one line, commands are one-liners, and a player is only ever asked while it is
//  running (never launched). macOS asks once per player whether OpenClicky may control it.
//

import AppKit
import Foundation

struct AppleScriptMediaSource: MediaSourcing {
    /// Scripts run here, off the main thread: a player can take a moment to answer.
    private static let queue = DispatchQueue(label: "openclicky.media.applescript", qos: .utility)
    /// Players whose script failed once (no permission, no dictionary): logged once, not every poll.
    nonisolated(unsafe) private static var loggedFailures: Set<MediaPlayer> = []

    init() {}

    /// A playing player first; Spotify before Music on a tie; else the first running one.
    static func pick(running: [MediaPlayer], playing: Set<MediaPlayer>) -> MediaPlayer? {
        if playing.contains(.spotify) && running.contains(.spotify) { return .spotify }
        if let first = running.first(where: { playing.contains($0) }) { return first }
        return running.first
    }

    static func runningPlayers() -> [MediaPlayer] {
        MediaPlayer.allCases.filter { !NSRunningApplication.runningApplications(withBundleIdentifier: $0.bundleIdentifier).isEmpty }
    }

    /// The eight fields joined by ASCII 30; "stopped" when nothing is up.
    static func nowPlayingScript(for player: MediaPlayer) -> String {
        switch player {
        case .music:
            return """
            tell application "Music"
                if player state is stopped then return "stopped"
                try
                    set t to current track
                on error
                    return "stopped"
                end try
                set s to (player state as text)
                set p to (player position as text)
                set d to (duration of t as text)
                set k to (persistent ID of t as text)
                set AppleScript's text item delimiters to (ASCII character 30)
                return {s, name of t, artist of t, album of t, p, d, k, ""} as text
            end tell
            """
        case .spotify:
            return """
            tell application "Spotify"
                if player state is stopped then return "stopped"
                try
                    set t to current track
                on error
                    return "stopped"
                end try
                set s to (player state as text)
                set p to (player position as text)
                set d to (((duration of t) / 1000) as text)
                set AppleScript's text item delimiters to (ASCII character 30)
                return {s, name of t, artist of t, album of t, p, d, id of t, artwork url of t} as text
            end tell
            """
        }
    }

    static func commandScript(_ command: MediaCommand, for player: MediaPlayer) -> String {
        let app = player == .music ? "Music" : "Spotify"
        switch command {
        case .playPause: return "tell application \"\(app)\" to playpause"
        case .next: return "tell application \"\(app)\" to next track"
        case .previous: return "tell application \"\(app)\" to previous track"
        case .seek(let seconds): return "tell application \"\(app)\" to set player position to \(Int(seconds.rounded()))"
        }
    }

    // MARK: MediaSourcing

    func readNowPlaying() async -> MediaSnapshot? {
        let running = Self.runningPlayers()
        guard !running.isEmpty else { return nil }
        var snapshots: [MediaPlayer: MediaSnapshot] = [:]
        for player in running {
            if let reply = await Self.run(Self.nowPlayingScript(for: player), player: player)?.stringValue,
               let snapshot = MediaSnapshot.parse(reply, player: player, sampledAt: Date()) {
                snapshots[player] = snapshot
            }
        }
        let playing = Set(snapshots.filter { $0.value.isPlaying }.map(\.key))
        guard let picked = Self.pick(running: running.filter { snapshots[$0] != nil }, playing: playing) else { return nil }
        return snapshots[picked]
    }

    func perform(_ command: MediaCommand, on player: MediaPlayer) async {
        _ = await Self.run(Self.commandScript(command, for: player), player: player)
    }

    /// Music hands the artwork over as bytes; Spotify gives a URL.
    func loadArtwork(for snapshot: MediaSnapshot) async -> NSImage? {
        switch snapshot.player {
        case .music:
            let script = "tell application \"Music\" to return raw data of artwork 1 of current track"
            guard let data = await Self.run(script, player: .music)?.data else { return nil }
            return NSImage(data: data)
        case .spotify:
            guard let url = snapshot.artworkURL, let (data, _) = try? await URLSession.shared.data(from: url) else { return nil }
            return NSImage(data: data)
        }
    }

    /// Runs a script on the utility queue; a failure is logged once per player and yields nil.
    private static func run(_ source: String, player: MediaPlayer) async -> NSAppleEventDescriptor? {
        await withCheckedContinuation { continuation in
            queue.async {
                var errorInfo: NSDictionary?
                let result = NSAppleScript(source: source)?.executeAndReturnError(&errorInfo)
                if result == nil, !loggedFailures.contains(player) {
                    loggedFailures.insert(player)
                    AppLog.append("now playing: \(player.displayName) script failed \(errorInfo?[NSAppleScript.errorMessage] ?? "unknown")")
                }
                continuation.resume(returning: result)
            }
        }
    }
}
