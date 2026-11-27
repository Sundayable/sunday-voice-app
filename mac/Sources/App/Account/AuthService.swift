import AppKit
import AuthenticationServices
import CryptoKit
import DictationEngine

struct UserProfile: Codable, Equatable {
    var id: String; var email: String; var name: String?; var picture: String?
    /// Invited guest (signed in with a one-time code): dictation only, no Gmail/Slack connections.
    var guest: Bool? = nil
}

enum AuthError: Error, Equatable { case notConfigured, cancelled, stateMismatch, server(String), signedOut }

@MainActor
protocol AuthWebSession: AnyObject {
    func start() -> Bool
    func cancel()
}

extension ASWebAuthenticationSession: AuthWebSession {}

/// Injectable so auth tests never read or change the user's credentials.
@MainActor
protocol AuthStorage: AnyObject {
    var refreshToken: String? { get set }
    var profile: Data? { get set }
    var acceptedConsent: String? { get set }
}

@MainActor
private final class KeychainAuthStorage: AuthStorage {
    var refreshToken: String? {
        get { Keychain.read("refresh_token") }
        set {
            if let newValue { Keychain.write("refresh_token", newValue) }
            else { Keychain.delete("refresh_token") }
        }
    }
    var profile: Data? {
        get { UserDefaults.standard.data(forKey: "profile") }
        set {
            if let newValue { UserDefaults.standard.set(newValue, forKey: "profile") }
            else { UserDefaults.standard.removeObject(forKey: "profile") }
        }
    }
    var acceptedConsent: String? {
        get { UserDefaults.standard.string(forKey: "acceptedConsent") }
        set {
            if let newValue { UserDefaults.standard.set(newValue, forKey: "acceptedConsent") }
            else { UserDefaults.standard.removeObject(forKey: "acceptedConsent") }
        }
    }
}

/// Google sign-in through the API (PKCE + custom URL scheme), token refresh with rotation.
/// Holds the access token in memory only; the refresh token lives in the keychain.
@MainActor
final class AuthService: NSObject, ObservableObject, AccessTokenProvider, ASWebAuthenticationPresentationContextProviding {
    typealias WebCompletion = @Sendable (URL?, Error?) -> Void
    typealias WebSessionFactory = (URL, String, ASWebAuthenticationPresentationContextProviding, @escaping WebCompletion) -> AuthWebSession
    typealias Request = (URLRequest) async throws -> (Data, URLResponse)

    @MainActor private final class SignInAttempt {
        let id = UUID()
        let state = AuthService.randomVerifier()
        var startURL: URL?
        var usingExternalBrowser = false
        var callback: CheckedContinuation<URL, Error>?
        var session: AuthWebSession?
        var poll: Task<Void, Never>?
        var timeout: Task<Void, Never>?
    }

    @Published private(set) var user: UserProfile?
    @Published private(set) var consentRequired = true
    @Published private(set) var consentChecked = false
    @Published private(set) var consentVersion: String?
    @Published private(set) var signingIn = false
    @Published private(set) var browserRecoveryAvailable = false
    private var access: (token: String, expiry: Date)?
    private var refreshing: (id: UUID, task: Task<String, Error>)?
    private var generation = UUID()
    private var signInAttempt: SignInAttempt?
    private let storage: AuthStorage
    private let makeWebSession: WebSessionFactory
    private let openBrowser: (URL) -> Bool
    private let sendRequest: Request
    private let pollingInterval: Duration
    private let signInTimeout: Duration
    private let configuredBaseURL: URL?
    private let environment: [String: String]
    let http: URLSession
    var baseURL: URL? { configuredBaseURL ?? AppIdentity.apiBaseURL }

