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
    /// Puts the stored sign-in on the request; injectable so tests carry a token of their own
    /// (a request sent without one gets its 401 back, never a refresh).
    var authorize: (inout URLRequest) -> Void = { OpenClickyConfiguration.authorize(&$0) }

    var displayName: String { "OpenClicky" }

    func polish(system: String, user: String) async throws -> String {
        guard let url = URL(string: "\(OpenClickyConfiguration.backendBaseURL)/v1/polish") else { throw AccountPolishError.unavailable(0) }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        authorize(&request)
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

/// Polish and edits on the person's own Anthropic key, straight to Anthropic: the request the
/// backend's /v1/polish sends upstream (polish.ts), on Claude Haiku. No account involved.
struct AnthropicTakePolisher: TakePolisher {
    let anthropicKey: String
    var send: @Sendable (URLRequest) async throws -> (Data, URLResponse) = { try await URLSession.shared.data(for: $0) }

    var displayName: String { "Claude (your key)" }

    func polish(system: String, user: String) async throws -> String {
        var request = try DirectProviderRequests.anthropicPolish(key: anthropicKey, system: system, text: user)
        request.timeoutInterval = 20
        let (data, response) = try await send(request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            AppLog.append("polish (own anthropic key): anthropic answered \(status)")
            throw BackendPolishError.refused(status: status, message: String(decoding: data.prefix(200), as: UTF8.self))
        }
        guard let text = DirectProviderRequests.anthropicReplyText(from: data) else {
            AppLog.append("polish (own anthropic key): the reply had no whole text")
            throw BackendPolishError.unreadable
        }
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

/// Polish and edits on any other answer key the person added (OpenRouter, Gemini, Groq, Mistral,
/// xAI), straight to that vendor through the ask lane's own provider. A quick model where the
/// default answer model is a slow one: the clean-up gives up after `TakeFormatter.modelTimeoutSeconds`.
/// The two plans are left out: starting their CLI alone takes longer than that.
struct AnswerKeyTakePolisher: TakePolisher {
    let source: AnswerSource
    let credentials: ProviderCredentials

    /// The keys that can polish, in the order they are tried; the fast ones first.
    static let sourcesInOrder: [AnswerSource] = [.groq, .gemini, .mistral, .openRouter, .xai]

    /// The model asked to tidy a take, where it differs from the answer model.
    static func polishModel(for source: AnswerSource) -> String? {
        switch source {
        case .openRouter: return "openai/gpt-4.1-mini"
        case .mistral: return "mistral-small-latest"
        default: return nil
        }
    }

    /// The first source with a key, nil without any.
    static func firstAvailable(credentials: ProviderCredentials) -> AnswerKeyTakePolisher? {
        sourcesInOrder.first { credentials.key(for: $0) != nil }.map { AnswerKeyTakePolisher(source: $0, credentials: credentials) }
    }

    var displayName: String { "\(source.shortName) (your key)" }

    func polish(system: String, user: String) async throws -> String {
        var models: [String: String] = [:]
        if let model = Self.polishModel(for: source) { models[source.rawValue] = model }
        let provider = try await AnswerProviderFactory.make(for: source, credentials: credentials, modelOverrides: models)
        let request = AnswerRequest(images: [], systemPrompt: system, history: [], userPrompt: user, tools: [], maxTokens: 1024)
        do {
            let result = try await provider.answer(request, onTextChunk: { _ in })
            let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { throw BackendPolishError.unreadable }
            return text
        } catch let error as AnswerProviderError {
            AppLog.append("polish (own \(source.rawValue) key): \(error.status)")
            throw BackendPolishError.refused(status: error.status, message: error.message)
        }
    }
}
