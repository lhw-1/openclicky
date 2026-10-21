# Island components: the switchboard, system stats, the shelf and coding agents

Date: 2026-10-21. Scope: the macOS app's notch island (`IslandComponents.swift`,
`IslandComponentViews.swift`, `NotchHUD.swift`, `NotchHUDPanels.swift`, Settings → General).
Builds on the island glass refresh (`2026-10-20-island-glass-refresh-design.md`): the slot, the
selector, the capsule and the component protocol exist. Three PR-sized plans, one per component,
each shippable alone; the switchboard ships with the first.

## Intent

The island's slot can hold more than the shortcuts, the transcript and the agent line, and the user
should pick what it holds. Three new components, each off until the user turns it on:

- **System**: a glance at the Mac's CPU, memory, disk and battery.
- **Shelf**: drag files, text and links onto the island to park them; drag them out, or click to
  copy, later.
- **Coding agents**: what the Claude Code and Codex sessions running on this Mac are doing right
  now, and how much of the plan's limit is used.

And a **switchboard** in Settings: a toggle per optional component, next to the default and order
rows that already exist.

## Goals

1. **Opt in.** The three new components are off by default. Settings → General gets an "Island
   components" row with a toggle per optional component. A component that is off is never
   available: not in the capsule, not as the default, not pulled in by context, not a drop target.
2. **System** shows live numbers in the island's tile language: a ring per figure, a label under
   it, sampled only while the component is on screen.
3. **Shelf** keeps what you drop on the island. A drag over the island unfolds it to the shelf;
   dropping adds the items; a tile dragged out goes wherever it is dropped and leaves the shelf; a
   click on a tile copies it. The shelf survives a relaunch.
4. **Coding agents** follows the sessions' own on-disk logs, no network and no telemetry for the
   session part, and reads Claude's plan limits with the sign-in Claude Code already has. It is
   never the moment's component (a developer's sessions are live most of the day and must not take
   the island from the chosen default); it is available whenever it is enabled, and while a session
   is live the peek line names it.
5. **Nothing moves for a user who leaves the toggles off.** The existing three components, the
   selector and the Settings rows behave exactly as before.

## Non-goals

- No shelf sync between Macs, no cloud, no sharing sheet. "Shared" here means shared between the
  apps on this Mac through drag and drop and the pasteboard.
- No file previews beyond the Finder icon (and the image itself for an image); no rename, no
  reorder, no folders inside the shelf.
- No Cursor, OpenCode or other agents in this round; no Codex plan limits (its CLI does not expose
  them in a documented way). The watcher protocol leaves room for both.
- No per-app volume, network throughput, GPU or temperature in System.
- No notifications or alerts when a limit is reached.

## Constraints

- Deployment target macOS 14.2; Swift Testing; no new dependencies; no new permission grants
  beyond two prompts the user's own act brings on: the one-time Keychain prompt under Coding agents,
  and macOS's Desktop / Documents / Downloads folder prompt the first time a file from one of them
  is dropped on the shelf (the shelf reads the file only at drop and at drag-out, never at launch).
- Copy is lower-case, short, in OpenClicky's voice ("drop to keep", "copied", "nothing running").
  Symbols are SF Symbols; no third-party marks or logos are drawn.
- The island's files, specs and commit messages describe these as OpenClicky's own features.

---

## 1. The switchboard

`IslandComponent` gains `var isOptional: Bool { get }` (default `false` via a protocol extension).
The three existing components are not optional. The new ones are.

`IslandComponentSettings` gains `enabledIDs: [String]` under the key
`openclicky.island.enabledComponents`; when the key is unset the value is `[]` (every optional
component off). `isEnabled(_ id: String, in registry:)` is true for a non-optional component, or an
optional one whose id is in `enabledIDs`.

`IslandComponentSelector.select(registry:order:defaultID:override:context:enabled:)` takes the
enabled set and drops disabled components before anything else, so `available`, the default and
the contextual pick all ignore them. A stored default that is disabled falls back to `shortcuts`.

