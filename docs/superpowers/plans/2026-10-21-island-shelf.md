# Island Shelf Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** An optional Shelf component: drop files, text and links on the island to park them; drag a tile out, or click it to copy; it survives a relaunch.

**Architecture:** A `ShelfStore` (JSON index + image and icon files under Application Support) owned by the HUD manager; a `ShelfDropReader` that turns the drag pasteboard into drops; the island model learns drag-hover, drag-out and a post-drop hold, all of which keep it `.full`; a SwiftUI `DropDelegate` on the island; tiles that are AppKit drag sources.

**Tech Stack:** Swift 6 / SwiftUI / AppKit (`NSPasteboard`, `NSDraggingSession`, `NSWorkspace`), Swift Testing.

**Spec:** `docs/superpowers/specs/2026-10-21-island-components-design.md` (section "Shelf"; "The switchboard" is built: `isOptional`, `enabledIDs`, `enabledComponentIDs`).

## Global Constraints

- Deployment target macOS 14.2; Swift Testing; no new dependencies.
- Copy lower-case and short: "drop to keep", "copied", "drop files, text or links on the island to keep them handy".
- Files are referenced, never copied or moved; only images dropped as data and the Finder icons are written under `~/Library/Application Support/OpenClicky/Shelf/`. Nothing is stat-ed at launch.
- Test command: `cd macos/OpenClicky && xcodebuild test -project OpenClicky.xcodeproj -scheme OpenClicky -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO -only-testing:OpenClickyTests/<Suite>` (the scratch runner `t.sh Suite[,Suite]` wraps it).
- Swift Testing quirk: single literals in `#expect`.
- Commit messages describe OpenClicky's own features; end with `Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>`.

## Review Focus

1. A drop while the shelf is off: nothing happens, the island does not unfold. Task 3 (model ignores drag-hover unless enabled) + Task 4 (delegate validates nothing).
2. A drag that enters and leaves without dropping: the island goes back to resting after the grace period. Task 3.
3. A drag-out that the destination refuses (operation `[]`): the tile stays. Task 5 (drag source policy test).
4. The 41st item: the oldest falls off, and its image/icon files are deleted. Task 1.
5. A corrupt or missing index.json on launch: an empty shelf, no crash. Task 1.

---

### Task 1: Shelf items and the store

**Files:**
- Create: `macos/OpenClicky/OpenClicky/ShelfStore.swift`
- Test: `macos/OpenClicky/OpenClickyTests/ShelfStoreTests.swift`

