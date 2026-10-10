//
//  DictationTakeControllerTests.swift
//  OpenClickyTests
//
//  The take state machine, driven through a fake capture side and a fake host: hold, tap, double
//  tap, esc, the hands-free gesture, a cancel while a model is at work, and where the words go.
//

import ApplicationServices
import AVFoundation
import CoreGraphics
import Combine
import Foundation
import Testing
@testable import OpenClicky

@MainActor
private final class FakeCapture: DictationCapturing {
    var isDictationInProgress = false
    var transcriptionProviderDisplayName = "fake"
    var preferredMicrophoneUID: String?
    var audioRetentionSink: (@Sendable (AVAudioPCMBuffer) -> Void)?
    let level = CurrentValueSubject<CGFloat, Never>(0)
    let errors = CurrentValueSubject<String?, Never>(nil)
    let activity = CurrentValueSubject<Bool, Never>(false)
    var audioPowerLevelPublisher: AnyPublisher<CGFloat, Never> { level.eraseToAnyPublisher() }
    var errorMessagePublisher: AnyPublisher<String?, Never> { errors.eraseToAnyPublisher() }
    var sessionActivityPublisher: AnyPublisher<Bool, Never> { activity.eraseToAnyPublisher() }

    private(set) var starts = 0
    private(set) var stops = 0
    private(set) var cancels = 0
    private var onPartial: ((String) -> Void)?
    private var onFinal: ((String) -> Void)?

    func startPushToTalkFromKeyboardShortcut(currentDraftText: String, updateDraftText: @escaping (String) -> Void, submitDraftText: @escaping (String) -> Void) async {
        starts += 1
        isDictationInProgress = true
        activity.send(true)
        onPartial = updateDraftText
        onFinal = submitDraftText
    }

    func stopPushToTalkFromKeyboardShortcut() { stops += 1 }

    func cancelCurrentDictation(preserveDraftText: Bool) {
        cancels += 1
        isDictationInProgress = false
        onFinal = nil
        activity.send(false)
    }

    func replaceTranscriptionProvider(_ provider: any BuddyTranscriptionProvider) {}
    func updateContextualKeyterms(_ contextualKeyterms: [String]) {}

    /// The engine's words arrive: the session ends, then the final text is delivered (as the real
    /// manager does: state first, callback second).
    func deliverFinal(_ text: String) {
        let final = onFinal
        isDictationInProgress = false
        onFinal = nil
        activity.send(false)
        final?(text)
    }

    func deliverPartial(_ text: String) { onPartial?(text) }
}

private struct SlowPolisher: TakePolisher {
    let seconds: Double
    let answer: String
    var displayName: String { "slow" }
    func polish(system: String, user: String) async throws -> String {
        try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        return answer
    }
}

@MainActor
private struct Harness {
    let settings: DictationSettings
    let capture = FakeCapture()
    let store: TakeStore
    let orb = OrbModel()
    let controller: DictationTakeController
    let pasted: Pasted

    final class Pasted {
        var texts: [String] = []
        var frontApp: String? = "com.apple.Notes"
        /// What live typing posted as keystrokes, one entry per typing step.
        var typed: [String] = []
        /// What was put on the pasteboard without a paste (live typing that had to stop).
        var copied: [String] = []
        /// The clock live typing measures word stability with; tests move it by hand.
        var now = Date(timeIntervalSince1970: 1_000)
        /// The focused element as Accessibility reports it (live typing re-reads it every phrase).
        var focusedTarget: FocusedTextTarget?
        /// The modifier keys physically held right now.
        var heldModifierFlags: CGEventFlags = []
    }

