import AuthenticationServices
import XCTest
@testable import Sunday_Voice

@MainActor
final class AuthServiceTests: XCTestCase {
    func testSignOutUpdatesUIBeforeAwaitingServer() async throws {
        let rig = AuthRig(); defer { rig.close() }
        try rig.auth.store(tokens("signed-in"))
        var cleared = false
        let operation = rig.run { await rig.auth.signOut { cleared = !rig.auth.isSignedIn && rig.storage.refreshToken == nil } }
        try await eventually { rig.requests.count == 1 }
        XCTAssertTrue(cleared)
        rig.requests[0].reply(["ok": true])
        try await success(operation)
    }

    func testBackgroundBrowserCompletionExchangesOnceAndPreservesPKCE() async throws {
        let rig = AuthRig(); defer { rig.close() }
        let login = rig.run { try await rig.auth.signIn() }
        try await eventually { rig.sessions.count == 1 }
        let session = rig.sessions[0], callback = rig.sessions[0].callback()
        let completion = session.completion
        await Task.detached {
            XCTAssertFalse(Thread.isMainThread)
            completion(callback, nil)
            completion(callback, nil)
        }.value
        try await eventually { rig.requests.count == 1 }
        XCTAssertFalse(rig.auth.handleCallback(callback))
        let request = rig.requests[0]
        XCTAssertEqual(request.body["grant_type"] as? String, "authorization_code")
        let verifier = try XCTUnwrap(request.body["code_verifier"] as? String)
        XCTAssertEqual(AuthService.challenge(for: verifier), session.query("code_challenge"))
        request.reply(tokens("one"))
        try await success(login)
        XCTAssertEqual(rig.auth.user?.id, "one")
        XCTAssertEqual(rig.storage.refreshToken, "refresh-one")
        XCTAssertFalse(rig.auth.signingIn)
        XCTAssertEqual(session.cancels, 1)
        XCTAssertEqual(rig.requests.count, 1)
    }

    func testStartFailureOpensExternalBrowserOnceAndAcceptsDeepLink() async throws {
        let rig = AuthRig(); rig.canStart = false; defer { rig.close() }
        let login = rig.run { try await rig.auth.signIn() }
        try await eventually { rig.browserURLs.count == 1 }
        XCTAssertEqual(rig.browserURLs.first, rig.sessions.first?.url)
        XCTAssertTrue(rig.auth.handleCallback(rig.sessions[0].callback()))
        try await eventually { rig.requests.count == 1 }
        rig.requests[0].reply(tokens("fallback"))
        try await success(login)
        XCTAssertEqual(rig.browserURLs.count, 1)
    }

    func testUserCanRecoverStalledBrowserOnceWithoutChangingPKCE() async throws {
        let rig = AuthRig(); defer { rig.close() }
        let login = rig.run { try await rig.auth.signIn() }
        try await eventually { rig.sessions.count == 1 }
        let session = rig.sessions[0]
        XCTAssertTrue(rig.auth.browserRecoveryAvailable)
        rig.auth.continueSignInInBrowser()
        rig.auth.continueSignInInBrowser()
        XCTAssertEqual(rig.browserURLs, [session.url])
        XCTAssertEqual(session.cancels, 1)
        XCTAssertFalse(rig.auth.browserRecoveryAvailable)
        XCTAssertTrue(rig.auth.signingIn)
        // A cancellation callback from the abandoned system session cannot cancel recovery.
        session.completion(nil, ASWebAuthenticationSessionError(.canceledLogin))
        await drainActor()
        XCTAssertTrue(rig.auth.handleCallback(session.callback()))
        try await eventually { rig.requests.count == 1 }
        let verifier = try XCTUnwrap(rig.requests[0].body["code_verifier"] as? String)
        XCTAssertEqual(AuthService.challenge(for: verifier), session.query("code_challenge"))
        rig.requests[0].reply(tokens("recovered"))
        try await success(login)
        XCTAssertEqual(rig.auth.user?.id, "recovered")
        XCTAssertFalse(rig.auth.browserRecoveryAvailable)
    }