`IslandContext.contextualKey`'s chain becomes: `shelf` while a drag hovers the island (a drag is
an explicit act and outranks everything), then the take, the landed take, the agent, nil. The
shelf key is only answered when the shelf is enabled (`isDragHovering` is never set otherwise).
Coding agents never enter the chain.

Settings → General, between "Default component" and "Component order": row `general.islandComponents`,
title "Island components", detail "The extras the island can show. Each one is off until you turn
it on.", one `Toggle` per optional component (title from the registry), writing `enabledIDs`.
The default picker lists only enabled components; the order row lists all, disabled ones dimmed.
The model refreshes on `UserDefaults.didChangeNotification` as it already does.

Each new component's view reads its data from a store the HUD manager owns (one per app, not per
display), so two displays never run two samplers.

## 2. System

Component id `system`, title "System", symbol `gauge.with.dots.needle.33percent`, height 70,
always available when enabled.

`SystemStatsSnapshot` (Equatable): `cpu: Double` (0…1), `memoryUsed`, `memoryTotal`, `diskFree`,
`diskTotal` (bytes, Int64), `battery: Battery?` with `level: Double` (0…1), `isCharging: Bool`,
`isPluggedIn: Bool`. `SystemStatsSampler` (a protocol, `func sample() -> SystemStatsSnapshot`)
with the live `MachSystemStatsSampler`: CPU from `host_processor_info` tick deltas between two
samples (the first sample reports 0), memory from `host_statistics64` (active + wired + compressed
over `hw.memsize`), disk from `/`'s `volumeAvailableCapacityForImportantUsage` and
`volumeTotalCapacity`, battery from `IOPSCopyPowerSourcesInfo` (nil when there is no internal
battery).

`SystemStatsStore` (`@MainActor ObservableObject`): `@Published snapshot`, `start()` samples now
and every 2 s on a Timer, `stop()` ends it; the view calls them from `onAppear` / `onDisappear`.
Tests inject a fake sampler.

`SystemStatsFormatter`: `percent(0.234) == "23%"`, `gigabytes(17179869184) == "16 GB"` (whole
gigabytes below 100, no decimals), `memory(used:total:) == "7 / 16 GB"`, `disk(free:) == "210 GB free"`,
`battery(level: 0.86, isCharging: true) == "86% ⚡"`. Ring colour: white at or under 85 %, amber
(`DS.warning`) above; the battery ring is amber at or under 20 % instead.

The view: an `HStack` of tiles, 56 pt wide each, a 28 pt ring (3 pt stroke, track white 0.12)
with the percentage inside at 9 pt, and a 10 pt caption under it ("cpu", "memory", "disk",
"battery"). Hovering a tile shows the long figure in its caption ("7 / 16 GB", "210 GB free").
Three tiles on a Mac without a battery. Content centred in the slot.

## 3. Shelf

Component id `shelf`, title "Shelf", symbol `tray`, height 84, always available when enabled;
the moment's component while a drag hovers the island (`IslandContext.isDragHovering`).

### Items and storage

`ShelfItem` (Codable, Identifiable, Equatable): `id: UUID`, `kind` (`.file(path: String)`,
`.text(String)`, `.link(URL)`, `.image(path: String)`), `title: String`, `addedAt: Date`.
Titles: a file's last path component; a link's host (or the whole string if none); text's first
line trimmed to 40 characters; an image "image <HH:mm>".

