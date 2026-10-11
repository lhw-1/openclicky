//
//  SettingsAccountPage.swift
//  OpenClicky
//
//  Settings → Account: who you are and what it costs. Sign in (or set up a free account with just
//  an email, in AccountSheet) or sign out; how much of the free allowance is used and what each
//  engine costs; your own OpenAI and Sarvam keys; and the backend host and token from shell.json.
//

import AppKit
import SwiftUI

extension SettingsCatalog {
    func accountItems() -> [SettingsItem] {
        [
            SettingsItem(
                id: "account.profile", page: .account, section: "",
                title: "Account", detail: "Sign in or out. A free account adds AI polish and spoken answers; dictation on this Mac works without one.",
                keywords: ["account", "sign in", "sign up", "sign out", "log in", "log out", "create", "email", "code", "free"],
                view: AnyView(AccountProfileRow())),
            SettingsItem(
                id: "account.plan", page: .account, section: "Plan & usage",
                title: "Free allowance", detail: "How much of this month’s free allowance is used.",
                keywords: ["billing", "allowance", "usage", "plan", "cost", "price", "limit"],
                view: AnyView(PlanSummary())),
            SettingsItem(
                id: "account.usage.offline", page: .account, section: "Plan & usage",
                title: "This Mac", detail: "Unlimited, no account.",
                keywords: ["offline", "free", "engine"],
                view: AnyView(SettingsRow(title: "This Mac", detail: "Unlimited, no account.") { SettingsTag(text: "Free", isPositive: true) })),
            SettingsItem(
                id: "account.usage.sarvam", page: .account, section: "Plan & usage",
                title: "Sarvam", detail: "Billed by Sarvam to your key.",
                keywords: ["sarvam", "billing", "engine", "dashboard"],
                view: AnyView(SettingsRow(title: "Sarvam", detail: "Billed by Sarvam to your key.") {
                    Button("Dashboard ↗") { openExternalLink("https://dashboard.sarvam.ai") }
                })),
            SettingsItem(
                id: "account.usage.backend", page: .account, section: "Plan & usage",
                title: "OpenAI and AssemblyAI", detail: "Through OpenClicky.",
                keywords: ["openai", "assemblyai", "allowance", "metered", "engine"],
                view: AnyView(BackendEngineUsageRow())),
            SettingsItem(
                id: "account.ownOpenAIKey", page: .account, section: "Your keys",
                title: "OpenAI", detail: "Unlocks fast voice and hands-free.",
                keywords: ["openai", "api key", "byok", "own key", "openaiApiKey"],
                view: AnyView(OwnOpenAIKeyEditor())),
            SettingsItem(
                id: "account.sarvamKey", page: .account, section: "Your keys",
                title: "Sarvam", detail: "For the Sarvam engine.",
                keywords: ["sarvam", "saaras", "api key", "api-subscription-key", "key"],
                view: AnyView(SarvamKeyEditor())),
            SettingsItem(
                id: "account.keysNote", page: .account, section: "Your keys",
                title: "Where keys go", detail: "Keys are sent to the OpenClicky backend with each request and used instead of your free allowance. Stored in ~/.openclicky/shell.json.",
                keywords: ["shell.json", "byok"],
                chrome: .footer,
                view: AnyView(SettingsFootnote(text: "Keys are sent to the OpenClicky backend with each request and used instead of your free allowance. Stored in ~/.openclicky/shell.json."))),
            SettingsItem(
                id: "account.backendHost", page: .account, section: "Backend",
                title: "Host", detail: "Where OpenClicky’s model calls go. Change it in shell.json.",
                keywords: ["backend", "server", "url", "host", "shell.json"],
                view: AnyView(BackendDetailsRow(kind: .host))),
            SettingsItem(
                id: "account.backendToken", page: .account, section: "Backend",
                title: "Session token", detail: "Written when you sign in.",
                keywords: ["token", "bearer", "shell.json", "session"],
                view: AnyView(BackendDetailsRow(kind: .token))),
        ]
    }
}

// MARK: - you

