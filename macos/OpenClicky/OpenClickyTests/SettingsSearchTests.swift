//
//  SettingsSearchTests.swift
//  OpenClickyTests
//
//  Settings search: which items a query matches, how results group into "page › section",
//  and which words get the highlighter.
//

import SwiftUI
import Testing
@testable import OpenClicky

@MainActor
struct SettingsSearchTests {
    private func item(_ id: String, page: DictationSettingsPage, section: String, title: String, detail: String = "", keywords: [String] = []) -> SettingsItem {
        SettingsItem(id: id, page: page, section: section, title: title, detail: detail, keywords: keywords, view: AnyView(EmptyView()))
    }

    @Test func matchesTitleDetailKeywordsAndPageCaseInsensitively() {
        let openAtLogin = item("login", page: .general, section: "Startup", title: "Open at login", detail: "Start OpenClicky when you log in.", keywords: ["startup"])
        #expect(openAtLogin.matches("Login"))
        #expect(openAtLogin.matches("log in"))
        #expect(openAtLogin.matches("startup"))
        #expect(openAtLogin.matches("general"))
        #expect(!openAtLogin.matches("microphone"))
    }

    @Test func everyWordOfTheQueryMustMatch() {
        let sounds = item("sounds", page: .orb, section: "Feedback", title: "Sounds", detail: "Tones when a take starts.")
        #expect(sounds.matches("take tones"))
        #expect(!sounds.matches("take haptics"))
    }

    @Test func resultsGroupByPageInOrder() {
        let items = [
            item("a", page: .keyboard, section: "Dictation", title: "Dictation key"),
            item("b", page: .keyboard, section: "Dictation", title: "Cancel a take"),
            item("c", page: .clicky, section: "Pointer", title: "Show the pointer"),
        ]
        let groups = SettingsSectionGroup.groups(items) { $0.page.title }
        #expect(groups.map(\.title) == ["Keyboard", "Clicky"])
        #expect(groups.first?.items.count == 2)
    }

    @Test func aFooterJoinsTheSectionBeforeIt() {
        var footer = item("f", page: .privacy, section: "Where things live", title: "Privacy summary")
        footer.chrome = .footer
        let items = [item("a", page: .privacy, section: "Where things live", title: "History"), footer]
        let groups = SettingsSectionGroup.groups(items)
        #expect(groups.count == 1)
        #expect(groups.first?.items.map(\.id) == ["a"])
        #expect(groups.first?.footers.map(\.id) == ["f"])
    }

    @Test func highlightMarksEveryOccurrence() {
        let highlighted = settingsHighlighted("tap fn + ⌃ twice; FN again", query: "fn")
        let markedRuns = highlighted.runs.filter { $0.backgroundColor != nil }
        #expect(markedRuns.count == 2)
    }
}
