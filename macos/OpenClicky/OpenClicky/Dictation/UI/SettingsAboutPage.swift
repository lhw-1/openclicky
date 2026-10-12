//
//  SettingsAboutPage.swift
//  OpenClicky
//
//  Settings → About: the version, the source and reporting a bug. Software updates are on
//  General, where macOS keeps its own; their rows are drawn here.
//

import AppKit
import SwiftUI

extension SettingsCatalog {
    func aboutItems() -> [SettingsItem] {
        [
            SettingsItem(
                id: "about.app", page: .about, section: "",
                title: "OpenClicky", detail: "Version \(AppVersion.shortVersion) (\(AppVersion.buildNumber)) · Open source, MIT",
                keywords: ["version", "about", "build", "mit", "license"],
                view: AnyView(AboutAppRow())),
            SettingsItem(
                id: "about.source", page: .about, section: "Help",
                title: "Source code", detail: "Issues and pull requests welcome.",
                keywords: ["github", "source", "license", "mit", "code"],
                view: AnyView(SettingsRow(title: "Source code", detail: "Issues and pull requests welcome.") {
                    Button("GitHub ↗") { openExternalLink("https://github.com/prasanthsasikumar/openclicky") }
                        .pointerCursor()
                })),
            SettingsItem(
                id: "about.reportBug", page: .about, section: "Help",
                title: "Report a bug", detail: "Attach the log — it lists what each take did, not what you said.",
                keywords: ["bug", "log", "issue", "problem", "feedback", "app.log"],
                view: AnyView(SettingsRow(title: "Report a bug", detail: "Attach the log — it lists what each take did, not what you said.") {
                    HStack(spacing: 8) {
                        Button("Show Log") { NSWorkspace.shared.activateFileViewerSelecting([AppLog.fileURL]) }
                            .pointerCursor()
                        Button("Open Issues ↗") { openExternalLink("https://github.com/prasanthsasikumar/openclicky/issues") }
                            .pointerCursor()
                    }
                })),
        ]
    }
}

/// The app's icon, name and version.
private struct AboutAppRow: View {
    var body: some View {
        HStack(spacing: 12) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 44, height: 44)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("OpenClicky").font(.system(size: 15, weight: .semibold))
                Text("Version \(AppVersion.shortVersion) (\(AppVersion.buildNumber)) · Open source, MIT")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            Spacer()
        }
        .padding(.vertical, 6)
    }
}

struct AutomaticUpdatesRow: View {
    @ObservedObject private var updater = AppUpdater.shared
    @State private var checksDaily = AppUpdater.shared.automaticallyChecks

    var body: some View {
        SettingsRow(title: "Check for updates daily",
                    detail: updater.isConfigured ? updater.lastCheckDescription.prefix(1).uppercased() + updater.lastCheckDescription.dropFirst() + "." : "This build has no update feed (a development build).") {
            SettingsSwitch(isOn: Binding(get: { checksDaily }, set: { isOn in
                updater.automaticallyChecks = isOn
                checksDaily = updater.automaticallyChecks
            }))
            .disabled(!updater.isConfigured)
        }
        .onAppear { checksDaily = updater.automaticallyChecks }
    }
}

struct CheckNowRow: View {
    @ObservedObject private var updater = AppUpdater.shared

    var body: some View {
        SettingsRow(title: "Check now", detail: nil) {
            Button("Check Now") { updater.checkNow() }
                .disabled(!updater.isConfigured)
                .pointerCursor(isEnabled: updater.isConfigured)
        }
    }
}
