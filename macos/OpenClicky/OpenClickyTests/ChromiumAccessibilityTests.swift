//
//  ChromiumAccessibilityTests.swift
//  OpenClickyTests
//
//  Which apps get the "an assistive client is here" write: the Chromium family, told by the
//  renderer helper in the bundle, never a native AppKit app.
//

import Foundation
@testable import OpenClicky
import Testing

struct ChromiumAccessibilityTests {
    private func makeBundle(name: String, rendererHelperAt relativePath: String?) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("chromium-tests-\(UUID().uuidString)", isDirectory: true)
        let bundleURL = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL.appendingPathComponent("Contents/Frameworks"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: bundleURL.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
        if let relativePath {
            try FileManager.default.createDirectory(at: bundleURL.appendingPathComponent(relativePath), withIntermediateDirectories: true)
        }
        return bundleURL
    }

    @Test func chromeKeepsItsRendererHelperInsideItsFramework() throws {
        let chrome = try makeBundle(name: "Google Chrome.app", rendererHelperAt:
            "Contents/Frameworks/Google Chrome Framework.framework/Versions/155.0.8059.40/Helpers/Google Chrome Helper (Renderer).app")
        #expect(ChromiumAccessibility.isChromiumBased(bundleURL: chrome))
    }

    @Test func electronAndCEFAppsKeepItNextToTheFramework() throws {
        let electron = try makeBundle(name: "Claude.app", rendererHelperAt: "Contents/Frameworks/Claude Helper (Renderer).app")
        let cef = try makeBundle(name: "OBS.app", rendererHelperAt: "Contents/Frameworks/OBS Helper (Renderer).app")
        #expect(ChromiumAccessibility.isChromiumBased(bundleURL: electron))
        #expect(ChromiumAccessibility.isChromiumBased(bundleURL: cef))
    }

    @Test func aNativeAppIsLeftAlone() throws {
        let native = try makeBundle(name: "TextEdit.app", rendererHelperAt: nil)
        let withOtherFrameworks = try makeBundle(name: "Sparkle User.app", rendererHelperAt: "Contents/Frameworks/Sparkle.framework/Versions/B/Resources")
        let noFrameworksFolder = FileManager.default.temporaryDirectory.appendingPathComponent("not-there-\(UUID().uuidString).app")
        #expect(!ChromiumAccessibility.isChromiumBased(bundleURL: native))
        #expect(!ChromiumAccessibility.isChromiumBased(bundleURL: withOtherFrameworks))
        #expect(!ChromiumAccessibility.isChromiumBased(bundleURL: noFrameworksFolder))
    }

    /// The installed Chrome, when this Mac has one: the real layout, not the one the tests drew.
    @Test func theInstalledChromeIsRecognised() {
        let chromeURL = URL(fileURLWithPath: "/Applications/Google Chrome.app")
        guard FileManager.default.fileExists(atPath: chromeURL.path) else { return }
        #expect(ChromiumAccessibility.isChromiumBased(bundleURL: chromeURL))
    }
}
