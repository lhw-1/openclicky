# Island switchboard and System component Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Optional island components the user turns on in Settings, and the first one: a System glance (CPU, memory, disk, battery).

**Architecture:** `IslandComponent` gains `isOptional`; `IslandComponentSettings` gains the enabled list; the selector drops disabled components first. A pure sampler protocol behind a `@MainActor` store the HUD manager owns feeds a tile row view. Settings → General gets a toggle row.

**Tech Stack:** Swift 6 / SwiftUI / AppKit, Mach host statistics, IOKit power sources, Swift Testing.

**Spec:** `docs/superpowers/specs/2026-10-21-island-components-design.md` (sections "The switchboard" and "System").

## Global Constraints

- Deployment target macOS 14.2; Swift Testing (`import Testing`, `#expect`, `@Test`); no new dependencies.
- Copy lower-case and short; SF Symbols only.
- Optional components are off by default: `enabledIDs` unset → `[]`.
- Test command (one suite): `cd macos/OpenClicky && xcodebuild test -project OpenClicky.xcodeproj -scheme OpenClicky -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO -only-testing:OpenClickyTests/<Suite> 2>&1 | tail -6`
- Swift Testing quirk: compare against a single literal (`== 57`), never a literal sum.
- Files under `macos/OpenClicky/OpenClicky/` are auto-included (synchronized group); no project edits.
- Commit messages describe OpenClicky's own features; end with `Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>`.

## Review Focus

1. A stored default id that is now disabled (the user turned System off after making it the default): the island must show `shortcuts`, never an empty slot. Pinned in Task 1's selector test.
2. The capsule override pointing at a component the user then disables: `select` must drop it silently. Task 1.
3. Two displays: one sampler, started by the first visible view and stopped by the last. Task 4 counts start/stop.
4. A Mac without a battery: three tiles, no crash on a nil battery. Task 3 formatter / Task 6 view take an optional.
5. The first CPU sample has no delta and must report 0, not NaN. Task 5.

---

### Task 1: The switchboard in the registry, the settings and the selector

**Files:**
- Modify: `macos/OpenClicky/OpenClicky/IslandComponents.swift`
- Test: `macos/OpenClicky/OpenClickyTests/IslandComponentSelectorTests.swift`

**Interfaces:**
- Produces: `protocol IslandComponent { var isOptional: Bool { get } }` with a protocol extension defaulting to `false`; `IslandComponentSettings.enabledIDs: [String]` (key `openclicky.island.enabledComponents`, unset → `[]`); `IslandComponentSettings.isEnabled(_ id: String, in registry: [any IslandComponent]) -> Bool`; `static func enabledIDs(in registry:settings:) -> Set<String>`; `IslandComponentSelector.select(registry:order:defaultID:override:context:enabled: Set<String>)` (the old signature stays as a convenience that passes every id, so existing tests compile unchanged).

- [ ] **Step 1: Write the failing tests** in `IslandComponentSelectorTests`:

```swift
@Test func aDisabledComponentIsNeverAvailableAndADisabledDefaultFallsBackToShortcuts() {
    let system = Stub(id: "system") { _ in true }
    let registry: [any IslandComponent] = [shortcuts, transcript, agent, system]
    let off = IslandComponentSelector.select(registry: registry, order: [], defaultID: "system", override: "system", context: .idle, enabled: ["shortcuts", "transcript", "agent"])
    #expect(off == IslandComponentSelection(active: "shortcuts", available: ["shortcuts"]))
    let on = IslandComponentSelector.select(registry: registry, order: [], defaultID: "system", override: nil, context: .idle, enabled: ["shortcuts", "transcript", "agent", "system"])
    #expect(on == IslandComponentSelection(active: "system", available: ["shortcuts", "system"]))
}

@Test func optionalComponentsAreOffUntilTurnedOn() {
    let defaults = UserDefaults(suiteName: "island-switchboard-tests")!
    defaults.removePersistentDomain(forName: "island-switchboard-tests")
    var settings = IslandComponentSettings(defaults: defaults)
    struct Optional: IslandComponent { let id = "system"; let title = "System"; let symbolName = "gauge"; let preferredHeight: CGFloat = 70; let isOptional = true; func isAvailable(in context: IslandContext) -> Bool { true }; @MainActor func makeView(companionManager: CompanionManager, model: NotchHUDModel) -> AnyView { AnyView(EmptyView()) } }
    let registry: [any IslandComponent] = [Stub(id: "shortcuts") { _ in true }, Optional()]
    #expect(settings.enabledIDs == [])
    #expect(settings.isEnabled("shortcuts", in: registry))
    #expect(!settings.isEnabled("system", in: registry))
    settings.enabledIDs = ["system"]
    #expect(settings.isEnabled("system", in: registry))
    #expect(IslandComponentSettings.enabledIDs(in: registry, settings: settings) == ["shortcuts", "system"])
}
```

