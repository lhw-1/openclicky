//
//  BackendProxyURLFallbackTests.swift
//  OpenClickyTests
//
//  ClaudeAPI and AnswerVoicePlayer build their backend URL from the user-configurable backend
//  base URL (shell.json or an environment override), not a compile-time literal. A malformed value
//  must fall back to the hosted backend's own endpoint instead of force-unwrapping into a crash.
//

import Foundation
import Testing
@testable import OpenClicky

struct BackendProxyURLFallbackTests {
    @Test func claudeAPIUsesTheProxyURLWhenItParses() {
        let url = ClaudeAPI.resolvedAPIURL(fromProxyURL: "https://example.com/chat")
        #expect(url.absoluteString == "https://example.com/chat")
    }

    @Test func claudeAPIFallsBackToTheHostedBackendWhenTheProxyURLDoesNotParse() {
        // An empty string is the one input that reliably fails URL(string:) on every Foundation
        // version, which is what makes it a good stand-in for "the configured backend URL is
        // malformed" in this test.
        let url = ClaudeAPI.resolvedAPIURL(fromProxyURL: "")
        #expect(url.absoluteString == "\(OpenClickyConfiguration.hostedBackendURL)/chat")
    }

    @Test func elevenLabsUsesTheProxyURLWhenItParses() {
        let url = AnswerVoicePlayer.resolvedProxyURL(fromProxyURL: "https://example.com/tts")
        #expect(url.absoluteString == "https://example.com/tts")
    }

    @Test func elevenLabsFallsBackToTheHostedBackendWhenTheProxyURLDoesNotParse() {
        let url = AnswerVoicePlayer.resolvedProxyURL(fromProxyURL: "")
        #expect(url.absoluteString == "\(OpenClickyConfiguration.hostedBackendURL)/tts")
    }

    // F-31: the backend URL is read per request, so an edit to shell.json reaches the next question.
    @MainActor @Test func theClientsReadTheBackendURLForEveryRequest() {
        var currentBackend = "https://first.example"
        let claudeAPI = ClaudeAPI(currentProxyURL: { "\(currentBackend)/chat" })
        #expect(claudeAPI.apiURL.absoluteString == "https://first.example/chat")
        currentBackend = "https://second.example"
        #expect(claudeAPI.apiURL.absoluteString == "https://second.example/chat")

        let ttsClient = AnswerVoicePlayer(currentProxyURL: { "\(currentBackend)/tts" })
        #expect(ttsClient.proxyURL.absoluteString == "https://second.example/tts")
        currentBackend = "https://third.example"
        #expect(ttsClient.proxyURL.absoluteString == "https://third.example/tts")
    }
}
