import AppKit
import AppAuthCore
import GTMAppAuth

/// Native Google OAuth using AppAuth's public external-browser API and Google's Keychain/refresh
/// adapter. The system browser avoids SafariLaunchAgent failures without changing PKCE or state.
/// The existing Internal project owns the public client; no web secret or server relay is used.
@MainActor
final class GoogleCalendarAuth: GoogleCalendarAuthorizing {
    static let scope = "https://www.googleapis.com/auth/calendar.readonly"
    private static weak var active: GoogleCalendarAuth?
    private let clientID: String
    private let store: any AuthSessionStore
    private let openBrowser: (URL) -> Bool
    private let timeout: Duration
    private var session: GTMAppAuth.AuthSession?
    private var generation = UUID()
    private var flow: (any OIDExternalUserAgentSession)?
    private var pending: (id: UUID, continuation: CheckedContinuation<OIDAuthState, Error>)?
    private var timeoutTask: Task<Void, Never>?

    init(clientID: String? = nil, store: (any AuthSessionStore)? = nil,
         openBrowser: ((URL) -> Bool)? = nil, timeout: Duration = .seconds(600)) {
        self.clientID = clientID ?? Bundle.main.object(forInfoDictionaryKey: "GIDClientID") as? String ?? ""
        self.store = store ?? KeychainStore(itemName: AppIdentity.bundleID + ".google-calendar")
        self.openBrowser = openBrowser ?? { NSWorkspace.shared.open($0) }
        self.timeout = timeout
    }

    func restore() async throws -> GoogleCalendarAccount? {
        guard clientID.hasSuffix(".apps.googleusercontent.com") else { return nil }
        if session == nil {
            do { session = try store.retrieveAuthSession() }
            catch let error as KeychainStore.Error {
                if case .passwordNotFound = error { return nil }
                throw error
            }
        }
        guard let session else { return nil }
        let account = try account(session)
        // Validate the persisted grant once per app launch, also exercising the real refresh path.
        _ = try await accessToken(forceRefresh: true)
        return account
    }