    init(polisher: (any TakePolisher)? = nil, field: FocusedFieldSnapshot? = nil) throws {
        let suite = "openclicky-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        settings = DictationSettings(defaults: defaults)
        settings.sounds = false
        settings.haptics = false
        settings.engine = .offline
        settings.readNearbyText = false
        settings.polishWithModel = true
        settings.polishOfflineTakes = polisher != nil
        store = try TakeStore(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent("takes-\(UUID().uuidString).sqlite"))
        let pasted = Pasted()
        self.pasted = pasted
        let snapshot = field ?? FocusedFieldSnapshot(appBundleID: "com.apple.Notes", appName: "Notes", role: "AXTextArea", isEditable: true, isSecure: false, value: "", selectedText: nil)
        pasted.focusedTarget = FocusedTextTarget(processID: Harness.notesProcessID, element: AXUIElementCreateApplication(Harness.notesProcessID),
                                                 role: snapshot.role, isSecure: snapshot.isSecure)
        var host = DictationHost()
        host.readFocusedField = { snapshot }
        host.readNearbyTerms = { [] }
        host.frontAppBundleID = { pasted.frontApp }
        host.isSecureInputOn = { false }
        host.isAccessibilityTrusted = { true }
        host.paste = { text in pasted.texts.append(text); return .typed }
        host.verifyPaste = { _, _ in .verified }
        host.typeText = { text in pasted.typed.append(text); return true }
        host.copyToPasteboard = { text in pasted.copied.append(text) }
        host.now = { pasted.now }
        host.readFocusedTextTarget = { pasted.focusedTarget }
        host.heldModifierFlags = { pasted.heldModifierFlags }
        host.makePolisher = { polisher }
        host.engineUnavailableReason = { _ in nil }
        let spaceStore = DictationSpaceStore(directoryURL: FileManager.default.temporaryDirectory.appendingPathComponent("space-\(UUID().uuidString)"))
        let audioStore = TakeAudioStore(directoryURL: FileManager.default.temporaryDirectory.appendingPathComponent("audio-\(UUID().uuidString)"))
        controller = DictationTakeController(settings: settings, spaceStore: spaceStore, takeStore: store, orb: orb, capture: capture, host: host, audioStore: audioStore)
        controller.liveTypingTiming = .algorithmTests
    }

    static let notesProcessID: pid_t = 4242

    /// Lets the controller's start task and main-queue hops run.
    func settle(_ seconds: Double = 0.05) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    /// Waits for a condition the controller reaches asynchronously, up to a few seconds: a slow CI
    /// runner takes longer than a fixed sleep allows, and a fast one should not wait for it.
    func waitUntil(_ seconds: Double = 5, _ condition: () -> Bool) async {
        let deadline = Date(timeIntervalSinceNow: seconds)
        while !condition() && Date() < deadline {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }
}

struct DictationTakeControllerTests {

    @Test @MainActor func holdingTheKeyPastesTheWordsAndRecordsTheTake() async throws {
        let h = try Harness()
        h.controller.handle(.dictationPressed)
        #expect(h.controller.state == .starting)
        await h.waitUntil { h.controller.state == .listening }
        #expect(h.controller.state == .listening)
        #expect(h.capture.starts == 1)
        h.controller.handle(.dictationReleased(wasTap: false))
        #expect(h.controller.state == .finishing)
        #expect(h.capture.stops == 1)
        h.capture.deliverFinal("hello there")
        await h.waitUntil { h.controller.state == .idle }
        #expect(h.pasted.texts == ["Hello there"])
        #expect(h.controller.state == .idle)
        let rows = try h.store.recent()
        #expect(rows.count == 1)
        #expect(rows.first?.formattedText == "Hello there")
        #expect(rows.first?.pasteOutcome == .verified)
        #expect(rows.first?.appBundleID == "com.apple.Notes")
    }

