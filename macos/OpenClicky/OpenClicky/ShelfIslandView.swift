//
//  ShelfIslandView.swift
//  OpenClicky
//
//  The Shelf component: a row of tiles for what was dropped on the island. A tile drags out
//  (an AppKit drag session, so the shelf learns whether the drop landed and lets the tile go),
//  a click copies it, hovering shows a cross that removes it.
//

import AppKit
import SwiftUI

/// An extra the user turns on in Settings: drop things on the island, reach for them later.
struct ShelfIslandComponent: IslandComponent {
    let id = IslandComponentRegistry.shelfID
    let title = "Shelf"
    let symbolName = "tray"
    let preferredHeight: CGFloat = 84
    let isOptional = true
    func isAvailable(in context: IslandContext) -> Bool { true }
    @MainActor func makeView(companionManager: CompanionManager, model: NotchHUDModel) -> AnyView {
        AnyView(ShelfIslandView(shelf: companionManager.notchHUDManager.shelf, model: model))
    }
}

/// When a tile dragged out leaves the shelf, and what a drag may do at its destination.
enum ShelfDragPolicy {
    /// The destination took it (a copy or a move): the tile goes. A refused drop keeps it.
    static func removesAfterDrag(operation: NSDragOperation) -> Bool {
        !operation.isEmpty
    }

    /// A file may be moved or copied as Finder decides; everything else is copied.
    static func sourceOperationMask(for kind: ShelfItem.Kind) -> NSDragOperation {
        if case .file = kind { return [.copy, .move] }
        return .copy
    }
}

struct ShelfIslandView: View {
    @ObservedObject var shelf: ShelfStore
    @ObservedObject var model: NotchHUDModel
    @State private var hoveredID: UUID?
    @State private var copiedID: UUID?

    private let tileSize = CGSize(width: 76, height: 70)

    var body: some View {
        Group {
            if shelf.items.isEmpty && !model.isDragHovering {
                Text("drop files, text or links on the island to keep them handy")
                    .font(.system(size: 12))
                    .foregroundColor(DS.HUD.text3)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 8) {
                        if model.isDragHovering {
                            dropTarget
                        }
                        ForEach(shelf.items) { item in
                            tile(for: item)
                        }
                    }
                    .padding(.vertical, 2)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            }
        }
        .animation(.easeInOut(duration: 0.18), value: shelf.items.map(\.id))
        .animation(.easeInOut(duration: 0.18), value: model.isDragHovering)
    }

    /// The leading tile while a drag hovers: where the drop will land.
    private var dropTarget: some View {
        VStack(spacing: 6) {
            Image(systemName: "arrow.down.to.line")
                .font(.system(size: 16, weight: .medium))
                .foregroundColor(DS.HUD.text2)
                .frame(width: 40, height: 40)
            Text("drop to keep")
                .font(.system(size: 11))
                .foregroundColor(DS.HUD.text3)
        }
        .frame(width: tileSize.width, height: tileSize.height)
        .background(RoundedRectangle(cornerRadius: DS.HUD.tileRadius, style: .continuous).strokeBorder(DS.HUD.text3, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
        .transition(.opacity)
    }

    private func tile(for item: ShelfItem) -> some View {
        ZStack(alignment: .topTrailing) {
            VStack(spacing: 4) {
                ShelfTileIcon(item: item)
                    .frame(width: 40, height: 40)
                Text(copiedID == item.id ? "copied" : item.title)
                    .font(.system(size: 11))
                    .foregroundColor(copiedID == item.id ? DS.HUD.text : DS.HUD.text2)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(width: tileSize.width - 4)
            }
            .frame(width: tileSize.width, height: tileSize.height)
            .background(RoundedRectangle(cornerRadius: DS.HUD.tileRadius, style: .continuous).fill(hoveredID == item.id ? (model.glassLevel > 0 ? DS.HUD.glassTileHovered : DS.HUD.surfaceRaisedSoft) : Color.clear))
            .overlay(
                ShelfTileDragView(
                    item: item,
                    onClick: { copy(item) },
                    onDragBegan: { model.setDragOut(true) },
                    onDragEnded: { operation in
                        model.setDragOut(false)
                        if ShelfDragPolicy.removesAfterDrag(operation: operation) { shelf.remove(id: item.id) }
                    },
                    onMissingFile: { shelf.remove(id: item.id) }
                )
            )
            if hoveredID == item.id {
                Button(action: { shelf.remove(id: item.id) }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 14))
                        .foregroundColor(DS.HUD.text2)
                        .background(Circle().fill(DS.HUD.island).padding(2))
                }
                .buttonStyle(.plain)
                .pointerCursor()
                .help("remove from the shelf")
                .offset(x: 4, y: -4)
            }
        }
        .onHover { hovering in
            if hovering { hoveredID = item.id } else if hoveredID == item.id { hoveredID = nil }
        }
        .help(item.title)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(item.title)
        .transition(.opacity)
    }

    private func copy(_ item: ShelfItem) {
        item.write(to: .general)
        copiedID = item.id
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            if copiedID == item.id { copiedID = nil }
        }
    }
}

