//
//  SystemPromptGuard.swift
//  OpenClicky
//
//  Keeps the pointer off macOS's own permission and password prompts. Asked how to save a file
//  while "OpenClicky would like to access files in your Documents folder" was on screen, the model
//  pointed at Allow six times out of six, even when the prompt told it not to. Whether to grant a
//  permission is the person's choice, never a step Clicky walks them through, so a point that
//  lands on one of these prompts is not shown.
//
//  The prompts are found by the process that draws them (CGWindowList gives owner names and
//  bounds without Screen Recording permission).
//

import CoreGraphics
import Foundation

enum SystemPromptGuard {
    /// Processes that draw macOS's permission, password and security prompts.
    static let promptOwnerNames: Set<String> = [
        "UserNotificationCenter",     // "would like to access files in …" and other privacy alerts
        "SecurityAgent",              // the password prompt
        "coreautha",                  // Touch ID
        "CoreServicesUIAgent",        // "downloaded from the internet. are you sure…"
        "universalAccessAuthWarn",    // the Accessibility request
    ]

    /// How far outside a prompt a point still counts as aimed at it: the models' pixel guesses are
    /// 30 to 100 px off.
    static let marginInPoints: CGFloat = 40

    /// Whether `quartzPoint` (global, origin top-left of the main display) is on or beside a prompt.
    static func isOnSystemPrompt(quartzPoint: CGPoint, windows: [(ownerName: String, bounds: CGRect)]) -> Bool {
        windows.contains { window in
            promptOwnerNames.contains(window.ownerName)
                && window.bounds.insetBy(dx: -marginInPoints, dy: -marginInPoints).contains(quartzPoint)
        }
    }

    /// The same, for an AppKit point (origin bottom-left of the main display) against the windows on screen now.
    static func isOnSystemPrompt(appKitPoint: CGPoint, mainDisplayHeight: CGFloat) -> Bool {
        let quartzPoint = CGPoint(x: appKitPoint.x, y: mainDisplayHeight - appKitPoint.y)
        return isOnSystemPrompt(quartzPoint: quartzPoint, windows: onScreenWindows())
    }

    private static func onScreenWindows() -> [(ownerName: String, bounds: CGRect)] {
        guard let windowInfos = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return []
        }
        return windowInfos.compactMap { windowInfo in
            guard let ownerName = windowInfo[kCGWindowOwnerName as String] as? String,
                  promptOwnerNames.contains(ownerName),
                  let boundsDictionary = windowInfo[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDictionary) else { return nil }
            return (ownerName, bounds)
        }
    }
}