    @Test @MainActor func aTapKeepsListeningUntilTheNextPress() async throws {
        let h = try Harness()
        h.controller.handle(.dictationPressed)
        await h.waitUntil { h.controller.state == .listening }
        h.controller.handle(.dictationReleased(wasTap: true))
        #expect(h.controller.state == .listening)
        #expect(h.capture.stops == 0)
        h.controller.handle(.dictationPressed)
        #expect(h.controller.state == .finishing)
        #expect(h.capture.stops == 1)
        h.controller.handle(.dictationReleased(wasTap: true))
        #expect(h.controller.state == .finishing)
        #expect(h.capture.stops == 1)
    }

    @Test @MainActor func twoQuickTapsCancelWithoutPasting() async throws {
        let h = try Harness()
        h.controller.handle(.dictationPressed)
        await h.waitUntil { h.controller.state == .listening }
        h.controller.handle(.dictationReleased(wasTap: true))
        h.controller.handle(.dictationPressed)
        h.controller.handle(.dictationReleased(wasTap: true))
        h.controller.handle(.dictationDoubleTapped)
        #expect(h.controller.state == .idle)
        #expect(h.capture.cancels == 1)
        await h.settle(0.2)
        #expect(h.pasted.texts.isEmpty)
        #expect(try h.store.recent().isEmpty)
    }

    @Test @MainActor func escapeCancelsAListeningTake() async throws {
        let h = try Harness()
        h.controller.handle(.dictationPressed)
        await h.waitUntil { h.controller.state == .listening }
        #expect(h.controller.handle(.escapePressed))
        #expect(h.controller.state == .idle)
        #expect(h.capture.cancels == 1)
        #expect(!h.controller.handle(.escapePressed))
    }

    @Test @MainActor func aCancelledTakeNeverPastesIntoTheNextOne() async throws {
        let h = try Harness(polisher: SlowPolisher(seconds: 0.4, answer: "Old words, polished."))
        h.controller.handle(.dictationPressed)
        await h.waitUntil { h.controller.state == .listening }
        h.controller.handle(.dictationReleased(wasTap: false))
        h.capture.deliverFinal("old words")
        await h.settle()
        // esc while the model is at work, then a new take at once.
        h.controller.handle(.escapePressed)
        #expect(h.controller.state == .idle)
        h.controller.handle(.dictationPressed)
        await h.waitUntil { h.controller.state == .listening }
        #expect(h.controller.state == .listening)
        #expect(h.capture.starts == 2)
        await h.settle(0.6)
        // The old polish has finished by now; nothing was pasted and the new take still listens.
        #expect(h.pasted.texts.isEmpty)
        #expect(h.controller.state == .listening)
        h.controller.handle(.dictationReleased(wasTap: false))
        h.capture.deliverFinal("new words")
        await h.waitUntil(8) { !h.pasted.texts.isEmpty }
        // The slow polisher answers the same for any input; what matters is that only the second take pasted.
        #expect(h.pasted.texts == ["Old words, polished."])
    }

    @Test @MainActor func aQuickControlTapNeverOpensAnEditTake() async throws {
        let h = try Harness()
        // fn + ⌃ tapped twice, as the recogniser reports it: no take, hands-free goes to the companion.
        h.controller.handle(.dictationEditPressed)
        h.controller.handle(.dictationReleased(wasTap: true))
        h.controller.handle(.dictationEditPressed)
        h.controller.handle(.dictationReleased(wasTap: true))
        #expect(!h.controller.handle(.handsFreeToggleRequested))
        await h.settle(0.6)
        #expect(h.controller.state == .idle)
        #expect(h.capture.starts == 0)
    }

    @Test @MainActor func controlHeldPastTheTapWindowIsAnEditTake() async throws {
        let h = try Harness()
        h.controller.handle(.dictationEditPressed)
        #expect(h.controller.state == .idle)
        await h.waitUntil { h.controller.state == .listening }
        #expect(h.controller.state == .listening)
        #expect(h.orb.phase == .editListening)
    }

