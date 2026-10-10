//
//  DictationWindowNavigationTests.swift
//  OpenClickyTests
//
//  The window's one sidebar: which row is selected for a section or settings page, how every
//  entry point lands on the page it asks for, and how the settings search gives way to a page.
//

import Testing
@testable import OpenClicky

@MainActor
struct DictationWindowNavigationTests {
    @Test func mainSectionsSelectTheirOwnRow() {
        let model = DictationWindowModel()
        for section in DictationSection.allCases where section != .settings {
            model.select(.section(section))
            #expect(model.selectedSidebarRow == .section(section))
        }
    }

    @Test func eachSettingsPageSelectsItsRowInTheSettingsGroup() {
        let model = DictationWindowModel()
        for page in DictationSettingsPage.allCases {
            model.select(.settingsPage(page))
            #expect(model.section == .settings)
            #expect(model.settingsPage == page)
            #expect(model.selectedSidebarRow == .settingsPage(page))
        }
    }

    @Test func openingASettingsPageLandsOnItEvenWithASectionGiven() {
        let model = DictationWindowModel()
        model.open(section: .history, settingsPage: .voice)
        #expect(model.selectedSidebarRow == .settingsPage(.voice))
    }

    @Test func openingWithNothingKeepsWhereTheWindowWas() {
        let model = DictationWindowModel()
        model.select(.settingsPage(.orb))
        model.settingsSearchText = "paste"
        model.open()
        #expect(model.settingsPage == .orb)
        #expect(model.settingsSearchText == "paste")
    }

    @Test func openingAPageClearsALeftoverSearch() {
        // Otherwise "change engine" or the HUD's "open all settings" would leave the results on screen.
        let model = DictationWindowModel()
        model.settingsSearchText = "microphone"
        model.open(settingsPage: .account)
        #expect(!model.isSearchingSettings)
        #expect(model.selectedSidebarRow == .settingsPage(.account))
    }

    @Test func searchingSelectsNoRowAndClearingReturnsToTheSelectedPage() {
        let model = DictationWindowModel()
        model.select(.settingsPage(.privacy))
        model.settingsSearchText = "  key "
        #expect(model.isSearchingSettings)
        #expect(model.trimmedSettingsSearchText == "key")
        #expect(model.selectedSidebarRow == nil)
        model.settingsSearchText = ""
        #expect(model.selectedSidebarRow == .settingsPage(.privacy))
    }

    @Test func whitespaceIsNotASearch() {
        let model = DictationWindowModel()
        model.settingsSearchText = "   "
        #expect(!model.isSearchingSettings)
        #expect(model.selectedSidebarRow == .section(.record))
    }

    @Test func choosingAnyRowClearsTheSearch() {
        let model = DictationWindowModel()
        model.settingsSearchText = "orb"
        model.select(.section(.styles))
        #expect(model.settingsSearchText.isEmpty)
        #expect(model.selectedSidebarRow == .section(.styles))
    }

    @Test func theKeyboardPageIsNotCalledPlainShortcuts() {
        // The spoken "shortcuts" page sits in the same sidebar; the keyboard page needs its own name.
        #expect(DictationSettingsPage.shortcuts.title != DictationSection.shortcuts.title)
        #expect(DictationSettingsPage.shortcuts.title == "keys & shortcuts")
    }
}
