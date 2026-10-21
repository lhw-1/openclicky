//
//  ShelfStore.swift
//  OpenClicky
//
//  The shelf: what a drop on the island becomes, and the store that keeps the items across
//  launches. Files are referenced, never copied: dragging one out moves or copies as the
//  destination decides, the shelf only hands the URL over. Images dropped as data and the Finder
//  icons rendered at drop time are the only files written, under Application Support.
//

import AppKit
import Combine
import Foundation

/// What a drop on the island turned out to be.
enum ShelfDrop: Equatable {
    case file(URL)
    case text(String)
    case link(URL)
    case image(Data)
}

/// One tile on the shelf.
struct ShelfItem: Codable, Identifiable, Equatable {
    enum Kind: Codable, Equatable {
        case file(path: String)
        case text(String)
        case link(URL)
        case image(path: String)
    }

    let id: UUID
    let kind: Kind
    let title: String
    let addedAt: Date
    /// A file's Finder icon, rendered once at drop time so the tile never touches the file again.
    let iconPath: String?

    /// A file's name, a link's host, a note's first line, "image HH:mm".
    static func title(for drop: ShelfDrop, now: Date) -> String {
        switch drop {
        case .file(let url):
            return url.lastPathComponent
        case .link(let url):
            return url.host ?? url.absoluteString
        case .text(let text):
            let firstLine = text.trimmingCharacters(in: .whitespacesAndNewlines).split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
            return String(firstLine.prefix(40))
        case .image:
            let formatter = DateFormatter()
            formatter.dateFormat = "HH:mm"
            return "image \(formatter.string(from: now))"
        }
    }
}

/// One per app: the items, newest first, at most 40, in `index.json` under `directory`.
@MainActor
final class ShelfStore: ObservableObject {
    static let maximumItems = 40

    static var defaultDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/OpenClicky/Shelf", isDirectory: true)
    }

    @Published private(set) var items: [ShelfItem] = []

    private let directory: URL
    private let iconRenderer: ((URL) -> Data?)?
    private let now: () -> Date
    private var indexURL: URL { directory.appendingPathComponent("index.json") }

    init(directory: URL, iconRenderer: ((URL) -> Data?)? = nil, now: @escaping () -> Date = Date.init) {
        self.directory = directory
        self.iconRenderer = iconRenderer
        self.now = now
        load()
    }

    /// The drops become items ahead of everything already there, in the order given; what falls
    /// off the end of the 40 loses its files.
    @discardableResult
    func add(_ drops: [ShelfDrop]) -> [ShelfItem] {
        guard !drops.isEmpty else { return [] }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let added = drops.map(makeItem)
        var next = added + items
        if next.count > Self.maximumItems {
            for item in next[Self.maximumItems...] { deleteFiles(of: item) }
            next = Array(next.prefix(Self.maximumItems))
        }
        items = next
        save()
        return added
    }

    func remove(id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        deleteFiles(of: items[index])
        items.remove(at: index)
        save()
    }

    func removeAll() {
        items.forEach(deleteFiles)
        items = []
        save()
    }

    // MARK: Items

    private func makeItem(from drop: ShelfDrop) -> ShelfItem {
        let id = UUID()
        let addedAt = now()
        let title = ShelfItem.title(for: drop, now: addedAt)
        switch drop {
        case .file(let url):
            var iconPath: String?
            if let data = iconRenderer?(url) {
                let iconURL = directory.appendingPathComponent("\(id.uuidString)-icon.png")
                if (try? data.write(to: iconURL)) != nil { iconPath = iconURL.path }
            }
            return ShelfItem(id: id, kind: .file(path: url.path), title: title, addedAt: addedAt, iconPath: iconPath)
        case .text(let text):
            return ShelfItem(id: id, kind: .text(text), title: title, addedAt: addedAt, iconPath: nil)
        case .link(let url):
            return ShelfItem(id: id, kind: .link(url), title: title, addedAt: addedAt, iconPath: nil)
        case .image(let data):
            let imageURL = directory.appendingPathComponent("\(id.uuidString).png")
            try? data.write(to: imageURL)
            return ShelfItem(id: id, kind: .image(path: imageURL.path), title: title, addedAt: addedAt, iconPath: nil)
        }
    }

    private func deleteFiles(of item: ShelfItem) {
        if case .image(let path) = item.kind { try? FileManager.default.removeItem(atPath: path) }
        if let iconPath = item.iconPath { try? FileManager.default.removeItem(atPath: iconPath) }
    }

    // MARK: Disk

    /// A missing or broken index is an empty shelf. Nothing is stat-ed: a file item's path may
    /// point at a Desktop file, and checking it at launch would raise macOS's folder prompt.
    private func load() {
        guard let data = try? Data(contentsOf: indexURL),
              let decoded = try? JSONDecoder().decode([ShelfItem].self, from: data) else {
            items = []
            return
        }
        items = decoded
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(items) else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: indexURL, options: .atomic)
    }
}

// MARK: - The pasteboard

/// Reads the drag pasteboard: files first, else a web link, else an image, else text.
enum ShelfDropReader {
    static let acceptedTypes: [NSPasteboard.PasteboardType] = [.fileURL, .URL, .string, .tiff, .png]

    static func drops(from pasteboard: NSPasteboard) -> [ShelfDrop] {
        if let files = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !files.isEmpty {
            return files.map { .file($0) }
        }
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [:]) as? [URL], let link = urls.first(where: { !$0.isFileURL && $0.host != nil }) {
            return [.link(link)]
        }
        if let string = pasteboard.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines), !string.isEmpty {
            if let link = webLink(in: string) { return [.link(link)] }
            return [.text(string)]
        }
        if let image = NSImage(pasteboard: pasteboard), let data = pngData(of: image) {
            return [.image(data)]
        }
        return []
    }

    /// A string that is one http(s) URL with a host; anything else is a note.
    private static func webLink(in string: String) -> URL? {
        guard !string.contains(where: \.isWhitespace), let url = URL(string: string), let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https", url.host != nil else { return nil }
        return url
    }

    private static func pngData(of image: NSImage) -> Data? {
        guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff) else { return nil }
        return bitmap.representation(using: .png, properties: [:])
    }
}

extension ShelfItem {
    /// What a tile hands over: the file's URL, the note, the link, or the saved image's file URL.
    var pasteboardWriter: NSPasteboardWriting {
        switch kind {
        case .file(let path), .image(let path): return URL(fileURLWithPath: path) as NSURL
        case .text(let text): return text as NSString
        case .link(let url): return url as NSURL
        }
    }

    /// A click on a tile: the item replaces what is on the pasteboard.
    func write(to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        pasteboard.writeObjects([pasteboardWriter])
    }
}
