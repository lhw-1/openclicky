//
//  ShelfStoreTests.swift
//  OpenClickyTests
//
//  The shelf: what a drop becomes, how items are kept across launches, and the tile policies.
//

import AppKit
import Foundation
import Testing
@testable import OpenClicky

@MainActor
struct ShelfStoreTests {
    func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("shelf-tests-\(UUID().uuidString)", isDirectory: true)
    }

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