    func connect(hint: String?) async throws -> GoogleCalendarAccount {
        guard pending == nil else { throw GoogleCalendarError.unavailable }
        let request = try Self.authorizationRequest(clientID: clientID, hint: hint)
        let generation = self.generation
        let id = UUID()
        let state = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                pending = (id, continuation)
                Self.active = self
                let browser = GoogleCalendarBrowserAgent(open: openBrowser)
                flow = OIDAuthState.authState(byPresenting: request, externalUserAgent: browser) { [weak self] state, error in
                    // SDK callbacks may arrive off-main. Never assume actor isolation here.
                    Task { @MainActor in
                        if let state { self?.finish(id, result: .success(state)) }
                        else { self?.finish(id, result: .failure(error ?? GoogleCalendarError.consentRequired)) }
                    }
                }
                timeoutTask = Task { [weak self, timeout] in
                    do { try await Task.sleep(for: timeout) } catch { return }
                    self?.cancel(id, error: GoogleCalendarError.signInTimedOut)
                }
                if Task.isCancelled { cancel(id, error: CancellationError()) }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancel(id, error: CancellationError()) }
        }
        try check(generation)
        let authorized = GTMAppAuth.AuthSession(authState: state)
        let account = try account(authorized)
        try store.save(authSession: authorized)
        session = authorized
        return account
    }

    func accessToken(forceRefresh: Bool) async throws -> String {
        guard let session else { throw GoogleCalendarError.consentRequired }
        _ = try account(session)
        let generation = self.generation
        if forceRefresh { session.authState.setNeedsTokenRefresh() }
        let request = NSMutableURLRequest(url: URL(string: "https://www.googleapis.com/calendar/v3/users/me/calendarList")!)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            session.authorizeRequest(request) { error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            }
        }
        try check(generation)
        _ = try account(session)
        // Persist any rotated refresh token only after the generation check.
        try store.save(authSession: session)
        guard let header = request.value(forHTTPHeaderField: "Authorization"), header.hasPrefix("Bearer ") else {
            throw GoogleCalendarError.unauthorized
        }
        return String(header.dropFirst(7))
    }

    func disconnect() {
        generation = UUID()
        if let id = pending?.id { cancel(id, error: CancellationError()) }
        session = nil
        // Local sign-out only; never revoke grants held by other clients in the project.
        try? store.removeAuthSession()
    }

    private func check(_ expected: UUID) throws {
        guard generation == expected else { throw CancellationError() }
        try Task.checkCancellation()
    }

    private func account(_ session: GTMAppAuth.AuthSession) throws -> GoogleCalendarAccount {
        let state = session.authState
        guard state.lastAuthorizationResponse.request.clientID == clientID,
              state.isAuthorized,
              Self.hasOnlyCalendarAccess(state.scope),
              let id = session.userID, let email = session.userEmail else { throw GoogleCalendarError.consentRequired }
        return GoogleCalendarAccount(id: id, email: email)
    }

    private func finish(_ id: UUID, result: Result<OIDAuthState, Error>) {
        guard let pending, pending.id == id else { return }
        self.pending = nil
        flow = nil
        timeoutTask?.cancel(); timeoutTask = nil
        if Self.active === self { Self.active = nil }
        pending.continuation.resume(with: result)
    }

    private func cancel(_ id: UUID, error: Error) {
        guard pending?.id == id else { return }
        let flow = self.flow
        finish(id, result: .failure(error)) // clear ownership before cancel can re-enter the callback
        flow?.cancel()
    }

    static func authorizationRequest(clientID: String, hint: String?) throws -> OIDAuthorizationRequest {
        guard clientID.hasSuffix(".apps.googleusercontent.com"), !clientID.contains("$("),
              let callback = URL(string: clientID.split(separator: ".").reversed().joined(separator: ".") + ":/oauth2callback")
        else { throw GoogleCalendarError.notConfigured }
        let configuration = OIDServiceConfiguration(
            authorizationEndpoint: URL(string: "https://accounts.google.com/o/oauth2/v2/auth")!,
            tokenEndpoint: URL(string: "https://oauth2.googleapis.com/token")!,
            issuer: URL(string: "https://accounts.google.com")!)
        // This project also owns a separate Gmail client. Do not aggregate its existing grants
        // into this client's token; requesting the identity scopes again preserves native login.
        var parameters = ["include_granted_scopes": "false", "access_type": "offline"]
        if let hint, !hint.isEmpty { parameters["login_hint"] = hint }
        return OIDAuthorizationRequest(configuration: configuration, clientId: clientID,
            scopes: ["openid", "email", "profile", scope], redirectURL: callback,
            responseType: OIDResponseTypeCode, additionalParameters: parameters)
    }

    static func handle(_ url: URL) -> Bool {
        guard let active, let flow = active.flow else { return false }
        let scheme = active.clientID.split(separator: ".").reversed().joined(separator: ".")
        guard url.scheme == scheme, url.host == nil, url.path == "/oauth2callback" else { return false }
        // AppAuth validates the complete redirect and unpredictable state before exchanging a code.
        return flow.resumeExternalUserAgentFlow(with: url)
    }

    static func hasOnlyCalendarAccess(_ scope: String?) -> Bool {
        let granted = Set((scope ?? "").split(separator: " ").map(String.init))
        let allowed: Set<String> = [Self.scope, "openid", "email", "profile",
            "https://www.googleapis.com/auth/userinfo.email", "https://www.googleapis.com/auth/userinfo.profile"]
        return granted.contains(Self.scope) && granted.isSubset(of: allowed)
    }
}

/// A public AppAuth extension point. No embedded web view, SDK swizzling or private APIs.
final class GoogleCalendarBrowserAgent: NSObject, OIDExternalUserAgent {
    private let open: (URL) -> Bool
    init(open: @escaping (URL) -> Bool) { self.open = open }
    func present(_ request: any OIDExternalUserAgentRequest, session: any OIDExternalUserAgentSession) -> Bool {
        guard let url = request.externalUserAgentRequestURL(),
              url.scheme == "https", url.host == "accounts.google.com" else { return false }
        return open(url)
    }
    func dismiss(animated: Bool, completion: @escaping () -> Void) { completion() }
}
