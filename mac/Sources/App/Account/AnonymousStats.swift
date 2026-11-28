import Foundation
import DictationEngine

extension Prefs {
    /// Opt-in anonymous usage stats. STRICTLY OFF by default: in Free Local Mode nothing leaves the Mac unless enabled.
    static var anonymousStatsEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: "anonymousStatsEnabled") }
        set { UserDefaults.standard.set(newValue, forKey: "anonymousStatsEnabled") }
    }

    /// Random, resettable install ID used only if the user opts in to anonymous stats. Never hardware-derived.
    static var anonymousStatsInstallID: String {
        if let existing = UserDefaults.standard.string(forKey: "anonymousStatsInstallID"), UUID(uuidString: existing) != nil {
            return existing
        }
        let fresh = UUID().uuidString.lowercased()
        UserDefaults.standard.set(fresh, forKey: "anonymousStatsInstallID")
        return fresh
    }

    @discardableResult
    static func resetAnonymousStatsInstallID() -> String {
        let fresh = UUID().uuidString.lowercased()
        UserDefaults.standard.set(fresh, forKey: "anonymousStatsInstallID")
        return fresh
    }

    /// Tracks whether this install already sent its one-time opt-in `first_launch` ping.
    static var anonymousStatsFirstLaunchSent: Bool {
        get { UserDefaults.standard.bool(forKey: "anonymousStatsFirstLaunchSent") }
        set { UserDefaults.standard.set(newValue, forKey: "anonymousStatsFirstLaunchSent") }
    }

    /// Tracks whether the user explicitly subscribed to product updates from this Mac (UI convenience only).
    static var productUpdatesSubscribed: Bool {
        get { UserDefaults.standard.bool(forKey: "productUpdatesSubscribed") }
        set { UserDefaults.standard.set(newValue, forKey: "productUpdatesSubscribed") }
    }
}

/// Strictly allowlisted aggregate payload. Audio, text, app names, window titles, screen terms,
/// emails, user IDs, and IP addresses cannot be represented in this type.
struct AnonymousStatsPayload: Codable, Equatable {
    let install_id: String
    let day: String
    let app_version: String
    let mode: String
    let dictation_count: Int?
    let error_code: String?
    let onboarding_step: String?
    let first_launch: Bool?

    init(install_id: String, day: String, app_version: String, mode: String,
         dictation_count: Int? = nil, error_code: String? = nil,
         onboarding_step: String? = nil, first_launch: Bool? = nil) {
        self.install_id = install_id
        self.day = day
        self.app_version = app_version
        self.mode = mode
        self.dictation_count = dictation_count
        self.error_code = error_code
        self.onboarding_step = onboarding_step
        self.first_launch = first_launch
    }
}

@MainActor
final class AnonymousStats {
    static let shared = AnonymousStats()

    var baseURL: () -> URL? = { AppIdentity.apiBaseURL ?? URL(string: "https://voice.sundayable.com") }
    var isEnabled: () -> Bool = { Prefs.anonymousStatsEnabled }
    var installID: () -> String = { Prefs.anonymousStatsInstallID }
    var hasSentFirstLaunch: () -> Bool = { Prefs.anonymousStatsFirstLaunchSent }
    var markFirstLaunchSent: () -> Void = { Prefs.anonymousStatsFirstLaunchSent = true }
    var now: () -> Date = { Date() }
    var sendRequest: (URLRequest) async throws -> Void = { request in
        let session = URLSession(configuration: .ephemeral)
        _ = try await session.data(for: request)
    }

    private static let utcDayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(secondsFromGMT: 0)
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    static func utcDay(_ date: Date = Date()) -> String {
        utcDayFormatter.string(from: date)
    }

    /// Maps internal error codes onto a tiny fixed allowlist so raw messages can never leak.
    static func coarseErrorCode(_ raw: String?) -> String {
        guard let code = raw?.lowercased(), !code.isEmpty else { return "unknown" }
        if code.contains("no_speech") { return "no_speech" }
        if code.contains("too_short") { return "too_short" }
        if code.contains("microphone") || code.contains("mic") { return "mic_denied" }
        if code.contains("accessibility") { return "ax_missing" }
        if code.contains("input_monitoring") { return "input_monitoring_missing" }
        if code.contains("subscription") { return "subscription_required" }
        if code.contains("local_model") { return "local_model_missing" }
        if code.contains("quota") { return "quota_exceeded" }
        if code.contains("secure_field") { return "secure_field" }
        if code.contains("audio_saved") { return "audio_saved" }
        if code.contains("network") || code.contains("timeout") || code.contains("connection") { return "network" }
        if code.contains("client_error") { return "client_error" }
        return "unknown"
    }

