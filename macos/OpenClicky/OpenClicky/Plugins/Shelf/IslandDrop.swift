//
//  IslandDrop.swift
//  OpenClicky
//
//  The island as a drop target: a drag from another app unfolds it to the shelf, a drop adds
//  what was dragged, and the island stays open a moment so the new tile is seen. Only with the
//  shelf on; otherwise the island takes nothing and does not react.
//

import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct IslandDropDelegate: DropDelegate {
    let model: NotchHUDModel
    let shelf: ShelfStore

    /// What the island accepts, by type: files, web links, text and images.
    static let acceptedTypes: [UTType] = [.fileURL, .url, .utf8PlainText, .image]

    /// Drops land only when the shelf is one of the components the user turned on.
    static func accepts(enabled: Set<String>) -> Bool {
        enabled.contains(IslandPluginRegistry.shelfID)
    }

    /// And never the island's own tiles (any display): they carry a marker type.
    static func accepts(enabled: Set<String>, pasteboardTypes: [NSPasteboard.PasteboardType]) -> Bool {
        accepts(enabled: enabled) && !pasteboardTypes.contains(ShelfDragPolicy.markerType)
    }

    func validateDrop(info: DropInfo) -> Bool {
        Self.accepts(enabled: model.enabledComponentIDs, pasteboardTypes: NSPasteboard(name: .drag).types ?? [])
    }

    func dropEntered(info: DropInfo) {
        model.setDragHovering(true)
    }

    func dropExited(info: DropInfo) {
        model.setDragHovering(false)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .copy)
    }

    func performDrop(info: DropInfo) -> Bool {
        let drops = ShelfDropReader.drops(from: NSPasteboard(name: .drag))
        let added = shelf.add(drops)
        model.setDragHovering(false)
        if !added.isEmpty { model.holdOpenAfterDrop() }
        return !added.isEmpty
    }
}

extension ShelfStore {
    /// A file's Finder icon as a 64 pt PNG, rendered once at drop time.
    static func finderIcon(for url: URL) -> Data? {
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        icon.size = NSSize(width: 64, height: 64)
        guard let tiff = icon.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff) else { return nil }
        return bitmap.representation(using: .png, properties: [:])
    }
}