    func testUserCancelDiscardsLateCallbackAndPermitsFreshAttempt() async throws {
        let rig = AuthRig(); defer { rig.close() }
        let login = rig.run { try await rig.auth.signIn() }
        try await eventually { rig.sessions.count == 1 }
        let stale = rig.sessions[0]
        rig.auth.cancelSignIn()
        try await failure(login, .cancelled)
        XCTAssertFalse(rig.auth.signingIn)
        XCTAssertFalse(rig.auth.browserRecoveryAvailable)
        rig.auth.continueSignInInBrowser()
        XCTAssertTrue(rig.browserURLs.isEmpty)
        XCTAssertFalse(rig.auth.handleCallback(stale.callback()))
        let retry = rig.run { try await rig.auth.signIn() }
        try await eventually { rig.sessions.count == 2 }
        XCTAssertTrue(rig.auth.browserRecoveryAvailable)
        XCTAssertNotEqual(stale.query("state"), rig.sessions[1].query("state"))
        rig.auth.cancelSignIn()
        try await failure(retry, .cancelled)
    }

    func testAsynchronousWebErrorFallsBackOnceAndPollCanWin() async throws {
        let rig = AuthRig(pollingInterval: .milliseconds(5)); defer { rig.close() }
        let login = rig.run { try await rig.auth.signIn() }
        try await eventually { rig.sessions.count == 1 }
        let session = rig.sessions[0], completion = rig.sessions[0].completion
        await Task.detached {
            completion(nil, URLError(.unsupportedURL))
            completion(nil, URLError(.unsupportedURL))
        }.value
        try await eventually { rig.browserURLs.count == 1 && rig.requests.count == 1 }
        XCTAssertTrue(rig.auth.signingIn) // cancel()'s callback must not cancel the fallback.
        rig.requests[0].reply(["code": "polled", "state": session.query("state")!])
        try await eventually { rig.requests.count == 2 }
        XCTAssertFalse(rig.auth.handleCallback(session.callback()))
        rig.requests[1].reply(tokens("polled"))
        try await success(login)
        XCTAssertEqual(rig.browserURLs.count, 1)
        XCTAssertEqual(rig.requests[1].body["code"] as? String, "polled")
    }

    func testExplicitBrowserCancellationDoesNotOpenFallbackOrPollAfterwards() async throws {
        let rig = AuthRig(pollingInterval: .milliseconds(30)); defer { rig.close() }
        let login = rig.run { try await rig.auth.signIn() }
        try await eventually { rig.sessions.count == 1 }
        rig.sessions[0].completion(nil, ASWebAuthenticationSessionError(.canceledLogin))
        try await failure(login, .cancelled)
        try await Task.sleep(for: .milliseconds(60))
        XCTAssertTrue(rig.browserURLs.isEmpty)
        XCTAssertTrue(rig.requests.isEmpty)
        XCTAssertFalse(rig.auth.signingIn)
    }

    func testBothBrowserStartMethodsFailWithoutLeavingPendingSignIn() async throws {
        let rig = AuthRig(); rig.canStart = false; rig.browserCanOpen = false; defer { rig.close() }
        let login = rig.run { try await rig.auth.signIn() }
        try await failure(login, .server("web_auth"))
        XCTAssertFalse(rig.auth.signingIn)
        XCTAssertFalse(rig.auth.handleCallback(rig.sessions[0].callback()))
        XCTAssertTrue(rig.requests.isEmpty)
    }

    func testUnrelatedAndStaleDeepLinksCannotConsumeCurrentSignIn() async throws {
        let rig = AuthRig(); defer { rig.close() }
        let login = rig.run { try await rig.auth.signIn() }
        try await eventually { rig.sessions.count == 1 }
        let session = rig.sessions[0]
        XCTAssertFalse(rig.auth.handleCallback(session.callback(state: "old", error: "not_invited")))
        var wrongScheme = URLComponents(url: session.callback(), resolvingAgainstBaseURL: false)!
        wrongScheme.scheme = "unrelated"
        XCTAssertFalse(rig.auth.handleCallback(wrongScheme.url!))
        var duplicateState = URLComponents(url: session.callback(), resolvingAgainstBaseURL: false)!
        duplicateState.queryItems!.append(URLQueryItem(name: "state", value: session.query("state")))
        XCTAssertFalse(rig.auth.handleCallback(duplicateState.url!))
        XCTAssertTrue(rig.auth.signingIn)
        XCTAssertTrue(rig.auth.handleCallback(session.callback(error: "not_invited")))
        try await failure(login, .server("not_invited"))
        XCTAssertTrue(rig.requests.isEmpty)
    }