    @Test @MainActor func controlJoiningAHeldKeyTurnsTheTakeIntoAnEdit() async throws {
        let h = try Harness()
        h.controller.handle(.dictationPressed)
        await h.waitUntil { h.controller.state == .listening }
        h.controller.handle(.dictationEditModifierJoined)
        #expect(h.orb.phase == .editListening)
        #expect(h.capture.starts == 1)
    }

    @Test @MainActor func nothingHeardIsNotRecorded() async throws {
        let h = try Harness()
        h.controller.handle(.dictationPressed)
        await h.waitUntil { h.controller.state == .listening }
        h.controller.handle(.dictationReleased(wasTap: false))
        h.capture.deliverFinal("   ")
        await h.waitUntil { h.controller.state == .idle }
        #expect(h.controller.state == .idle)
        #expect(h.pasted.texts.isEmpty)
        #expect(try h.store.recent().isEmpty)
        #expect(h.orb.phase == .failed("didn't catch that"))
    }

    @Test @MainActor func aSessionThatEndsWithoutWordsFailsTheTake() async throws {
        let h = try Harness()
        h.controller.handle(.dictationPressed)
        await h.waitUntil { h.controller.state == .listening }
        h.controller.handle(.dictationReleased(wasTap: false))
        // The engine gave up without a transcript: the manager's session flag drops.
        h.capture.cancelCurrentDictation(preserveDraftText: false)
        await h.waitUntil { h.controller.state == .idle }
        #expect(h.controller.state == .idle)
        #expect(h.orb.phase == .failed("didn't catch that"))
    }

    @Test @MainActor func theWordsAreCopiedWhenTheAppChanged() async throws {
        let h = try Harness()
        h.controller.handle(.dictationPressed)
        await h.waitUntil { h.controller.state == .listening }
        h.controller.handle(.dictationReleased(wasTap: false))
        h.pasted.frontApp = "com.apple.Safari"
        h.capture.deliverFinal("hello")
        await h.waitUntil { h.controller.state == .idle }
        #expect(h.pasted.texts.isEmpty)
        // Nowhere to put them: on the clipboard, one line on the orb, no box.
        #expect(h.pasted.copied == ["Hello"])
        #expect(!h.orb.isBoxOpen)
        #expect(h.orb.phase == .done("the app changed — copied, press ⌘V"))
        #expect(try h.store.recent().first?.pasteOutcome == .leftOnPasteboard)
    }

    @Test @MainActor func withTheCleanUpOffTheBoxOffersNoAIRewrites() async throws {
        let h = try Harness()
        h.settings.polishWithModel = false
        h.settings.choosePolishOfflineTakes(false)
        h.settings.orbRestsExpanded = true
        h.controller.handle(.dictationPressed)
        await h.waitUntil { h.controller.state == .listening }
        h.controller.handle(.dictationReleased(wasTap: false))
        h.capture.deliverFinal("hello")
        await h.waitUntil { h.controller.state == .idle }
        #expect(h.orb.quickRewrites.isEmpty)
    }

    @Test @MainActor func aSecureFieldIsNeverPastedInto() async throws {
        let secure = FocusedFieldSnapshot(appBundleID: "com.apple.Safari", appName: "Safari", role: "AXTextField", isEditable: false, isSecure: true, value: nil, selectedText: nil)
        let h = try Harness(field: secure)
        h.pasted.frontApp = "com.apple.Safari"
        h.controller.handle(.dictationPressed)
        await h.waitUntil { h.controller.state == .listening }
        h.controller.handle(.dictationReleased(wasTap: false))
        h.capture.deliverFinal("my password")
        await h.waitUntil { h.controller.state == .idle }
        #expect(h.pasted.texts.isEmpty)
        #expect(h.pasted.copied.isEmpty)
        #expect(!h.orb.isBoxOpen)
        #expect(h.orb.phase == .done("not pasting into a password field"))
    }