/// Signed in: the address, sign out, and the confirmation code while the address is unconfirmed.
/// Signed out: "Not signed in" and Sign In…, which opens the account sheet.
private struct AccountProfileRow: View {
    @ObservedObject private var authSession = OpenClickyAuthSession.shared
    @StateObject private var billing = BillingStatusModel()
    @State private var showsAccountSheet = false
    @State private var resendNote: String?
    @State private var resendWork = AccountWorkSlot()

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            ZStack {
                Circle().fill(authSession.accountEmail == nil ? Color(nsColor: .tertiaryLabelColor) : SettingsLook.accent)
                Text(initial).font(.system(size: 18, weight: .semibold)).foregroundStyle(.white)
            }
            .frame(width: 44, height: 44)
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                if let accountEmail = authSession.accountEmail {
                    Text(accountEmail).font(.system(size: 15, weight: .semibold))
                    Text("Signing out keeps your history on this Mac.").font(.system(size: 12)).foregroundStyle(.secondary)
                    if billing.summary?.isUnconfirmed == true {
                        HStack(spacing: 6) {
                            Text(resendNote ?? "Unconfirmed — check your inbox for the code.")
                                .font(SettingsLook.caption).foregroundStyle(.secondary)
                            Button("Resend", action: resend).buttonStyle(.link).font(SettingsLook.caption)
                        }
                        GuestConfirmationCodeField(onConfirmed: { billing.refresh() })
                    }
                } else {
                    Text("Not signed in").font(.system(size: 15, weight: .semibold))
                    Text("A free account adds AI polish and spoken answers. Dictation on this Mac works without one.")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    // Signed out by a dead sign-in, not by the person: say why, where they look.
                    if let sessionExpiredNotice = authSession.sessionExpiredNotice {
                        Text(sessionExpiredNotice).font(SettingsLook.caption).foregroundStyle(SettingsLook.danger)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            Spacer(minLength: 12)
            if authSession.accountEmail != nil {
                Button("Sign Out") {
                    authSession.signOut()
                    ShellSettingsRevision.shared.noteChanged()
                }
            } else {
                Button("Sign In…") { showsAccountSheet = true }
                    .buttonStyle(.borderedProminent)
                    .tint(SettingsLook.accent)
            }
        }
        .padding(.vertical, 6)
        .onAppear { if authSession.accountEmail != nil { billing.refresh() } }
        .onDisappear { resendWork.cancel() }
        .task { await authSession.refreshAccountsOpen() }
        .sheet(isPresented: $showsAccountSheet) {
            // The own-key field is on this page, behind the sheet: closing it is the way there.
            AccountSheet(onDone: { showsAccountSheet = false }, onUseOwnKey: { showsAccountSheet = false })
        }
    }

    private var initial: String {
        if let accountEmail = authSession.accountEmail { return String(accountEmail.prefix(1)).uppercased() }
        return String(NSFullUserName().prefix(1)).uppercased()
    }

    private func resend() {
        resendWork.start {
            let sent = await authSession.resendLink()
            resendNote = sent ? "Sent — check your inbox." : "Couldn’t send it — try again in a minute."
        }
    }
}

// MARK: - plan & usage

private struct PlanSummary: View {
    @StateObject private var billing = BillingStatusModel()
    @ObservedObject private var authSession = OpenClickyAuthSession.shared
    @ObservedObject private var shellSettingsRevision = ShellSettingsRevision.shared
    @State private var showsDetails = false