    func testSessionValidatesStateBeforeAcceptingError() async throws {
        let rig = AuthRig(); defer { rig.close() }
        let login = rig.run { try await rig.auth.signIn() }
        try await eventually { rig.sessions.count == 1 }
        rig.sessions[0].completion(rig.sessions[0].callback(state: "wrong", error: "not_invited"), nil)
        try await failure(login, .stateMismatch)
        XCTAssertTrue(rig.requests.isEmpty)
    }

    func testTimeoutFinishesEvenWhilePollRequestIsSuspended() async throws {
        let rig = AuthRig(pollingInterval: .milliseconds(1), timeout: .milliseconds(50)); defer { rig.close() }
        let login = rig.run { try await rig.auth.signIn() }
        try await eventually { rig.requests.count == 1 }
        try await failure(login, .server("sign_in_timeout"))
        let session = rig.sessions[0]
        rig.requests[0].reply(["code": "too-late", "state": session.query("state")!])
        await drainActor()
        XCTAssertEqual(rig.requests.count, 1)
        XCTAssertFalse(rig.auth.signingIn)
        XCTAssertEqual(session.cancels, 1)
    }

    func testCallerCancellationFinishesPendingContinuation() async throws {
        let rig = AuthRig(); defer { rig.close() }
        let login = rig.run { try await rig.auth.signIn() }
        try await eventually { rig.sessions.count == 1 }
        login.task.cancel()
        try await failure(login, .cancelled)
        XCTAssertFalse(rig.auth.signingIn)
        XCTAssertEqual(rig.sessions[0].cancels, 1)
        XCTAssertTrue(rig.browserURLs.isEmpty)
    }

    func testAlreadyCancelledCallerDoesNotStartBrowser() async throws {
        let rig = AuthRig(); defer { rig.close() }
        let login = rig.run { try await rig.auth.signIn() }
        login.task.cancel()
        try await failure(login, .cancelled)
        XCTAssertTrue(rig.sessions.isEmpty)
        XCTAssertTrue(rig.requests.isEmpty)
    }

    func testRetryIgnoresOldBrowserAndPollCompletions() async throws {
        let rig = AuthRig(pollingInterval: .milliseconds(5)); defer { rig.close() }
        let first = rig.run { try await rig.auth.signIn() }
        try await eventually { rig.requests.count == 1 }
        let old = rig.sessions[0]
        let second = rig.run { try await rig.auth.signIn() }
        try await eventually { rig.sessions.count == 2 }
        try await failure(first, .cancelled)
        old.completion(old.callback(), nil)
        rig.requests[0].reply(["code": "old-poll", "state": old.query("state")!])
        XCTAssertFalse(rig.auth.handleCallback(old.callback()))
        await drainActor()
        XCTAssertTrue(rig.auth.signingIn)
        XCTAssertFalse(rig.requests.contains { $0.body["grant_type"] != nil })
        XCTAssertTrue(rig.auth.handleCallback(rig.sessions[1].callback(code: "new-code")))
        try await eventually { rig.requests.contains { $0.body["code"] as? String == "new-code" } }
        rig.requests.first { $0.body["code"] as? String == "new-code" }!.reply(tokens("new"))
        try await success(second)
        XCTAssertEqual(rig.auth.user?.id, "new")
    }

    func testDeepLinkWinningRaceDiscardsInFlightPollAndBrowserCancellation() async throws {
        let rig = AuthRig(pollingInterval: .milliseconds(1)); defer { rig.close() }
        let login = rig.run { try await rig.auth.signIn() }
        try await eventually { rig.requests.count == 1 }
        let session = rig.sessions[0]
        XCTAssertTrue(rig.auth.handleCallback(session.callback(code: "direct")))
        rig.requests[0].reply(["code": "polled", "state": session.query("state")!])
        try await eventually { rig.requests.count == 2 }
        rig.requests[1].reply(tokens("direct"))
        try await success(login)
        XCTAssertEqual(rig.requests[1].body["code"] as? String, "direct")
        XCTAssertEqual(rig.requests.count, 2)
    }