- [ ] **Step 2: Run** `-only-testing:OpenClickyTests/IslandComponentSelectorTests`. Expected: build FAILS (`extra argument 'enabled'`, no member `enabledIDs`).

- [ ] **Step 3: Implement** in `IslandComponents.swift`: the `isOptional` requirement + extension default; `enabledKey`, `enabledIDs` get/set, `isEnabled(_:in:)` (non-optional → true; optional → `enabledIDs.contains`), the static `enabledIDs(in:settings:)`; `select(...enabled:)` filters `registry` by `enabled.contains($0.id)` before availability, and `defaultID` falls back to `IslandComponentRegistry.shortcutsID` when not enabled; keep the old `select` signature calling the new one with every registry id.

- [ ] **Step 4: Run** the suite. Expected: PASS, every earlier test still green.

- [ ] **Step 5: Commit** `Island: optional components are off until turned on; the selector ignores disabled ones`.

### Task 2: The model and Settings carry the enabled set

**Files:**
- Modify: `macos/OpenClicky/OpenClicky/NotchHUD.swift` (`recomputeSelection`, init)
- Modify: `macos/OpenClicky/OpenClicky/Dictation/UI/SettingsGeneralPage.swift`
- Test: `macos/OpenClicky/OpenClickyTests/NotchHUDModelTests.swift`

**Interfaces:**
- Consumes: Task 1.
- Produces: `NotchHUDModel.enabledComponentIDs: Set<String>` (computed from `componentSettings` and `registry`); Settings row id `general.islandComponents` (`IslandComponentsRow`).

- [ ] **Step 1: Write the failing test** in `NotchHUDModelTests`:

```swift
@Test func anOptionalComponentJoinsTheSlotOnlyWhenTurnedOn() {
    let defaults = UserDefaults(suiteName: "island-model-switchboard")!
    defaults.removePersistentDomain(forName: "island-model-switchboard")
    let model = NotchHUDModel(geometry: notchModel().geometry, registry: IslandComponentSelectorTests().registry + [IslandComponentSelectorTests.Stub(id: "system", isOptional: true) { _ in true }], componentSettings: IslandComponentSettings(defaults: defaults))
    #expect(model.selection.available == ["shortcuts"])
    var settings = IslandComponentSettings(defaults: defaults)
    settings.enabledIDs = ["system"]
    model.componentSettings = settings
    #expect(model.selection.available == ["shortcuts", "system"])
    #expect(model.showsCapsule)
}
```
(Give `Stub` an `isOptional` stored property defaulting to `false`.)

- [ ] **Step 2: Run** `NotchHUDModelTests`. Expected: FAIL (`available == ["shortcuts", "system"]` before the toggle, or a compile error on `isOptional:`).

