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
        let refused = NSError(domain: "ClaudeAPI", code: 401, userInfo: [NSLocalizedDescriptionKey: "API Error (401): {\"error\":\"unauthorized\"}"])
        #expect(CompanionManager.isSignInRejection(refused))
        #expect(!CompanionManager.isAccountNotice(refused))
        #expect(!CompanionManager.isSignInRejection(NSError(domain: "ClaudeAPI", code: 402)))
        #expect(!CompanionManager.isSignInRejection(NSError(domain: "ClaudeAPI", code: 500)))
    }
}