`ShelfStore` (`@MainActor ObservableObject`): `@Published private(set) var items: [ShelfItem]`,
newest first, at most 40 (the oldest fall off). `add(_ items:)`, `remove(id:)`, `removeAll()`.
Persists to `~/Library/Application Support/OpenClicky/Shelf/index.json`; images dropped as data
are written to `Shelf/<uuid>.png` and referenced by path; files are referenced by their own path
(never copied or moved: dragging out moves or copies as Finder decides, the shelf only hands the
URL over). At drop time the file's Finder icon is rendered once to `Shelf/<uuid>-icon.png` (64 pt)
so the tile never touches the file again until it is dragged out; nothing is stat-ed at launch (a
launch-time check of a Desktop file would raise macOS's folder prompt). A drag-out of a file that
no longer exists removes the tile instead of starting a session.

`ShelfDropReader.items(from pasteboard: NSPasteboard) -> [ShelfItem]`: file URLs first
(`NSPasteboard.ReadingOptions` for `.fileURL`), else a web URL (`.URL`) as a link, else an image
(`NSImage` data → png on disk) as an image, else a string as text. An http(s) string on the
pasteboard becomes a link. Nothing readable → empty, and the drop is refused.

### The island as a drop target

The island window registers for `fileURL`, `URL`, `string`, `tiff`, `png`. A `DropDelegate` on
the island view calls `model.setDragHovering(true)` on entered and `false` on exited or after
`performDrop`. The model's `reconcile` treats drag-hover like a pinned panel (`.full`) when the
shelf is enabled and no card or composer is up; `IslandContext.contextualKey` returns `shelf` while
dragging so the slot shows it. After a drop the island stays open 1.5 s (a `collapseTask` as
today's grace) and then returns to its resting state unless the pointer is on it. If the shelf is
disabled the delegate validates nothing and the island does not react.

While a drag hovers, the shelf view shows a dashed outline tile at the leading edge with
"drop to keep" (text3); after a drop the new tiles appear with the panel's opacity transition.

### The shelf view

A horizontally scrolling row of tiles, each 76 × 70: a 40 pt icon (the Finder icon via
`NSWorkspace.shared.icon(forFile:)`, the image itself, `link` for a link, `text.alignleft` for
text; a file's icon from its saved `-icon.png`) over an 11 pt title in text2, one line,
middle-truncated. Hovering shows a 16 pt "×" in the
tile's top-trailing corner that removes it. Empty shelf: "drop files, text or links on the island
to keep them handy" centred in text3.

Each tile is an AppKit drag source (`ShelfTileDragView`, an `NSViewRepresentable`): a mouse-down
followed by 4 pt of movement begins an `NSDraggingSession` with the item's pasteboard writer (the
file URL, the string, the URL, or the image's file URL) and a snapshot of the tile as the drag
image; `draggingSession(_:endedAt:operation:)` with any operation other than `[]` removes the item
from the store. A mouse-up without movement copies the item to the general pasteboard and the tile
shows "copied" in place of its title for 1.2 s. The model exposes `setDragOut(true/false)` around
the session so the island does not collapse while the pointer is away; the session's source
operation mask is `.copy` plus `.move` for files (the destination decides, like Finder).

The capsule's tray icon shows nothing extra; the count is visible in the row.

## 4. Coding agents

Component id `agents`, title "Coding agents", symbol `terminal`, height 76, available whenever it
is enabled (an empty state when nothing runs); never the moment's component.

### Sessions

`AgentSession` (Equatable, Identifiable): `id` (the log path), `agent: AgentKind` (`.claudeCode`,
`.codex`), `project: String` (the `cwd`'s last path component), `title: String?` (Claude's
`ai-title` record, Codex's first user message trimmed to 60 characters), `activity: AgentActivity`,
`lastEventAt: Date`.

`AgentActivity`: `.tool(name: String, detail: String?)` (a `tool_use` / `function_call`: detail is
`file_path`'s last component, or the first 40 characters of `command`, or nil), `.thinking`,
`.writing(String)` (the assistant's latest text line, 60 characters), `.waiting` (the last record
is a user prompt or tool result, so the model is working on it), `.idle`.

A session is **live** when its log file was modified within the last 120 s and its activity is
not `.idle`; it is otherwise shown as recent for 10 min, then dropped. Idle for Claude Code: the
last `assistant` record's `message.stop_reason` is `end_turn` (the answer is finished) and no
`user` record follows it; a `user` record after it means `.waiting`. Idle for Codex: the last
record is `event_msg/task_complete`.

OpenClicky's own plan answers are not sessions: Codex rollouts whose `cwd` is under the
`openclicky-plan-answers` folder of the temporary directory (`PlanCLIs.makeScratchWorkingDirectory`)
are skipped (its Claude answers keep no log).

`AgentSessionParser`: pure, per agent. `parseClaudeTail(_ text: String) -> (activity, title?, cwd?)`
reads the last 64 KB of a `~/.claude/projects/*/*.jsonl` (or `$CLAUDE_CONFIG_DIR`), line by line,
and takes the activity from the last `assistant` record: `.idle` when its `stop_reason` is
`end_turn`, else its last content block (`tool_use` → tool, `thinking` → thinking, `text` →
writing); `.waiting` if a `user` record comes after it. Records of other types (`attachment`,
`api-request`, `last-prompt`, …) are ignored;
`cwd` from any record, title from the last `ai-title`. `parseCodexTail` reads
`~/.codex/sessions/**/rollout-*.jsonl`: `session_meta.cwd`, the last `response_item` of type
`function_call` (`name`, `arguments` JSON's `command`/`path`) or `message` with role `assistant`
(writing) or `reasoning` (thinking); `event_msg/task_complete` as the last record means idle.
Malformed lines are skipped.

`AgentSessionWatcher` (`@MainActor ObservableObject`): `@Published sessions: [AgentSession]`
(live first, then by `lastEventAt`), `liveCount`. It polls (a Timer) every 3 s while the component
is on screen and every 20 s otherwise once the component is enabled, listing the two trees with
`FileManager` and reading only files modified within 10 min, at most 64 KB from the tail of each.
`start()` / `stop()` follow the toggle; the HUD manager owns one watcher.

### Plan limits

`ClaudeUsageClient`: reads the `Claude Code-credentials` generic password (service
`Claude Code-credentials`, account the login name) via `SecItemCopyMatching`; its data is JSON with
`claudeAiOauth.accessToken`. `GET https://api.anthropic.com/api/oauth/usage` with
`Authorization: Bearer <token>` and `anthropic-beta: oauth-2025-04-20`. The reply's `five_hour`
and `seven_day` objects each give `utilization` (0…100) and `resets_at` (ISO 8601); `UsageWindow`
(`fraction: Double`, `resetsAt: Date?`) × 2 in `ClaudeUsage`. Fetched when the component appears
and every 5 min while it stays, never otherwise. The Keychain is read at most once per 30 min
(each read may prompt when the user chose "Allow" rather than "Always Allow"). States under the
rings: no item or a 401 (the token expired; Claude Code refreshes it when it next runs) → "sign in
to claude to see limits"; the Keychain read refused (`errSecAuthFailed`,
`errSecInteractionNotAllowed`, `errSecUserCanceled`) → "allow keychain access to see limits" and
no further reads until the toggle is turned off and on or the app relaunches; a network failure
keeps the last figures and dims them. macOS asks
once whether OpenClicky may read that Keychain item; the Settings detail for the toggle says so:
"Follows Claude Code and Codex sessions on this Mac from their own logs. macOS asks once to let
OpenClicky read Claude Code's sign-in for the plan limits."

### The view

Left: up to three session rows (18 pt each): the agent's name in 11 pt semibold text ("claude" /
"codex"), the project in text2, then the activity line in text ("editing Foo.swift",
"running: git status", "thinking", "writing", "waiting") and, for a live session, a 2 pt
`IslandIndeterminateBar` under the row; a recent one shows "done <m> min ago" in text3. More than
three: "+<n> more" in text3. None: "nothing running" with "start claude or codex in a terminal
and it shows up here" in text3.

Right: two 28 pt rings, "5 h" and "7 d", the fraction inside; amber above 80 %, red
(`DS.HUD.pointer`) at 100 %; under each, the reset in short form ("resets 2 h 10 m"). Rings only
when the usage client has figures or an error line to show.

The peek line, when the agents component is enabled and a session is live, shows
"claude · editing Foo.swift" (the newest live session: agent · activity) in place of the pointer
status; the user opted in. The compact busy strip is untouched.

## What's left to the builder

- Exact ring geometry and the tile hover affordances (within the sizes above).
- The IOKit and Mach calls' Swift spelling and the sampler's unit tests' fake values.
- How the drag image is snapshotted (`NSView.dataWithPDF` / `bitmapImageRepForCachingDisplay`).
- Which `Timer` tolerance to use (anything up to 0.5 s is fine).