    init(http: URLSession = URLSession(configuration: .ephemeral), storage: AuthStorage? = nil,
         makeWebSession: WebSessionFactory? = nil, openBrowser: ((URL) -> Bool)? = nil,
         request: Request? = nil, baseURL: URL? = nil,
         pollingInterval: Duration = .milliseconds(1500), signInTimeout: Duration = .seconds(600),
         environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.http = http
        self.storage = storage ?? KeychainAuthStorage()
        self.makeWebSession = makeWebSession ?? { url, scheme, provider, completion in
            let session = ASWebAuthenticationSession(url: url, callbackURLScheme: scheme, completionHandler: completion)
            session.presentationContextProvider = provider
            return session
        }
        self.sendRequest = request ?? { try await http.data(for: $0) }
        self.openBrowser = openBrowser ?? { NSWorkspace.shared.open($0) }
        self.configuredBaseURL = baseURL
        self.pollingInterval = pollingInterval
        self.signInTimeout = signInTimeout
        self.environment = environment
        super.init()
        if let data = self.storage.profile, self.storage.refreshToken != nil,
           let decoded = try? JSONDecoder().decode(UserProfile.self, from: data) {
            user = decoded
            if let cached = self.storage.acceptedConsent, cached.hasPrefix("\(decoded.id)|") {
                let version = String(cached.dropFirst(decoded.id.count + 1))
                if !version.isEmpty {
                    consentVersion = version
                    consentRequired = false
                }
            }
        }
    }

    var isSignedIn: Bool { user != nil && !consentRequired }

    /// Screenshot gallery only: show a signed-in state without touching the keychain.
    func previewSignedIn(_ profile: UserProfile?) { user = profile; consentRequired = profile == nil; consentChecked = true; consentVersion = "2026-10-16.1" }

    func previewNeedsConsent() { consentRequired = true; consentChecked = true; consentVersion = "2026-10-16.1" }

    // MARK: PKCE