    static func stepName(_ step: OnboardingStep) -> String {
        switch step {
        case .signIn: return "start"
        case .proUpgrade: return "pro_upgrade"
        case .permissions: return "permissions"
        case .mic: return "mic"
        case .keys: return "keys"
        case .localModel: return "local_model"
        case .connect: return "connect"
        case .voice: return "voice"
        case .tryIt: return "try_it"
        case .done: return "done"
        }
    }

    func recordDictation(localMode: Bool) {
        send(localMode: localMode, dictationCount: 1, errorCode: nil, onboardingStep: nil, firstLaunch: nil)
    }

    func recordError(_ rawCode: String?, localMode: Bool) {
        send(localMode: localMode, dictationCount: nil, errorCode: Self.coarseErrorCode(rawCode), onboardingStep: nil, firstLaunch: nil)
    }

    func recordOnboardingStep(_ step: OnboardingStep, localMode: Bool) {
        send(localMode: localMode, dictationCount: nil, errorCode: nil, onboardingStep: Self.stepName(step), firstLaunch: nil)
    }

    /// Sends a single opt-in `first_launch` ping per install when anonymous stats are enabled.
    /// Zero network traffic when `isEnabled()` is false.
    func recordFirstLaunchIfNeeded(localMode: Bool) {
        guard isEnabled(), !hasSentFirstLaunch() else { return }
        markFirstLaunchSent()
        send(localMode: localMode, dictationCount: nil, errorCode: nil, onboardingStep: nil, firstLaunch: true)
    }

    private func send(localMode: Bool, dictationCount: Int?, errorCode: String?, onboardingStep: String?, firstLaunch: Bool?) {
        // Hard privacy gate: when OFF, zero network traffic ever leaves this Mac.
        guard isEnabled(), let base = baseURL() else { return }
        let payload = AnonymousStatsPayload(
            install_id: installID(),
            day: Self.utcDay(now()),
            app_version: (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "0.0.0",
            mode: localMode ? "local" : "pro",
            dictation_count: dictationCount,
            error_code: errorCode,
            onboarding_step: onboardingStep,
            first_launch: firstLaunch
        )
        guard let body = try? JSONEncoder().encode(payload) else { return }
        var req = URLRequest(url: base.appendingPathComponent("api/stats"))
        req.httpMethod = "POST"
        req.timeoutInterval = 10
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = body
        let transport = sendRequest
        Task { try? await transport(req) }
    }
}

enum ProductUpdatesError: Error, Equatable {
    case invalidEmail
    case consentRequired
    case networkFailed
}

/// Optional CASL-compliant product updates subscription client.
/// Never auto-subscribes on Google sign-in; requires explicit user email + consent checkbox.
@MainActor
final class ProductUpdatesClient {
    static let shared = ProductUpdatesClient()

    enum Source: String {
        case onboardingDone = "onboarding_done"
        case settingsAccount = "settings_account"
    }

    var baseURL: () -> URL? = { AppIdentity.apiBaseURL ?? URL(string: "https://voice.sundayable.com") }
    var sendRequest: (URLRequest) async throws -> (Data, URLResponse) = { request in
        try await URLSession(configuration: .ephemeral).data(for: request)
    }

    static func isValidEmail(_ raw: String) -> Bool {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count <= 254 else { return false }
        let parts = trimmed.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty, !parts[0].contains(" ") else { return false }
        let domain = parts[1]
        guard domain.contains("."), !domain.hasPrefix("."), !domain.hasSuffix("."), !domain.contains(" ") else { return false }
        return domain.split(separator: ".").last.map { $0.count >= 2 } ?? false
    }

    func subscribe(email: String, consent: Bool, source: Source, locale: String = UILanguage.code) async throws {
        guard consent else { throw ProductUpdatesError.consentRequired }
        let normalized = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard Self.isValidEmail(normalized) else { throw ProductUpdatesError.invalidEmail }
        guard let base = baseURL() else { throw ProductUpdatesError.networkFailed }

        var req = URLRequest(url: base.appendingPathComponent("api/updates/subscribe"))
        req.httpMethod = "POST"
        req.timeoutInterval = 15
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let payload: [String: Any] = [
            "email": normalized,
            "consent": true,
            "source": source.rawValue,
            "locale": locale == "ko" ? "ko" : "en",
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: payload)
        let (_, response) = try await sendRequest(req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else { throw ProductUpdatesError.networkFailed }
    }
}
