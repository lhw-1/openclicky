//
//  DictationCapturing.swift
//  OpenClicky
//
//  The microphone-and-engine side of a take, as the take controller sees it: start, stop, cancel,
//  and three streams (level, errors, whether a session is open). `BuddyDictationManager` is the
//  real one; the controller's tests drive a fake, since a real session needs a microphone.
//

import AppKit
import ApplicationServices
import AVFoundation
import Carbon.HIToolbox
import Combine
import Foundation

@MainActor
protocol DictationCapturing: AnyObject {
    var isDictationInProgress: Bool { get }
    var transcriptionProviderDisplayName: String { get }
    var preferredMicrophoneUID: String? { get set }
    var audioRetentionSink: (@Sendable (AVAudioPCMBuffer) -> Void)? { get set }

    var audioPowerLevelPublisher: AnyPublisher<CGFloat, Never> { get }
    var errorMessagePublisher: AnyPublisher<String?, Never> { get }
    /// True from the moment a keyboard session opens until its transcript was delivered or it ended.
    var sessionActivityPublisher: AnyPublisher<Bool, Never> { get }

    func startPushToTalkFromKeyboardShortcut(
        currentDraftText: String,
        updateDraftText: @escaping (String) -> Void,
        submitDraftText: @escaping (String) -> Void
    ) async
    func stopPushToTalkFromKeyboardShortcut()
    func cancelCurrentDictation(preserveDraftText: Bool)
    func replaceTranscriptionProvider(_ provider: any BuddyTranscriptionProvider)
    /// Words the engine should expect (the dictionary); sent with the next session.
    func updateContextualKeyterms(_ contextualKeyterms: [String])
}

extension BuddyDictationManager: DictationCapturing {
    var audioPowerLevelPublisher: AnyPublisher<CGFloat, Never> { $currentAudioPowerLevel.eraseToAnyPublisher() }
    var errorMessagePublisher: AnyPublisher<String?, Never> { $lastErrorMessage.eraseToAnyPublisher() }
    var sessionActivityPublisher: AnyPublisher<Bool, Never> { $isKeyboardShortcutSessionActiveOrFinalizing.eraseToAnyPublisher() }
}

/// What the controller needs from the Mac around a take; injectable so tests paste and type nowhere.
struct DictationHost {
    var readFocusedField: () -> FocusedFieldSnapshot = { FocusedFieldReader.snapshot() }
    /// A Chromium browser in front is told an assistive client is here, else it reports no field.
    var wakeFrontAppAccessibility: () -> Void = { ChromiumAccessibility.wakeFrontApp() }
    var readNearbyTerms: () -> [String] = { FocusedFieldReader.nearbyTerms() }
    var frontAppBundleID: () -> String? = { NSWorkspace.shared.frontmostApplication?.bundleIdentifier }
    var isSecureInputOn: () -> Bool = { IsSecureEventInputEnabled() }
    var isAccessibilityTrusted: () -> Bool = { AXIsProcessTrusted() }
    var paste: @MainActor (String) -> FrontAppTextInserter.Outcome = { FrontAppTextInserter.insert($0) }
    /// Live typing: the text as posted keystrokes (no pasteboard); false when they could not be posted.
    var typeText: @MainActor (String) -> Bool = { FrontAppTextInserter.typeAsKeystrokes($0) }
    /// Live typing that had to stop leaves the rest of the take here, for a manual ⌘V.
    var copyToPasteboard: @MainActor (String) -> Void = { FrontAppTextInserter.copyToPasteboard($0) }
    /// The clock live typing measures how long a word has been stable with.
    var now: () -> Date = { Date() }
    /// The focused element through Accessibility, read at press and before every typed phrase.
    var readFocusedTextTarget: () -> FocusedTextTarget? = { FocusedFieldReader.focusedTextTarget() }
    /// The modifier keys physically held right now (live typing waits while a foreign one is).
    var heldModifierFlags: () -> CGEventFlags = { CGEventSource.flagsState(.hidSystemState) }
    var verifyPaste: (String, FocusedFieldSnapshot) async -> PasteLanding = { await PasteLanding.verify(text: $0, before: $1) }
    var makePolisher: () -> (any TakePolisher)? = { DictationEngineResolver.makePolisher() }
    var engineUnavailableReason: (DictationEngineChoice) -> String? = { DictationEngineResolver.unavailableReason(for: $0) }
}
