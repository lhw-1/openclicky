//
//  ClaudeUsageTests.swift
//  OpenClickyTests
//
//  Claude's plan limits: the reply's two windows, how a reset reads, and the store's states
//  (sign in, a refused Keychain, stale figures).
//

import Foundation
import Testing
@testable import OpenClicky

struct ClaudeUsageTests {
    let reply = Data(#"{"five_hour":{"utilization":38.0,"resets_at":"2026-10-21T15:00:00.000000+00:00"},"seven_day":{"utilization":37.0,"resets_at":"2026-10-25T09:00:00+00:00"},"extra_usage":{}}"#.utf8)

    @Test func theReplyBecomesTwoWindows() throws {
        let usage = try #require(ClaudeUsage.parse(reply))
        #expect(usage.fiveHour.fraction == 0.38)
        #expect(usage.sevenDay.fraction == 0.37)
        #expect(usage.fiveHour.resetsAt == ISO8601DateFormatter().date(from: "2026-10-21T15:00:00Z"))
        #expect(ClaudeUsage.parse(Data("{}".utf8)) == nil)
    }

    @Test func resetsReadShort() {
        let now = Date()
        #expect(ClaudeUsagePolicy.resetText(until: now.addingTimeInterval(2 * 3600 + 10 * 60 + 5), now: now) == "resets 2 h 10 m")
        #expect(ClaudeUsagePolicy.resetText(until: now.addingTimeInterval(35 * 60), now: now) == "resets 35 m")
        #expect(ClaudeUsagePolicy.resetText(until: now.addingTimeInterval(30), now: now) == "resets soon")
        #expect(ClaudeUsagePolicy.resetText(until: nil, now: now) == "")
        #expect(ClaudeUsagePolicy.shouldReadKeychain(lastRead: nil, now: now))
        #expect(!ClaudeUsagePolicy.shouldReadKeychain(lastRead: now.addingTimeInterval(-1799), now: now))
        #expect(ClaudeUsagePolicy.shouldReadKeychain(lastRead: now.addingTimeInterval(-1801), now: now))
    }

    @MainActor @Test func theStoreTellsSignInFromARefusedKeychainFromStaleFigures() async {
        final class Reader: ClaudeCredentialReading {
            var result: ClaudeCredentialResult = .missing
            var reads = 0
            func readAccessToken() -> ClaudeCredentialResult { reads += 1; return result }
        }
        final class Server { var status = 200; var data = Data() }
        let reader = Reader()
        let server = Server()
        server.data = reply
        let store = ClaudeUsageStore(credentials: reader, transport: { _ in (server.data, server.status) })
        store.setEnabled(true)
        await store.refreshNow()
        #expect(store.state == .signInNeeded)
        reader.result = .refused
        await store.refreshNow()
        #expect(store.state == .keychainRefused)
        await store.refreshNow()
        #expect(reader.reads == 2)             // a refusal is remembered: no second prompt
        store.setEnabled(false)
        store.setEnabled(true)
        reader.result = .token("t")
        await store.refreshNow()
        guard case .figures(let usage, let stale) = store.state else { Issue.record("no figures"); return }
        #expect(usage.fiveHour.fraction == 0.38 && !stale)
        server.status = 500
        await store.refreshNow()
        #expect(store.state == .figures(usage, stale: true))
        server.status = 401
        await store.refreshNow()
        #expect(store.state == .signInNeeded)
    }
}