    @Test @MainActor func incognitoPastesButRecordsNothing() async throws {
        let h = try Harness()
        h.settings.incognito = true
        h.controller.handle(.dictationPressed)
        await h.waitUntil { h.controller.state == .listening }
        h.controller.handle(.dictationReleased(wasTap: false))
        h.capture.deliverFinal("secret plans")
        await h.waitUntil { h.controller.state == .idle }
        #expect(h.pasted.texts == ["Secret plans"])
        #expect(try h.store.recent().isEmpty)
    }

    // MARK: live typing (no model polish: the words go in as they settle)

    /// Delivers a partial now and again after the stability threshold, so its settled words commit.
    @MainActor private func speak(_ partial: String, in h: Harness) {
        h.capture.deliverPartial(partial)
        h.pasted.now = h.pasted.now.addingTimeInterval(h.controller.liveTypingTiming.requiredStableSeconds + 0.1)
        h.capture.deliverPartial(partial)
    }

    @Test @MainActor func withoutPolishTheSettledWordsAreTypedWhileSpeakingAndTheRestAtRelease() async throws {
        let h = try Harness()
        h.controller.handle(.dictationPressed)
        await h.waitUntil { h.controller.state == .listening }
        speak("hello there my friend", in: h)
        #expect(h.pasted.typed == ["Hello there"])
        // The words are appearing in the app, so the orb shows only the listening pill.
        #expect(h.orb.liveTranscript == "")
        speak("hello there my friend how are you", in: h)
        // "my friend" had already settled and is now clear of the tail; "how" settles a moment later.
        #expect(h.pasted.typed == ["Hello there", " my friend", " how"])
        h.controller.handle(.dictationReleased(wasTap: false))
        h.capture.deliverFinal("Hello there, my friend, how are you?")
        await h.waitUntil { h.controller.state == .idle }
        #expect(h.pasted.typed == ["Hello there", " my friend", " how", " are you?"])
        #expect(h.pasted.texts.isEmpty)
        let record = try #require(try h.store.recent().first)
        #expect(record.rawText == "Hello there, my friend, how are you?")
        #expect(record.formattedText == "Hello there my friend how are you?")
        #expect(record.pasteOutcome == .posted)
        #expect(record.status == .complete)
    }

    @Test @MainActor func aTakeThatWillBePolishedIsNotTypedLive() async throws {
        let h = try Harness(polisher: SlowPolisher(seconds: 0.05, answer: "Hello there, my friend."))
        h.controller.handle(.dictationPressed)
        await h.waitUntil { h.controller.state == .listening }
        speak("hello there my friend", in: h)
        #expect(h.pasted.typed.isEmpty)
        #expect(h.orb.liveTranscript == "hello there my friend")
        h.controller.handle(.dictationReleased(wasTap: false))
        h.capture.deliverFinal("hello there my friend")
        await h.waitUntil { h.controller.state == .idle }
        #expect(h.pasted.typed.isEmpty)
        #expect(h.pasted.texts == ["Hello there, my friend."])
    }

    @Test @MainActor func aFieldThatIsNotEditableIsNotTypedInto() async throws {
        let label = FocusedFieldSnapshot(appBundleID: "com.apple.finder", appName: "Finder", role: "AXStaticText", isEditable: false, isSecure: false, value: nil, selectedText: nil)
        let h = try Harness(field: label)
        h.pasted.frontApp = "com.apple.finder"
        h.controller.handle(.dictationPressed)
        await h.waitUntil { h.controller.state == .listening }
        speak("hello there my friend", in: h)
        #expect(h.pasted.typed.isEmpty)
    }

