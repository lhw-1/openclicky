//
//  SystemPromptGuardTests.swift
//  OpenClickyTests
//
//  The pointer never lands on macOS's permission and password prompts.
//

import CoreGraphics
import Testing
@testable import OpenClicky

struct SystemPromptGuardTests {
    // Where "OpenClicky would like to access files in your Documents folder" sat on the test Mac.
    let documentsPrompt = (ownerName: "UserNotificationCenter", bounds: CGRect(x: 626, y: 166, width: 260, height: 208))

    @Test func aPointOnThePromptsAllowButtonIsRefused() {
        #expect(SystemPromptGuard.isOnSystemPrompt(quartzPoint: CGPoint(x: 712, y: 301), windows: [documentsPrompt]))
    }

    @Test func aPointJustOutsideThePromptStillCounts() {
        #expect(SystemPromptGuard.isOnSystemPrompt(quartzPoint: CGPoint(x: 900, y: 390), windows: [documentsPrompt]))
    }

    @Test func thePointElsewhereOnScreenIsShown() {
        #expect(!SystemPromptGuard.isOnSystemPrompt(quartzPoint: CGPoint(x: 137, y: 12), windows: [documentsPrompt]))
    }

    @Test func otherAppsWindowsDoNotCount() {
        let textEditWindow = (ownerName: "TextEdit", bounds: CGRect(x: 300, y: 200, width: 700, height: 500))
        #expect(!SystemPromptGuard.isOnSystemPrompt(quartzPoint: CGPoint(x: 712, y: 301), windows: [textEditWindow]))
    }
}
