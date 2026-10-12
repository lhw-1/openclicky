//
//  AppIconView.swift
//  OpenClicky
//
//  An app's icon and name by bundle id, as the window's pages show them next to a take or a
//  writing style, cached because a list redraws them on every scroll.
//

import AppKit
import SwiftUI

/// The icon of an app, by bundle id, from the system; a quiet native placeholder for an app that
/// is not on this Mac (or a take that recorded none).
struct AppIconView: View {
    let bundleID: String?
    var size: CGFloat = 18

    var body: some View {
        Group {
            if let image = AppIconCache.shared.icon(for: bundleID) {
                Image(nsImage: image).resizable().interpolation(.high)
            } else {
                RoundedRectangle(cornerRadius: size * 0.22, style: .continuous).fill(Color(nsColor: .quaternaryLabelColor))
            }
        }
        .frame(width: size, height: size)
    }
}

final class AppIconCache {
    static let shared = AppIconCache()
    private var icons: [String: NSImage] = [:]
    private var names: [String: String] = [:]

    func icon(for bundleID: String?) -> NSImage? {
        guard let bundleID else { return nil }
        if let cached = icons[bundleID] { return cached }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        let image = NSWorkspace.shared.icon(forFile: url.path)
        icons[bundleID] = image
        return image
    }

    func name(for bundleID: String) -> String? {
        if let cached = names[bundleID] { return cached }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        let name = (Bundle(url: url)?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (Bundle(url: url)?.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? url.deletingPathExtension().lastPathComponent
        names[bundleID] = name
        return name
    }
}