    func testSignOutCancelsBrowserAndDiscardsLateTokenExchange() async throws {
        let rig = AuthRig(); defer { rig.close() }
        let first = rig.run { try await rig.auth.signIn() }
        try await eventually { rig.sessions.count == 1 }
        await rig.auth.signOut()
        try await failure(first, .cancelled)
        let second = rig.run { try await rig.auth.signIn() }
        try await eventually { rig.sessions.count == 2 }
        rig.auth.handleCallback(rig.sessions[1].callback())
        try await eventually { rig.requests.count == 1 }
        await rig.auth.signOut()
        rig.requests[0].reply(tokens("late-login"))
        try await failure(second, .cancelled)
        XCTAssertFalse(rig.auth.isSignedIn)
        XCTAssertNil(rig.storage.refreshToken)
        XCTAssertNil(rig.storage.profile)
    }

    func testRetriedLoginSuppressesOldExchangeErrorAndPreservesNewBusyState() async throws {
        let rig = AuthRig(); defer { rig.close() }
        let old = rig.run { try await rig.auth.signIn() }
        try await eventually { rig.sessions.count == 1 }
        rig.auth.handleCallback(rig.sessions[0].callback())
        try await eventually { rig.requests.count == 1 }
        let current = rig.run { try await rig.auth.signIn() }
        try await eventually { rig.sessions.count == 2 }
        rig.requests[0].reply(["error": ["code": "invalid_grant"]], status: 401)
        try await failure(old, .cancelled)
        XCTAssertTrue(rig.auth.signingIn)
        rig.auth.handleCallback(rig.sessions[1].callback())
        try await eventually { rig.requests.count == 2 }
        rig.requests[1].reply(tokens("current"))
        try await success(current)
        XCTAssertEqual(rig.auth.user?.id, "current")
    }

    func testCancellationDuringExchangeReportsCancellationAndStoresNothing() async throws {
        let rig = AuthRig(); defer { rig.close() }
        let login = rig.run { try await rig.auth.signIn() }
        try await eventually { rig.sessions.count == 1 }
        rig.auth.handleCallback(rig.sessions[0].callback())
        try await eventually { rig.requests.count == 1 }
        login.task.cancel()
        rig.requests[0].fail(URLError(.cancelled))
        try await failure(login, .cancelled)
        XCTAssertFalse(rig.auth.isSignedIn)
        XCTAssertNil(rig.storage.refreshToken)
    }

    func testConcurrentTokenCallsShareOneRefreshRotation() async throws {
        let rig = AuthRig(); defer { rig.close() }
        rig.storage.refreshToken = "seed"
        let first = rig.run { try await rig.auth.accessToken() }
        let second = rig.run { try await rig.auth.accessToken() }
        try await eventually { rig.requests.count == 1 }
        await drainActor()
        XCTAssertEqual(rig.requests.count, 1)
        XCTAssertEqual(rig.requests[0].body["refresh_token"] as? String, "seed")
        rig.requests[0].reply(tokens("rotated"))
        try await assertToken(first, equals: "access-rotated")
        try await assertToken(second, equals: "access-rotated")
        XCTAssertEqual(rig.storage.refreshToken, "refresh-rotated")
    }

    func testSignOutClearsImmediatelyAndLateRefreshCannotRestoreCredentials() async throws {
        let rig = AuthRig(); defer { rig.close() }
        try rig.auth.store(tokens("old", expires: 0))
        let refresh = rig.run { try await rig.auth.accessToken() }
        try await eventually { rig.requests.count == 1 }
        let logout = rig.run { await rig.auth.signOut() }
        try await eventually { rig.requests.count == 2 }
        XCTAssertNil(rig.auth.user)
        XCTAssertNil(rig.storage.refreshToken)
        rig.requests[0].reply(tokens("late-rotation"))
        try await failure(refresh, .signedOut)
        rig.requests[1].reply(["ok": true])
        try await success(logout)
        XCTAssertNil(rig.auth.user)
        XCTAssertNil(rig.storage.refreshToken)
        XCTAssertNil(rig.storage.profile)
    }

