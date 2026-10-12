//
//  BillingStatus.swift
//  OpenClicky
//
//  What the account has used (GET /billing/me) and the sentences that say it: the free
//  allowance this month and today, the shared budget, the spoken characters. Also the island's
//  account rows in Settings → more: sign in, or the allowance and sign out; with an own key in
//  shell.json, "not metered".
//

import AppKit
import Combine
import SwiftUI

struct BillingSummary: Decodable, Equatable {
    let byok: Bool
    let spentMonthUsd: Double
    let monthlyLimitUsd: Double
    let spentTodayUsd: Double
    let dailyLimitUsd: Double
    let ttsCharsMonth: Int
    let ttsCharsLimit: Int
    let monthEnd: String
    let dayEnd: String
    let budgetExhausted: Bool
    let blocked: Bool
    /// "grant", "byok" or "unmetered"; older backends send neither of these two.
    var plan: String? = nil
    /// For a grant login: whether it has an OpenClicky account (and is not paused).
    var onPlan: Bool? = nil
    /// Email-first accounts: false until the confirmation link is clicked; older backends omit it.
    var confirmed: Bool? = nil
    /// The Mac's starter allowance (spend before confirming) and its cap.
    var guestSpentUsd: Double? = nil
    var guestLimitUsd: Double? = nil
    /// Masked, e.g. "p•••@flowsxr.com".
    var email: String? = nil

    var isUnconfirmed: Bool { confirmed == false }
}

/// Where the free allowance stands, most pressing first: each case has its own sentence because
/// "used up this month" is wrong when only today's share or the shared budget ran out.
enum AllowanceStanding: Equatable { case plenty, runningLow, usedUpThisMonth, usedUpToday, sharedBudgetUsedUp, paused, unconfirmed }

extension BillingSummary {
    var allowanceStanding: AllowanceStanding {
        if blocked { return .paused }
        if confirmed == false { return .unconfirmed }
        if fractionUsed >= 1 { return .usedUpThisMonth }
        if budgetExhausted { return .sharedBudgetUsedUp }
        if dailyLimitUsd > 0 && spentTodayUsd >= dailyLimitUsd { return .usedUpToday }
        return level == .runningLow ? .runningLow : .plenty
    }

    /// One calm line under the usage bar and in the island ("plenty left this month · resets on
    /// nov 1"). `resetDay` is `monthResetDay(...)`; nil when the date could not be read.
    func allowanceSentence(resetDay: String?) -> String {
        let onResetDay = resetDay.map { "on \($0)" } ?? "on the 1st"
        switch allowanceStanding {
        case .plenty: return "plenty left this month · resets \(onResetDay)"
        case .runningLow: return "running low this month · resets \(onResetDay)"
        case .usedUpThisMonth: return "this month's free allowance is used, it comes back \(onResetDay)"
        case .usedUpToday: return "today's free allowance is used, it comes back tomorrow"
        case .sharedBudgetUsedUp: return "the free allowance is used up for now"
        case .paused: return "this account is paused, dictation still works"
        case .unconfirmed:
            let limit = guestLimitUsd ?? 0, spent = guestSpentUsd ?? 0
            if limit > 0 && spent >= limit { return "the starter allowance is used, confirm your email to keep going" }
            let percent = limit > 0 ? Int((spent / limit * 100).rounded()) : 0
            return "confirm your email to unlock the full free allowance · \(percent)% of the starter used"
        }
    }

    /// The day the month's allowance comes back, as "nov 1". Months are UTC calendar months, so
    /// the date is read in UTC: midnight on the 1st is still the 31st in the Americas otherwise.
    func monthResetDay(locale: Locale = .current) -> String? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let date = fractional.date(from: monthEnd) ?? ISO8601DateFormatter().date(from: monthEnd),
              let utc = TimeZone(identifier: "UTC") else { return nil }
        let style = Date.FormatStyle(locale: locale, timeZone: utc).day().month(.abbreviated)
        return date.formatted(style).lowercased()
    }

    /// The "details" line: "$4.50 of $10 this month · 300 spoken characters of 20,000" (with "· $0.20 of $2 today" when a daily limit is set).
    func usageDetails(locale: Locale = .current) -> String {
        func dollars(_ amount: Double) -> String {
            amount == amount.rounded() ? "$\(Int(amount))" : String(format: "$%.2f", amount)
        }
        func count(_ number: Int) -> String { number.formatted(.number.locale(locale)) }
        // No daily limit (0) is the norm since 2026-10-12: only the month is shown then.
        let todayPart = dailyLimitUsd > 0 ? " · \(dollars(spentTodayUsd)) of \(dollars(dailyLimitUsd)) today" : ""
        return "\(dollars(spentMonthUsd)) of \(dollars(monthlyLimitUsd)) this month\(todayPart) · \(count(ttsCharsMonth)) spoken characters of \(count(ttsCharsLimit))"
    }
}

@MainActor
final class BillingStatusModel: ObservableObject {
    @Published var summary: BillingSummary?
    @Published var errorText: String?

    func refresh() {
        guard OpenClickyConfiguration.hasAccountToken else {
            summary = nil
            return
        }
        Task {
            do {
                let fetched = try await Self.fetchSummary()
                summary = fetched
                errorText = nil
                AccountProfileStore.shared.absorb(fetched)
            } catch {
                errorText = Self.errorSentence(for: error)
                AppLog.append("billing: /billing/me failed: \(error.localizedDescription)")
            }
        }
    }

    /// GET /billing/me. Errors carry the HTTP status as their code (503 means the free service's ledger is down).
    static func fetchSummary() async throws -> BillingSummary {
        // backendBaseURL is user-configurable (shell.json or an environment override), not
        // a compile-time literal, so a malformed value must throw instead of crashing the app.
        guard let billingURL = URL(string: "\(OpenClickyConfiguration.backendBaseURL)/billing/me") else {
            throw NSError(domain: "OpenClickyBilling", code: -1, userInfo: [NSLocalizedDescriptionKey: "backend URL is invalid"])
        }
        var request = URLRequest(url: billingURL)
        OpenClickyConfiguration.authorize(&request)
        let (data, response) = try await BackendSignIn.send(request) { try await URLSession.shared.data(for: $0) }
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard statusCode == 200 else {
            throw NSError(domain: "OpenClickyBilling", code: statusCode, userInfo: [NSLocalizedDescriptionKey: statusCode == 401 ? "session expired, sign in again" : "backend answered \(statusCode)"])
        }
        return try JSONDecoder().decode(BillingSummary.self, from: data)
    }

    static func errorSentence(for error: Error) -> String {
        // A refused sign-in has already been refreshed once, or signed out; its sentence says which.
        if let signInError = error as? BackendSignInError { return signInError.localizedDescription }
        switch (error as NSError).code {
        case 401: return "your sign-in ran out, sign in again."
        case 503: return AccountLimitError.serviceTroubleMessage
        default: return "couldn't load your allowance right now."
        }
    }
}