    var body: some View {
        let _ = shellSettingsRevision.revision
        VStack(alignment: .leading, spacing: 6) {
            if let summary = billing.summary {
                if summary.byok {
                    meterHeader(trailing: "Your keys")
                    Text("OpenClicky meters nothing: every request runs on your own key.").font(SettingsLook.caption).foregroundStyle(.secondary)
                } else if !summary.isMetered {
                    meterHeader(trailing: "Not metered")
                    Text("This backend meters nothing: every request runs without an allowance.").font(SettingsLook.caption).foregroundStyle(.secondary)
                } else if summary.isSwitchedOff {
                    meterHeader(trailing: "Paused")
                    Text(BillingSummary.switchedOffMessage)
                        .font(SettingsLook.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    meterHeader(trailing: "\(Int((summary.fractionUsed * 100).rounded()))% used")
                    ProgressView(value: min(1, max(0, summary.fractionUsed)))
                        .progressViewStyle(.linear)
                        .tint(SettingsLook.accent)
                    DisclosureGroup(isExpanded: $showsDetails) {
                        Text(summary.usageDetails())
                            .font(SettingsLook.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.top, 4)
                    } label: {
                        Text("Details").font(SettingsLook.caption).foregroundStyle(.secondary)
                    }
                }
            } else if OpenClickyConfiguration.usesOwnKeys {
                meterHeader(trailing: "Your keys")
                Text("No account needed: your keys in shell.json go straight to OpenAI and Anthropic, and nothing is metered.")
                    .font(SettingsLook.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if authSession.accountEmail == nil && !OpenClickyConfiguration.isConfigured {
                meterHeader(trailing: "Sign in to see usage")
                ProgressView(value: 0).progressViewStyle(.linear).tint(SettingsLook.accent)
            } else {
                meterHeader(trailing: billing.errorText ?? "Loading…")
            }
        }
        .padding(.vertical, 2)
        .onAppear { billing.refresh() }
        .onChange(of: shellSettingsRevision.revision) { _, _ in billing.refresh() }
    }

    private func meterHeader(trailing: String) -> some View {
        HStack {
            Text("Free allowance").font(SettingsLook.rowTitle)
            Spacer()
            Text(trailing).font(.system(size: 12)).foregroundStyle(.secondary)
        }
    }
}

private struct BackendEngineUsageRow: View {
    @ObservedObject private var shellSettingsRevision = ShellSettingsRevision.shared

    var body: some View {
        let _ = shellSettingsRevision.revision
        let detail: String
        let badge: String
        if OpenClickyConfiguration.usesOwnKeys {
            detail = OpenClickyConfiguration.hasAccountToken
                ? "OpenAI runs straight on your own key, not metered. AssemblyAI is on your account."
                : "OpenAI runs straight on your own key, not metered. AssemblyAI needs an account."
            badge = "Your key"
        } else if OpenClickyConfiguration.isConfigured {
            detail = "Through OpenClicky, counted against your free allowance."
            badge = "Allowance"
        } else {
            detail = "Through OpenClicky. Needs an account or your own OpenAI key."
            badge = "Needs account"
        }
        return SettingsRow(title: "OpenAI and AssemblyAI", detail: detail) {
            Text(badge).font(.system(size: 12, design: .monospaced)).foregroundStyle(.secondary)
        }
    }
}

// MARK: - your keys

private struct OwnOpenAIKeyEditor: View {
    @State private var openaiKey = OpenClickyConfiguration.settings.openaiApiKey ?? ""
    @State private var status: String?

    var body: some View {
        SettingsRow(title: "OpenAI", detail: status ?? "Unlocks fast voice and hands-free.") {
            HStack(spacing: 8) {
                SecureField("", text: $openaiKey, prompt: Text("sk-…"))
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 180)
                    .onSubmit(saveKey)
                    .accessibilityLabel("OpenAI key")
                Button("Save", action: saveKey)
            }
        }
    }

    private func saveKey() {
        let trimmed = openaiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        OpenClickyConfiguration.update { $0.openaiApiKey = trimmed.isEmpty ? nil : trimmed }
        // A changed key is a changed credential: a live realtime session reconnects with it.
        NotificationCenter.default.post(name: OpenClickyConfiguration.credentialsChangedNotification, object: nil)
        status = trimmed.isEmpty ? "Key removed." : "✓ Saved."
    }
}

/// The Sarvam key: field, test, save, and what happened. Kept in ~/.openclicky/shell.json.
private struct SarvamKeyEditor: View {
    @State private var sarvamKey = OpenClickyConfiguration.settings.sarvamKey ?? ""
    @State private var keyCheck: KeyCheck = .idle

    enum KeyCheck: Equatable {
        case idle, checking, works, saved, removed
        case failed(String)
    }

    var body: some View {
        SettingsRow(title: "Sarvam", detail: statusText) {
            HStack(spacing: 8) {
                SecureField("", text: $sarvamKey, prompt: Text("Sarvam key"))
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 180)
                    .onSubmit(saveKey)
                    .accessibilityLabel("Sarvam key")
                Button("Test", action: testKey).disabled(keyCheck == .checking)
                Button("Save", action: saveKey)
            }
        }
    }

    private var statusText: String {
        switch keyCheck {
        case .idle:
            return (OpenClickyConfiguration.settings.sarvamKey ?? "").isEmpty
                ? "For the Sarvam engine. Get one at dashboard.sarvam.ai."
                : "For the Sarvam engine. Key saved."
        case .checking: return "Checking…"
        case .works: return "✓ The key works and is saved."
        case .saved: return "✓ Saved."
        case .removed: return "Key removed."
        case .failed(let message): return message
        }
    }

    private func saveKey() {
        let trimmed = sarvamKey.trimmingCharacters(in: .whitespacesAndNewlines)
        OpenClickyConfiguration.update { $0.sarvamKey = trimmed.isEmpty ? nil : trimmed }
        ShellSettingsRevision.shared.noteChanged()
        keyCheck = trimmed.isEmpty ? .removed : .saved
    }

    private func testKey() {
        let trimmed = sarvamKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { keyCheck = .failed("Paste a key first."); return }
        keyCheck = .checking
        Task {
            do {
                _ = try await SarvamSpeechClient(key: trimmed).complete(system: "Reply with the single word: ok", user: "ping", maxTokens: 5)
                // A key that answers is worth keeping.
                saveKey()
                keyCheck = .works
            } catch {
                keyCheck = .failed(error.localizedDescription)
            }
        }
    }
}

// MARK: - backend

private struct BackendDetailsRow: View {
    enum Kind { case host, token }
    let kind: Kind
    @ObservedObject private var shellSettingsRevision = ShellSettingsRevision.shared

    var body: some View {
        let _ = shellSettingsRevision.revision
        switch kind {
        case .host:
            SettingsRow(title: "Host", detail: OpenClickyConfiguration.backendHostDescription) {
                Button("Show shell.json") { OpenClickyConfiguration.revealSettingsFile() }
                    .help(OpenClickyConfiguration.backendBaseURL)
            }
        case .token:
            SettingsRow(title: "Session token", detail: "Written when you sign in.") {
                Text(maskedToken).font(SettingsLook.key).foregroundStyle(.secondary)
            }
        }
    }

    private var maskedToken: String {
        guard let token = OpenClickyConfiguration.token else { return "None" }
        return "••••" + String(token.suffix(4))
    }
}