- [ ] **Step 3: Implement**: `recomputeSelection` passes `enabled: IslandComponentSettings.enabledIDs(in: registry, settings: componentSettings)`; the init too. In Settings add the row `general.islandComponents` (title "Island components", detail "The extras the island can show. Each one is off until you turn it on.", keywords island/component/extra/system/shelf/agents/toggle) with `IslandComponentsRow`: one `SettingsSwitch` per `IslandComponentRegistry.all.filter(\.isOptional)` bound to `enabledIDs`. `IslandDefaultComponentRow` lists only enabled components; `IslandComponentOrderRow` dims disabled ones (`.opacity(0.5)`).

- [ ] **Step 4: Run** `NotchHUDModelTests` and `IslandComponentSelectorTests`. Expected: PASS.

- [ ] **Step 5: Commit** `Island: Settings lists the optional components with a switch each`.

### Task 3: System stats snapshot and formatter

**Files:**
- Create: `macos/OpenClicky/OpenClicky/SystemStats.swift`
- Test: `macos/OpenClicky/OpenClickyTests/SystemStatsTests.swift`

**Interfaces:**
- Produces: `struct SystemStatsSnapshot: Equatable { var cpu: Double; var memoryUsed: Int64; var memoryTotal: Int64; var diskFree: Int64; var diskTotal: Int64; var battery: Battery?; struct Battery: Equatable { var level: Double; var isCharging: Bool; var isPluggedIn: Bool } ; static let empty }`; `protocol SystemStatsSampling { mutating func sample() -> SystemStatsSnapshot }`; `enum SystemStatsFormatter { static func percent(_:) ; gigabytes(_:) ; memory(used:total:) ; disk(free:) ; battery(level:isCharging:) }`; `enum SystemStatsTone { static func isWarning(cpuOrMemoryOrDisk fraction: Double) -> Bool; static func isWarning(batteryLevel: Double) -> Bool }`.

- [ ] **Step 1: Write the failing tests**:

```swift
@Test func figuresReadLikeAGlance() {
    #expect(SystemStatsFormatter.percent(0.234) == "23%")
    #expect(SystemStatsFormatter.percent(1.2) == "100%")
    #expect(SystemStatsFormatter.gigabytes(17_179_869_184) == "16 GB")
    #expect(SystemStatsFormatter.gigabytes(1_099_511_627_776) == "1024 GB")
    #expect(SystemStatsFormatter.memory(used: 7_516_192_768, total: 17_179_869_184) == "7 / 16 GB")
    #expect(SystemStatsFormatter.disk(free: 225_485_783_040) == "210 GB free")
    #expect(SystemStatsFormatter.battery(level: 0.86, isCharging: true) == "86% ⚡")
    #expect(SystemStatsFormatter.battery(level: 0.17, isCharging: false) == "17%")
}

@Test func ringsTurnAmberAboveEightyFivePercentAndBatteriesUnderTwenty() {
    #expect(!SystemStatsTone.isWarning(fraction: 0.85))
    #expect(SystemStatsTone.isWarning(fraction: 0.851))
    #expect(SystemStatsTone.isWarning(batteryLevel: 0.2))
    #expect(!SystemStatsTone.isWarning(batteryLevel: 0.21))
}
```

- [ ] **Step 2: Run** `SystemStatsTests`. Expected: build FAILS (types missing).
- [ ] **Step 3: Implement** the types in `SystemStats.swift` (gigabytes rounds to the nearest whole GB with 1 GB = 2^30 bytes; percent clamps 0…1 and rounds).
- [ ] **Step 4: Run.** Expected: PASS.
- [ ] **Step 5: Commit** `System stats: the snapshot, how its figures read, and when a ring warns`.

### Task 4: The store samples only while watched

**Files:**
- Modify: `macos/OpenClicky/OpenClicky/SystemStats.swift`
- Test: `macos/OpenClicky/OpenClickyTests/SystemStatsTests.swift`

**Interfaces:**
- Produces: `@MainActor final class SystemStatsStore: ObservableObject { @Published private(set) var snapshot: SystemStatsSnapshot; init(sampler: any SystemStatsSampling, interval: TimeInterval = 2); func beginWatching(); func endWatching(); var isSampling: Bool }` — ref-counted: the first `beginWatching` samples at once and starts the timer; the last `endWatching` stops it.

