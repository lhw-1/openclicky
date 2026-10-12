import Foundation
import Testing
@testable import OpenClicky

struct SignInExpiryTests {
    @Test func aRefusedRefreshTokenEndsTheSession() {
        // 400 is what Supabase answers for an unknown or revoked refresh token (e.g. one issued by
        // the project before the move to US East).
        #expect(OpenClickyAuthSession.refreshRejectionEndsSession(status: 400))
        #expect(OpenClickyAuthSession.refreshRejectionEndsSession(status: 401))
        #expect(OpenClickyAuthSession.refreshRejectionEndsSession(status: 403))
    }

    @Test func aPassingFailureKeepsTheSession() {
        #expect(!OpenClickyAuthSession.refreshRejectionEndsSession(status: 0))
        #expect(!OpenClickyAuthSession.refreshRejectionEndsSession(status: 429))
        #expect(!OpenClickyAuthSession.refreshRejectionEndsSession(status: 500))
        #expect(!OpenClickyAuthSession.refreshRejectionEndsSession(status: 503))
    }

    @MainActor @Test func aRefusedTokenIsASignInProblemNotABackendFailure() {
        let refused = BackendHTTPError(service: .answers, status: 401, body: Data(#"{"error":"unauthorized"}"#.utf8))
        #expect(CompanionManager.isSignInRejection(refused))
        #expect(!CompanionManager.isAccountNotice(refused))
        #expect(!CompanionManager.isSignInRejection(BackendHTTPError(service: .answers, status: 402, body: Data())))
        #expect(!CompanionManager.isSignInRejection(BackendHTTPError(service: .answers, status: 500, body: Data())))
        // The voice's own 401 is not the question's.
        #expect(!CompanionManager.isSignInRejection(BackendHTTPError(service: .voice, status: 401, body: Data())))
    }

    // BackendSignIn renews a refused token and asks again before the ask lane hears of it; what it
    // throws after that is said with the same sentences the ask lane used when it renewed itself.
    @Test func aSignInOneRenewalCouldNotSaveIsSaidAsBefore() {
        #expect(OpenClickyAuthSession.spokenSentence(after: BackendSignInError.expired)
                == OpenClickyAuthSession.spokenSentence(after: .signedOut))
        #expect(OpenClickyAuthSession.spokenSentence(after: BackendSignInError.expired)
                == "your openclicky sign-in has expired. sign in again in settings, account.")
        #expect(OpenClickyAuthSession.spokenSentence(after: BackendSignInError.couldNotRenew)
                == OpenClickyAuthSession.unreachableMessage)
    }
}
