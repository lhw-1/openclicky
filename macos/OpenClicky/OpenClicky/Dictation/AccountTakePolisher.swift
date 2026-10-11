//
//  AccountTakePolisher.swift
//  OpenClicky
//
//  Polish and Hey Clicky edits for signed-in accounts: the app says what to do and sends the
//  words; the backend picks the model (a cheap one) and bills the grant. A limit throws a typed
//  error so the take still pastes with local cleanup.
//

import Foundation

enum AccountPolishError: Error, Equatable {
    case limit(AccountLimitError)
    case unavailable(Int)
}

extension AccountPolishError: LocalizedError {
    /// A plain sentence for the orb and Hey Clicky edits, never "error 0".
    var errorDescription: String? {
        if case .limit(let limit) = self, !limit.message.isEmpty { return limit.message }
        if case .unavailable(503) = self { return AccountLimitError.serviceTroubleMessage }
        return "couldn't reach openclicky right now."
    }
}

struct AccountTakePolisher: TakePolisher {
    var purpose: String = "polish"
    var send: (URLRequest) async throws -> (Data, URLResponse) = { try await URLSession.shared.data(for: $0) }
    /// What a 401 does to the session (refresh once, sign out on the second); injectable for tests.
    var signIn: BackendSignIn.SignInRejectionHandling = .live

    var displayName: String { "OpenClicky" }

    func polish(system: String, user: String) async throws -> String {
        guard let url = URL(string: "\(OpenClickyConfiguration.backendBaseURL)/v1/polish") else { throw AccountPolishError.unavailable(0) }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        OpenClickyConfiguration.authorize(&request)
        request.httpBody = try JSONSerialization.data(withJSONObject: ["purpose": purpose, "system": system, "text": user])
        // A refused sign-in is refreshed once and sent again; a second refusal throws
        // `BackendSignInError.expired`, whose sentence is the sign-in one, not "couldn't reach".
        let (data, response) = try await BackendSignIn.send(request, using: send, signIn: signIn)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if let limit = AccountLimitError.from(status: status, body: data) { throw AccountPolishError.limit(limit) }
        guard (200..<300).contains(status),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let text = json["text"] as? String else { throw AccountPolishError.unavailable(status) }
        return text
    }
}

/// Why a take was pasted with only the local clean-up, said once per session (every take hitting
/// the same limit would otherwise repeat it). The orb still says "cleaned up locally"; this is the
/// reason behind it, shown as the companion's quiet caption. Nil for a reason not worth saying
/// (a timeout, a passing server error): the log has those.
enum PolishFailureNotice {
    static func sentence(for error: Error) -> String? {
        switch error {
        case BackendSignInError.expired:
            // Signing out already said so, on the account page and in a caption.
            return nil
        case AccountPolishError.limit(let limit):
            return limit.message.isEmpty ? nil : limit.message
        case AccountPolishError.unavailable(503):
            return AccountLimitError.serviceTroubleMessage
        case BackendPolishError.refused(let status, _) where status == 401 || status == 403:
            return ownKeyRefusedSentence
        default:
            return nil
        }
    }

    static let ownKeyRefusedSentence = "your own api key was refused, so your words were cleaned up locally — check the key in settings, account."

    /// Sentences already shown this session.
    @MainActor private static var shownSentences: Set<String> = []

    /// Returns the sentence when it is new this session (and marks it shown), nil otherwise.
    @MainActor static func sentenceToShow(for error: Error, alreadyShown: inout Set<String>) -> String? {
        guard let sentence = sentence(for: error), !alreadyShown.contains(sentence) else { return nil }
        alreadyShown.insert(sentence)
        return sentence
    }

    @MainActor static func note(_ error: Error) {
        guard let sentence = sentenceToShow(for: error, alreadyShown: &shownSentences) else { return }
        AccountProfileStore.shared.showNotice?(sentence)
    }
}