- [ ] **Step 1: Write the failing test**:

```swift
@MainActor @Test func theStoreSamplesWhileAnyViewWatchesAndStopsWithTheLast() {
    struct Counting: SystemStatsSampling { var count = 0; mutating func sample() -> SystemStatsSnapshot { count += 1; return SystemStatsSnapshot(cpu: Double(count) / 10, memoryUsed: 1, memoryTotal: 2, diskFree: 3, diskTotal: 4, battery: nil) } }
    let store = SystemStatsStore(sampler: Counting(), interval: 60)
    #expect(!store.isSampling)
    store.beginWatching(); store.beginWatching()
    #expect(store.isSampling)
    #expect(store.snapshot.cpu == 0.1)   // sampled at once, exactly once
    store.endWatching()
    #expect(store.isSampling)
    store.endWatching()
    #expect(!store.isSampling)
}
```

- [ ] **Step 2: Run.** Expected: build FAILS (no `SystemStatsStore`).
- [ ] **Step 3: Implement** with a `Timer` (tolerance 0.5 s) and a watcher count.
- [ ] **Step 4: Run.** Expected: PASS.
- [ ] **Step 5: Commit** `System stats: a store that samples only while a tile row is on screen`.

### Task 5: The live sampler

**Files:**
- Create: `macos/OpenClicky/OpenClicky/SystemStatsSampler.swift`
- Test: `macos/OpenClicky/OpenClickyTests/SystemStatsTests.swift`

**Interfaces:**
- Produces: `struct MachSystemStatsSampler: SystemStatsSampling` with `static func cpuFraction(previous: [UInt32]?, current: [UInt32]) -> Double` (four ticks per CPU: user, system, idle, nice; busy = user + system + nice over total delta; `nil` previous → 0; zero delta → 0).

- [ ] **Step 1: Write the failing tests**:

```swift
@Test func cpuFractionComesFromTickDeltasAndTheFirstSampleIsZero() {
    #expect(MachSystemStatsSampler.cpuFraction(previous: nil, current: [10, 10, 80, 0]) == 0)
    #expect(MachSystemStatsSampler.cpuFraction(previous: [10, 10, 80, 0], current: [30, 20, 150, 0]) == 0.3)
    #expect(MachSystemStatsSampler.cpuFraction(previous: [10, 10, 80, 0], current: [10, 10, 80, 0]) == 0)
}

@Test func theLiveSamplerReportsSaneFigures() {
    var sampler = MachSystemStatsSampler()
    let snapshot = sampler.sample()
    #expect((0...1).contains(snapshot.cpu))
    #expect(snapshot.memoryTotal > 0 && snapshot.memoryUsed <= snapshot.memoryTotal)
    #expect(snapshot.diskTotal > 0 && snapshot.diskFree <= snapshot.diskTotal)
}
```

- [ ] **Step 2: Run.** Expected: build FAILS.
- [ ] **Step 3: Implement**: `host_processor_info(PROCESSOR_CPU_LOAD_INFO)` summed over CPUs into four tick totals (deallocate with `vm_deallocate`); `host_statistics64(HOST_VM_INFO64)` with `vm_kernel_page_size` (used = active + wired + compressor pages); `URL(fileURLWithPath: "/").resourceValues([.volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey])`; `IOPSCopyPowerSourcesInfo` / `IOPSCopyPowerSourcesList` / `IOPSGetPowerSourceDescription` (`kIOPSCurrentCapacityKey`, `kIOPSMaxCapacityKey`, `kIOPSIsChargingKey`, `kIOPSPowerSourceStateKey == kIOPSACPowerValue`), `nil` when the list has no internal battery (`kIOPSTypeKey == kIOPSInternalBatteryType`).
- [ ] **Step 4: Run.** Expected: PASS.
- [ ] **Step 5: Commit** `System stats: CPU, memory, disk and battery from Mach and IOKit`.

