# Now Playing plugin Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The island shows what Apple Music or Spotify is playing, with artwork, live progress and play/pause/previous/next, as a plugin.

**Architecture:** A pure snapshot + parser; a `MediaSourcing` protocol with the AppleScript source behind it; a `@MainActor` store the HUD manager owns, polled only while the plugin is on; a view in `Plugins/Media/`; the context's `isMediaPlaying` makes it the moment's component.

**Tech Stack:** Swift / SwiftUI, `NSAppleScript`, `URLSession`, Swift Testing.

**Spec:** `docs/superpowers/specs/2026-10-21-island-media-plugin-design.md`.

## Global Constraints

- Deployment target macOS 14.2; Swift Testing; no new dependencies. Files under `Plugins/Media/`.
- Never launch Music or Spotify: script a player only when `NSRunningApplication` lists it.
- `NSAppleEventsUsageDescription` in Info.plist: "OpenClicky shows what Music or Spotify is playing on the island and lets you pause or skip."
- Copy lower-case: "nothing playing", "play something in music or spotify".
- Test runner: `t.sh Suite[,Suite]`. Commit messages end with `Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>`.

## Review Focus

1. A paused track: not the moment's component, no peek line, the bar stops moving. Task 1 (`position(at:)` frozen when paused) + Task 4 (`contextualKey`).
2. Spotify and Music both running, one playing: the playing one wins. Task 3 (`AppleScriptMediaSource.pick`).
3. Music running but no track (stopped): `parse` returns nil, the store's snapshot is nil, empty state. Task 1.
4. The player quit mid-track: the next poll finds no running player, snapshot nil, artwork cleared. Task 2.
5. The Automation prompt denied: the script errors, snapshot nil, no crash, no repeated prompt beyond macOS's own. Task 3 (errors swallowed, logged once).

---

### Task 1: Snapshot, parser, clock

**Files:** Create `macos/OpenClicky/OpenClicky/Plugins/Media/MediaSnapshot.swift`; Test `macos/OpenClicky/OpenClickyTests/MediaPluginTests.swift`.

**Interfaces:** `enum MediaPlayer: String { case music, spotify; var bundleIdentifier: String; var displayName: String }`; `struct MediaSnapshot: Equatable { player, isPlaying, title, artist, album, position, duration, artworkKey, artworkURL: URL?, sampledAt; func position(at:) -> TimeInterval; static let fieldSeparator = "\u{1E}"; static func parse(_ line: String, player: MediaPlayer, sampledAt: Date) -> MediaSnapshot? }`; `enum MediaFormatter { static func clock(_:) -> String }`.

- [ ] **Step 1: tests**
```swift
struct MediaPluginTests {
    let now = Date(timeIntervalSince1970: 1_000_000)
    func line(_ fields: [String]) -> String { fields.joined(separator: MediaSnapshot.fieldSeparator) }

    @Test func theScriptsOneLineReplyBecomesASnapshot() throws {
        let reply = line(["playing", "Blue Hero", "The Band", "Album", "83.5", "245", "ABC123", ""])
        let snapshot = try #require(MediaSnapshot.parse(reply, player: .music, sampledAt: now))
        #expect(snapshot.isPlaying && snapshot.title == "Blue Hero" && snapshot.artist == "The Band")
        #expect(snapshot.position == 83.5 && snapshot.duration == 245 && snapshot.artworkKey == "ABC123" && snapshot.artworkURL == nil)
        let spotify = try #require(MediaSnapshot.parse(line(["paused", "T", "A", "", "10", "200", "spotify:track:x", "https://i.scdn.co/image/abc"]), player: .spotify, sampledAt: now))
        #expect(!spotify.isPlaying && spotify.artworkURL == URL(string: "https://i.scdn.co/image/abc"))
        #expect(MediaSnapshot.parse(line(["stopped", "", "", "", "0", "0", "", ""]), player: .music, sampledAt: now) == nil)
        #expect(MediaSnapshot.parse("garbage", player: .music, sampledAt: now) == nil)
    }

    @Test func positionRunsOnWhilePlayingAndFreezesWhenPaused() throws {
        var snapshot = try #require(MediaSnapshot.parse(line(["playing", "T", "A", "", "100", "120", "k", ""]), player: .music, sampledAt: now))
        #expect(snapshot.position(at: now.addingTimeInterval(15)) == 115)
        #expect(snapshot.position(at: now.addingTimeInterval(50)) == 120)   // clamped to the duration
        snapshot.isPlaying = false
        #expect(snapshot.position(at: now.addingTimeInterval(15)) == 100)
    }

    @Test func theClockReadsLikeAPlayer() {
        #expect(MediaFormatter.clock(5) == "0:05")
        #expect(MediaFormatter.clock(83.7) == "1:23")
        #expect(MediaFormatter.clock(3723) == "1:02:03")
    }
}
```
- [ ] **Step 2: run** `MediaPluginTests`. Expected: build FAILS.
- [ ] **Step 3: implement.** - [ ] **Step 4: run.** PASS. - [ ] **Step 5: commit** `Now playing: a snapshot of the track and the script reply it comes from`.

