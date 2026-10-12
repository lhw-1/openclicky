import Foundation
import Testing
@testable import OpenClicky

@MainActor
struct EmailAccountFlowTests {
    private let device = String(repeating: "d", count: 64)
    private func json(_ s: String) -> Data { Data(s.utf8) }

    @Test func startPostsTheEmailAndDevice() throws {
        let request = try #require(OpenClickyAuthSession.startRequest(backendBaseURL: "https://api.example", email: "gran@example.com", device: device))
        #expect(request.url?.absoluteString == "https://api.example/auth/start")
        #expect(request.httpMethod == "POST")
        let body = try JSONSerialization.jsonObject(with: try #require(request.httpBody)) as? [String: String]
        #expect(body == ["email": "gran@example.com", "device": device])
    }

    @Test func eachAnswerBecomesOneOutcome() {
        let signedIn = OpenClickyAuthSession.outcome(status: 200, body: json(#"{"status":"signed_in","session":{"access_token":"a","refresh_token":"r","expires_in":3600},"confirmed":false}"#), email: "g@x.co")
        #expect(signedIn == .signedIn(.init(access_token: "a", refresh_token: "r", expires_in: 3600), confirmed: false))
        #expect(OpenClickyAuthSession.outcome(status: 200, body: json(#"{"status":"code_sent"}"#), email: "g@x.co") == .codeSent)
        #expect(OpenClickyAuthSession.outcome(status: 402, body: json(#"{"error":"accounts_full"}"#), email: "g@x.co") == .failed(AccountLimitError.accountsFull.message))
        #expect(OpenClickyAuthSession.outcome(status: 402, body: json(#"{"error":"device_limit"}"#), email: "g@x.co") == .failed(AccountLimitError.deviceLimit.message))
        #expect(OpenClickyAuthSession.outcome(status: 400, body: json(#"{"error":"bad_email"}"#), email: "g") == .failed("that doesn't look like an email address."))
        #expect(OpenClickyAuthSession.outcome(status: 401, body: json(#"{"error":"bad_code"}"#), email: "g@x.co") == .failed("that code didn't work. check it, or ask for a new one."))
        #expect(OpenClickyAuthSession.outcome(status: 429, body: json(#"{"error":"slow_down"}"#), email: "g@x.co") == .failed("too many tries, wait a few minutes and try again."))
        #expect(OpenClickyAuthSession.outcome(status: 502, body: json("{}"), email: "g@x.co") == .failed("couldn't reach openclicky right now, try again in a minute."))
        #expect(OpenClickyAuthSession.outcome(status: 200, body: json("not json"), email: "g@x.co") == .failed("couldn't reach openclicky right now, try again in a minute."))
    }

    @Test func codeAndResendRequests() throws {
        let code = try #require(OpenClickyAuthSession.codeRequest(backendBaseURL: "https://api.example", email: "g@x.co", code: "123456", device: device))
        #expect(code.url?.path == "/auth/code")
        // F-42: the code sign-in carries the same device hash as /auth/start.
        #expect((try JSONSerialization.jsonObject(with: try #require(code.httpBody)) as? [String: String]) == ["email": "g@x.co", "code": "123456", "device": device])
        let resend = try #require(OpenClickyAuthSession.resendRequest(backendBaseURL: "https://api.example", token: "tok"))
        #expect(resend.url?.path == "/auth/resend")
        #expect(resend.value(forHTTPHeaderField: "Authorization") == "Bearer tok")
    }

    // MARK: F-42 (Mac half): confirming a guest's email with the code

    @Test func confirmPostsTheCodeWithTheGuestsToken() throws {
        let confirm = try #require(OpenClickyAuthSession.confirmRequest(backendBaseURL: "https://api.example", token: "guest", code: "123456"))
        #expect(confirm.url?.path == "/auth/confirm")
        #expect(confirm.httpMethod == "POST")
        #expect(confirm.value(forHTTPHeaderField: "Authorization") == "Bearer guest")
        #expect((try JSONSerialization.jsonObject(with: try #require(confirm.httpBody)) as? [String: String]) == ["code": "123456"])
    }

    @Test func eachConfirmAnswerBecomesOneOutcome() {
        let signedIn = OpenClickyAuthSession.confirmOutcome(status: 200, body: json(#"{"status":"signed_in","session":{"access_token":"a2","refresh_token":"r2","expires_in":3600},"confirmed":true}"#))
        #expect(signedIn == .signedIn(.init(access_token: "a2", refresh_token: "r2", expires_in: 3600)))
        #expect(OpenClickyAuthSession.confirmOutcome(status: 200, body: json(#"{"status":"already_confirmed"}"#)) == .alreadyConfirmed)
        #expect(OpenClickyAuthSession.confirmOutcome(status: 401, body: json(#"{"error":"bad_code"}"#)) == .failed(OpenClickyAuthSession.badCodeMessage))
        // An older backend has no /auth/confirm: the link stays the way.
        #expect(OpenClickyAuthSession.confirmOutcome(status: 404, body: json("Not Found")) == .notSupported)
        #expect(OpenClickyAuthSession.confirmOutcome(status: 503, body: json(#"{"error":"accounts_unavailable"}"#)) == .failed(OpenClickyAuthSession.accountsUnavailableMessage))
    }

    @Test func accountTroubleIsNotAConnectionProblem() {
        #expect(OpenClickyAuthSession.outcome(status: 503, body: json(#"{"error":"accounts_unavailable"}"#), email: "g@x.co")
                == .failed("openclicky's accounts are having trouble right now, try again in a few minutes."))
    }

    @Test func aRetryAfterSaysHowLongToWait() {
        #expect(OpenClickyAuthSession.outcome(status: 429, body: json(#"{"error":"slow_down"}"#), email: "g@x.co", retryAfterSeconds: 180)
                == .failed("too many tries, wait about 3 minutes and try again."))
        #expect(OpenClickyAuthSession.slowDownMessage(retryAfterSeconds: 30) == "too many tries, wait about 1 minute and try again.")
        #expect(OpenClickyAuthSession.slowDownMessage(retryAfterSeconds: 61) == "too many tries, wait about 2 minutes and try again.")
        #expect(OpenClickyAuthSession.slowDownMessage(retryAfterSeconds: nil) == "too many tries, wait a few minutes and try again.")
        let response = HTTPURLResponse(url: URL(string: "https://api.example")!, statusCode: 429, httpVersion: nil, headerFields: ["Retry-After": "120"])
        #expect(OpenClickyAuthSession.retryAfterSeconds(of: response) == 120)
        #expect(OpenClickyAuthSession.retryAfterSeconds(of: nil) == nil)
    }

    @Test func onlyASendInFlightBlocksANewStart() {
        #expect(!OpenClickyAuthSession.canStart(from: .sending))
        #expect(!OpenClickyAuthSession.canStart(from: .checkingCode(email: "g@x.co")))
        #expect(OpenClickyAuthSession.canStart(from: .idle))
        #expect(OpenClickyAuthSession.canStart(from: .needsCode(email: "g@x.co")))
        #expect(OpenClickyAuthSession.canStart(from: .failed("no")))
    }

    @Test func aLateReplyNeverUndoesAResetOrSignOut() {
        #expect(OpenClickyAuthSession.shouldApply(current: .checkingCode(email: "g@x.co"), inFlight: .checkingCode(email: "g@x.co")))
        #expect(OpenClickyAuthSession.shouldApply(current: .sending, inFlight: .sending))
        #expect(!OpenClickyAuthSession.shouldApply(current: .idle, inFlight: .checkingCode(email: "g@x.co")))
        #expect(!OpenClickyAuthSession.shouldApply(current: .idle, inFlight: .sending))
    }

    @Test func aCancelledStartReturnsToIdle() {
        #expect(OpenClickyAuthSession.isCancellation(CancellationError()))
        #expect(OpenClickyAuthSession.stateAfterCancellation(.sending) == .idle)
        #expect(OpenClickyAuthSession.stateAfterCancellation(.checkingCode(email: "g@x.co")) == .needsCode(email: "g@x.co"))
        #expect(OpenClickyAuthSession.stateAfterCancellation(.needsCode(email: "g@x.co")) == .needsCode(email: "g@x.co"))
    }

    @Test func aRefreshWithAnEmptyEmailKeepsTheStoredOne() throws {
        let reply = { (email: String) in try JSONDecoder().decode(OpenClickyAuthSession.TokenResponse.self, from: self.json(#"{"access_token":"a","refresh_token":"r","expires_in":3600,"user":{"email":"\#(email)","is_anonymous":true}}"#)) }
        #expect(OpenClickyAuthSession.refreshedEmail(try reply(""), stored: "gran@example.com") == "gran@example.com")
        #expect(OpenClickyAuthSession.refreshedEmail(try reply("  "), stored: "gran@example.com") == "gran@example.com")
        #expect(OpenClickyAuthSession.refreshedEmail(try reply("new@example.com"), stored: "gran@example.com") == "new@example.com")
        let noUser = try JSONDecoder().decode(OpenClickyAuthSession.TokenResponse.self, from: json(#"{"access_token":"a","refresh_token":"r","expires_in":3600}"#))
        #expect(OpenClickyAuthSession.refreshedEmail(noUser, stored: "gran@example.com") == "gran@example.com")
    }
}
