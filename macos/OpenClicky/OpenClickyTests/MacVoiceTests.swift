//
//  MacVoiceTests.swift
//  OpenClickyTests
//
//  This Mac's voice: when it is chosen (shell.json `speechVoice`), how its voices are labelled,
//  and that the setting survives a round trip through shell.json's encoding.
//

import AVFoundation
import Foundation
import Testing
@testable import OpenClicky

@MainActor
struct MacVoiceTests {
    @Test func onlyMacMeansTheMacVoice() {
        var settings = OpenClickyShellSettings()
        #expect(!MacVoice.isChosen(settings: settings))
        settings.speechVoice = "cloud"
        #expect(!MacVoice.isChosen(settings: settings))
        settings.speechVoice = "mac"
        #expect(MacVoice.isChosen(settings: settings))
    }

    @Test func voicesSayTheirRegionAndQuality() {
        #expect(MacVoice.Choice(id: "a", name: "Eddy", region: "United Kingdom", quality: .default).label == "Eddy, United Kingdom")
        #expect(MacVoice.Choice(id: "b", name: "Ava", region: "United States", quality: .premium).label == "Ava, United States (Premium)")
        #expect(MacVoice.Choice(id: "c", name: "Zoe", region: nil, quality: .enhanced).label == "Zoe (Enhanced)")
    }

    @Test func theVoiceChoiceRoundTripsThroughShellJSON() throws {
        var settings = OpenClickyShellSettings()
        settings.speechVoice = "mac"
        settings.macVoiceIdentifier = "com.apple.voice.premium.en-US.Ava"
        let decoded = try JSONDecoder().decode(OpenClickyShellSettings.self, from: JSONEncoder().encode(settings))
        #expect(decoded.speechVoice == "mac")
        #expect(decoded.macVoiceIdentifier == "com.apple.voice.premium.en-US.Ava")
    }
}
