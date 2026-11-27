import AppAuthCore
import GTMAppAuth
import XCTest
@testable import Sunday_Voice

private final class CalendarAuthTestStore: NSObject, AuthSessionStore {
    var saves = 0
    var removals = 0
    func save(authSession: GTMAppAuth.AuthSession) throws { saves += 1 }
    func removeAuthSession() throws { removals += 1 }
    func retrieveAuthSession() throws -> GTMAppAuth.AuthSession {
        throw KeychainStore.Error.passwordNotFound(forItemName: "synthetic")
    }
}

@MainActor
final class GoogleCalendarAuthTests: XCTestCase {
    private let client = "123456789012-synthetic.apps.googleusercontent.com"
    private func callback(_ query: String) -> URL {
        URL(string: "com.googleusercontent.apps.123456789012-synthetic:/oauth2callback?" + query)!
    }

    func testBrowserRequestRetainsPKCEStateNonceAndOnlyReadOnlyDataScope() throws {
        let one = try GoogleCalendarAuth.authorizationRequest(clientID: client, hint: "me@example.com")
        let two = try GoogleCalendarAuth.authorizationRequest(clientID: client, hint: nil)
        XCTAssertNotEqual(one.state, two.state)
        XCTAssertNotEqual(one.codeVerifier, two.codeVerifier)
        XCTAssertNotNil(one.nonce)
        XCTAssertEqual(one.codeChallengeMethod, "S256")
        XCTAssertNil(one.clientSecret)
        XCTAssertEqual(Set((one.scope ?? "").split(separator: " ").map(String.init)),
                       Set(["openid", "email", "profile", GoogleCalendarAuth.scope]))
        XCTAssertEqual(one.additionalParameters?["include_granted_scopes"], "false")
        XCTAssertEqual(one.additionalParameters?["access_type"], "offline")
        XCTAssertEqual(one.configuration.tokenEndpoint.host, "oauth2.googleapis.com")
        XCTAssertEqual(one.redirectURL?.scheme, "com.googleusercontent.apps.123456789012-synthetic")
        XCTAssertThrowsError(try GoogleCalendarAuth.authorizationRequest(clientID: "", hint: nil))
    }

    func testMissingKeychainGrantDoesNotOpenBrowserOrNetwork() async throws {
        let auth = GoogleCalendarAuth(clientID: client, store: CalendarAuthTestStore(), openBrowser: { _ in
            XCTFail("Restore must not open consent"); return false
        })
        let account = try await auth.restore()
        XCTAssertNil(account)
    }

    func testExistingGmailGrantCannotBeInheritedByCalendarClient() {
        XCTAssertTrue(GoogleCalendarAuth.hasOnlyCalendarAccess("openid https://www.googleapis.com/auth/userinfo.email " + GoogleCalendarAuth.scope))
        XCTAssertFalse(GoogleCalendarAuth.hasOnlyCalendarAccess(GoogleCalendarAuth.scope + " https://www.googleapis.com/auth/gmail.readonly"))
        XCTAssertFalse(GoogleCalendarAuth.hasOnlyCalendarAccess("openid email profile"))
        XCTAssertFalse(GoogleCalendarAuth.hasOnlyCalendarAccess(nil))
    }

    func testUnavailableSystemBrowserFinishesWithoutHanging() async {
        let store = CalendarAuthTestStore()
        var opens = 0
        let auth = GoogleCalendarAuth(clientID: client, store: store, openBrowser: { url in
            opens += 1
            XCTAssertEqual(url.host, "accounts.google.com")
            return false
        })
        do { _ = try await auth.connect(hint: nil); XCTFail("Expected browser failure") } catch {}
        XCTAssertEqual(opens, 1)
        XCTAssertEqual(store.saves, 0)
    }

    func testDisconnectCancelsBrowserFlowAndIgnoresLateCallback() async {
        let store = CalendarAuthTestStore()
        var opened = false
        let auth = GoogleCalendarAuth(clientID: client, store: store, openBrowser: { _ in opened = true; return true })
        let task = Task { try await auth.connect(hint: nil) }
        while !opened { await Task.yield() }
        XCTAssertFalse(GoogleCalendarAuth.handle(URL(string: "https://example.com/oauth2callback")!))
        auth.disconnect()
        do { _ = try await task.value; XCTFail("Expected cancellation") } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertFalse(GoogleCalendarAuth.handle(callback("error=access_denied&state=late")))
        XCTAssertEqual(store.saves, 0)
        XCTAssertEqual(store.removals, 1)
    }

    func testWrongStateCannotAuthorizeOrSaveAnAccount() async {
        let store = CalendarAuthTestStore()
        var opened = false
        let auth = GoogleCalendarAuth(clientID: client, store: store, openBrowser: { _ in opened = true; return true })
        let task = Task { try await auth.connect(hint: nil) }
        while !opened { await Task.yield() }
        _ = GoogleCalendarAuth.handle(callback("error=access_denied&state=wrong"))
        do { _ = try await task.value; XCTFail("Expected state rejection") } catch {}
        XCTAssertEqual(store.saves, 0)
        XCTAssertFalse(GoogleCalendarAuth.handle(callback("error=access_denied&state=wrong")))
    }

    func testTimeoutReleasesAttemptAndAllowsRetry() async {
        let store = CalendarAuthTestStore()
        var opens = 0
        let auth = GoogleCalendarAuth(clientID: client, store: store, openBrowser: { _ in opens += 1; return true },
                                      timeout: .milliseconds(10))
        for _ in 0..<2 {
            do { _ = try await auth.connect(hint: nil); XCTFail("Expected timeout") }
            catch { XCTAssertEqual(error as? GoogleCalendarError, .signInTimedOut) }
        }
        XCTAssertEqual(opens, 2)
        XCTAssertEqual(store.saves, 0)
    }
}
