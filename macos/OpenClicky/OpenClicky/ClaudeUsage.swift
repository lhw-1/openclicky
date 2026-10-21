//
//  ClaudeUsage.swift
//  OpenClicky
//
//  Claude's plan limits for the Coding agents component, read with the sign-in Claude Code
//  already keeps in the Keychain: two windows (5 hours, 7 days), each a fraction and a reset
//  time. The Keychain is read sparingly (macOS may ask each time), a refusal is remembered, and
//  the endpoint is asked only while the component is on screen.
//

import Combine
import Foundation
import Security

struct UsageWindow: Equatable {
    var fraction: Double
    var resetsAt: Date?
}

struct ClaudeUsage: Equatable {
    var fiveHour: UsageWindow
    var sevenDay: UsageWindow

    /// The usage reply: `five_hour` / `seven_day` with `utilization` (0…100) and `resets_at`.
    static func parse(_ data: Data) -> ClaudeUsage? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let fiveHour = window(object["five_hour"]), let sevenDay = window(object["seven_day"]) else { return nil }
        return ClaudeUsage(fiveHour: fiveHour, sevenDay: sevenDay)
    }

    private static func window(_ value: Any?) -> UsageWindow? {
        guard let object = value as? [String: Any], let utilization = object["utilization"] as? Double else { return nil }
        return UsageWindow(fraction: min(max(utilization / 100, 0), 1), resetsAt: (object["resets_at"] as? String).flatMap(date(from:)))
    }

    private static func date(from string: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: string) ?? ISO8601DateFormatter().date(from: string)
    }
}

enum ClaudeUsageState: Equatable {
    case none
    case signInNeeded
    case keychainRefused
    case figures(ClaudeUsage, stale: Bool)
}

enum ClaudeCredentialResult {
    case token(String)
    case missing
    case refused
}

protocol ClaudeCredentialReading {
    func readAccessToken() -> ClaudeCredentialResult
}

/// The `Claude Code-credentials` generic password: JSON with `claudeAiOauth.accessToken`.
struct KeychainClaudeCredentialReader: ClaudeCredentialReading {
    static let service = "Claude Code-credentials"

    func readAccessToken() -> ClaudeCredentialResult {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data,
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let oauth = object["claudeAiOauth"] as? [String: Any],
                  let token = oauth["accessToken"] as? String, !token.isEmpty else { return .missing }
            return .token(token)
        case errSecItemNotFound:
            return .missing
        case errSecAuthFailed, errSecInteractionNotAllowed, errSecUserCanceled:
            return .refused
        default:
            return .missing
        }
    }
}

enum ClaudeUsagePolicy {
    static let fetchInterval: TimeInterval = 300
    static let keychainInterval: TimeInterval = 1800
    static let endpoint = URL(string: "https://api.anthropic.com/api/oauth/usage")!

    static func shouldReadKeychain(lastRead: Date?, now: Date) -> Bool {
        guard let lastRead else { return true }
        return now.timeIntervalSince(lastRead) > keychainInterval
    }

    /// "resets 2 h 10 m", "resets 35 m", "resets soon"; nothing without a date.
    static func resetText(until: Date?, now: Date) -> String {
        guard let until else { return "" }
        let seconds = Int(until.timeIntervalSince(now).rounded(.down))
        guard seconds >= 60 else { return "resets soon" }
        let hours = seconds / 3600
        let minutes = (seconds % 3600) / 60
        return hours > 0 ? "resets \(hours) h \(minutes) m" : "resets \(minutes) m"
    }
}

/// One per app. `transport` performs the GET with the bearer token and returns the body and
/// the HTTP status, or nil when the network failed.
@MainActor
final class ClaudeUsageStore: ObservableObject {
    @Published private(set) var state: ClaudeUsageState = .none

    private let credentials: any ClaudeCredentialReading
    private let transport: (String) async -> (Data, Int)?
    private let now: () -> Date
    private var isEnabled = false
    private var watchers = 0
    private var timer: Timer?
    private var token: String?
    private var keychainReadAt: Date?
    private var keychainRefused = false
    private var usage: ClaudeUsage?

    init(credentials: any ClaudeCredentialReading, transport: @escaping (String) async -> (Data, Int)?, now: @escaping () -> Date = Date.init) {
        self.credentials = credentials
        self.transport = transport
        self.now = now
    }

    /// The real one: the Keychain reader and a plain `URLSession` GET.
    static func live() -> ClaudeUsageStore {
        ClaudeUsageStore(credentials: KeychainClaudeCredentialReader(), transport: { token in
            var request = URLRequest(url: ClaudeUsagePolicy.endpoint)
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.timeoutInterval = 15
            guard let (data, response) = try? await URLSession.shared.data(for: request), let http = response as? HTTPURLResponse else { return nil }
            return (data, http.statusCode)
        })
    }

    /// The component's switch: off forgets the token, the refusal and the figures.
    func setEnabled(_ enabled: Bool) {
        guard isEnabled != enabled else { return }
        isEnabled = enabled
        if !enabled {
            token = nil
            keychainReadAt = nil
            keychainRefused = false
            usage = nil
            state = .none
        }
        rebuildTimer()
    }

    func beginWatching() {
        watchers += 1
        guard watchers == 1 else { return }
        if isEnabled { Task { await refreshNow() } }
        rebuildTimer()
    }

    func endWatching() {
        watchers = max(0, watchers - 1)
        if watchers == 0 { rebuildTimer() }
    }

    /// One fetch: the Keychain when due, then the endpoint.
    func refreshNow() async {
        guard isEnabled else { return }
        if keychainRefused {
            state = .keychainRefused
            return
        }
        if token == nil || ClaudeUsagePolicy.shouldReadKeychain(lastRead: keychainReadAt, now: now()) {
            keychainReadAt = now()
            switch credentials.readAccessToken() {
            case .token(let value):
                token = value
            case .missing:
                token = nil
            case .refused:
                token = nil
                keychainRefused = true
                state = .keychainRefused
                return
            }
        }
        guard let token else {
            state = .signInNeeded
            return
        }
        guard let (data, status) = await transport(token) else {
            state = usage.map { .figures($0, stale: true) } ?? .none
            return
        }
        switch status {
        case 200:
            if let parsed = ClaudeUsage.parse(data) {
                usage = parsed
                state = .figures(parsed, stale: false)
            } else {
                state = usage.map { .figures($0, stale: true) } ?? .none
            }
        case 401:
            self.token = nil
            state = .signInNeeded
        default:
            state = usage.map { .figures($0, stale: true) } ?? .none
        }
    }

    private func rebuildTimer() {
        timer?.invalidate()
        timer = nil
        guard isEnabled, watchers > 0 else { return }
        let timer = Timer(timeInterval: ClaudeUsagePolicy.fetchInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.refreshNow() }
        }
        timer.tolerance = 10
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }
}