    func testLateLogoutAndOldRefreshFailureDoNotEraseNewLogin() async throws {
        let rig = AuthRig(); defer { rig.close() }
        try rig.auth.store(tokens("old", expires: 0))
        let refresh = rig.run { try await rig.auth.accessToken() }
        try await eventually { rig.requests.count == 1 }
        let logout = rig.run { await rig.auth.signOut() }
        try await eventually { rig.requests.count == 2 }
        let login = rig.run { try await rig.auth.signIn() }
        try await eventually { rig.sessions.count == 1 }
        rig.auth.handleCallback(rig.sessions[0].callback())
        try await eventually { rig.requests.count == 3 }
        rig.requests[2].reply(tokens("new"))
        try await success(login)
        rig.requests[0].reply(["error": ["code": "invalid_grant"]], status: 401)
        try await failure(refresh, .signedOut)
        rig.requests[1].reply(["ok": true])
        try await success(logout)
        XCTAssertEqual(rig.auth.user?.id, "new")
        XCTAssertEqual(rig.storage.refreshToken, "refresh-new")
    }

    func testOldRefreshCleanupDoesNotRemoveNewSharedRefreshTask() async throws {
        let rig = AuthRig(); defer { rig.close() }
        rig.storage.refreshToken = "old"
        let old = rig.run { try await rig.auth.accessToken() }
        try await eventually { rig.requests.count == 1 }
        let logout = rig.run { await rig.auth.signOut() }
        try await eventually { rig.requests.count == 2 }
        rig.storage.refreshToken = "new"
        let current = rig.run { try await rig.auth.accessToken() }
        try await eventually { rig.requests.count == 3 }
        rig.requests[0].reply(["error": ["code": "invalid_grant"]], status: 401)
        try await failure(old, .signedOut)
        let joined = rig.run { try await rig.auth.accessToken() }
        await drainActor()
        XCTAssertEqual(rig.requests.count, 3)
        rig.requests[2].reply(tokens("new"))
        try await assertToken(current, equals: "access-new")
        try await assertToken(joined, equals: "access-new")
        rig.requests[1].reply(["ok": true])
        try await success(logout)
    }

    func testCurrentInvalidGrantSignsOutButTransportFailureDoesNot() async throws {
        let rig = AuthRig(); defer { rig.close() }
        try rig.auth.store(tokens("old", expires: 0))
        let offline = rig.run { try await rig.auth.accessToken() }
        try await eventually { rig.requests.count == 1 }
        rig.requests[0].fail(URLError(.notConnectedToInternet))
        await fulfillment(of: [offline.finished], timeout: 2)
        XCTAssertEqual(rig.storage.refreshToken, "refresh-old")
        let rejected = rig.run { try await rig.auth.accessToken() }
        try await eventually { rig.requests.count == 2 }
        rig.requests[1].reply(["error": ["code": "invalid_grant"]], status: 401)
        try await failure(rejected, .signedOut)
        XCTAssertNil(rig.auth.user)
        XCTAssertNil(rig.storage.refreshToken)
    }

    func testLate401DoesNotInvalidateAlreadyRotatedAccessToken() async throws {
        let rig = AuthRig(); defer { rig.close() }
        try rig.auth.store(tokens("old"))
        await rig.auth.invalidateAccessToken("access-old")
        let refreshed = rig.run { try await rig.auth.accessToken() }
        try await eventually { rig.requests.count == 1 }
        rig.requests[0].reply(tokens("new"))
        try await assertToken(refreshed, equals: "access-new")
        await rig.auth.invalidateAccessToken("access-old")
        let cached = try await rig.auth.accessToken()
        XCTAssertEqual(cached, "access-new")
        XCTAssertEqual(rig.requests.count, 1)
    }

    func testAPIClient401RetriesWithNewTokenAndStopsAfterSecond401() async throws {
        for retrySucceeds in [true, false] {
            let rig = AuthRig(); defer { rig.close() }
            try rig.auth.store(tokens("old"))
            let responder = APIResponses(retrySucceeds: retrySucceeds)
            AuthAPIProtocol.responses = responder
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [AuthAPIProtocol.self]
            let session = URLSession(configuration: configuration)
            defer { session.invalidateAndCancel(); AuthAPIProtocol.responses = nil }
            let api = APIClient(auth: rig.auth, session: session)
            let call = rig.run { try await api.dictionary() }
            try await eventually { rig.requests.count == 1 }
            rig.requests[0].reply(tokens("new"))
            await fulfillment(of: [call.finished], timeout: 2)
            if retrySucceeds { XCTAssertEqual(try XCTUnwrap(call.result).get(), ["word"]) }
            else if case .failure(let error) = call.result { XCTAssertEqual(error as? APIError, .http(401, "unauthorized")) }
            else { XCTFail("Expected the second 401 to end the retry") }
            XCTAssertEqual(responder.authorizationHeaders, ["Bearer access-old", "Bearer access-new"])
            XCTAssertEqual(rig.requests.count, 1)
        }
    }

