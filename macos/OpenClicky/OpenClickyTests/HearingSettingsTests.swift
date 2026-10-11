//
//  HearingSettingsTests.swift
//  OpenClickyTests
//
//  One setting, every reader: the microphone chosen in settings reaches every engine that opens
//  the microphone (F-13, F-21), the styles page's language reaches every dictation engine (F-16),
//  and the hearing code logs its failures to the file the person can send, not only stdout (F-37).
//

import CoreAudio
import Foundation
import Testing
@testable import OpenClicky

struct HearingSettingsTests {

    // MARK: microphone

    private let builtIn = MicrophoneDevices.ConnectedInput(deviceID: 41, uid: "BuiltInMicrophoneDevice")
    private let usb = MicrophoneDevices.ConnectedInput(deviceID: 77, uid: "AppleUSBAudioEngine:Blue:Yeti")

    @Test func aConnectedChosenMicrophoneIsSelected() {
        let choice = MicrophoneDevices.deviceToSelect(preferredUID: usb.uid, connected: [builtIn, usb], defaultDeviceID: builtIn.deviceID)
        #expect(choice.deviceID == usb.deviceID)
        #expect(!choice.chosenUIDIsMissing)
    }

    /// "mac default" after a chosen microphone: the default is selected explicitly, so an engine
    /// kept for the app's life leaves the old device.
    @Test func macDefaultSelectsTheDefaultDeviceExplicitly() {
        let choice = MicrophoneDevices.deviceToSelect(preferredUID: nil, connected: [builtIn, usb], defaultDeviceID: usb.deviceID)
        #expect(choice.deviceID == usb.deviceID)
        #expect(!choice.chosenUIDIsMissing)
        #expect(MicrophoneDevices.deviceToSelect(preferredUID: "", connected: [builtIn], defaultDeviceID: builtIn.deviceID).deviceID == builtIn.deviceID)
    }

    @Test func anUnpluggedChosenMicrophoneFallsBackToTheDefaultAndIsReported() {
        let choice = MicrophoneDevices.deviceToSelect(preferredUID: usb.uid, connected: [builtIn], defaultDeviceID: builtIn.deviceID)
        #expect(choice.deviceID == builtIn.deviceID)
        #expect(choice.chosenUIDIsMissing)
    }

    /// F-13: the realtime lane's engine is handed the same microphone as dictation.
    @Test @MainActor func theRealtimeClientPassesTheChosenMicrophoneToItsEngine() async {
        let client = RealtimeVoiceClient()
        client.preferredMicrophoneUID = usb.uid
        #expect(await client.audio.currentPreferredMicrophoneUID() == usb.uid)
        client.preferredMicrophoneUID = nil
        #expect(await client.audio.currentPreferredMicrophoneUID() == nil)
    }

    /// Every owner of an `AVAudioEngine` that records a take or a question selects the chosen
    /// microphone. The settings page's level meter is left out: it opens a fresh engine on the
    /// chosen device for a few seconds and is checked by eye.
    @Test func everyRecordingEngineSelectsTheChosenMicrophone() throws {
        for name in ["BuddyDictationManager.swift", "RealtimeVoiceClient.swift"] {
            let text = try sourceText(of: name)
            #expect(text.contains("AVAudioEngine()"), "\(name) no longer owns an engine; update this test")
            #expect(text.contains("MicrophoneDevices.apply(preferredUID:"), "\(name) records without the chosen microphone")
        }
    }

    // MARK: language

    /// F-16: the styles page's language, not the HUD's, reaches the backend engines; auto sends none.
    @Test @MainActor func everyDictationEngineReceivesTheStylesPageLanguage() throws {
        let settings = DictationSettings(defaults: UserDefaults(suiteName: "openclicky-tests-\(UUID().uuidString)")!)
        settings.languageCode = "hi-IN"

        let openClicky = try #require(DictationEngineResolver.makeProvider(for: .openclicky, settings: settings) as? OpenAIAudioTranscriptionProvider)
        let assemblyAI = try #require(DictationEngineResolver.makeProvider(for: .assemblyai, settings: settings) as? AssemblyAIStreamingTranscriptionProvider)
        #expect(openClicky.language() == "hi")
        #expect(assemblyAI.language() == "hi")

        settings.languageCode = "auto"
        #expect(openClicky.language() == nil)
        #expect(assemblyAI.language() == nil)
    }

    /// The ⌃⌥ lane builds the provider without a dictation language and keeps the HUD's.
    @Test @MainActor func theAskLaneKeepsTheReplyLanguage() {
        #expect(OpenAIAudioTranscriptionProvider().language() == ReplyLanguage.currentCode)
    }

    /// AssemblyAI's streaming model hears Hindi and Marathi but not Tamil; the missing ones are logged.
    @Test func assemblyAIKnowsWhichLanguagesItHears() {
        #expect(AssemblyAIStreamingTranscriptionProvider.hears(languageCode: "hi"))
        #expect(AssemblyAIStreamingTranscriptionProvider.hears(languageCode: nil))
        #expect(!AssemblyAIStreamingTranscriptionProvider.hears(languageCode: "ta"))
    }

    // MARK: logging

    /// F-37: a failure in the hearing code reaches ~/Library/Logs/OpenClicky/app.log. A `print` that
    /// reports a failure must sit next to an `AppLog.append` (the print stays for the smoke runs).
    @Test func hearingFailuresAreWrittenToTheAppLog() throws {
        let failureWords = ["❌", "⚠️", "failed", "error", "denied", "unavailable", "silent"]
        let files = ["BuddyDictationManager.swift", "AppleSpeechTranscriptionProvider.swift",
                     "OpenAIAudioTranscriptionProvider.swift", "AssemblyAIStreamingTranscriptionProvider.swift"]
        for name in files {
            let lines = try sourceText(of: name).components(separatedBy: "\n")
            #expect(lines.contains { $0.contains("AppLog.append(") }, "\(name) never writes to the app log")
            for (index, line) in lines.enumerated() where line.contains("print(") {
                let lowered = line.lowercased()
                guard failureWords.contains(where: { lowered.contains($0.lowercased()) }) else { continue }
                let neighbours = lines[max(0, index - 1)...min(lines.count - 1, index + 1)]
                #expect(neighbours.contains { $0.contains("AppLog.append(") }, "\(name):\(index + 1) reports a failure with print only")
            }
        }
    }

    private func sourceText(of fileName: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("OpenClicky")
        let file = try #require(FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }.first { $0.lastPathComponent == fileName })
        return try String(contentsOf: file, encoding: .utf8)
    }
}