### Task 2: The store

**Files:** Create `Plugins/Media/MediaStore.swift`; Test `MediaPluginTests.swift`.

**Interfaces:** `enum MediaCommand: Equatable { case playPause, next, previous, seek(TimeInterval) }`; `protocol MediaSourcing: Sendable { func readNowPlaying() async -> MediaSnapshot?; func perform(_ command: MediaCommand, on player: MediaPlayer) async; func loadArtwork(for snapshot: MediaSnapshot) async -> NSImage? }`; `@MainActor final class MediaStore: ObservableObject { @Published private(set) var snapshot: MediaSnapshot?; @Published private(set) var artwork: NSImage?; var isPlaying: Bool; var nowPlayingLine: String?; static let watchedInterval = 2.0, backgroundInterval = 5.0; init(source: any MediaSourcing, now:); func setEnabled(_:); func beginWatching(); func endWatching(); var isPolling: Bool; var pollInterval: TimeInterval; func refreshNow() async; func playPause() async; func next() async; func previous() async; func seek(to fraction: Double) async }`.

- [ ] **Step 1: test**
```swift
@MainActor @Test func theStoreFollowsTheSourceFetchesArtworkOncePerTrackAndForwardsCommands() async throws {
    final class Source: MediaSourcing, @unchecked Sendable {
        var reply: MediaSnapshot?; var commands: [MediaCommand] = []; var artworkLoads = 0
        func readNowPlaying() async -> MediaSnapshot? { reply }
        func perform(_ command: MediaCommand, on player: MediaPlayer) async { commands.append(command) }
        func loadArtwork(for snapshot: MediaSnapshot) async -> NSImage? { artworkLoads += 1; return NSImage(size: NSSize(width: 1, height: 1)) }
    }
    let source = Source()
    let store = MediaStore(source: source, now: { self.now })
    store.setEnabled(true)
    #expect(store.isPolling && store.pollInterval == 5)
    store.beginWatching(); #expect(store.pollInterval == 2)
    await store.refreshNow()
    #expect(store.snapshot == nil && store.artwork == nil && store.nowPlayingLine == nil)
    source.reply = try #require(MediaSnapshot.parse(line(["playing", "Blue Hero", "The Band", "", "1", "200", "k1", ""]), player: .spotify, sampledAt: now))
    await store.refreshNow(); await store.refreshNow()
    #expect(store.isPlaying && store.nowPlayingLine == "♪ Blue Hero · The Band" && store.artwork != nil && source.artworkLoads == 1)
    source.reply?.isPlaying = false
    await store.refreshNow()
    #expect(!store.isPlaying && store.nowPlayingLine == nil && source.artworkLoads == 1)
    await store.playPause(); await store.seek(to: 0.5); await store.next()
    #expect(source.commands == [.playPause, .seek(100), .next])
    source.reply = nil
    await store.refreshNow()
    #expect(store.snapshot == nil && store.artwork == nil)
    store.endWatching(); #expect(store.pollInterval == 5)
    store.setEnabled(false); #expect(!store.isPolling && store.snapshot == nil)
}
```
- [ ] **Step 2: run.** FAIL. - [ ] **Step 3: implement** (timer like the other stores; a generation counter so a stale read never overwrites a newer one). - [ ] **Step 4: run.** PASS. - [ ] **Step 5: commit** `Now playing: a store that polls the player only while the plugin is on`.

### Task 3: The AppleScript source

**Files:** Create `Plugins/Media/AppleScriptMediaSource.swift`; Modify `OpenClicky/Info.plist` (usage description); Test `MediaPluginTests.swift`.