/// The tile's picture: the saved Finder icon or the image itself, a symbol for a link or a note.
private struct ShelfTileIcon: View {
    let item: ShelfItem

    var body: some View {
        switch item.kind {
        case .file:
            if let iconPath = item.iconPath, let image = NSImage(contentsOfFile: iconPath) {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
            } else {
                symbol("doc")
            }
        case .image(let path):
            if let image = NSImage(contentsOfFile: path) {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
                    .frame(width: 40, height: 40)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            } else {
                symbol("photo")
            }
        case .link:
            symbol("link")
        case .text:
            symbol("text.alignleft")
        }
    }

    private func symbol(_ name: String) -> some View {
        Image(systemName: name)
            .font(.system(size: 18, weight: .medium))
            .foregroundColor(DS.HUD.text2)
    }
}

// MARK: - Drag source

/// An AppKit layer over a tile: a press and 4 pt of movement begin a drag session with the
/// item; a release without movement is a click. The session's end says whether the drop landed.
struct ShelfTileDragView: NSViewRepresentable {
    let item: ShelfItem
    let onClick: () -> Void
    let onDragBegan: () -> Void
    let onDragEnded: (NSDragOperation) -> Void
    let onMissingFile: () -> Void

    func makeNSView(context: Context) -> ShelfTileDragSourceView {
        let view = ShelfTileDragSourceView()
        update(view)
        return view
    }

    func updateNSView(_ nsView: ShelfTileDragSourceView, context: Context) {
        update(nsView)
    }

    private func update(_ view: ShelfTileDragSourceView) {
        view.item = item
        view.onClick = onClick
        view.onDragBegan = onDragBegan
        view.onDragEnded = onDragEnded
        view.onMissingFile = onMissingFile
    }
}

final class ShelfTileDragSourceView: NSView, NSDraggingSource {
    var item: ShelfItem?
    var onClick: (() -> Void)?
    var onDragBegan: (() -> Void)?
    var onDragEnded: ((NSDragOperation) -> Void)?
    var onMissingFile: (() -> Void)?

    private var pressLocation: NSPoint?
    private var isDragging = false

    override func mouseDown(with event: NSEvent) {
        pressLocation = event.locationInWindow
        isDragging = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard let pressLocation, !isDragging, let item else { return }
        let moved = hypot(event.locationInWindow.x - pressLocation.x, event.locationInWindow.y - pressLocation.y)
        guard moved >= 4 else { return }
        if case .file(let path) = item.kind, !FileManager.default.fileExists(atPath: path) {
            self.pressLocation = nil
            onMissingFile?()
            return
        }
        isDragging = true
        let draggingItem = NSDraggingItem(pasteboardWriter: item.pasteboardWriter)
        draggingItem.setDraggingFrame(bounds, contents: snapshot())
        onDragBegan?()
        beginDraggingSession(with: [draggingItem], event: event, source: self)
    }

    override func mouseUp(with event: NSEvent) {
        defer { pressLocation = nil }
        guard pressLocation != nil, !isDragging else { return }
        onClick?()
    }

    /// The tile as the drag image: the SwiftUI tile underneath this layer.
    private func snapshot() -> NSImage? {
        guard let target = superview, let rep = target.bitmapImageRepForCachingDisplay(in: target.bounds) else { return nil }
        target.cacheDisplay(in: target.bounds, to: rep)
        let image = NSImage(size: target.bounds.size)
        image.addRepresentation(rep)
        return image
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        guard let item else { return [] }
        return ShelfDragPolicy.sourceOperationMask(for: item.kind)
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        isDragging = false
        pressLocation = nil
        onDragEnded?(operation)
    }
}
