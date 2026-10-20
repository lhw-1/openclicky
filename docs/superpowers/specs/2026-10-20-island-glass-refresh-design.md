# Island glass refresh

Date: 2026-10-20. Scope: the macOS app's notch island (`NotchHUD.swift`, `NotchHUDPanels.swift`,
`DS.HUD`). One PR.

## Intent

The island is OpenClicky's home on screen, and today it is a flat black panel that opens on hover with
one hard-wired row. This refresh gives it the finish of a first-class notch surface and a body that can
grow: hovering only teases, a click opens the panel, the panel is black around the camera and melts into
glass below, its corners follow the notch housing, it unfolds on springs, and its body is a slot that
different components (the shortcuts, the live transcript, an agent's progress, later an agents pill and
dictation stats) can occupy, picked by the moment or by the user.

## Goals

1. **Hover teases, click opens.** Hover grows the island slightly and shows one line; it never opens the
   panel. A click opens the full panel, pinned, until a click elsewhere or a click on the island.
2. **The dress.** Solid black around the camera, continuous with the hardware notch, top corners flared
   into the menu bar; the lower part of the open panel melts from black into glass (native Liquid Glass
   on macOS 26, a frosted material before), so controls sit on tinted, blurred wallpaper. Bottom corners
   scale with the panel. A soft shadow when open, none when idle.
3. **Motion.** A spring unfold from the notch, width then height, a slight scale on press, and the glass
   band fading in with the unfold. Reduce motion turns all of it into plain fades.
4. **A modular body.** The band (pointer status, voice pill, Settings, quit) stays. Under it, one slot
   holds the active component. The app swaps components by context (transcript while dictating, agent
   progress while an agent runs, back to the default afterwards); the user picks the default and the
   order in Settings; a small navigation capsule under the panel flips between the components available
   right now.
5. **Compact like a phone's island.** While OpenClicky listens, thinks or speaks, the compact strip puts
   its indicator left of the camera and its words right of it, with black between where the notch is.

## Non-goals

- No new pages or content beyond the three components named below; no media, files, or widgets.
- No fully clear "glass capsule" mode; black-into-glass is the one open-panel material.
- No change to the connect, permission, tour and composer cards beyond the new material and corners.
- No change to where the island lives (notch, side drawer, hidden) or how the side drawer opens.
- No change to the orb, the main window, or the menu bar.

## Anti-goals (a failure even if it works)

- The island activates the app, becomes main, or steals keyboard focus from the app in front.
- The idle island looks different from the hardware notch (a visible outline, shadow or lip while idle),
  or covers menu bar extras while idle.
- The glass costs battery while idle: no backdrop sampling exists unless the panel is open.
- Private API, third-party packages, or anything that needs the sandbox or library validation off.
- Text that cannot be read because the glass band has no contrast on a bright wallpaper.

## Constraints

- Deployment target macOS 14.2; Xcode 27; Swift 5 mode. Liquid Glass APIs exist only on macOS 26 and
  must be behind availability checks; the frosted fallback must look intentional, not degraded.
- The island window is a non-activating `NSPanel` at pop-up-menu level that can become key only for the
  composer and the tour field. Glass must render "active" in a non-key window of a background app.
- One window per screen; everything is sized to its state so transparent areas never block clicks.
- Hover is detected by polling the pointer against the island frame (SwiftUI's `onHover` is unreliable
  here); the grace periods and the click-outside monitor stay as they are.
- Nothing from any other product is copied: all shapes, strings, icons and sounds are drawn fresh.

## The design

### States

| State | Size (notch placement) | What shows |
|---|---|---|
| collapsed | the notch itself (hardware notch, or the thin handle on other displays) | nothing |
| **peek** (new) | notch width + 28, notch height + 24 | one line under the camera: the pointer status, then " · click to open" in the dimmer text colour. Hover-in opens it on a short spring; hover-out closes it after today's grace period. |
| compact | 380 wide; height = notch height + 8, plus the 26 pt detail line when there is one | indicator (level bars, spinner, pointer) **left of the camera**, the status words **right of it**; the detail line hangs under the whole strip as today. Speaking and the guide keep today's "click to stop" behaviour. |
| connect / permission / tour / composer | as today | as today, in the new material |
| full | 512 wide (360 in a side drawer); height = band row + active component height + capsule row when the capsule shows | the band, the component slot, the navigation capsule |