    static func base64url(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
    static func randomVerifier() -> String { base64url(Data((0..<32).map { _ in UInt8.random(in: 0...255) })) }
    static func challenge(for verifier: String) -> String { base64url(Data(SHA256.hash(data: Data(verifier.utf8)))) }

    // MARK: sign in

    func signIn() async throws {
        guard let baseURL else { throw AuthError.notConfigured }
        guard !Task.isCancelled else { throw AuthError.cancelled }
        invalidatePendingWork()
        let attempt = SignInAttempt()
        let id = attempt.id
        signInAttempt = attempt
        signingIn = true
        defer { finishSignIn(id: id) }

        do {
            try await withTaskCancellationHandler {
                let verifier = Self.randomVerifier()
                #if DEBUG
                if let secret = environment["SUNDAY_VOICE_DEV_LOGIN_SECRET"], let email = environment["SUNDAY_VOICE_DEV_EMAIL"] {
                    let body: [String: Any] = ["email": email, "code_challenge": Self.challenge(for: verifier), "state": attempt.state]
                    let object = try await post("api/auth/dev-login", body, headers: ["x-dev-login-secret": secret])
                    try checkSignIn(id: id)
                    guard let code = object["code"] as? String else { throw AuthError.server("dev_login") }
                    return try await exchange(code: code, verifier: verifier, attemptID: id)
                }
                #endif
                var components = URLComponents(url: baseURL.appendingPathComponent("auth/google/start"), resolvingAgainstBaseURL: false)!
                components.queryItems = [URLQueryItem(name: "code_challenge", value: Self.challenge(for: verifier)),
                                         URLQueryItem(name: "state", value: attempt.state),
                                         URLQueryItem(name: "redirect_uri", value: "\(AppIdentity.urlScheme)://auth")]
                attempt.startURL = components.url
                let callback: URL = try await withCheckedThrowingContinuation { continuation in
                    guard !Task.isCancelled, signInAttempt?.id == id else {
                        continuation.resume(throwing: AuthError.cancelled)
                        return
                    }
                    attempt.callback = continuation
                    // AuthenticationServices can complete on SafariLaunchAgent's XPC queue. A sendable
                    // callback must hop to the actor, not assert that it is already running there.
                    let completion: WebCompletion = { [weak self] url, error in
                        Task { @MainActor [weak self] in
                            self?.webSessionCompleted(id: id, url: url, error: error)
                        }
                    }
                    let session = makeWebSession(components.url!, AppIdentity.urlScheme, self, completion)
                    attempt.session = session
                    browserRecoveryAvailable = true
                    startPolling(attempt)
                    if !session.start() { useExternalBrowser(id: id) }
                }
                try checkSignIn(id: id)
                let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
                if let error = items.first(where: { $0.name == "error" })?.value { throw AuthError.server(error) }
                let codes = items.filter { $0.name == "code" }
                guard codes.count == 1, let code = codes.first?.value, !code.isEmpty else { throw AuthError.server("missing_code") }
                try await exchange(code: code, verifier: verifier, attemptID: id)
            } onCancel: {
                Task { @MainActor [weak self] in self?.finishSignIn(id: id) }
            }
        } catch {
            // A superseded exchange may fail rather than succeed. Do not surface that old error
            // in the current onboarding attempt (or turn task cancellation into a network error).
            try checkSignIn(id: id)
            throw error
        }
    }

    /// Let the user recover if the system browser session starts but never presents a window.
    /// Reuse the same PKCE request so polling and a late deep link still have one owner.
    func continueSignInInBrowser() {
        guard let attempt = signInAttempt, browserRecoveryAvailable else { return }
        useExternalBrowser(id: attempt.id)
    }

    func cancelSignIn() {
        guard let attempt = signInAttempt else { return }
        finishSignIn(id: attempt.id)
    }

    /// Fallback when the browser's redirect never reaches us (another app copy, a blocked prompt): ask the
    /// server every 1.5 s whether this sign-in finished. The code still needs our PKCE verifier.
    private func startPolling(_ attempt: SignInAttempt) {
        let id = attempt.id, state = attempt.state
        let interval = pollingInterval, timeout = signInTimeout
        attempt.timeout = Task { [weak self] in
            do { try await Task.sleep(for: timeout) } catch { return }
            self?.resolveCallback(id: id, result: .failure(AuthError.server("sign_in_timeout")))
        }
        attempt.poll = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: interval) } catch { return }
                guard let self, self.signInAttempt?.id == id, self.signInAttempt?.callback != nil else { return }
                let object: [String: Any]
                do { object = try await self.post("api/auth/poll", ["state": state]) }
                catch { continue }
                // An in-flight request can finish after cancellation or after a new sign-in starts.
                guard !Task.isCancelled, self.signInAttempt?.id == id, self.signInAttempt?.callback != nil else { return }
                guard object["pending"] == nil else { continue }
                var components = URLComponents()
                components.scheme = AppIdentity.urlScheme; components.host = "auth"
                components.queryItems = object.compactMap { key, value in (value as? String).map { URLQueryItem(name: key, value: $0) } }
                if let url = components.url, self.handleCallback(url) { return }
            }
        }
    }

    /// `<scheme>://auth?…` delivered to the app itself (default browser didn't hand it back to the
    /// web-auth session). Completes the pending sign-in; returns false if none is pending.
    @discardableResult func handleCallback(_ url: URL) -> Bool {
        guard let attempt = signInAttempt, attempt.callback != nil, matchesCallback(url, state: attempt.state) else { return false }
        resolveCallback(id: attempt.id, result: .success(url))
        return true
    }

    private func matchesCallback(_ url: URL, state: String) -> Bool {
        guard url.scheme == AppIdentity.urlScheme, url.host == "auth" else { return false }
        let states = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.filter { $0.name == "state" } ?? []
        return states.count == 1 && states.first?.value == state
    }

    private func webSessionCompleted(id: UUID, url: URL?, error: Error?) {
        guard let attempt = signInAttempt, attempt.id == id, attempt.callback != nil, !attempt.usingExternalBrowser else { return }
        if let url {
            resolveCallback(id: id, result: matchesCallback(url, state: attempt.state) ? .success(url) : .failure(AuthError.stateMismatch))
        } else if let error = error as? ASWebAuthenticationSessionError, error.code == .canceledLogin {
            resolveCallback(id: id, result: .failure(AuthError.cancelled))
        } else {
            useExternalBrowser(id: id)
        }
    }

    /// Some default browsers cannot service ASWebAuthenticationSession (including asynchronous
    /// dry-run failures). Keep the same PKCE/state and polling, and open the browser only once.
    private func useExternalBrowser(id: UUID) {
        guard let attempt = signInAttempt, attempt.id == id, attempt.callback != nil, !attempt.usingExternalBrowser else { return }
        attempt.usingExternalBrowser = true
        browserRecoveryAvailable = false
        let session = attempt.session
        attempt.session = nil
        session?.cancel()
        guard let url = attempt.startURL, openBrowser(url) else {
            resolveCallback(id: id, result: .failure(AuthError.server("web_auth")))
            return
        }
    }

    /// Every completion source goes through this gate. Clear ownership before cancel(), which can
    /// itself invoke the browser completion, and before resuming the suspended sign-in.
    private func resolveCallback(id: UUID, result: Result<URL, Error>) {
        guard let attempt = signInAttempt, attempt.id == id, let callback = attempt.callback else { return }
        attempt.callback = nil
        stopWaiting(attempt)
        callback.resume(with: result)
    }

    private func stopWaiting(_ attempt: SignInAttempt) {
        browserRecoveryAvailable = false
        attempt.poll?.cancel(); attempt.poll = nil
        attempt.timeout?.cancel(); attempt.timeout = nil
        let session = attempt.session
        attempt.session = nil
        session?.cancel()
    }

    private func finishSignIn(id: UUID) {
        guard let attempt = signInAttempt, attempt.id == id else { return }
        signInAttempt = nil
        signingIn = false
        let callback = attempt.callback
        attempt.callback = nil
        stopWaiting(attempt)
        callback?.resume(throwing: AuthError.cancelled)
    }

    private func checkSignIn(id: UUID) throws {
        guard !Task.isCancelled, signInAttempt?.id == id else { throw AuthError.cancelled }
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        NSApp.keyWindow ?? NSApp.windows.first ?? ASPresentationAnchor()
    }

    private func exchange(code: String, verifier: String, attemptID: UUID) async throws {
        let object = try await post("api/auth/token", ["grant_type": "authorization_code", "code": code, "code_verifier": verifier])
        try checkSignIn(id: attemptID)
        invalidateRefresh()
        try store(object)
    }

    func store(_ object: [String: Any]) throws {
        guard let token = object["access_token"] as? String, let refresh = object["refresh_token"] as? String else { throw AuthError.server("token_response") }
        let expiresIn = object["expires_in"] as? Double ?? 3600
        access = (token, Date().addingTimeInterval(expiresIn - 60))
        storage.refreshToken = refresh
        if let raw = object["user"], let data = try? JSONSerialization.data(withJSONObject: raw),
           let profile = try? JSONDecoder().decode(UserProfile.self, from: data) {
            user = profile
            storage.profile = data
        }
        applyConsent(object["consent"] as? [String: Any])
    }

    private func applyConsent(_ object: [String: Any]?) {
        consentVersion = object?["version"] as? String
        consentRequired = object?["required"] as? Bool ?? true
        consentChecked = true
        if !consentRequired, let id = user?.id, let version = consentVersion, !version.isEmpty {
            storage.acceptedConsent = "\(id)|\(version)"
        } else {
            storage.acceptedConsent = nil
        }
    }

    var onDiagnosticError: ((String) -> Void)?
    func reportClientError(_ code: String) async { onDiagnosticError?(code) }

    func consentReviewRequired() async {
        consentRequired = true
        consentChecked = true
        storage.acceptedConsent = nil
    }

    func refreshConsent() async throws {
        guard let baseURL else { throw AuthError.notConfigured }
        let identity = generation
        var request = URLRequest(url: baseURL.appendingPathComponent("api/consent"))
        request.setValue("Bearer \(try await accessToken())", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 20
        let (data, response) = try await sendRequest(request)
        guard generation == identity else { throw AuthError.signedOut }
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            consentRequired = true
            consentChecked = true
            storage.acceptedConsent = nil
            throw AuthError.server("consent_unavailable")
        }
        applyConsent(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func agreeToTerms() async throws {
        guard let version = consentVersion else { try await refreshConsent(); throw AuthError.server("review_terms") }
        let identity = generation
        let token = try await accessToken()
        let result = try await post("api/consent", ["version": version], headers: ["Authorization": "Bearer \(token)"])
        guard identity == generation else { throw AuthError.signedOut }
        applyConsent(result)
    }

    // MARK: tokens

    func accessToken() async throws -> String {
        try Task.checkCancellation()
        if let access, access.expiry > Date() { return access.token }
        let generation = self.generation
        let job: Task<String, Error>
        if let refreshing { job = refreshing.task }
        else {
            let id = UUID()
            job = Task { @MainActor () -> String in
                defer { if self.refreshing?.id == id { self.refreshing = nil } }
                guard !Task.isCancelled, self.generation == generation else { throw AuthError.signedOut }
                guard let refresh = self.storage.refreshToken else { throw AuthError.signedOut }
                do {
                    let object = try await self.post("api/auth/token", ["grant_type": "refresh_token", "refresh_token": refresh])
                    guard !Task.isCancelled, self.generation == generation else { throw AuthError.signedOut }
                    try self.store(object)
                    return self.access!.token
                } catch {
                    guard !Task.isCancelled, self.generation == generation else { throw AuthError.signedOut }
                    if let authError = error as? AuthError, authError == .server("invalid_grant") || authError == .server("unauthorized") {
                        self.forget()
                        throw AuthError.signedOut
                    }
                    throw error
                }
            }
            refreshing = (id, job)
        }
        let token = try await job.value
        guard self.generation == generation else { throw AuthError.signedOut }
        try Task.checkCancellation()
        return token
    }

    /// Invalidate only the token rejected by the server. A late 401 must not discard a newer token
    /// or start another rotation while another request is already refreshing.
    func invalidateAccessToken(_ rejectedToken: String) async {
        if access?.token == rejectedToken { access = nil }
    }

    func signOut(afterLocalClear: (() -> Void)? = nil) async {
        let refresh = storage.refreshToken
        // Clear locally before awaiting logout. Its eventual response cannot erase a newer login.
        forget()
        afterLocalClear?()
        if let refresh { _ = try? await post("api/auth/logout", ["refresh_token": refresh]) }
    }

    private func invalidatePendingWork() {
        invalidateRefresh()
        if let attempt = signInAttempt { finishSignIn(id: attempt.id) }
    }

    private func invalidateRefresh() {
        generation = UUID()
        refreshing?.task.cancel(); refreshing = nil
    }

    private func forget() {
        invalidatePendingWork()
        access = nil; user = nil; consentRequired = true; consentChecked = false; consentVersion = nil
        storage.refreshToken = nil
        storage.profile = nil
        storage.acceptedConsent = nil
    }

    // MARK: http

    func post(_ path: String, _ body: [String: Any], headers: [String: String] = [:]) async throws -> [String: Any] {
        guard let baseURL else { throw AuthError.notConfigured }
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(AppVersion.header, forHTTPHeaderField: AppVersion.headerName)
        headers.forEach { request.setValue($1, forHTTPHeaderField: $0) }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await sendRequest(request)
        let object = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        guard let status = (response as? HTTPURLResponse)?.statusCode, (200..<300).contains(status) else {
            throw AuthError.server(((object["error"] as? [String: Any])?["code"] as? String) ?? "http")
        }
        return object
    }
}
