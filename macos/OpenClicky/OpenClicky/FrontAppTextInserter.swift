//
//  FrontAppTextInserter.swift
//  OpenClicky
//
//  Types dictated text into whatever app is in front (fn + control dictation): the text goes on
//  the pasteboard, a ⌘V keystroke is posted to the front app, and the pasteboard is restored a
//  moment later. Posting keystrokes needs the Accessibility permission OpenClicky already asks
//  for; without it the text is left on the pasteboard for a manual paste.
//

import AppKit
import ApplicationServices

enum FrontAppTextInserter {
    enum Outcome: Equatable {
        /// The keystroke was posted; the app in front received the text.
        case typed
        /// No Accessibility permission (or no event source): the text is on the pasteboard instead.
        case leftOnPasteboard
    }

    private static let virtualKeyCodeV: CGKeyCode = 9
    /// When the last paste was posted; the clipboard history monitor ignores the pasteboard for a
    /// moment after it.
    @MainActor static var lastInsertedAt = Date.distantPast

    @MainActor
    static func insert(_ text: String) -> Outcome {
        let pasteboard = NSPasteboard.general
        let previousPasteboardItems = snapshot(of: pasteboard)
        lastInsertedAt = Date()
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        guard AXIsProcessTrusted(),
              let eventSource = CGEventSource(stateID: .combinedSessionState),
              let pasteKeyDown = CGEvent(keyboardEventSource: eventSource, virtualKey: virtualKeyCodeV, keyDown: true),
              let pasteKeyUp = CGEvent(keyboardEventSource: eventSource, virtualKey: virtualKeyCodeV, keyDown: false) else {
            return .leftOnPasteboard
        }
        pasteKeyDown.flags = .maskCommand
        pasteKeyUp.flags = .maskCommand
        pasteKeyDown.post(tap: .cghidEventTap)
        pasteKeyUp.post(tap: .cghidEventTap)

        // Give the front app time to read the pasteboard before the user's clipboard comes back.
        let restore = DispatchWorkItem {
            guard pasteboard.string(forType: .string) == text else { return }
            pasteboard.clearContents()
            if !previousPasteboardItems.isEmpty {
                pasteboard.writeObjects(previousPasteboardItems)
            }
        }
        pendingClipboardRestore?.cancel()
        pendingClipboardRestore = restore
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: restore)
        return .typed
    }

    /// The person's clipboard, due back shortly after a paste. `copyToPasteboard` cancels it: a
    /// paste that could not be seen landing leaves the words there for a manual ⌘V, and putting
    /// the old clipboard back (it only checks that the words are still there) would take them.
    @MainActor private static var pendingClipboardRestore: DispatchWorkItem?

    // MARK: live typing

    /// `CGEventKeyboardSetUnicodeString` carries at most 20 UTF-16 units per event; longer strings
    /// are cut off by the system, so text is posted in chunks of this size.
    static let maximumUTF16UnitsPerKeyboardEvent = 20

    /// Stamped into `eventSourceUserData` of every keystroke live typing posts, so OpenClicky's own
    /// shortcut tap can ignore them (a typed letter would otherwise read as a key pressed during the
    /// dictation key's hold and break tap / double-tap detection). The bytes spell "OCLT".
    static let liveTypingEventMarker: Int64 = 0x4F43_4C54

    /// The virtual key the text-carrying events claim to be. Not a letter (keycode 0 is the A key,
    /// and fn+A or ⌃A mean something): 0x42 has no `kVK_` constant in HIToolbox's Events.h,
    /// so the event has no key meaning of its own and the app reads only its unicode string.
    static let liveTypingVirtualKeyCode: CGKeyCode = 0x42

    /// Types text into the app in front as keystrokes carrying the text itself, leaving the
    /// pasteboard alone (live typing posts many small phrases; pasting each would churn the
    /// clipboard). False without Accessibility or an event source.
    @MainActor
    static func typeAsKeystrokes(_ text: String) -> Bool {
        guard !text.isEmpty else { return true }
        // A private event source carries no modifier state of its own, and posting at the session
        // tap (not the HID tap) keeps the events from picking up the modifiers physically held —
        // the dictation key usually still is. The controller also waits while a foreign modifier
        // is held (`LiveTypingModifierGuard`).
        guard AXIsProcessTrusted(), let eventSource = CGEventSource(stateID: .privateState) else { return false }
        eventSource.userData = liveTypingEventMarker
        for chunk in keyboardChunks(of: text) {
            let utf16Units = Array(chunk.utf16)
            guard let keyDown = CGEvent(keyboardEventSource: eventSource, virtualKey: liveTypingVirtualKeyCode, keyDown: true),
                  let keyUp = CGEvent(keyboardEventSource: eventSource, virtualKey: liveTypingVirtualKeyCode, keyDown: false) else { return false }
            for event in [keyDown, keyUp] {
                event.keyboardSetUnicodeString(stringLength: utf16Units.count, unicodeString: utf16Units)
                event.flags = []
                event.setIntegerValueField(.eventSourceUserData, value: liveTypingEventMarker)
            }
            keyDown.post(tap: .cgSessionEventTap)
            keyUp.post(tap: .cgSessionEventTap)
        }
        return true
    }

    /// Cuts text into pieces of at most `maximumUTF16UnitsPerKeyboardEvent` UTF-16 units without
    /// splitting a character (an emoji's surrogate pair, a letter with its combining marks).
    static func keyboardChunks(of text: String) -> [String] {
        var chunks: [String] = []
        var currentChunk = ""
        for character in text {
            let characterUnits = String(character).utf16.count
            if currentChunk.utf16.count + characterUnits > maximumUTF16UnitsPerKeyboardEvent, !currentChunk.isEmpty {
                chunks.append(currentChunk)
                currentChunk = ""
            }
            if characterUnits > maximumUTF16UnitsPerKeyboardEvent {
                // A single grapheme longer than one event (a long emoji sequence): its scalars go
                // separately, which still never splits a surrogate pair.
                for scalar in character.unicodeScalars {
                    let scalarText = String(scalar)
                    if currentChunk.utf16.count + scalarText.utf16.count > maximumUTF16UnitsPerKeyboardEvent, !currentChunk.isEmpty {
                        chunks.append(currentChunk)
                        currentChunk = ""
                    }
                    currentChunk += scalarText
                }
            } else {
                currentChunk.append(character)
            }
        }
        if !currentChunk.isEmpty { chunks.append(currentChunk) }
        return chunks
    }

    /// Puts text on the pasteboard and leaves it there (no keystroke): what live typing could not
    /// type is waiting for the person's own ⌘V.
    @MainActor
    static func copyToPasteboard(_ text: String) {
        pendingClipboardRestore?.cancel()
        pendingClipboardRestore = nil
        let pasteboard = NSPasteboard.general
        lastInsertedAt = Date()
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    /// Copies every item and type on the pasteboard so it can be put back after the paste.
    private static func snapshot(of pasteboard: NSPasteboard) -> [NSPasteboardItem] {
        (pasteboard.pasteboardItems ?? []).map { item in
            let copiedItem = NSPasteboardItem()
            for type in item.types {
                if let data = item.data(forType: type) {
                    copiedItem.setData(data, forType: type)
                }
            }
            return copiedItem
        }
    }
}