**Interfaces:**
- Produces: `enum ShelfDrop: Equatable { case file(URL), text(String), link(URL), image(Data) }`; `struct ShelfItem: Codable, Identifiable, Equatable { let id: UUID; let kind: Kind; let title: String; let addedAt: Date; let iconPath: String?; enum Kind: Codable, Equatable { case file(path: String), text(String), link(URL), image(path: String) } ; static func title(for drop: ShelfDrop, now: Date) -> String }`; `@MainActor final class ShelfStore: ObservableObject { static let maximumItems = 40; @Published private(set) var items: [ShelfItem]; init(directory: URL, iconRenderer: ((URL) -> Data?)? = nil, now: @escaping () -> Date = Date.init); @discardableResult func add(_ drops: [ShelfDrop]) -> [ShelfItem]; func remove(id: UUID); func removeAll(); static var defaultDirectory: URL }` — newest first; `index.json` rewritten after each change; images → `<uuid>.png`, icons → `<uuid>-icon.png` (the renderer's data); removing an item deletes its files.

- [ ] **Step 1: Write the failing tests**:

```swift
@MainActor struct ShelfStoreTests {
    func temporaryDirectory() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("shelf-tests-\(UUID().uuidString)", isDirectory: true) }

    @Test func titlesReadLikeTheThingDropped() {
        let noon = Calendar.current.date(bySettingHour: 12, minute: 5, second: 0, of: Date())!
        #expect(ShelfItem.title(for: .file(URL(fileURLWithPath: "/tmp/Report final.pdf")), now: noon) == "Report final.pdf")
        #expect(ShelfItem.title(for: .link(URL(string: "https://example.com/a/b")!), now: noon) == "example.com")
        #expect(ShelfItem.title(for: .text("  first line of a long note that keeps going and going\nsecond"), now: noon) == "first line of a long note that keeps goi")
        #expect(ShelfItem.title(for: .image(Data()), now: noon) == "image 12:05")
    }

    @Test func dropsBecomeItemsNewestFirstAndSurviveARelaunch() throws {
        let directory = temporaryDirectory()
        let store = ShelfStore(directory: directory)
        store.add([.text("hello")])
        store.add([.link(URL(string: "https://example.com")!)])
        #expect(store.items.map(\.title) == ["example.com", "hello"])
        let again = ShelfStore(directory: directory)
        #expect(again.items == store.items)
    }

    @Test func imagesAndIconsAreFilesInTheShelfFolderAndGoWithTheirItem() throws {
        let directory = temporaryDirectory()
        let store = ShelfStore(directory: directory, iconRenderer: { _ in Data([1, 2, 3]) })
        let items = store.add([.image(Data([9, 9])), .file(URL(fileURLWithPath: "/tmp/x.txt"))])
        guard case .image(let imagePath) = items[0].kind else { Issue.record("not an image"); return }
        #expect(FileManager.default.fileExists(atPath: imagePath))
        let iconPath = try #require(items[1].iconPath)
        #expect(FileManager.default.fileExists(atPath: iconPath))
        store.remove(id: items[0].id)
        store.remove(id: items[1].id)
        #expect(!FileManager.default.fileExists(atPath: imagePath))
        #expect(!FileManager.default.fileExists(atPath: iconPath))
        #expect(store.items.isEmpty)
    }

    @Test func theFortyFirstItemPushesTheOldestOut() {
        let store = ShelfStore(directory: temporaryDirectory())
        for index in 0..<41 { store.add([.text("note \(index)")]) }
        #expect(store.items.count == 40)
        #expect(store.items.last?.title == "note 1")
    }

    @Test func aBrokenIndexMeansAnEmptyShelf() throws {
        let directory = temporaryDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: directory.appendingPathComponent("index.json"))
        #expect(ShelfStore(directory: directory).items.isEmpty)
    }
}
```

- [ ] **Step 2: Run** `ShelfStoreTests`. Expected: build FAILS (types missing).
- [ ] **Step 3: Implement** `ShelfStore.swift`. `add` prepends in the order given (so the first drop ends up newest? No: keep the order given, all of them ahead of the existing items: `new + items`), trims to 40 deleting the files of what falls off, saves. `title(for:)` text: trim whitespace, first line, prefix 40. Link: `host ?? absoluteString`. Image: `"image " + HH:mm` (`DateFormatter` with `dateFormat = "HH:mm"`). `defaultDirectory` = `~/Library/Application Support/OpenClicky/Shelf`.
- [ ] **Step 4: Run.** Expected: PASS.
- [ ] **Step 5: Commit** `Shelf: items and a store that keeps them across launches`.

### Task 2: Reading a drop from the pasteboard

**Files:**
- Modify: `macos/OpenClicky/OpenClicky/ShelfStore.swift`
- Test: `macos/OpenClicky/OpenClickyTests/ShelfStoreTests.swift`

**Interfaces:**
- Produces: `enum ShelfDropReader { static let acceptedTypes: [NSPasteboard.PasteboardType] = [.fileURL, .URL, .string, .tiff, .png]; static func drops(from pasteboard: NSPasteboard) -> [ShelfDrop] }`; `extension ShelfItem { func write(to pasteboard: NSPasteboard); var pasteboardWriter: NSPasteboardWriting }`.

- [ ] **Step 1: Write the failing tests**:

```swift
@Test func filesComeFirstThenALinkThenAnImageThenText() {
    let pasteboard = NSPasteboard(name: NSPasteboard.Name("shelf-tests-\(UUID().uuidString)"))
    pasteboard.clearContents()
    pasteboard.writeObjects([URL(fileURLWithPath: "/tmp/a.txt") as NSURL, URL(fileURLWithPath: "/tmp/b.txt") as NSURL])
    #expect(ShelfDropReader.drops(from: pasteboard) == [.file(URL(fileURLWithPath: "/tmp/a.txt")), .file(URL(fileURLWithPath: "/tmp/b.txt"))])
    pasteboard.clearContents()
    pasteboard.setString("https://example.com/page", forType: .string)
    #expect(ShelfDropReader.drops(from: pasteboard) == [.link(URL(string: "https://example.com/page")!)])
    pasteboard.clearContents()
    pasteboard.setString("just words", forType: .string)
    #expect(ShelfDropReader.drops(from: pasteboard) == [.text("just words")])
    pasteboard.clearContents()
    let image = NSImage(size: NSSize(width: 2, height: 2))
    image.lockFocus(); NSColor.red.setFill(); NSRect(x: 0, y: 0, width: 2, height: 2).fill(); image.unlockFocus()
    pasteboard.writeObjects([image])
    let drops = ShelfDropReader.drops(from: pasteboard)
    #expect(drops.count == 1)
    if case .image(let data) = drops[0] { #expect(!data.isEmpty) } else { Issue.record("not an image") }
    pasteboard.clearContents()
    #expect(ShelfDropReader.drops(from: pasteboard).isEmpty)
}

@Test func anItemWritesItselfBackToAPasteboard() {
    let pasteboard = NSPasteboard(name: NSPasteboard.Name("shelf-tests-\(UUID().uuidString)"))
    ShelfItem(id: UUID(), kind: .text("hi"), title: "hi", addedAt: Date(), iconPath: nil).write(to: pasteboard)
    #expect(pasteboard.string(forType: .string) == "hi")
    ShelfItem(id: UUID(), kind: .file(path: "/tmp/a.txt"), title: "a.txt", addedAt: Date(), iconPath: nil).write(to: pasteboard)
    #expect(pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] == [URL(fileURLWithPath: "/tmp/a.txt")])
}
```

- [ ] **Step 2: Run.** Expected: build FAILS.
- [ ] **Step 3: Implement**: file URLs via `readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])`; else a web URL (`readObjects` with `NSURL`, non-file, or a string that parses as http(s) with a host) → `.link`; else `NSImage(pasteboard:)` → PNG data (`NSBitmapImageRep` from `tiffRepresentation`) → `.image`; else a non-empty trimmed string → `.text`. `write(to:)` clears and writes the writer (`NSURL` for file/link/image file, `NSString` for text).
- [ ] **Step 4: Run.** Expected: PASS.
- [ ] **Step 5: Commit** `Shelf: what a drop on the island becomes, and how an item copies back out`.

### Task 3: The island model knows about drags

**Files:**
- Modify: `macos/OpenClicky/OpenClicky/IslandComponents.swift` (`IslandContext.isDragHovering`, `contextualKey`, `IslandComponentRegistry.shelfID`)
- Modify: `macos/OpenClicky/OpenClicky/NotchHUD.swift` (`NotchHUDModel`)
- Test: `macos/OpenClicky/OpenClickyTests/NotchHUDModelTests.swift`, `IslandComponentSelectorTests.swift`

**Interfaces:**
- Produces: `IslandContext.isDragHovering: Bool` (default false; `contextualKey` returns `IslandComponentRegistry.shelfID` ("shelf") first when true); `NotchHUDModel.setDragHovering(_:)` (ignored unless `enabledComponentIDs` contains `shelf`; keeps `context.isDragHovering` in step and `setContext` preserves it), `setDragOut(_:)`, `holdOpenAfterDrop()` (1.5 s), `isDragHovering`, `isDraggingOut`; `reconcile` targets `.full` while any of the three is set and no card/composer/setup outranks it.

- [ ] **Step 1: Write the failing tests**:

```swift
// IslandComponentSelectorTests
@Test func aDragOverTheIslandOutranksEveryOtherMoment() {
    var context = IslandContext.idle
    context.isTakeLive = true
    context.isDragHovering = true
    #expect(context.contextualKey == "shelf")
    context.isDragHovering = false
    #expect(context.contextualKey == "transcript")
}
// NotchHUDModelTests
@Test func aDragOverTheIslandUnfoldsItOnlyWhenTheShelfIsOn() async throws {
    let defaults = UserDefaults(suiteName: "island-model-shelf")!
    defaults.removePersistentDomain(forName: "island-model-shelf")
    let registry = IslandComponentSelectorTests().registry + [IslandComponentSelectorTests.Stub(id: "shelf", isOptional: true) { _ in true }]
    let model = NotchHUDModel(geometry: notchModel().geometry, registry: registry, componentSettings: IslandComponentSettings(defaults: defaults))
    model.setDragHovering(true)
    #expect(model.expansion == .collapsed)
    var settings = IslandComponentSettings(defaults: defaults)
    settings.enabledIDs = ["shelf"]
    model.componentSettings = settings
    model.setDragHovering(true)
    #expect(model.expansion == .full)
    #expect(model.selection.active == "shelf")
    model.setContext(.idle)                       // the manager's context never clears the drag
    #expect(model.context.isDragHovering)
    model.setDragHovering(false)
    try await waitFor(model, .collapsed)
    #expect(model.expansion == .collapsed)
    model.setDragOut(true)
    #expect(model.expansion == .full)
    model.setDragOut(false)
    model.holdOpenAfterDrop()
    #expect(model.expansion == .full)
    try await waitFor(model, .collapsed)
    #expect(model.expansion == .collapsed)
}
```

- [ ] **Step 2: Run** both suites. Expected: FAIL (no `isDragHovering`, no `setDragHovering`).
- [ ] **Step 3: Implement** as the Interfaces block says. `holdOpenAfterDrop` sets `isHoldingAfterDrop = true`, reconciles, and a `Task` clears it after 1.5 s then reconciles. In `reconcile`, after the `isPinnedOpen` branch: `else if (isDragHovering || isDraggingOut || isHoldingAfterDrop) && !isSetupInProgress { target = .full }`.
- [ ] **Step 4: Run.** Expected: PASS.
- [ ] **Step 5: Commit** `Island: a drag over the island, a drag out of it and a fresh drop all hold it open`.

### Task 4: The island is a drop target

**Files:**
- Create: `macos/OpenClicky/OpenClicky/IslandDrop.swift`
- Modify: `macos/OpenClicky/OpenClicky/NotchHUD.swift` (the manager owns `shelf: ShelfStore`; `NotchHUDView` adds `.onDrop(of:delegate:)`)
- Test: `macos/OpenClicky/OpenClickyTests/ShelfStoreTests.swift`

**Interfaces:**
- Consumes: Tasks 1–3.
- Produces: `struct IslandDropDelegate: DropDelegate { let model: NotchHUDModel; let shelf: ShelfStore; init(model:shelf:) }` — `validateDrop` true only when `model.enabledComponentIDs` contains `shelf`; `dropEntered` → `model.setDragHovering(true)`; `dropExited` → `false`; `performDrop` reads `NSPasteboard(name: .drag)` through `ShelfDropReader`, adds to the store, calls `setDragHovering(false)` and `holdOpenAfterDrop()`, returns whether anything was added. A pure helper `static func accepts(enabled: Set<String>) -> Bool` carries the rule. `NotchHUDManager.shelf = ShelfStore(directory: ShelfStore.defaultDirectory, iconRenderer: ShelfStore.finderIcon)` with `static func finderIcon(for url: URL) -> Data?` (64 pt `NSWorkspace.shared.icon(forFile:)` → PNG).

- [ ] **Step 1: Write the failing test**:

```swift
@Test func theIslandTakesDropsOnlyWhenTheShelfIsOn() {
    #expect(!IslandDropDelegate.accepts(enabled: ["shortcuts", "system"]))
    #expect(IslandDropDelegate.accepts(enabled: ["shortcuts", "shelf"]))
}
```

- [ ] **Step 2: Run.** Expected: build FAILS.
- [ ] **Step 3: Implement**; attach `.onDrop(of: [.fileURL, .url, .utf8PlainText, .image], delegate: IslandDropDelegate(model: model, shelf: companionManager.notchHUDManager.shelf))` to the island `ZStack` in `NotchHUDView` (on the outer ZStack so the collapsed notch, the peek and the open panel all take drops).
- [ ] **Step 4: Run** `ShelfStoreTests`, then build Debug. Expected: PASS, BUILD SUCCEEDED.
- [ ] **Step 5: Commit** `Island: dropping on the island hands the drop to the shelf`.

### Task 5: The shelf view and its tiles

**Files:**
- Create: `macos/OpenClicky/OpenClicky/ShelfIslandView.swift`
- Modify: `macos/OpenClicky/OpenClicky/IslandComponents.swift` (registry adds `ShelfIslandComponent`), `UITour.swift` (shot `04d-panel-shelf`), `AGENTS.md`
- Test: `macos/OpenClicky/OpenClickyTests/ShelfStoreTests.swift`, `IslandComponentSelectorTests.swift`

**Interfaces:**
- Produces: `struct ShelfIslandComponent: IslandComponent` (id `shelf`, "Shelf", `tray`, 84, optional, always available); `struct ShelfIslandView: View` (`@ObservedObject shelf`, `@ObservedObject model`); `struct ShelfTileDragView: NSViewRepresentable` wrapping `ShelfTileDragSourceView: NSView, NSDraggingSource` (mouse-down + 4 pt → session with the item's writer and a snapshot drag image; `draggingSession(_:endedAt:operation:)` → `onDragEnded(operation)`; a plain mouse-up → `onClick`); `enum ShelfDragPolicy { static func removesAfterDrag(operation: NSDragOperation) -> Bool }` (true unless `[]`); `static func sourceOperationMask(for kind: ShelfItem.Kind) -> NSDragOperation` (`[.copy, .move]` for a file, `.copy` otherwise).

- [ ] **Step 1: Write the failing tests**:

```swift
// ShelfStoreTests
@Test func aTileLeavesTheShelfOnlyWhenTheDropLanded() {
    #expect(ShelfDragPolicy.removesAfterDrag(operation: .copy))
    #expect(ShelfDragPolicy.removesAfterDrag(operation: .move))
    #expect(!ShelfDragPolicy.removesAfterDrag(operation: []))
    #expect(ShelfDragPolicy.sourceOperationMask(for: .file(path: "/tmp/a")) == [.copy, .move])
    #expect(ShelfDragPolicy.sourceOperationMask(for: .text("a")) == .copy)
}
// IslandComponentSelectorTests: extend theRealRegistryHasTheSystemComponentAsAnOptionalFourth → ids ["shortcuts","transcript","agent","system","shelf"], heights [45,52,52,70,84], optional [false,false,false,true,true]; rename to theRealRegistryListsTheBuiltInsThenTheExtras.
```

- [ ] **Step 2: Run.** Expected: FAIL.
- [ ] **Step 3: Implement** the view: a `ScrollView(.horizontal)` of tiles 56 × 70 (icon 40 pt: the saved icon png for a file, the image itself, `link` / `text.alignleft` symbols; title 11 pt text2, one line, `.truncationMode(.middle)`); hover shows a 16 pt `xmark.circle.fill` top-trailing that removes; a dashed `RoundedRectangle` "drop to keep" tile leads while `model.isDragHovering`; empty state centred in text3; each tile wrapped in `ShelfTileDragView` with `onClick` (write to `.general`, show "copied" 1.2 s) and `onDragEnded` (remove when the policy says so; `model.setDragOut(false)`), `onDragBegan` → `model.setDragOut(true)`; a file that no longer exists at drag start → remove, no session. The tour adds two demo items (`shelf.add([.text("remember the milk"), .link(URL(string: "https://example.com")!)])`), shows `shelf`, shoots `04d-panel-shelf`, then `removeAll()`.
- [ ] **Step 4: Run** the suites, build Debug, run the island tour (when the screen is unlocked) and look at `04d-panel-shelf`. Expected: PASS; two tiles under the band.
- [ ] **Step 5: Commit** `Island: a Shelf component; tiles drag out, click to copy`.
