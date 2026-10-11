//
//  BackendSignIn.swift
//  OpenClicky
//
//  One answer to "the backend said 401" for every caller. Before this, only the ⌃⌥ Claude lane
//  handled a refused sign-in; polish, transcription, the voice, realtime, skills and billing each
//  swallowed it their own way (one blamed Sarvam). The rule here: refresh once, send once more
//  with the new token, and a second 401 signs out and throws `BackendSignInError.expired`, whose
//  sentence is the one the account form shows.
//

import Foundation

/// A backend request the sign-in was refused for, and one refresh did not fix.
nonisolated enum BackendSignInError: LocalizedError, Equatable {
    /// Signed out (or never signed in): the person has to sign in again.
    case expired
    /// The refresh could not be tried (offline, sign-in server down); the session is kept.
    case couldNotRenew

    var errorDescription: String? {
        switch self {
        case .expired: return OpenClickyAuthSession.sessionExpiredMessage
        case .couldNotRenew: return OpenClickyAuthSession.unreachableMessage
        }
    }
}

nonisolated enum BackendSignIn {
    typealias Transport = (URLRequest) async throws -> (Data, URLResponse)

    /// Sends a backend request authorised with the stored token. On a 401 about the sign-in it
    /// refreshes once and sends the request again with the new token; a second 401 signs out and
    /// throws `.expired`. Any other answer (including a 401 relayed from the person's own
    /// provider key) is returned as it is, for the caller to read.
    static func send(_ request: URLRequest, using transport: Transport,
                     signIn: SignInRejectionHandling = .live) async throws -> (Data, URLResponse) {
        let firstAnswer = try await transport(request)
        guard isSignInRejection(status: statusCode(of: firstAnswer.1), body: firstAnswer.0) else { return firstAnswer }
        switch await signIn.handleRejection(bearerToken(in: request)) {
        case .signedOut: throw BackendSignInError.expired
        case .couldNotCheck: throw BackendSignInError.couldNotRenew
        case .tryAgain: break
        }
        guard let renewedToken = await signIn.currentToken() else { throw BackendSignInError.expired }
        var retriedRequest = request
        retriedRequest.setValue("Bearer \(renewedToken)", forHTTPHeaderField: "Authorization")
        let secondAnswer = try await transport(retriedRequest)
        guard isSignInRejection(status: statusCode(of: secondAnswer.1), body: secondAnswer.0) else { return secondAnswer }
        // A token just renewed and refused as well: the sign-in itself is dead, not its token.
        AppLog.append("sign-in: the renewed token was refused too; signing out")
        await signIn.signOutExpired()
        throw BackendSignInError.expired
    }

    /// The session side of `send`, injectable so tests never touch the real shell.json.
    struct SignInRejectionHandling: Sendable {
        var handleRejection: @Sendable (_ sentToken: String?) async -> OpenClickyAuthSession.RejectionOutcome
        var currentToken: @Sendable () async -> String?
        var signOutExpired: @Sendable () async -> Void

        static let live = SignInRejectionHandling(
            handleRejection: { sentToken in await OpenClickyAuthSession.shared.handleBackendRejection(sentToken: sentToken) },
            currentToken: { await MainActor.run { OpenClickyConfiguration.token } },
            signOutExpired: { await OpenClickyAuthSession.shared.signOut(becauseSignInExpired: true) })
    }

    /// A 401 from the backend's own sign-in check carries `{"error": "<sentence>"}`. The proxy
    /// routes relay the provider's own 401 for a person's own key, whose `error` is an object;
    /// that one is about the key, and must never sign anybody out.
    static func isSignInRejection(status: Int, body: Data) -> Bool {
        status == 401 && !isOwnKeyRefusal(body: body)
    }

    static func isOwnKeyRefusal(body: Data) -> Bool {
        guard let json = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] else { return false }
        return json["error"] is [String: Any]
    }

    static func statusCode(of response: URLResponse) -> Int {
        (response as? HTTPURLResponse)?.statusCode ?? 0
    }

    static func bearerToken(in request: URLRequest) -> String? {
        guard let header = request.value(forHTTPHeaderField: "Authorization"), header.hasPrefix("Bearer ") else { return nil }
        return String(header.dropFirst("Bearer ".count))
    }
}