    func testConsentIsFailClosedAndAgreementUsesCurrentServerVersion() async throws {
        let rig = AuthRig(); defer { rig.close() }
        try rig.auth.store(tokens("pending"))
        XCTAssertFalse(rig.auth.isSignedIn)
        let refresh = rig.run { try await rig.auth.refreshConsent() }
        try await eventually { rig.requests.count == 1 }
        rig.requests[0].reply(["version": "2026-10-16.1", "required": true])
        try await success(refresh)
        XCTAssertFalse(rig.auth.isSignedIn)
        let accept = rig.run { try await rig.auth.agreeToTerms() }
        try await eventually { rig.requests.count == 2 }
        rig.requests[1].reply(["version": "2026-10-16.1", "required": false])
        try await success(accept)
        XCTAssertTrue(rig.auth.isSignedIn)
        await rig.auth.consentReviewRequired()
        XCTAssertFalse(rig.auth.isSignedIn)
    }

    private func tokens(_ id: String, expires: Double = 3600) -> [String: Any] {
        ["access_token": "access-\(id)", "refresh_token": "refresh-\(id)", "expires_in": expires,
         "user": ["id": id, "email": "\(id)@example.invalid"]]
    }

    private func value<T>(_ operation: AuthOperation<T>, file: StaticString = #filePath, line: UInt = #line) async throws -> T {
        await fulfillment(of: [operation.finished], timeout: 2)
        return try XCTUnwrap(operation.result, file: file, line: line).get()
    }

    private func success(_ operation: AuthOperation<Void>, file: StaticString = #filePath, line: UInt = #line) async throws {
        try await value(operation, file: file, line: line)
    }

    private func assertToken(_ operation: AuthOperation<String>, equals expected: String, file: StaticString = #filePath, line: UInt = #line) async throws {
        let token = try await value(operation, file: file, line: line)
        XCTAssertEqual(token, expected, file: file, line: line)
    }

    private func failure<T>(_ operation: AuthOperation<T>, _ expected: AuthError, file: StaticString = #filePath, line: UInt = #line) async throws {
        await fulfillment(of: [operation.finished], timeout: 2)
        switch try XCTUnwrap(operation.result, file: file, line: line) {
        case .success: XCTFail("Expected \(expected)", file: file, line: line)
        case .failure(let error): XCTAssertEqual(error as? AuthError, expected, file: file, line: line)
        }
    }

    private func eventually(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(1)) }
        _ = try XCTUnwrap(condition() ? true : nil, "Expected async work to reach the checkpoint", file: file, line: line)
    }

    private func drainActor() async { for _ in 0..<20 { await Task.yield() } }
}

@MainActor
private final class AuthOperation<T> {
    let finished = XCTestExpectation(description: "Auth operation completed")
    var result: Result<T, Error>?
    var task: Task<Void, Never>!
    init(_ work: @escaping @MainActor () async throws -> T) {
        task = Task {
            do { result = .success(try await work()) }
            catch { result = .failure(error) }
            finished.fulfill()
        }
    }
}

@MainActor
final class MemoryAuthStorage: AuthStorage {
    var refreshToken: String?
    var profile: Data?
}

