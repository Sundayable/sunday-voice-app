import XCTest
import DictationEngine
@testable import Sunday_Voice

/// Guests (invited non-company addresses): one-time-code sign-in, dictation only.
@MainActor
final class GuestAccessTests: XCTestCase {
    func testGuestFlagDecodesAndOldProfilesStayTeamMembers() throws {
        let guest = try JSONDecoder().decode(UserProfile.self, from: Data(#"{"id":"g","email":"g@gmail.com","name":"G","picture":null,"guest":true}"#.utf8))
        XCTAssertEqual(guest.guest, true)
        let stored = try JSONDecoder().decode(UserProfile.self, from: Data(#"{"id":"d","email":"d@sundayable.com"}"#.utf8))
        XCTAssertNil(stored.guest)
    }

    func testGuestsSkipConnectAndVoiceSteps() {
        let auth = AuthService(storage: MemoryAuthStorage())
        auth.previewSignedIn(UserProfile(id: "g", email: "g@gmail.com", name: nil, picture: nil, guest: true))
        let model = OnboardingModel(auth: auth, api: APIClient(auth: auth), monitor: PermissionMonitor(), engine: MockDictationEngine())
        model.billing = BillingSummary(plan: "pro", status: "active", entitled: true, pro_required: true, price_usd_monthly: 19, current_period_end: nil, cancel_at_period_end: false, has_customer: true, checkout_available: true)
        XCTAssertTrue(model.isGuest)
        model.step = .keys
        model.next()
        XCTAssertEqual(model.step, .tryIt)
        model.back()
        XCTAssertEqual(model.step, .keys)
    }

    func testTeamMembersKeepEveryStep() {
        let auth = AuthService(storage: MemoryAuthStorage())
        auth.previewSignedIn(UserProfile(id: "d", email: "d@sundayable.com", name: nil, picture: nil))
        let model = OnboardingModel(auth: auth, api: APIClient(auth: auth), monitor: PermissionMonitor(), engine: MockDictationEngine())
        XCTAssertFalse(model.isGuest)
        model.step = .keys
        model.next()
        XCTAssertEqual(model.step, .connect)
    }

    func testRequestsCarryTheAppVersion() {
        XCTAssertEqual(AppVersion.headerName, "X-Sunday-Voice-Version")
        XCTAssertTrue(AppVersion.header.range(of: #"^\d+\.\d+\.\d+ \(\d+\)$"#, options: .regularExpression) != nil, AppVersion.header)
    }

    func testGuestStringsExistInBothLanguages() {
        for key in ["settings.guestNoConnections", "hud.pending", "hud.copied", "menu.recent", "menu.recent.copyLatest", "menu.recent.clear"] {
            XCTAssertNotEqual(L(key), key, key)
        }
    }
}
