import Foundation
import Supabase
import XCTest
@testable import Fridge

/// F0.2: restoring a session must only start over (new anonymous account) when the
/// server has rejected the session for good. Anything else must keep the session.
final class SessionErrorPolicyTests: XCTestCase {
    private func apiError(_ code: String, status: Int) -> AuthError {
        .api(
            message: "test",
            errorCode: ErrorCode(rawValue: code),
            underlyingData: Data(),
            underlyingResponse: HTTPURLResponse(
                url: URL(string: "https://example.supabase.co/auth/v1/token")!,
                statusCode: status, httpVersion: nil, headerFields: nil)!
        )
    }

    // MARK: Start over: the session can never work again

    func testMissingSessionStartsOver() {
        XCTAssertEqual(SessionErrorPolicy.action(forRestoreError: AuthError.sessionMissing), .startOver)
    }

    func testRejectedRefreshTokenStartsOver() {
        for code in ["refresh_token_not_found", "session_not_found", "session_expired", "user_not_found"] {
            XCTAssertEqual(SessionErrorPolicy.action(forRestoreError: apiError(code, status: 400)), .startOver, code)
        }
    }

    // MARK: Retry later: never throw the account away

    func testOfflineRetries() {
        for code: URLError.Code in [.notConnectedToInternet, .timedOut, .networkConnectionLost, .cannotFindHost] {
            XCTAssertEqual(SessionErrorPolicy.action(forRestoreError: URLError(code)), .retryLater, "\(code)")
        }
    }

    func testServerErrorRetries() {
        XCTAssertEqual(SessionErrorPolicy.action(forRestoreError: apiError("unexpected_failure", status: 500)), .retryLater)
        XCTAssertEqual(SessionErrorPolicy.action(forRestoreError: apiError("over_request_rate_limit", status: 429)), .retryLater)
    }

    func testUnknownAuthErrorRetries() {
        XCTAssertEqual(SessionErrorPolicy.action(forRestoreError: apiError("something_new", status: 400)), .retryLater)
        XCTAssertEqual(SessionErrorPolicy.action(forRestoreError: AuthError.refreshDiscarded), .retryLater)
    }

    func testNonAuthErrorRetries() {
        struct Whatever: Error {}
        XCTAssertEqual(SessionErrorPolicy.action(forRestoreError: Whatever()), .retryLater)
        XCTAssertEqual(SessionErrorPolicy.action(forRestoreError: CancellationError()), .retryLater)
    }

    // MARK: Offline screen text

    func testOfflineMessage() {
        XCTAssertTrue(SessionErrorPolicy.message(for: URLError(.notConnectedToInternet)).hasPrefix("You're offline"))
        XCTAssertTrue(SessionErrorPolicy.message(for: AuthError.sessionMissing).hasPrefix("Couldn't reach the server"))
    }
}