@MainActor
private final class FakeWebSession: AuthWebSession {
    let url: URL
    let scheme: String
    let completion: AuthService.WebCompletion
    let canStart: Bool
    var cancels = 0
    init(url: URL, scheme: String, canStart: Bool, completion: @escaping AuthService.WebCompletion) {
        self.url = url; self.scheme = scheme; self.canStart = canStart; self.completion = completion
    }
    func start() -> Bool { canStart }
    func cancel() {
        cancels += 1
        // Deliberately reenter the real completion, as AuthenticationServices may do on cancel.
        completion(nil, ASWebAuthenticationSessionError(.canceledLogin))
    }
    func query(_ name: String) -> String? {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == name }?.value
    }
    func callback(code: String = "code", state: String? = nil, error: String? = nil) -> URL {
        var parts = URLComponents(); parts.scheme = scheme; parts.host = "auth"
        parts.queryItems = [URLQueryItem(name: "state", value: state ?? query("state"))]
        parts.queryItems!.append(error.map { URLQueryItem(name: "error", value: $0) } ?? URLQueryItem(name: "code", value: code))
        return parts.url!
    }
}

@MainActor
private final class PendingAuthRequest {
    let request: URLRequest
    let body: [String: Any]
    private var continuation: CheckedContinuation<(Data, URLResponse), Error>?
    init(_ request: URLRequest, _ continuation: CheckedContinuation<(Data, URLResponse), Error>) {
        self.request = request; self.continuation = continuation
        self.body = (try? JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any]) ?? [:]
    }
    func reply(_ object: [String: Any], status: Int = 200) {
        let pending = continuation; continuation = nil
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        pending?.resume(returning: (try! JSONSerialization.data(withJSONObject: object), response))
    }
    func fail(_ error: Error) { let pending = continuation; continuation = nil; pending?.resume(throwing: error) }
}

/// Requests deliberately ignore cancellation until replied to: this exercises late network results,
/// not just the cooperative cancellation that URLSession normally provides. No real IO occurs.
@MainActor
private final class AuthRig {
    let storage = MemoryAuthStorage()
    var sessions: [FakeWebSession] = []
    var requests: [PendingAuthRequest] = []
    var browserURLs: [URL] = []
    var canStart = true
    var browserCanOpen = true
    private var cancellations: [() -> Void] = []
    private var closed = false
    private let pollingInterval: Duration
    private let timeout: Duration
    lazy var auth = AuthService(storage: storage, makeWebSession: { [unowned self] url, scheme, _, completion in
        let session = FakeWebSession(url: url, scheme: scheme, canStart: canStart, completion: completion)
        sessions.append(session)
        return session
    }, openBrowser: { [unowned self] url in
        browserURLs.append(url)
        return browserCanOpen
    }, request: { [unowned self] request in
        guard !closed else { throw URLError(.cancelled) }
        return try await withCheckedThrowingContinuation { requests.append(PendingAuthRequest(request, $0)) }
    }, baseURL: URL(string: "https://auth-tests.invalid")!, pollingInterval: pollingInterval, signInTimeout: timeout, environment: [:])

    init(pollingInterval: Duration = .seconds(60), timeout: Duration = .seconds(10)) {
        self.pollingInterval = pollingInterval; self.timeout = timeout
    }
    func run<T>(_ work: @escaping @MainActor () async throws -> T) -> AuthOperation<T> {
        let operation = AuthOperation(work)
        cancellations.append { operation.task.cancel() }
        return operation
    }
    func close() {
        closed = true
        cancellations.forEach { $0() }
        requests.forEach { $0.fail(URLError(.cancelled)) }
    }
}

private final class APIResponses: @unchecked Sendable {
    private let lock = NSLock()
    private var headers: [String] = []
    private let retrySucceeds: Bool
    init(retrySucceeds: Bool) { self.retrySucceeds = retrySucceeds }
    var authorizationHeaders: [String] { lock.withLock { headers } }
    func response(to request: URLRequest) -> (Int, Data) {
        lock.withLock {
            let header = request.value(forHTTPHeaderField: "Authorization") ?? ""
            headers.append(header)
            let ok = retrySucceeds && header == "Bearer access-new"
            return (ok ? 200 : 401, Data((ok ? "{\"words\":[\"word\"]}" : "{\"error\":{\"code\":\"unauthorized\"}}").utf8))
        }
    }
}

private final class AuthAPIProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    private static var storedResponses: APIResponses?
    static var responses: APIResponses? {
        get { lock.withLock { storedResponses } }
        set { lock.withLock { storedResponses = newValue } }
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let responses = Self.responses else { client?.urlProtocol(self, didFailWithError: URLError(.cancelled)); return }
        let (status, data) = responses.response(to: request)
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