Rules: hovering never yields `full`; `peek` is what hovering gives when nothing busier is up. A
contextual component never opens the panel on its own: while a take or an agent runs the closed island
shows the compact strip, and a click on the strip opens `full` with the contextual component active
(the orb keeps showing the live words for a closed island). A click on
the island in collapsed, peek or compact (not while speaking or in a guide, where the click stops those)
pins `full`. A click outside, a click on the island while `full`, Settings opening, or the composer
closing unpins. The side drawer keeps opening on hover and does not peek. Hidden placement is unchanged.

### Shape

`NotchIslandShape` stays the outline. Its two parameters become functions of the state:

- Top corner flare: 6 pt collapsed and peek (matches the housing), 10 pt for compact and the cards, 12 pt
  for the full panel. Side drawers: 0.
- Bottom corner radius: 11 pt collapsed (the hardware corner), 18 pt peek and compact, and for cards and
  the full panel `clamp(width × 0.05, 20, 30)` so a 512 pt panel gets ~26 pt and the drawer's 360 pt
  gets 20. Both animate with the unfold.

### Material: black melting into glass

The island body is two layers inside the shape's clip:

1. **Glass**, full size, only present in `full` and the cards (never collapsed, peek or compact). On
   macOS 26 it is the system Liquid Glass (`NSGlassEffectView` or SwiftUI's glass effect, builder's
   choice) in its regular, dark-tinted style. Before macOS 26 it is an `NSVisualEffectView` with the
   `hudWindow` material, `behindWindow` blending and `state = .active` so it never greys out in a
   non-key window. Both get a dark wash of 35 % black on top so white text keeps contrast on bright
   wallpapers.
2. **Black**, full size, masked by a vertical gradient: opaque from the top down to `glassStart`, fading
   to clear at `glassEnd`. For the full panel `glassStart` = the bottom of the band row and
   `glassEnd` = `glassStart` + 40 % of the remaining height; the slot's controls therefore sit on the
   glass band and the band row stays pure black and continuous with the camera housing. Cards use the
   same rule with the card's top inset as the band.

**Glass level** (Settings → General, island section): a slider from 0 to 1, default 0.6. It scales how
far the black reaches: at 0 the panel is all black (today's look, and the material layer is not created
at all); at 1 the black ends right under the band row. Values in between move `glassStart` between the
panel's bottom and the band row. Stored under `openclicky.island.glassLevel`.

Band controls (pills, round buttons) keep their raised fills. Tiles that sit on the glass band (the dock
button, the (i), the capsule) use a translucent white fill (white 14 %, white 22 % hovered) instead of
the raised greys, so they read as glass controls; the pointer-orange dock state is unchanged.

**Shadow**: a drop shadow of black 35 %, radius 14, offset y 6, behind the shape in `full` and the cards
only. Collapsed, peek and compact have none, so they read as part of the notch.

### Motion

- **Unfold**: from collapsed or peek to full, width animates on one spring (response ≈ 0.36, damping
  ≈ 0.82) and height on a second spring (response ≈ 0.42, damping ≈ 0.84) that starts ~60 ms later, so
  the island widens first and then drops. The glass layer fades in over the last part of the drop; the
  corner radii and flare animate with the frame. Closing reverses it with the height going first.
- **Peek**: a short spring (response ≈ 0.3, damping ≈ 0.8) in and out.
- **Press**: on mouse-down anywhere on the island it scales to 0.97 around its top centre for about
  120 ms, then back; the click's action runs on mouse-up as today.
- **Reduce motion** (the existing setting): every spring becomes a 0.15 s fade; no press scale.
- The compact strip and the cards keep today's fade-and-scale transitions.

### The component slot

```swift
protocol IslandComponent {
    var id: String { get }                       // stable, stored in Settings
    var title: String { get }                    // for Settings and the capsule's help text
    var symbolName: String { get }               // the capsule's icon
    var preferredHeight: CGFloat { get }         // the slot's height for this component (notch placement)
    func isAvailable(in context: IslandContext) -> Bool
    @MainActor func makeView(companionManager: CompanionManager, model: NotchHUDModel) -> AnyView
}
```

