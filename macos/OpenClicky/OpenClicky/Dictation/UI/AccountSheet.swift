//
//  AccountSheet.swift
//  OpenClicky
//
//  The account sheet: a heading, the one email form (EmailAccountForm), and "not now".
//  Also the work slot the form runs its requests in.
//

import SwiftUI

struct AccountSheet: View {
    let onDone: () -> Void
    /// Offered under the email field; nil leaves the link out.
    var onUseOwnKey: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("your free openclicky account")
                .font(SettingsLook.body(20, weight: .semibold))
            Text("polished dictation and spoken answers, on us: up to $10 of use a month once your email is confirmed.")
                .font(SettingsLook.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            EmailAccountForm(onSignedIn: onDone, onUseOwnKey: onUseOwnKey)
            Button("not now", action: onDone)
                .keyboardShortcut(.cancelAction)
                .pointerCursor()
        }
        .padding(28)
        .frame(width: 440, alignment: .leading)
    }
}

/// Holds the one sign-up or sign-in a sheet runs at a time. `start` refuses while one is running
/// and says so synchronously, before the task has had a chance to run a single line.
@MainActor
final class AccountWorkSlot {
    private(set) var isRunning = false
    private var task: Task<Void, Never>?

    @discardableResult
    func start(_ work: @escaping @MainActor () async -> Void) -> Bool {
        guard !isRunning else { return false }
        isRunning = true
        task = Task { @MainActor [weak self] in
            await work()
            self?.isRunning = false
        }
        return true
    }

    func cancel() { task?.cancel() }
}
