# Island Glass Refresh Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The notch island teases on hover and opens on click, is black melting into glass with notch-shaped corners and a spring unfold, and its body is a slot that components fill by context or by the user's choice.

**Architecture:** `NotchHUDModel` (pure state, `@MainActor`) gains a `peek` expansion, click-to-open rules, and a component slot driven by an `IslandContext` the HUD manager builds from publishers it already observes. Pure style maths (corners, gradient, motion) live in `IslandStyle.swift`; the component protocol, registry, selector and settings live in `IslandComponents.swift`; views (glass background, capsule, the three components) live in `IslandComponentViews.swift`. `NotchHUDView` draws two layers inside `NotchIslandShape`: glass (only when open) and gradient-masked black.

**Tech Stack:** Swift 5, SwiftUI + AppKit, Swift Testing (`import Testing`), Xcode 27, deployment target macOS 14.2.

**Spec:** `docs/superpowers/specs/2026-10-20-island-glass-refresh-design.md`

## Global Constraints

- Deployment target macOS 14.2; Liquid Glass only behind `if #available(macOS 26, *)`; before 26 an `NSVisualEffectView` with `.hudWindow`, `.behindWindow`, `state = .active`.
- The island window stays a non-activating `NSPanel` at `.popUpMenu` level; no new key-window case; the app is never activated by the island.
- No private API, no new packages, no sandbox or library-validation changes.
- Nothing is drawn while idle except the notch itself (no outline, shadow or lip); no material view exists unless the panel is open or a card is up.
- Copy, commit messages, comments and names describe OpenClicky's own features only; nothing names other products or research sources. Commit messages are plain sentences like the repo's (`git log`).
- Tests: `cd macos/OpenClicky && xcodebuild test -project OpenClicky.xcodeproj -scheme OpenClicky -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO -only-testing:OpenClickyTests/<Suite>` (the suite name is the test struct's name).
- Hand checks happen on this Mac (macOS 26): install with `scripts/release.sh --no-notarize`; never drive the user's pointer or keyboard with synthetic input.

## Review Focus

1. A display whose menu bar band is 0 pt (external monitor without a menu bar): peek and compact heights must still have room for a 24 pt line, so they use `topBandHeight` (≥ 34) not `notchHeight`. Test in Task 2.
2. Glass level 0 must draw exactly today's all-black island and create no material view. Test in Task 1 (stops) and Task 5 (view hierarchy).
3. Reduce motion on: no springs, no press scale, plain 0.15 s fades. Test in Task 1 (`IslandMotion.animation(reduceMotion:)`).
4. A stored default component id that is unknown or unavailable right now: the first available component in the user's order is active and nothing crashes. Test in Task 3.
5. The user flipped the capsule while the transcript was contextually active; a new partial transcript arrives: the override must stay. It resets only when the contextual key changes (take ends, agent starts). Test in Task 4.

---

### Task 1: Island style maths (corners, glass stops, motion)

**Files:**
- Create: `macos/OpenClicky/OpenClicky/IslandStyle.swift`
- Modify: `macos/OpenClicky/OpenClicky/DesignSystem.swift:42-65` (add tokens)
- Test: `macos/OpenClicky/OpenClickyTests/IslandStyleTests.swift`

**Interfaces:**
- Produces:
  - `enum IslandCorners { static func bottomRadius(for expansion: NotchHUDExpansion, width: CGFloat) -> CGFloat; static func topFlare(for expansion: NotchHUDExpansion, isSideDrawer: Bool) -> CGFloat }`
  - `struct IslandGlassStops: Equatable { let start: CGFloat; let end: CGFloat }` (fractions of panel height, 0 = top)
  - `enum IslandGlass { static let defaultsKey = "openclicky.island.glassLevel"; static let defaultLevel: Double = 0.6; static func stops(level: Double, bandBottom: CGFloat, panelHeight: CGFloat) -> IslandGlassStops?; static let wash: Double = 0.35 }` (nil when level ≤ 0)
  - `enum IslandMotion { static func unfoldWidth(reduceMotion: Bool) -> Animation; static func unfoldHeight(reduceMotion: Bool) -> Animation; static func peek(reduceMotion: Bool) -> Animation; static let heightDelay: TimeInterval = 0.06; static let pressScale: CGFloat; static func pressScale(reduceMotion: Bool) -> CGFloat; static let pressDuration: TimeInterval = 0.12 }`
  - `DS.HUD.glassTile = Color.white.opacity(0.14)`, `DS.HUD.glassTileHovered = Color.white.opacity(0.22)`, `DS.HUD.capsule = Color.black.opacity(0.6)`, `DS.HUD.capsuleActive = Color.white.opacity(0.18)`, `DS.HUD.shadow = (opacity: 0.35, radius: 14, y: 6)`.
- Consumes: `NotchHUDExpansion` (Task 2 adds `.peek`; add the case in this task so the switch compiles, with no behaviour yet).

- [ ] **Step 1: Write the failing tests**

```swift
import CoreGraphics
import SwiftUI
import Testing
@testable import OpenClicky

struct IslandStyleTests {
    @Test func bottomRadiusFollowsTheState() {
        #expect(IslandCorners.bottomRadius(for: .collapsed, width: 190) == 11)
        #expect(IslandCorners.bottomRadius(for: .peek, width: 218) == 18)
        #expect(IslandCorners.bottomRadius(for: .compact, width: 380) == 18)
        #expect(IslandCorners.bottomRadius(for: .full, width: 512) == 25.6)
        #expect(IslandCorners.bottomRadius(for: .full, width: 360) == 20)   // clamped low
        #expect(IslandCorners.bottomRadius(for: .connect, width: 1000) == 30) // clamped high
    }

    @Test func topFlareFollowsTheStateAndVanishesInADrawer() {
        #expect(IslandCorners.topFlare(for: .collapsed, isSideDrawer: false) == 6)
        #expect(IslandCorners.topFlare(for: .peek, isSideDrawer: false) == 6)
        #expect(IslandCorners.topFlare(for: .compact, isSideDrawer: false) == 10)
        #expect(IslandCorners.topFlare(for: .permission, isSideDrawer: false) == 10)
        #expect(IslandCorners.topFlare(for: .full, isSideDrawer: false) == 12)
        #expect(IslandCorners.topFlare(for: .full, isSideDrawer: true) == 0)
    }

    @Test func glassStopsScaleWithTheLevel() {
        // Band row ends at 40 of a 120 pt panel. Level 1: black ends at the band; level 0.5: halfway
        // between the band and the bottom; the fade spans 40 % of what is left.
        let full = IslandGlass.stops(level: 1, bandBottom: 40, panelHeight: 120)
        #expect(full == IslandGlassStops(start: 40 / 120, end: (40 + 0.4 * 80) / 120))
        let half = IslandGlass.stops(level: 0.5, bandBottom: 40, panelHeight: 120)
        #expect(half == IslandGlassStops(start: 80 / 120, end: (80 + 0.4 * 40) / 120))
        #expect(IslandGlass.stops(level: 0, bandBottom: 40, panelHeight: 120) == nil)
        #expect(IslandGlass.stops(level: -1, bandBottom: 40, panelHeight: 120) == nil)
        #expect(IslandGlass.stops(level: 2, bandBottom: 40, panelHeight: 120) == full) // clamped
    }

    @Test func reduceMotionTurnsSpringsIntoFadesAndDropsThePressScale() {
        #expect(IslandMotion.pressScale(reduceMotion: false) == 0.97)
        #expect(IslandMotion.pressScale(reduceMotion: true) == 1)
        #expect(IslandMotion.unfoldWidth(reduceMotion: true) == .easeInOut(duration: 0.15))
        #expect(IslandMotion.unfoldHeight(reduceMotion: true) == .easeInOut(duration: 0.15))
        #expect(IslandMotion.peek(reduceMotion: true) == .easeInOut(duration: 0.15))
        #expect(IslandMotion.unfoldWidth(reduceMotion: false) != IslandMotion.unfoldWidth(reduceMotion: true))
    }
}
```

- [ ] **Step 2: Run the suite to verify it fails**

Run: the Global Constraints test command with `-only-testing:OpenClickyTests/IslandStyleTests`
Expected: build failure, `IslandCorners` not found.

- [ ] **Step 3: Implement `IslandStyle.swift` and the `DS.HUD` tokens**

Add `case peek` to `NotchHUDExpansion` between `collapsed` and `compact` (every `switch` over it in `NotchHUD.swift` gets a `.peek` arm returning the collapsed value for now). `bottomRadius`: 11 collapsed, 18 peek/compact, else `min(max(width * 0.05, 20), 30)`. `topFlare`: 0 in a drawer, 6 collapsed/peek, 12 full, 10 otherwise. Springs: width `.spring(response: 0.36, dampingFraction: 0.82)`, height `.spring(response: 0.42, dampingFraction: 0.84)`, peek `.spring(response: 0.3, dampingFraction: 0.8)`.

- [ ] **Step 4: Run the suite to verify it passes**

Expected: 4 tests pass.

- [ ] **Step 5: Commit**

```bash
git add macos/OpenClicky/OpenClicky/IslandStyle.swift macos/OpenClicky/OpenClicky/DesignSystem.swift macos/OpenClicky/OpenClicky/NotchHUD.swift macos/OpenClicky/OpenClickyTests/IslandStyleTests.swift
git commit -m "Island: corner, glass and motion maths with a peek state to hang them on"
```

---

### Task 2: Hover teases, click opens (model rules and sizes)

**Files:**
- Modify: `macos/OpenClicky/OpenClicky/NotchHUD.swift:77-90` (expansion), `:97-230` (sizes), `:280-300` and `:367-400` (hover/pin), `:432-479` (`restingExpansion`, `reconcile`)
- Test: `macos/OpenClicky/OpenClickyTests/NotchHUDModelTests.swift` (new)

**Interfaces:**
- Produces on `NotchHUDModel`: `var peekWidth: CGFloat` (= `geometry.notchWidth + 28`, or `collapsedWidth` in a drawer), `var peekHeight: CGFloat` (= `topBandHeight + 24`), `var compactHeight` (= `topBandHeight + 8 + (hasCompactDetailLine ? 26 : 0)`), `@Published private(set) var isPressed: Bool`, `func setPressed(_:)`, `func islandClicked()` (the one entry point for a click on the island body; replaces the inline `onTapGesture` logic), `var peekText: String` ("<pointer status> · click to open" is composed in the view; the model exposes nothing new for it).
- Consumes: Task 1's `.peek` case.

- [ ] **Step 1: Write the failing tests**

```swift
import CoreGraphics
import Testing
@testable import OpenClicky

@MainActor
struct NotchHUDModelTests {
    private func notchModel() -> NotchHUDModel {
        NotchHUDModel(geometry: NotchGeometry(screenFrame: CGRect(x: 0, y: 0, width: 1512, height: 982), hasHardwareNotch: true, notchWidth: 190, notchHeight: 33, visibleFrame: CGRect(x: 0, y: 0, width: 1512, height: 949)))
    }

    @Test func hoveringPeeksAndNeverOpensThePanel() {
        let model = notchModel()
        model.setHovering(true)
        #expect(model.expansion == .peek)
        #expect(model.width == 218)
        #expect(model.height == 33 + 24)
    }

    @Test func aClickOpensThePanelAndAnotherClickCloses() {
        let model = notchModel()
        model.setHovering(true)
        model.islandClicked()
        #expect(model.expansion == .full)
        model.islandClicked()
        #expect(model.expansion == .peek)   // still hovering
        model.setHovering(false)
        model.close()
        #expect(model.expansion == .collapsed)
    }

    @Test func aClickOnTheBusyStripOpensThePanelButNotWhileSpeakingOrInAGuide() {
        let model = notchModel()
        model.setBusy(true)
        #expect(model.expansion == .compact)
        model.islandClicked()
        #expect(model.expansion == .full)
        model.close()
        model.setSpeaking(true)
        model.islandClicked()
        #expect(model.expansion == .compact)
        model.setSpeaking(false)
        model.setGuideStep(1)
        model.islandClicked()
        #expect(model.expansion == .compact)
    }

    @Test func setupAndCardsOutrankThePeek() {
        let model = notchModel()
        model.setPermissionPrompt(PermissionPrompt.fixtureAccessibility)
        model.setHovering(true)
        #expect(model.expansion == .permission)
        model.setPermissionPrompt(nil)
        model.setConnectPrompt(AppConnectPrompt.fixture)
        #expect(model.expansion == .connect)
    }

    @Test func aDisplayWithoutAMenuBarBandStillHasRoomForThePeekLine() {
        let screenFrame = CGRect(x: -173, y: 982, width: 1920, height: 1080)
        let model = NotchHUDModel(geometry: NotchGeometry.virtualNotch(screenFrame: screenFrame, visibleFrame: screenFrame))
        model.setHovering(true)
        #expect(model.peekHeight == 34 + 24)
        model.setBusy(true)
        #expect(model.compactHeight == 34 + 8)
    }

    @Test func sideDrawersStillOpenOnHover() {
        let model = notchModel()
        model.placement = .left
        model.setHovering(true)
        #expect(model.expansion == .full)
    }

    @Test func pressIsAFlagTheViewScalesOn() {
        let model = notchModel()
        model.setPressed(true)
        #expect(model.isPressed)
        model.setPressed(false)
        #expect(!model.isPressed)
    }
}
```

`PermissionPrompt.fixtureAccessibility` and `AppConnectPrompt.fixture` exist for the tests already in `PermissionPromptTests.swift`; if not, add them as `static` test-only extensions in this test file.

- [ ] **Step 2: Run the suite to verify it fails**

Expected: compile errors for `islandClicked`, `peekWidth`, `isPressed`; then `expansion == .peek` failures.

- [ ] **Step 3: Implement the rules in `NotchHUDModel`**

In `reconcile`: the hover branch yields `.full` only when `placement.isSideDrawer`; otherwise `.peek`, with the same guards (`!isSetupInProgress && !isSpeaking && guideStep == nil && !isBusy`). `islandClicked()`: ignore while setup; if `expansion == .compact` and (`isSpeaking` or `guideStep != nil`) do nothing (the view keeps calling `stopSpeaking`/`stopGuide` itself before this); if `expansion` is `.connect/.permission/.composer/.tour` do nothing; else `togglePinned()`. Sizes: `width`/`height` switches gain `.peek`; `compactHeight` and `peekHeight` use `topBandHeight`. The `onTapGesture` in `NotchHUDView` (`NotchHUD.swift:1042-1046`) calls `model.islandClicked()` after its speaking/guide checks.

- [ ] **Step 4: Run the model suite and the existing island suites**

Run with `-only-testing:OpenClickyTests/NotchHUDModelTests -only-testing:OpenClickyTests/NotchGeometryTests -only-testing:OpenClickyTests/HUDPlacementTests`
Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add macos/OpenClicky/OpenClicky/NotchHUD.swift macos/OpenClicky/OpenClickyTests/NotchHUDModelTests.swift
git commit -m "Island: hovering only peeks, a click opens the panel"
```

---

### Task 3: Components: protocol, registry, selector, settings

**Files:**
- Create: `macos/OpenClicky/OpenClicky/IslandComponents.swift`
- Test: `macos/OpenClicky/OpenClickyTests/IslandComponentSelectorTests.swift`

**Interfaces:**
- Produces:
  - `struct IslandContext: Equatable { var isTakeLive: Bool; var takeLandedAt: Date?; var liveTranscript: String; var agentActivityText: String?; var isResultCardUp: Bool; var engineCanRun: Bool; var placement: HUDPlacement; var now: Date }` with `static let idle: IslandContext` and `var contextualKey: String?` ("transcript" while `isTakeLive` or `takeLandedAt` within 8 s of `now`; "agent" while `agentActivityText != nil || isResultCardUp`; else nil).
  - `protocol IslandComponent { var id: String { get }; var title: String { get }; var symbolName: String { get }; var preferredHeight: CGFloat { get }; func isAvailable(in context: IslandContext) -> Bool; @MainActor func makeView(companionManager: CompanionManager, model: NotchHUDModel) -> AnyView }`
  - `struct IslandComponentSelection: Equatable { let active: String; let available: [String] }`
  - `enum IslandComponentSelector { static func select(registry: [any IslandComponent], order: [String], defaultID: String, override: String?, context: IslandContext) -> IslandComponentSelection }` (pure; `override` wins when available; else the contextual key's component when registered and available; else `defaultID` when available; else the first available; `available` is the registry filtered by `isAvailable`, sorted by `order` with unknown ids ignored and missing ids appended in registry order; empty registry is a programmer error, `precondition`).
  - `struct IslandComponentSettings { static let defaultKey = "openclicky.island.defaultComponent"; static let orderKey = "openclicky.island.componentOrder"; init(defaults: UserDefaults); var defaultID: String { get set }; var order: [String] { get set } }` (defaults: `"shortcuts"`, `[]`).
  - `enum IslandComponentRegistry { static let shortcutsID = "shortcuts", transcriptID = "transcript", agentID = "agent"; @MainActor static var all: [any IslandComponent] }` (filled in Task 6; this task registers three stub components whose `makeView` returns `AnyView(EmptyView())` so the selector tests run).

- [ ] **Step 1: Write the failing tests**

```swift
import Foundation
import Testing
@testable import OpenClicky

struct IslandComponentSelectorTests {
    struct Stub: IslandComponent {
        let id: String; var title: String { id }; var symbolName: String { "circle" }; var preferredHeight: CGFloat { 45 }
        let available: (IslandContext) -> Bool
        func isAvailable(in context: IslandContext) -> Bool { available(context) }
        @MainActor func makeView(companionManager: CompanionManager, model: NotchHUDModel) -> AnyView { AnyView(EmptyView()) }
    }
    let shortcuts = Stub(id: "shortcuts") { _ in true }
    let transcript = Stub(id: "transcript") { $0.contextualKey == "transcript" }
    let agent = Stub(id: "agent") { $0.contextualKey == "agent" }
    var registry: [any IslandComponent] { [shortcuts, transcript, agent] }
    let now = Date(timeIntervalSince1970: 1_000_000)

    @Test func idleShowsTheDefaultAloneSoNoCapsule() {
        let s = IslandComponentSelector.select(registry: registry, order: [], defaultID: "shortcuts", override: nil, context: .idle)
        #expect(s == IslandComponentSelection(active: "shortcuts", available: ["shortcuts"]))
    }

    @Test func aLiveTakeMakesTheTranscriptActiveAndKeepsItEightSecondsAfterLanding() {
        var context = IslandContext.idle; context.now = now; context.isTakeLive = true
        #expect(IslandComponentSelector.select(registry: registry, order: [], defaultID: "shortcuts", override: nil, context: context).active == "transcript")
        context.isTakeLive = false; context.takeLandedAt = now.addingTimeInterval(-7.9)
        #expect(context.contextualKey == "transcript")
        context.takeLandedAt = now.addingTimeInterval(-8.1)
        #expect(context.contextualKey == nil)
    }

    @Test func anAgentOutranksTheDefaultButNotALiveTake() {
        var context = IslandContext.idle; context.agentActivityText = "editing Hero.swift"
        #expect(context.contextualKey == "agent")
        context.isTakeLive = true
        #expect(context.contextualKey == "transcript")
        context.isTakeLive = false; context.agentActivityText = nil; context.isResultCardUp = true
        #expect(context.contextualKey == "agent")
    }

    @Test func theOverrideWinsWhileAvailableAndTheOrderIsTheUsers() {
        var context = IslandContext.idle; context.agentActivityText = "working"
        let s = IslandComponentSelector.select(registry: registry, order: ["agent", "bogus", "shortcuts"], defaultID: "shortcuts", override: "shortcuts", context: context)
        #expect(s == IslandComponentSelection(active: "shortcuts", available: ["agent", "shortcuts"]))
        let gone = IslandComponentSelector.select(registry: registry, order: [], defaultID: "shortcuts", override: "transcript", context: context)
        #expect(gone.active == "agent")
    }

    @Test func anUnknownOrUnavailableDefaultFallsBackToTheFirstAvailable() {
        let s = IslandComponentSelector.select(registry: registry, order: ["transcript", "shortcuts"], defaultID: "nope", override: nil, context: .idle)
        #expect(s.active == "shortcuts")
        let t = IslandComponentSelector.select(registry: registry, order: [], defaultID: "transcript", override: nil, context: .idle)
        #expect(t.active == "shortcuts")
    }

    @Test func settingsRoundTripWithDefaults() {
        let defaults = UserDefaults(suiteName: "IslandComponentSelectorTests")!
        defaults.removePersistentDomain(forName: "IslandComponentSelectorTests")
        var settings = IslandComponentSettings(defaults: defaults)
        #expect(settings.defaultID == "shortcuts")
        #expect(settings.order == [])
        settings.defaultID = "agent"; settings.order = ["agent", "shortcuts"]
        let again = IslandComponentSettings(defaults: defaults)
        #expect(again.defaultID == "agent")
        #expect(again.order == ["agent", "shortcuts"])
    }
}
```

- [ ] **Step 2: Run the suite to verify it fails**

Expected: build failure, `IslandComponent` not found.

- [ ] **Step 3: Implement `IslandComponents.swift`**

As the Interfaces block states. The `isAvailable` rules for the three built-ins (in their stubs, kept by Task 6): shortcuts always; transcript when `contextualKey == "transcript"`; agent when `agentActivityText != nil || isResultCardUp`.

- [ ] **Step 4: Run the suite to verify it passes**

Expected: 6 tests pass.

- [ ] **Step 5: Commit**

```bash
git add macos/OpenClicky/OpenClicky/IslandComponents.swift macos/OpenClicky/OpenClickyTests/IslandComponentSelectorTests.swift
git commit -m "Island: components, a selector that picks one by the moment or by choice, and their settings"
```

---

### Task 4: The slot in the model

**Files:**
- Modify: `macos/OpenClicky/OpenClicky/NotchHUD.swift` (`NotchHUDModel`: sizes `:201-230`, new state next to `:148-165`)
- Test: `macos/OpenClicky/OpenClickyTests/NotchHUDModelTests.swift` (extend)

**Interfaces:**
- Produces on `NotchHUDModel`: `@Published private(set) var context: IslandContext`, `@Published private(set) var selection: IslandComponentSelection`, `var componentSettings: IslandComponentSettings` (injected, default `.init(defaults: .standard)`), `var registry: [any IslandComponent]` (default `IslandComponentRegistry.all`), `func setContext(_:)`, `func selectComponent(_ id: String)` (sets the override), `var showsCapsule: Bool` (`selection.available.count > 1`), `let capsuleRowHeight: CGFloat = 36` (28 + 8 gap), `var slotHeight: CGFloat` (the active component's `preferredHeight`; 45 for shortcuts in notch placement, 92 in a drawer, as today), `fullHeight = bandRowHeight + slotHeight + (showsCapsule ? capsuleRowHeight : 0)`.
- Consumes: Task 3's types.

- [ ] **Step 1: Write the failing tests**

```swift
    @Test func theSlotFollowsTheContextAndTheUsersOverrideSurvivesPartialTranscripts() {
        let model = notchModel()
        model.registry = IslandComponentSelectorTests().registry
        #expect(model.selection.active == "shortcuts")
        #expect(!model.showsCapsule)
        #expect(model.fullHeight == model.bandRowHeight + 45)
        var context = IslandContext.idle; context.isTakeLive = true; context.liveTranscript = "hello"
        model.setContext(context)
        #expect(model.selection.active == "transcript")
        #expect(model.showsCapsule)
        #expect(model.fullHeight == model.bandRowHeight + 45 + 36)
        model.selectComponent("shortcuts")
        context.liveTranscript = "hello there"
        model.setContext(context)
        #expect(model.selection.active == "shortcuts")      // override survives a partial
        context.isTakeLive = false; context.takeLandedAt = nil
        model.setContext(context)
        #expect(model.selection.active == "shortcuts")      // contextual key changed: override cleared, default wins
        context.agentActivityText = "working"
        model.setContext(context)
        #expect(model.selection.active == "agent")          // a fresh contextual key is followed again
    }
```

- [ ] **Step 2: Run to verify it fails**

Expected: `setContext` not found.

- [ ] **Step 3: Implement**

`setContext` stores the context, clears `override` when `context.contextualKey != previous.contextualKey`, recomputes `selection` with `IslandComponentSelector.select`, and calls `onLayoutChanged?()` when `fullHeight` changed and `expansion == .full`. `selectComponent` sets `override` and recomputes.

- [ ] **Step 4: Run the model suite**

Expected: pass.

- [ ] **Step 5: Commit**

```bash
git add macos/OpenClicky/OpenClicky/NotchHUD.swift macos/OpenClicky/OpenClickyTests/NotchHUDModelTests.swift
git commit -m "Island: the panel body is a slot the moment or the user fills"
```

---

### Task 5: The dress: glass, gradient-masked black, shadow, unfold and press

**Files:**
- Create: `macos/OpenClicky/OpenClicky/IslandComponentViews.swift` (start with `IslandGlassBackground` only)
- Modify: `macos/OpenClicky/OpenClicky/NotchHUD.swift:985-1136` (`NotchHUDView`), `:1141-1171` (`NotchIslandShape` unchanged, reused)
- Test: `macos/OpenClicky/OpenClickyTests/IslandStyleTests.swift` (one more test) + hand check

**Interfaces:**
- Produces: `struct IslandGlassBackground: NSViewRepresentable` (macOS 26: `NSGlassEffectView` with `cornerRadius = 0` and a dark tint; earlier: `NSVisualEffectView` `.hudWindow`/`.behindWindow`/`.active`; both overlaid by `Color.black.opacity(IslandGlass.wash)`), `struct IslandSurface: View` (the two layers clipped by `NotchIslandShape`, parameters `expansion`, `width`, `height`, `bandBottom`, `glassLevel`, `isSideDrawer`; `var hasGlassLayer: Bool` exposed for the test), `extension NotchHUDModel { var reduceMotion: Bool }` (read from `DictationSettings.reduceAnimation` through a closure the manager sets: `var reduceMotionProvider: () -> Bool = { false }`), `@Published var glassLevel: Double` on the model (manager sets it from `UserDefaults` key `IslandGlass.defaultsKey`).
- Consumes: Task 1 maths, Task 2 `isPressed`/`setPressed`.

- [ ] **Step 1: Write the failing test**

```swift
    @Test func theGlassLayerExistsOnlyWhenOpenAndLevelIsAboveZero() {
        #expect(IslandSurface(expansion: .full, width: 512, height: 120, bandBottom: 40, glassLevel: 0.6, isSideDrawer: false).hasGlassLayer)
        #expect(!IslandSurface(expansion: .full, width: 512, height: 120, bandBottom: 40, glassLevel: 0, isSideDrawer: false).hasGlassLayer)
        #expect(!IslandSurface(expansion: .peek, width: 218, height: 57, bandBottom: 33, glassLevel: 0.6, isSideDrawer: false).hasGlassLayer)
        #expect(!IslandSurface(expansion: .compact, width: 380, height: 41, bandBottom: 33, glassLevel: 0.6, isSideDrawer: false).hasGlassLayer)
        #expect(IslandSurface(expansion: .connect, width: 512, height: 150, bandBottom: 33, glassLevel: 0.6, isSideDrawer: false).hasGlassLayer)
    }
```

- [ ] **Step 2: Run to verify it fails**

Expected: `IslandSurface` not found.

- [ ] **Step 3: Implement `IslandSurface` and `IslandGlassBackground`; use them in `NotchHUDView`**

`islandBackground` becomes `IslandSurface(...)`: a `ZStack` of (a) `IslandGlassBackground` when `hasGlassLayer`, (b) `Color.black` masked by `LinearGradient(stops: [.init(color: .black, location: stops.start), .init(color: .clear, location: stops.end)], startPoint: .top, endPoint: .bottom)` (no mask when stops are nil), both `.clipShape(NotchIslandShape(...))`, with `.shadow(color: .black.opacity(0.35), radius: 14, y: 6)` applied to the whole surface only when `hasGlassLayer || expansion == .full`. `bandBottom` for `.full` is `model.bandRowHeight`; for cards `model.cardTopInset`. The glass layer fades in with `.transition(.opacity)`.

Motion: wrap the width in its own `.frame(width:)` with `.animation(IslandMotion.unfoldWidth(reduceMotion:), value: model.width)` and the height in `.frame(height:)` with `.animation(IslandMotion.unfoldHeight(reduceMotion:).delay(expansion == .full ? IslandMotion.heightDelay : 0), value: model.height)`; closing applies the delay to the width instead. The peek uses `IslandMotion.peek`. Replace the existing `.animation(..., value: expansion)` on the `ZStack` accordingly (keep the `isSettlingGracefully` slow spring). Press: a `DragGesture(minimumDistance: 0)` on the surface sets `model.setPressed(true)` on change and `false` on end, then the tap action; the surface gets `.scaleEffect(model.isPressed ? IslandMotion.pressScale(reduceMotion:) : 1, anchor: .top)` animated over `IslandMotion.pressDuration`.

- [ ] **Step 4: Run the style suite, then build and hand-check**

Run the test suite (pass), then `scripts/release.sh --no-notarize` and check on the built-in display: idle looks like the notch; hover peeks (one line, no glass); click unfolds width-then-height into a panel whose band row is black and whose lower part shows blurred wallpaper under a dark wash; a glass level of 0 (set with `defaults write com.openclicky.OpenClicky openclicky.island.glassLevel -float 0` using the app's real bundle id, then relaunch) gives the all-black panel; Reduce motion in Settings gives fades. Check the same on the external display. Note in the PR that the pre-26 material is untested here.

- [ ] **Step 5: Commit**

```bash
git add macos/OpenClicky/OpenClicky/IslandComponentViews.swift macos/OpenClicky/OpenClicky/NotchHUD.swift macos/OpenClicky/OpenClickyTests/IslandStyleTests.swift
git commit -m "Island: black melting into glass, notch-shaped corners, a spring unfold and a press"
```

---

### Task 6: The three components, the capsule and the full panel

**Files:**
- Modify: `macos/OpenClicky/OpenClicky/IslandComponentViews.swift` (add views), `macos/OpenClicky/OpenClicky/IslandComponents.swift` (replace the stubs with the real components), `macos/OpenClicky/OpenClicky/NotchHUDPanels.swift:21-36` (`NotchFullPanelView`), `:213-300` (tiles on glass), `:468-535` (result card visibility)
- Test: hand check; `IslandComponentSelectorTests` keep passing with the real registry (add `@Test func theRealRegistryHasTheThreeBuiltInsInOrder()` asserting ids `["shortcuts", "transcript", "agent"]`).

**Interfaces:**
- Produces: `struct ShortcutsIslandComponent`, `struct TranscriptIslandComponent`, `struct AgentIslandComponent` (all `IslandComponent`; `preferredHeight` 45, 52, 52 in notch placement; the shortcuts one returns 92 in a drawer, read from the model), `struct IslandNavigationCapsule: View` (`selection`, `registry`, `onSelect: (String) -> Void`), `AgentResultPanelState.isVisible: Bool` (`@Published`, set true in `AgentResultPanelManager.show…` and false in `hide()`), `NotchFullPanelView` = band row + `model.selection.active`'s view in a frame of `model.slotHeight` + the capsule when `model.showsCapsule`.
- Consumes: Tasks 3-5.

- [ ] **Step 1: Write the registry test** (above) and run it to see it fail (`IslandComponentRegistry.all` still returns stubs with `preferredHeight` 45 each; assert `TranscriptIslandComponent().preferredHeight == 52` too).

- [ ] **Step 2: Implement the views**

- Shortcuts: `NotchPanelBody` as it is, with the dock button, (i) and warning tiles switching to `DS.HUD.glassTile`/`glassTileHovered` fills when `model.glassLevel > 0`.
- Transcript: left, the engine's `listenerName` in `DS.HUD.text3` 11 pt; right, `companionManager.orbModel.liveTranscript` (or `lastTranscript` once landed) in 13 pt, two lines, `DS.HUD.text2` while the take is live and `DS.HUD.text` after.
- Agent: `companionManager.agentActivityText ?? agentResultPanelManager.state.title` in 13 pt with a 2 pt indeterminate bar in `DS.HUD.pointer` while running, and a "follow up" pill (`DS.HUD.glassTile`) that calls `model.close()` then `companionManager.hudManager.openTextComposer()` routed with `threadId: agentResultPanelManager.state.threadId` (add a `threadId` parameter to `openTextComposer` defaulting to nil and pass it to `submitTextToAgent`).
- Capsule: `HStack` of 24 pt round buttons with `Image(systemName: symbolName)` 11 pt semibold, active on a `DS.HUD.capsuleActive` disc, inside a 28 pt `Capsule().fill(DS.HUD.capsule)`, `.help(title)`; drawn under the island shape with an 8 pt gap, centred; it is outside the clip but inside the window (the window's bottom margin is 16 pt: raise `windowMargin` handling so the capsule row's 36 pt is part of `fullHeight` and the surface height is `fullHeight - capsuleRowHeight`).
- Symbols: shortcuts `keyboard`, transcript `text.quote`, agent `wand.and.sparkles`.

- [ ] **Step 3: Run the selector suite and hand-check**

Suite passes. Hand check: open the panel; dictate with the panel open: the slot switches to the transcript and the capsule appears; click the capsule's keyboard icon: shortcuts come back and stay through the take; after the take, 8 s later the capsule disappears. Ask an agent something with the panel open: the agent component shows and "follow up" opens the composer.

- [ ] **Step 4: Commit**

```bash
git add macos/OpenClicky/OpenClicky/IslandComponentViews.swift macos/OpenClicky/OpenClicky/IslandComponents.swift macos/OpenClicky/OpenClicky/NotchHUDPanels.swift macos/OpenClicky/OpenClicky/NotchHUD.swift macos/OpenClicky/OpenClickyTests/IslandComponentSelectorTests.swift
git commit -m "Island: shortcuts, the live transcript and the agent's progress as components, with a capsule to flip them"
```

---

### Task 7: Context wiring and the compact strip beside the camera

**Files:**
- Modify: `macos/OpenClicky/OpenClicky/NotchHUD.swift:840-890` (manager subscriptions), `:1179-1285` (`NotchCompactStatusView`), `:1081-1091` (compact layout in `NotchHUDView`)
- Test: `macos/OpenClicky/OpenClickyTests/IslandComponentSelectorTests.swift` (one more) + hand check

**Interfaces:**
- Produces: `extension IslandContext { static func make(takeState: DictationTakeController.TakeState, lastTake: TakeRecord?, liveTranscript: String, agentActivityText: String?, isResultCardUp: Bool, engineCanRun: Bool, placement: HUDPlacement, now: Date) -> IslandContext }` (`isTakeLive` = `takeState != .idle`; `takeLandedAt` = `lastTake?.date`), `NotchCompactStatusView` gains `let notchWidth: CGFloat` and lays its indicator left and its words right of a `Spacer().frame(width: notchWidth + 16)`.
- Consumes: Task 4's `setContext`, Task 6's `isVisible`.

- [ ] **Step 1: Write the failing test**

```swift
    @Test func theContextIsBuiltFromWhatTheAppAlreadyPublishes() {
        let now = Date()
        let c = IslandContext.make(takeState: .listening, lastTake: nil, liveTranscript: "hi", agentActivityText: nil, isResultCardUp: false, engineCanRun: true, placement: .notch, now: now)
        #expect(c.isTakeLive && c.contextualKey == "transcript" && c.liveTranscript == "hi")
        let d = IslandContext.make(takeState: .idle, lastTake: nil, liveTranscript: "", agentActivityText: nil, isResultCardUp: true, engineCanRun: true, placement: .notch, now: now)
        #expect(d.contextualKey == "agent")
    }
```

`TakeRecord`'s timestamp property name is in `TakeStore.swift`; use it.

- [ ] **Step 2: Run to verify it fails**, then implement `make` and the manager subscription: `Publishers.CombineLatest4(dictationTakeController.$state, dictationTakeController.$lastTake, orbModel.$liveTranscript, $agentActivityText)` combined with `agentResultPanelManager.state.$isVisible`, mapped through `make` (with `engineCanRun = DictationEngineResolver.unavailableReason(for: settings.engine) == nil`), `removeDuplicates()`, then `instances.forEach { $0.model.setContext($0) }`; a 1 s timer re-sends the last context while `takeLandedAt` is within 8 s so the window expires. Also set `model.glassLevel` from defaults at instance creation and on `UserDefaults.didChangeNotification`, and `model.reduceMotionProvider = { [settings] in settings.reduceAnimation }`.

- [ ] **Step 3: Compact strip**: height `topBandHeight + 8` (Task 2), content `.padding(.top, 0)` with the band's vertical centre, indicator left of the notch, words right; the detail line below spans the width. Hand check while dictating and while an answer is spoken: the status reads beside the camera; the stop-on-click still works.

- [ ] **Step 4: Run all four island suites**, then commit:

```bash
git add macos/OpenClicky/OpenClicky/NotchHUD.swift macos/OpenClicky/OpenClicky/IslandComponents.swift macos/OpenClicky/OpenClickyTests/IslandComponentSelectorTests.swift
git commit -m "Island: the slot follows takes and agents, and the busy strip sits beside the camera"
```

---

### Task 8: Settings rows and the file table

**Files:**
- Modify: `macos/OpenClicky/OpenClicky/Dictation/UI/SettingsGeneralPage.swift:30-35` (add three items after `general.hudPlacement`), `:170-240` (rows), `macos/OpenClicky/AGENTS.md` (Dictation/HUD file table: the three new files and the changed behaviour; the "where openclicky lives" hover copy)
- Test: hand check + the existing `SettingsCatalog` tests if any assert the item count (update them).

- [ ] **Step 1: Add the items**: `general.islandGlass` ("Glass level", detail "Where the island's black melts into glass. Left is all black.", a `Slider` 0…1 writing `IslandGlass.defaultsKey`, keywords glass/blur/transparent/black/island); `general.islandDefault` ("Default component", a `Picker` over `IslandComponentRegistry.all` titles writing `IslandComponentSettings.defaultID`); `general.islandOrder` ("Component order", up/down buttons per row writing `order`). Update `HUDPlacement.settingsDetail` for `.notch` to "Hangs from the notch. Hover to peek, click to open."

- [ ] **Step 2: Build, open Settings → General, move the slider**: the next panel open reflects it; pick "Agent" as default: the panel opens on it when no take is live.

- [ ] **Step 3: Update `macos/OpenClicky/AGENTS.md`** rows for `NotchHUD.swift`, `NotchHUDPanels.swift`, and new rows for `IslandStyle.swift`, `IslandComponents.swift`, `IslandComponentViews.swift`, in the table's style (one or two sentences each).

- [ ] **Step 4: Run every island suite once more and commit**

```bash
git add macos/OpenClicky/OpenClicky/Dictation/UI/SettingsGeneralPage.swift macos/OpenClicky/AGENTS.md
git commit -m "Settings: glass level and the island's default component and order"
```

---

### Task 9: Whole-feature hand check and PR

- [ ] **Step 1**: Build and install (`scripts/release.sh --no-notarize`), then walk the spec's states table on both displays: collapsed, peek, compact (dictating, speaking, guide), connect card (open a supported app for the first time or clear its "never" in Settings), permission card (not reproducible without revoking; skip and say so), composer, full with each component, side drawer placement (hover opens, no peek), hidden placement (menu bar icon opens the panel, no peek).
- [ ] **Step 2**: Open a PR with `gh pr create` whose body lists the states checked, the suites run, the glass level 0 check, and that the material before macOS 26 is built but unseen. The branch name and PR title describe the island refresh only.