**Interfaces:** `struct AppleScriptMediaSource: MediaSourcing { static func pick(running: [MediaPlayer], playing: Set<MediaPlayer>) -> MediaPlayer? (a playing one first, Spotify before Music on a tie, else the first running); static func nowPlayingScript(for player: MediaPlayer) -> String; static func commandScript(_ command: MediaCommand, for player: MediaPlayer) -> String; static func runningPlayers() -> [MediaPlayer] }`.

- [ ] **Step 1: tests**
```swift
@Test func thePlayingPlayerWinsAndSpotifyBreaksATie() {
    #expect(AppleScriptMediaSource.pick(running: [.music, .spotify], playing: [.music]) == .music)
    #expect(AppleScriptMediaSource.pick(running: [.music, .spotify], playing: [.music, .spotify]) == .spotify)
    #expect(AppleScriptMediaSource.pick(running: [.music], playing: []) == .music)
    #expect(AppleScriptMediaSource.pick(running: [], playing: []) == nil)
}
@Test func theScriptsAskEachPlayerInItsOwnWords() {
    #expect(AppleScriptMediaSource.nowPlayingScript(for: .spotify).contains("tell application \"Spotify\""))
    #expect(AppleScriptMediaSource.nowPlayingScript(for: .spotify).contains("/ 1000"))       // milliseconds → seconds
    #expect(AppleScriptMediaSource.nowPlayingScript(for: .music).contains("persistent ID"))
    #expect(AppleScriptMediaSource.commandScript(.seek(42), for: .music) == "tell application \"Music\" to set player position to 42")
    #expect(AppleScriptMediaSource.commandScript(.next, for: .spotify) == "tell application \"Spotify\" to next track")
}
```
- [ ] **Step 2: run.** FAIL. - [ ] **Step 3: implement.** The now-playing script returns the eight fields joined by `ASCII character 30`; it runs on a utility queue via `NSAppleScript`, errors are logged once per player and yield nil. `readNowPlaying` runs the script for each running player (to learn who is playing), then returns the picked one's snapshot. Music artwork: a second script `data of artwork 1 of current track` → `NSAppleEventDescriptor.data` → `NSImage(data:)`; Spotify: `URLSession` GET of `artworkURL`. - [ ] **Step 4: run.** PASS. - [ ] **Step 5: commit** `Now playing: Music and Spotify through their scripting interfaces`.

### Task 4: The plugin, the view, the moment and the peek line

**Files:** Create `Plugins/Media/MediaIslandView.swift`; Modify `Plugins/IslandPlugins.swift` (`mediaID`, registry), `IslandComponents.swift` (`IslandContext.isMediaPlaying`, `contextualKey`), `NotchHUD.swift` (manager owns `media: MediaStore`; `syncOptionalComponents`; the context carries `isMediaPlaying`; `NotchPeekLine` gets the media line), `NotchHUDPanels.swift`, `UITour.swift` (`04f-panel-media` with a debug snapshot), `AGENTS.md`; Test `IslandComponentSelectorTests.swift`, `MediaPluginTests.swift`.

- [ ] **Step 1: tests**
```swift
// IslandComponentSelectorTests
@Test func playingMusicIsTheMomentAfterTheAgent() {
    var context = IslandContext.idle
    context.isMediaPlaying = true
    #expect(context.contextualKey == "media")
    context.agentActivityText = "working"
    #expect(context.contextualKey == "agent")
}
// registry test: ids [..., "agents", "media"], heights [..., 76, 84], plugins [..., true, true]
// MediaPluginTests
@Test func thePeekLineNamesTheTrackAfterALiveSession() {
    #expect(NotchPeekLine.peekText(status: "s", agentLine: nil, mediaLine: "♪ T · A") == "♪ T · A")
    #expect(NotchPeekLine.peekText(status: "s", agentLine: "claude · thinking", mediaLine: "♪ T · A") == "claude · thinking")
    #expect(NotchPeekLine.peekText(status: "s", agentLine: nil, mediaLine: nil) == "s")
}
```
- [ ] **Step 2: run.** FAIL. - [ ] **Step 3: implement** the view per the spec; `MediaStore.debugSetSnapshot(_:artwork:)` (Debug) for the tour. - [ ] **Step 4: run** the suites, build Debug, tour shot `04f-panel-media`. - [ ] **Step 5: commit** `Island: a Now playing plugin with artwork, progress and controls`.