### Task 6: The System component and its tile row

**Files:**
- Create: `macos/OpenClicky/OpenClicky/SystemIslandView.swift`
- Modify: `macos/OpenClicky/OpenClicky/IslandComponents.swift` (registry), `NotchHUD.swift` (`NotchHUDManager.systemStats`), `UITour.swift` (one shot), `AGENTS.md` rows
- Test: `macos/OpenClicky/OpenClickyTests/IslandComponentSelectorTests.swift`, `SystemStatsTests.swift`

**Interfaces:**
- Consumes: Tasks 1, 3, 4, 5.
- Produces: `struct SystemIslandComponent: IslandComponent` (id `system`, title "System", symbol `gauge.with.dots.needle.33percent`, height 70, `isOptional = true`); `NotchHUDManager.systemStats: SystemStatsStore` (live sampler); `struct SystemIslandView: View` (tiles from a snapshot; `static func tiles(for snapshot:) -> [SystemTile]` with `SystemTile { id, caption, fraction, short, long, isWarning }`).

- [ ] **Step 1: Write the failing tests**:

```swift
// IslandComponentSelectorTests
@Test func theRealRegistryHasTheSystemComponentAsAnOptionalFourth() {
    let ids = IslandComponentRegistry.all.map(\.id)
    #expect(ids == ["shortcuts", "transcript", "agent", "system"])
    #expect(IslandComponentRegistry.all[3].isOptional)
    #expect(IslandComponentRegistry.all[3].preferredHeight == 70)
}
// SystemStatsTests
@Test func tilesFollowTheSnapshotAndSkipTheBatteryWhenThereIsNone() {
    let snapshot = SystemStatsSnapshot(cpu: 0.9, memoryUsed: 7_516_192_768, memoryTotal: 17_179_869_184, diskFree: 225_485_783_040, diskTotal: 1_000_000_000_000, battery: nil)
    let tiles = SystemIslandView.tiles(for: snapshot)
    #expect(tiles.map(\.caption) == ["cpu", "memory", "disk"])
    #expect(tiles[0].isWarning && !tiles[1].isWarning)
    #expect(tiles[1].long == "7 / 16 GB")
    #expect(tiles[2].fraction == 1 - 225_485_783_040.0 / 1_000_000_000_000.0)
    var withBattery = snapshot
    withBattery.battery = .init(level: 0.17, isCharging: false, isPluggedIn: false)
    let four = SystemIslandView.tiles(for: withBattery)
    #expect(four.count == 4 && four[3].isWarning && four[3].short == "17%")
}
```
(Update `theRealRegistryHasTheThreeBuiltInsInOrder` to the four-id list.)

- [ ] **Step 2: Run** both suites. Expected: FAIL.
- [ ] **Step 3: Implement**: the component in the registry (`all` appends `SystemIslandComponent()`); the manager owns `let systemStats = SystemStatsStore(sampler: MachSystemStatsSampler())`; the view (`@ObservedObject store`, `onAppear { store.beginWatching() }`, `onDisappear { store.endWatching() }`, `HStack(spacing: 12)` of 56 pt tiles: 28 pt ring (`Circle().trim`, 3 pt stroke, track `Color.white.opacity(0.12)`, fill white or `DS.warning`), 9 pt figure inside, 10 pt caption in text3 showing `long` while hovered, centred in the slot). The tour's notch pass enables `system` through a `debugSetEnabledComponents([...])` hook, selects it, shoots `04c-panel-system`, restores. AGENTS.md rows for the two new files.
- [ ] **Step 4: Run** the two suites, then build Debug and run the island tour (`OPENCLICKY_TOUR_ONLY=island`), look at `04c-panel-system`. Expected: tests PASS; the shot shows three or four rings under the band.
- [ ] **Step 5: Commit** `Island: a System component with CPU, memory, disk and battery rings`.
