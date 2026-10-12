//
//  BackendSignInTests.swift
//  OpenClickyTests
//
//  A 401 from the backend: refresh once, send once more, a second 401 signs out (F-06, F-20);
//  the expiry sentence stays reachable on the account form (F-26); a polish failure says why
//  once per session (F-32). The session side is injected, so nothing here touches shell.json.
//

import Foundation
import Testing
@testable import OpenClicky

/// Records what the injected session side was asked to do.
private actor SignInRecorder {
    var rejectionsHandled: [String?] = []
    var signOutCount = 0
    var sentAuthorizations: [String?] = []

    func noteRejection(_ sentToken: String?) { rejectionsHandled.append(sentToken) }
    func noteSignOut() { signOutCount += 1 }
    func noteSent(_ request: URLRequest) { sentAuthorizations.append(request.value(forHTTPHeaderField: "Authorization")) }
}

struct BackendSignInTests {
    private static let backendRefusal = Data(#"{"error":"invalid session token: expired"}"#.utf8)
    private static let ownKeyRefusal = Data(#"{"type":"error","error":{"type":"authentication_error","message":"invalid x-api-key"}}"#.utf8)

    private func answer(_ status: Int, _ body: Data = Data("{}".utf8)) -> (Data, URLResponse) {
        (body, HTTPURLResponse(url: URL(string: "https://backend.test/x")!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }

    private func request(token: String = "old-token") -> URLRequest {
        var request = URLRequest(url: URL(string: "https://backend.test/x")!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return request
    }

    private func signIn(_ recorder: SignInRecorder, outcome: OpenClickyAuthSession.RejectionOutcome,
                        renewedToken: String? = "new-token") -> BackendSignIn.SignInRejectionHandling {
        BackendSignIn.SignInRejectionHandling(
            handleRejection: { sentToken in await recorder.noteRejection(sentToken); return outcome },
            currentToken: { renewedToken },
            signOutExpired: { await recorder.noteSignOut() })
    }

    // MARK: the decision for one 401

    @Test func aTokenWithNothingToRefreshItSignsOut() {
        // F-06: a pasted or invite token used to answer "please ask that again" forever.
        #expect(OpenClickyAuthSession.decisionAfterRejection(
            currentToken: "pasted", sentToken: nil, hasRefreshToken: false, tokenFromLastForcedRefresh: nil) == .signOut)
    }

    @Test func theSecond401AfterARefreshSignsOut() {
        #expect(OpenClickyAuthSession.decisionAfterRejection(
            currentToken: "renewed", sentToken: nil, hasRefreshToken: true, tokenFromLastForcedRefresh: "renewed") == .signOut)
    }

    @Test func aFirst401Refreshes() {
        #expect(OpenClickyAuthSession.decisionAfterRejection(
            currentToken: "current", sentToken: "current", hasRefreshToken: true, tokenFromLastForcedRefresh: "earlier") == .refresh)
    }

    @Test func aRequestSentWithAnOlderTokenIsJustSentAgain() {
        // Another caller refreshed while this request was out: nothing is wrong with the new token.
        #expect(OpenClickyAuthSession.decisionAfterRejection(
            currentToken: "renewed", sentToken: "old", hasRefreshToken: true, tokenFromLastForcedRefresh: "renewed") == .alreadyRenewed)
    }

    @Test func noTokenHasNothingToSignOutOf() {
        #expect(OpenClickyAuthSession.decisionAfterRejection(
            currentToken: nil, sentToken: nil, hasRefreshToken: false, tokenFromLastForcedRefresh: nil) == .nothingToSignOutOf)
    }

    @Test func theAskLaneSaysWhatHappened() {
        #expect(OpenClickyAuthSession.spokenSentence(after: .tryAgain) == "please ask that again.")
        #expect(OpenClickyAuthSession.spokenSentence(after: .signedOut) == OpenClickyAuthSession.spokenSignInExpiredSentence)
        #expect(OpenClickyAuthSession.spokenSentence(after: .couldNotCheck) == OpenClickyAuthSession.unreachableMessage)
    }

    // MARK: F-26: the sentence is reachable

    @Test func theExpirySentenceSurvivesOpeningTheForm() {
        #expect(OpenClickyAuthSession.flowSurvivesFreshForm(.failed(OpenClickyAuthSession.sessionExpiredMessage)))
        #expect(!OpenClickyAuthSession.flowSurvivesFreshForm(.failed("that code didn't work. check it, or ask for a new one.")))
        #expect(!OpenClickyAuthSession.flowSurvivesFreshForm(.idle))
        #expect(!OpenClickyAuthSession.flowSurvivesFreshForm(.signedIn(confirmed: true)))
        #expect(OpenClickyAuthSession.flowSurvivesFreshForm(.needsCode(email: "a@b.co")))
    }

    @MainActor @Test func theSignInErrorReadsAsTheFormsSentence() {
        #expect(BackendSignInError.expired.localizedDescription == OpenClickyAuthSession.sessionExpiredMessage)
        #expect(BillingStatusModel.errorSentence(for: BackendSignInError.expired) == OpenClickyAuthSession.sessionExpiredMessage)
    }

    // MARK: F-20: one path for every caller

    @Test func anAcceptedRequestNeverTouchesTheSession() async throws {
        let recorder = SignInRecorder()
        let result = try await BackendSignIn.send(request(), using: { _ in answer(200) },
                                                  signIn: signIn(recorder, outcome: .signedOut))
        #expect((result.1 as? HTTPURLResponse)?.statusCode == 200)
        #expect(await recorder.rejectionsHandled.isEmpty)
    }

    @Test func a401IsRefreshedOnceAndSentAgainWithTheNewToken() async throws {
        let recorder = SignInRecorder()
        let result = try await BackendSignIn.send(request(), using: { sent in
            await recorder.noteSent(sent)
            return await recorder.sentAuthorizations.count == 1 ? answer(401, Self.backendRefusal) : answer(200)
        }, signIn: signIn(recorder, outcome: .tryAgain))
        #expect((result.1 as? HTTPURLResponse)?.statusCode == 200)
        #expect(await recorder.rejectionsHandled == ["old-token"])
        #expect(await recorder.sentAuthorizations == ["Bearer old-token", "Bearer new-token"])
        #expect(await recorder.signOutCount == 0)
    }

    @Test func aSecond401SignsOutAndThrowsExpired() async {
        let recorder = SignInRecorder()
        await #expect(throws: BackendSignInError.expired) {
            _ = try await BackendSignIn.send(request(), using: { sent in
                await recorder.noteSent(sent)
                return answer(401, Self.backendRefusal)
            }, signIn: signIn(recorder, outcome: .tryAgain))
        }
        #expect(await recorder.sentAuthorizations.count == 2)
        #expect(await recorder.signOutCount == 1)
    }

    @Test func aSignInNothingCanRenewIsNotSentAgain() async {
        let recorder = SignInRecorder()
        await #expect(throws: BackendSignInError.expired) {
            _ = try await BackendSignIn.send(request(), using: { sent in
                await recorder.noteSent(sent)
                return answer(401, Self.backendRefusal)
            }, signIn: signIn(recorder, outcome: .signedOut))
        }
        #expect(await recorder.sentAuthorizations.count == 1)
    }

    @Test func aRefreshThatCouldNotRunKeepsTheSession() async {
        let recorder = SignInRecorder()
        await #expect(throws: BackendSignInError.couldNotRenew) {
            _ = try await BackendSignIn.send(request(), using: { _ in answer(401, Self.backendRefusal) },
                                             signIn: signIn(recorder, outcome: .couldNotCheck))
        }
        #expect(await recorder.signOutCount == 0)
    }

    @Test func aRelayedOwnKey401IsNotAboutTheSignIn() async throws {
        // The proxy routes pass the provider's 401 through for a person's own key; signing them
        // out over a wrong Anthropic key would be wrong.
        let recorder = SignInRecorder()
        let result = try await BackendSignIn.send(request(), using: { _ in answer(401, Self.ownKeyRefusal) },
                                                  signIn: signIn(recorder, outcome: .signedOut))
        #expect((result.1 as? HTTPURLResponse)?.statusCode == 401)
        #expect(await recorder.rejectionsHandled.isEmpty)
        #expect(BackendSignIn.isOwnKeyRefusal(body: Self.ownKeyRefusal))
        #expect(!BackendSignIn.isOwnKeyRefusal(body: Self.backendRefusal))
    }

    // The ask lane's streamed answer goes through the same rule: its body is read only when it was
    // refused, so the stream of an accepted answer is left for the caller.
    private enum StreamedAnswer: Equatable {
        case streaming(status: Int)
        case refused(status: Int, body: Data)

        var statusAndBody: (status: Int, body: Data) {
            switch self {
            case .streaming(let status): return (status, Data())
            case .refused(let status, let body): return (status, body)
            }
        }
    }

    @Test func aStreamedQuestionIsAskedAgainAfterARefresh() async throws {
        let recorder = SignInRecorder()
        let result = try await BackendSignIn.send(request(), using: { sent in
            await recorder.noteSent(sent)
            let isFirstSend = await recorder.sentAuthorizations.count == 1
            return isFirstSend ? StreamedAnswer.refused(status: 401, body: Self.backendRefusal) : StreamedAnswer.streaming(status: 200)
        }, readingStatusAndBodyWith: { $0.statusAndBody }, signIn: signIn(recorder, outcome: .tryAgain))
        #expect(result == .streaming(status: 200))
        #expect(await recorder.sentAuthorizations == ["Bearer old-token", "Bearer new-token"])
    }

    @Test func aStreamedQuestionsOwnKeyRefusalComesBackAsItCame() async throws {
        let recorder = SignInRecorder()
        let result = try await BackendSignIn.send(request(), using: { _ in StreamedAnswer.refused(status: 401, body: Self.ownKeyRefusal) },
                                                  readingStatusAndBodyWith: { $0.statusAndBody },
                                                  signIn: signIn(recorder, outcome: .signedOut))
        #expect(result == .refused(status: 401, body: Self.ownKeyRefusal))
        #expect(await recorder.rejectionsHandled.isEmpty)
    }

    // The refusal ClaudeAPI and the voice throw keeps the body as it came and the old description,
    // and bridges to an NSError whose code is the status (what the log lines print).
    @Test func aRefusalKeepsItsBodyAndReadsAsBefore() {
        let body = Data(#"{"error":"daily_limit"}"#.utf8)
        let question = BackendHTTPError(service: .answers, status: 402, body: body)
        #expect(question.localizedDescription == #"API Error (402): {"error":"daily_limit"}"#)
        #expect((question as NSError).code == 402)
        #expect(BackendHTTPError(service: .voice, status: 402, body: body).localizedDescription == #"TTS API error (402): {"error":"daily_limit"}"#)
    }

    @Test func thePolisherRetriesAfterARefresh() async throws {
        let recorder = SignInRecorder()
        let polisher = AccountTakePolisher(purpose: "polish", send: { sent in
            await recorder.noteSent(sent)
            return await recorder.sentAuthorizations.count == 1 ? answer(401, Self.backendRefusal) : answer(200, Data(#"{"text":"Hi."}"#.utf8))
        }, signIn: signIn(recorder, outcome: .tryAgain),
        // Its own token: CI has none stored, and a request without one is never refreshed.
        authorize: { $0.setValue("Bearer old-token", forHTTPHeaderField: "Authorization") })
        #expect(try await polisher.polish(system: "s", user: "hi") == "Hi.")
    }

    // MARK: F-32: the polish failure's reason, once

    @MainActor @Test func aPolishLimitIsSaidOncePerSession() {
        var shown: Set<String> = []
        let limit = AccountPolishError.limit(.personalLimit)
        #expect(PolishFailureNotice.sentenceToShow(for: limit, alreadyShown: &shown) == AccountLimitError.personalLimit.message)
        #expect(PolishFailureNotice.sentenceToShow(for: limit, alreadyShown: &shown) == nil)
    }

    @Test func eachPolishFailureHasItsOwnReason() {
        #expect(PolishFailureNotice.sentence(for: AccountPolishError.unavailable(503)) == AccountLimitError.serviceTroubleMessage)
        #expect(PolishFailureNotice.sentence(for: BackendPolishError.refused(status: 401, message: "")) == PolishFailureNotice.ownKeyRefusedSentence)
        // The sign-out already said it; a timeout or a passing 5xx is for the log only.
        #expect(PolishFailureNotice.sentence(for: BackendSignInError.expired) == nil)
        #expect(PolishFailureNotice.sentence(for: AccountPolishError.unavailable(500)) == nil)
        #expect(PolishFailureNotice.sentence(for: CancellationError()) == nil)
        // Not Sarvam's error any more: the log names OpenClicky.
        #expect(BackendPolishError.refused(status: 500, message: "x").localizedDescription.hasPrefix("openclicky refused"))
    }
}
