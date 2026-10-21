# Now Playing plugin

Date: 2026-10-21. Scope: a fourth island plugin under `macos/OpenClicky/OpenClicky/Plugins/Media/`.
Builds on the plugins design (`2026-10-21-island-components-design.md`).

## Intent

While music plays in Apple Music or Spotify, the island shows the artwork, the title and artist, how
far along the track is, and play/pause, previous and next. Off until the user turns it on in
Settings → General → Plugins, like every plugin.

## Goals

1. **Reads the player through its scripting interface.** Apple Music (`com.apple.Music`) and
   Spotify (`com.spotify.client`), through AppleScript, only when that app is running (never
   launches it). macOS asks once per app whether OpenClicky may control it; the app declares why
   (`NSAppleEventsUsageDescription`: "OpenClicky shows what Music or Spotify is playing on the
   island and lets you pause or skip.").
2. **The moment's component while something plays.** With the plugin on and a track playing, the
   slot shows it (after the transcript and the agent in the contextual chain); paused or stopped,
   the user's default comes back. The peek line shows "♪ title · artist" while playing, after a
   live coding session.
3. **Live progress.** The bar moves every second between polls (position interpolated from the
   last poll while playing); a click on the bar seeks there.
4. **Controls that work from a non-key panel.** Previous, play/pause, next as 24 pt band-control
   buttons; the pill shows pause while playing.
5. **Cheap when idle.** Polled every 2 s while the row is on screen, every 5 s while the plugin is
   merely on (so the contextual switch and the peek line follow), never while off. Artwork fetched
   once per track.

## Non-goals

- No browsers, no other players (the system's now-playing feed is a private interface; a later
  plugin may add it). No volume, shuffle, repeat, queue, lyrics.
- No launching of Music or Spotify; "nothing playing" is the whole empty state.

## Design

`MediaPlayer`: `.music` / `.spotify` with `bundleIdentifier` and `displayName` ("music", "spotify").

`MediaSnapshot` (Equatable): `player`, `isPlaying`, `title`, `artist`, `album`, `position`
(seconds, at `sampledAt`), `duration` (seconds), `artworkKey` (the track's persistent id or Spotify
id, so artwork is fetched once per track), `artworkURL` (Spotify) ; `sampledAt: Date`;
`func position(at now: Date) -> TimeInterval` (position + elapsed since the sample while playing,
clamped to the duration); `static func parse(_ line: String, player:, sampledAt:) -> MediaSnapshot?`
for the script's one-line reply: fields joined by ASCII 30 in the order
`state, title, artist, album, position, duration, key, artworkURL` (`state` is `playing` or
`paused`; `stopped` or an empty title → nil; Spotify's millisecond duration is divided by 1000 by
the script, so both players report seconds).

`MediaFormatter.clock(_ seconds: TimeInterval) -> String` ("0:05", "1:23", "1:02:03").

`protocol MediaSourcing: Sendable { func readNowPlaying() async -> MediaSnapshot?; func perform(_ command: MediaCommand, on player: MediaPlayer) async; func loadArtwork(for snapshot: MediaSnapshot) async -> NSImage? }`
with `enum MediaCommand { case playPause, next, previous, seek(TimeInterval) }`.

`AppleScriptMediaSource`: for each running player (Spotify first if both run and it is playing,
else Music), runs the player's script with `NSAppleScript` off the main thread and parses the reply.
Music artwork: `data of artwork 1 of current track` (raw image data from the script's descriptor);
Spotify artwork: `artwork url of current track` fetched with `URLSession`. Commands: `playpause`,
`next track`, `previous track`, `set player position to N`.

`MediaStore` (`@MainActor ObservableObject`): `@Published snapshot: MediaSnapshot?`, `@Published
artwork: NSImage?`, `isPlaying`, `nowPlayingLine` ("♪ title · artist" while playing, else nil),
`setEnabled`, `beginWatching` / `endWatching` (ref-counted; 2 s watched, 5 s background),
`refreshNow()`, `playPause()`, `next()`, `previous()`, `seek(to:)` (each performs the command and
refreshes). Artwork is reloaded when `artworkKey` changes and cleared when the snapshot goes nil.

The plugin: id `media`, title "Now playing", symbol `music.note`, height 84, `isPlugin`, available
whenever on. `IslandContext.isMediaPlaying` makes `media` the contextual key after the agent.

The view (`MediaIslandView`): artwork 56 × 56 (radius 8; a `music.note` tile on band-control grey
when there is none) · a column with the title (13 pt white, one line, tail-truncated), the artist
(11 pt text2), then a 3 pt bar (track white 0.12, fill white; amber never) with "1:23" left and
"4:05" right in 9 pt text3, the bar wrapped in a `TimelineView(.periodic(1 s))` while playing;
a click on the bar seeks to that fraction · the three buttons in a 6 pt row at the trailing edge.
Empty state: "nothing playing" + "play something in music or spotify" in text3.

## What's left to the builder

- The exact AppleScript text per player and how the Music artwork descriptor is read.
- Whether to show the player's name under the artist (fine either way).
