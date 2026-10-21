//
//  MediaSnapshot.swift
//  OpenClicky
//
//  The Now playing plugin's picture of the track: which player, playing or paused, the title and
//  artist, where in the track it was at the last poll (and where it is now), and the key the
//  artwork is fetched by. Built from the one-line reply the player's script returns.
//

import Foundation

enum MediaPlayer: String, CaseIterable, Sendable {
    case music
    case spotify

    var bundleIdentifier: String {
        switch self {
        case .music: return "com.apple.Music"
        case .spotify: return "com.spotify.client"
        }
    }

    var displayName: String { rawValue }
}

struct MediaSnapshot: Equatable, Sendable {
    var player: MediaPlayer
    var isPlaying: Bool
    var title: String
    var artist: String
    var album: String
    /// Seconds into the track at `sampledAt`.
    var position: TimeInterval
    var duration: TimeInterval
    /// The track's persistent id (Music) or URI (Spotify): the artwork is fetched once per key.
    var artworkKey: String
    /// Spotify's artwork; Music hands its artwork over as data instead.
    var artworkURL: URL?
    var sampledAt: Date

    /// Where the track is now: the last position plus the time since, while playing; frozen while
    /// paused; never past the end.
    func position(at now: Date) -> TimeInterval {
        guard isPlaying else { return position }
        return min(max(position + now.timeIntervalSince(sampledAt), 0), duration)
    }

    /// ASCII 30 between the script's fields.
    static let fieldSeparator = "\u{1E}"

    /// `state, title, artist, album, position, duration, key, artworkURL`; `stopped` or an empty
    /// title is no track at all.
    static func parse(_ line: String, player: MediaPlayer, sampledAt: Date) -> MediaSnapshot? {
        let fields = line.components(separatedBy: fieldSeparator)
        guard fields.count >= 8 else { return nil }
        let state = fields[0].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let title = fields[1].trimmingCharacters(in: .whitespacesAndNewlines)
        guard state == "playing" || state == "paused", !title.isEmpty else { return nil }
        let position = Double(fields[4].trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")) ?? 0
        let duration = Double(fields[5].trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")) ?? 0
        let artworkURL = fields[7].isEmpty ? nil : URL(string: fields[7])
        return MediaSnapshot(
            player: player, isPlaying: state == "playing", title: title, artist: fields[2], album: fields[3],
            position: max(0, position), duration: max(0, duration), artworkKey: fields[6], artworkURL: artworkURL, sampledAt: sampledAt
        )
    }
}

enum MediaFormatter {
    /// "0:05", "1:23", "1:02:03".
    static func clock(_ seconds: TimeInterval) -> String {
        let total = Int(max(0, seconds).rounded(.down))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        if hours > 0 { return String(format: "%d:%02d:%02d", hours, minutes, secs) }
        return String(format: "%d:%02d", minutes, secs)
    }
}