`IslandContext` is a value built by the HUD manager from what it already observes: whether a take is
live and its words so far, whether an agent is running and its latest progress line, whether the engine
can run, and the placement. A pure `IslandComponentSelector` turns the registry, the user's order, the
user's default and the context into `(active: String, available: [String])`:

- **Contextual first**: if a take is live, or landed less than 8 s ago, the transcript component is
  active; else if an agent is running or a result card is up, the agent component; else the user's
  default. The user can still flip with the capsule while
  a contextual component is active; the contextual rule reapplies when the context changes.
- **Available**: every registered component whose `isAvailable` is true, in the user's order.
- The capsule shows only when two or more components are available.

Components in this PR:

| id | What it is | Available |
|---|---|---|
| `shortcuts` | Today's body row: dock/release, (i), the 2 × 2 shortcut grid or the engine warning | always; the default |
| `transcript` | The take's words so far (the same text the orb shows), two lines, dimmer while interim, with the engine's name on the left | while a take is live, and for 8 s after it lands |
| `agent` | The running agent's latest line and a progress treatment (the data the busy strip's detail line already carries), and a "follow up" button that opens the existing text composer routed to the agent's thread (no text field in the panel: the panel gains no new key-window case). The floating result card stays as it is; the card's visibility becomes a published flag the context reads | while an agent runs, and while a result card is up |

Later PRs add `agents` (the agents pill) and `stats` by registering a component; nothing in the island
changes for that.

**The navigation capsule**: a 28 pt tall capsule centred under the panel with an 8 pt gap, one 24 pt
round button per available component, the active one on a white 18 % disc; the capsule itself is black
60 % over the wallpaper (it hangs below the glass band, outside the island shape, inside the window's
margin). Clicking a button makes that component active until the context changes. Keyboard: none (the
panel is not key).

**Settings → General, island section** (next to "where openclicky lives"): "Default component" (a
picker of the registered ids) and "Component order" (a reorderable list). Stored as
`openclicky.island.defaultComponent` and `openclicky.island.componentOrder`; unknown ids are ignored,
missing ids are appended in registration order.

### Compact strip layout

The strip is 380 pt wide and `notch height + 8` tall. Its content is an `HStack` whose middle spacer is
the notch width plus 16 pt, so the indicator (28 pt) and the words sit beside the camera at the band's
vertical centre; on a display without a hardware notch the same layout sits in the menu bar band. The
detail line, when present, hangs under the strip across its full width as today. The caption strip (the
(i) text while the buddy is docked) is unchanged.

## What is the user's decision and what is mine

The user decided: hover teases only and click opens; the band plus shortcuts stays and the body becomes
swappable; both the app (by context) and the user (Settings and a navigation capsule) swap components;
black melting into glass, flared top corners, scaling bottom radii, spring unfold with press scale, and
the phone-style compact layout.

The user also decided (2026-10-20, on my recommendation): contextual components never open the panel
by themselves; the compact strip stays the busy state and a click opens the panel on the transcript or
agent view.

My calls (change them if wrong): the peek shows the pointer status line; the agent component's follow-up
is a button into the existing composer, and the floating result card stays; the transcript stays active
for 8 s after a take lands; the side drawer keeps opening
on hover; the glass level default of 0.6 and its slider; the three components in this PR and their
availability windows; the capsule hiding with one component; the numbers above for radii, flare,
shadow and springs; the frosted `hudWindow` fallback before macOS 26.

## Left to the builder

- Whether the glass on macOS 26 is `NSGlassEffectView` through an `NSViewRepresentable` or SwiftUI's
  glass effect modifier; pick what renders correctly in this non-key panel and keep it in one view.
- Exact spring constants within ±20 % of the figures above; the gradient's curve.
- How the two-phase unfold is expressed (two `animation(_:value:)` modifiers on separate frame
  modifiers, or an unfold phase enum driven by the model).
- Icon choices for the capsule.

## Testing

Pure logic gets unit tests in `OpenClickyTests`: the model's hover → peek and click → full rules
(including speaking, guide, setup and composer precedence), peek and full sizes, the radius and flare
functions, the gradient stops from a glass level, `IslandComponentSelector` (contextual precedence,
user order, unknown ids, capsule visibility), and the Settings persistence round trip. Visual results
are checked by hand on this Mac (macOS 26, notch display and the external display) against the
states table; the pre-26 fallback is built behind availability but cannot be seen on this Mac, which the
PR says.