    @Test @MainActor func whenTheAppChangesTypingStopsAndTheRestGoesToThePasteboard() async throws {
        let h = try Harness()
        h.controller.handle(.dictationPressed)
        await h.waitUntil { h.controller.state == .listening }
        speak("hello there my friend", in: h)
        #expect(h.pasted.typed == ["Hello there"])
        // Safari's text field has focus now (Accessibility's pid, not NSWorkspace, decides).
        let notesTarget = h.pasted.focusedTarget
        h.pasted.focusedTarget = FocusedTextTarget(processID: 5151, element: AXUIElementCreateApplication(5151), role: "AXTextField", isSecure: false)
        speak("hello there my friend and more words", in: h)
        #expect(h.pasted.typed == ["Hello there"])
        // Back in the original field: typing stays stopped for this take.
        h.pasted.focusedTarget = notesTarget
        speak("hello there my friend and more words to come", in: h)
        #expect(h.pasted.typed == ["Hello there"])
        h.controller.handle(.dictationReleased(wasTap: false))
        h.capture.deliverFinal("hello there my friend and more words to come")
        await h.waitUntil { h.controller.state == .idle }
        #expect(h.pasted.typed == ["Hello there"])
        #expect(h.pasted.texts.isEmpty)
        #expect(h.pasted.copied == ["my friend and more words to come"])
        #expect(h.orb.boxText == "my friend and more words to come")
        let record = try #require(try h.store.recent().first)
        #expect(record.pasteOutcome == .leftOnPasteboard)
    }

    @Test @MainActor func focusMovingInsideTheSameAppStopsTyping() async throws {
        let h = try Harness()
        h.controller.handle(.dictationPressed)
        await h.waitUntil { h.controller.state == .listening }
        speak("hello there my friend", in: h)
        #expect(h.pasted.typed == ["Hello there"])
        // Same app, another element (Terminal window A → B, compose box → message list).
        h.pasted.focusedTarget = FocusedTextTarget(processID: Harness.notesProcessID, element: AXUIElementCreateSystemWide(), role: "AXTextArea", isSecure: false)
        speak("hello there my friend and more words", in: h)
        #expect(h.pasted.typed == ["Hello there"])
        h.controller.handle(.dictationReleased(wasTap: false))
        h.capture.deliverFinal("hello there my friend and more words")
        await h.waitUntil { h.controller.state == .idle }
        #expect(h.pasted.typed == ["Hello there"])
        #expect(h.pasted.copied == ["my friend and more words"])
    }

    @Test @MainActor func aWebPageWithFocusIsNotTypedInto() async throws {
        let page = FocusedFieldSnapshot(appBundleID: "com.google.Chrome", appName: "Chrome", role: "AXWebArea", isEditable: true, isSecure: false, value: nil, selectedText: nil)
        let h = try Harness(field: page)
        h.pasted.frontApp = "com.google.Chrome"
        h.controller.handle(.dictationPressed)
        await h.waitUntil { h.controller.state == .listening }
        speak("archive this one please", in: h)
        #expect(h.pasted.typed.isEmpty)
        h.controller.handle(.dictationReleased(wasTap: false))
        h.capture.deliverFinal("archive this one please")
        await h.waitUntil { h.controller.state == .idle }
        // The old path: one paste of the whole take.
        #expect(h.pasted.texts == ["Archive this one please"])
    }

    @Test @MainActor func aLineBreakInADictionaryTermIsNeverTypedAndTheRestIsCopied() async throws {
        let h = try Harness()
        h.controller.spaceStore.update { $0.dictionary = [DictionaryTerm(written: "first\nsecond", heardAs: ["two lines"])] }
        h.controller.handle(.dictationPressed)
        await h.waitUntil { h.controller.state == .listening }
        speak("hello there my friend", in: h)
        #expect(h.pasted.typed == ["Hello there"])
        speak("hello there my friend two lines and more", in: h)
        // "my friend" settles first and is typed; "two lines" becomes "first\nsecond" and stops typing.
        #expect(h.pasted.typed == ["Hello there", " my friend"])
        h.controller.handle(.dictationReleased(wasTap: false))
        h.capture.deliverFinal("hello there my friend two lines and more")
        await h.waitUntil { h.controller.state == .idle }
        #expect(h.pasted.typed.allSatisfy { !$0.contains("\n") })
        #expect(h.pasted.typed == ["Hello there", " my friend"])
        // Formatted as a finished take would be: a new line starts a sentence.
        #expect(h.pasted.copied == ["first\nSecond and more"])
    }

    @Test @MainActor func aHeldModifierDefersTypingUntilItIsReleased() async throws {
        let h = try Harness()
        h.controller.handle(.dictationPressed)
        await h.waitUntil { h.controller.state == .listening }
        h.pasted.heldModifierFlags = [.maskSecondaryFn, .maskCommand]
        speak("hello there my friend", in: h)
        #expect(h.pasted.typed.isEmpty)
        h.pasted.heldModifierFlags = [.maskSecondaryFn]
        speak("hello there my friend how are you", in: h)
        // The deferred words go first, with the ones that settled since.
        #expect(h.pasted.typed.first == "Hello there my friend")
        #expect(h.pasted.typed.joined() == "Hello there my friend how")
    }

    @Test @MainActor func aLatePartialAfterReleaseIsNeverTyped() async throws {
        let h = try Harness()
        h.controller.handle(.dictationPressed)
        await h.waitUntil { h.controller.state == .listening }
        speak("hello there my friend", in: h)
        h.controller.handle(.dictationReleased(wasTap: false))
        #expect(h.controller.state == .finishing)
        speak("hello there my friend how are you today", in: h)
        #expect(h.pasted.typed == ["Hello there"])
        h.capture.deliverFinal("hello there my friend how are you today")
        await h.waitUntil { h.controller.state == .idle }
        #expect(h.pasted.typed == ["Hello there", " my friend how are you today"])
        #expect(h.pasted.texts.isEmpty)
    }

    @Test @MainActor func controlJoiningAfterWordsWereTypedDoesNotBecomeAnEdit() async throws {
        let h = try Harness()
        h.controller.handle(.dictationPressed)
        await h.waitUntil { h.controller.state == .listening }
        speak("hello there my friend", in: h)
        h.controller.handle(.dictationEditModifierJoined)
        #expect(h.orb.phase == .listening)
        #expect(h.orb.hint == "already typing — release and start an edit")
        h.controller.handle(.dictationReleased(wasTap: false))
        h.capture.deliverFinal("hello there my friend")
        await h.waitUntil { h.controller.state == .idle }
        #expect(h.pasted.typed == ["Hello there", " my friend"])
        #expect(try h.store.recent().first?.mode == .dictate)
    }

    @Test @MainActor func aFailedTakeCopiesTheHeardButUntypedWords() async throws {
        let h = try Harness()
        h.controller.handle(.dictationPressed)
        await h.waitUntil { h.controller.state == .listening }
        speak("hello there my friend", in: h)
        h.capture.errors.send("the socket closed")
        await h.waitUntil { h.controller.state == .idle }
        #expect(h.pasted.typed == ["Hello there"])
        #expect(h.pasted.copied == ["my friend"])
        let record = try #require(try h.store.recent().first)
        #expect(record.status == .failed)
        #expect(record.formattedText == "Hello there")
    }

    @Test @MainActor func cancellingLeavesTheTypedWordsAndRecordsThem() async throws {
        let h = try Harness()
        h.controller.handle(.dictationPressed)
        await h.waitUntil { h.controller.state == .listening }
        speak("hello there my friend", in: h)
        #expect(h.pasted.typed == ["Hello there"])
        #expect(h.controller.handle(.escapePressed))
        #expect(h.controller.state == .idle)
        await h.settle(0.2)
        #expect(h.pasted.typed == ["Hello there"])
        #expect(h.pasted.texts.isEmpty)
        #expect(h.pasted.copied.isEmpty)
        let record = try #require(try h.store.recent().first)
        #expect(record.status == .cancelled)
        #expect(record.formattedText == "Hello there")
        #expect(record.pasteOutcome == .posted)
    }
}
