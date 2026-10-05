import Foundation

/// Where the signed-in session is kept between launches.
public protocol SessionStorage: Sendable {
    func get(_ key: String) async -> String?
    func set(_ key: String, value: String) async
    func remove(_ key: String) async
}

/// Keeps the session in memory only (the user signs in again after a restart). The default off Apple platforms.
public actor MemorySessionStorage: SessionStorage {
    private var values: [String: String] = [:]
    public init() {}
    public func get(_ key: String) -> String? { values[key] }
    public func set(_ key: String, value: String) { values[key] = value }
    public func remove(_ key: String) { values[key] = nil }
}

/// The result of a sign-up: a session when no confirmation is needed, otherwise only the user.
public struct SignUpResult: Sendable {
    public let user: User?
    public let session: Session?
}

/// Espobase App Authentication for your app's users (sign-up, sign-in, sessions). Access tokens are refreshed for you:
/// requests made through `from()`, `storage`, `functions` and `rpc` carry the signed-in user's token.
public actor AuthClient {
    private let http: Http
    private let storage: SessionStorage
    private let storageKey: String
    private let autoRefresh: Bool
    private let now: @Sendable () -> Date
    private let isSecretKey: Bool

    private var session: Session?
    private var loaded = false
    private var refreshing: Task<Session, Error>?
    private var pendingMfa: String?
    private var listeners: [UUID: AsyncStream<(AuthEvent, Session?)>.Continuation] = [:]

    /// Two-step sign-in: finish a waiting sign-in, set up and remove methods.
    public nonisolated let mfa: MfaClient

    private static let refreshMargin: TimeInterval = 30

    init(http: Http, storage: SessionStorage, secretKey: Bool, autoRefresh: Bool, now: @escaping @Sendable () -> Date) {
        self.http = http
        self.storage = storage
        self.isSecretKey = secretKey
        self.autoRefresh = autoRefresh
        self.now = now
        let path = URL(string: http.base)?.path ?? ""
        self.storageKey = "espobase.auth." + path.replacingOccurrences(of: "[^A-Za-z0-9_]+", with: "_", options: .regularExpression)
        self.mfa = MfaClient(http: http)
        self.mfa.attach(self)
    }

    // MARK: State

    /// Sign-in, sign-out and refresh events: `for await (event, session) in auth.authStateChanges { … }`.
    public var authStateChanges: AsyncStream<(AuthEvent, Session?)> {
        let id = UUID()
        return AsyncStream { continuation in
            listeners[id] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeListener(id) }
            }
        }
    }

    private func removeListener(_ id: UUID) { listeners[id] = nil }

    private func emit(_ event: AuthEvent, _ session: Session?) {
        for continuation in listeners.values { continuation.yield((event, session)) }
    }

    private func guardKey() throws {
        if isSecretKey { throw EspobaseError.client("secret_key", "Use a publishable key for App Authentication.") }
    }

    private func load() async {
        guard !loaded else { return }
        loaded = true
        if let text = await storage.get(storageKey), let data = text.data(using: .utf8),
            let saved = try? JSONDecoder().decode(Session.self, from: data)
        {
            session = saved
        }
    }

    private func save(_ new: Session, _ event: AuthEvent) async {
        session = new
        loaded = true
        if let data = try? JSONEncoder().encode(new), let text = String(data: data, encoding: .utf8) {
            await storage.set(storageKey, value: text)
        }
        emit(event, new)
    }

    private func clear(_ event: AuthEvent) async {
        session = nil
        loaded = true
        await storage.remove(storageKey)
        emit(event, nil)
    }

    /// The current session (refreshed first when it is about to expire), or nil when signed out.
    public func currentSession() async throws -> Session? {
        await load()
        guard let current = session else { return nil }
        if autoRefresh && Double(current.expiresAt) - Self.refreshMargin <= now().timeIntervalSince1970 {
            return try await refreshSession()
        }
        return current
    }

    /// The signed-in user (from the stored session; nil when signed out).
    public func currentUser() async throws -> User? {
        try await currentSession()?.user
    }

    /// Access token for API calls (nil when signed out).
    public func accessToken() async throws -> String? {
        try await currentSession()?.accessToken
    }

    // MARK: Sign-in

    private struct PendingWire: Decodable {
        struct Factor: Decodable {
            let id: String
            let type: MfaFactorType
        }
        let mfa_required: Bool?
        let enrollment_required: Bool?
        let mfa_token: String?
        let factors: [Factor]?
        let recovery_codes: Bool?
    }

    /// Turns a sign-in answer into a session, or throws `mfa_required` / `mfa_enrollment_required` when the second step is
    /// still waiting (then finish it with `auth.mfa.verify`).
    func finishSignIn(_ data: Data, status: Int) async throws -> Session {
        if let pending = try? JSONDecoder().decode(PendingWire.self, from: data), pending.mfa_required == true,
            let token = pending.mfa_token
        {
            pendingMfa = token
            let enrollment = pending.enrollment_required ?? false
            throw EspobaseError(
                status: status,
                code: enrollment ? "mfa_enrollment_required" : "mfa_required",
                message: enrollment
                    ? "Set up two-step sign-in to finish signing in." : "Enter the code from your second sign-in step.",
                mfa: MfaPending(
                    enrollmentRequired: enrollment,
                    factors: (pending.factors ?? []).map { MfaPending.Factor(id: $0.id, type: $0.type) },
                    recoveryCodes: pending.recovery_codes ?? false))
        }
        let signedIn = try Http.decode(Session.self, from: data)
        pendingMfa = nil
        await save(signedIn, .signedIn)
        return signedIn
    }

    func pendingMfaToken() -> String? { pendingMfa }
    func clearPendingMfa() { pendingMfa = nil }

    private func post(_ path: String, _ body: [String: String?], token: String? = nil) async throws -> HTTPResult {
        let compact = body.compactMapValues { $0 }
        return try await http.send(
            path, method: "POST", body: try JSONEncoder().encode(compact), token: token)
    }

    /// Creates an account. With email confirmation on (the default) the user gets a link and no session yet.
    /// `redirectTo` is where the link opens: an https URL or an app link such as `myapp://auth/callback`, listed under
    /// Authentication › Settings › Allowed redirect URLs.
    public func signUp(email: String, password: String, redirectTo: String? = nil) async throws -> SignUpResult {
        try guardKey()
        let result = try await post(
            "/auth/v1/signup", ["email": email, "password": password, "redirect_to": redirectTo])
        struct Wire: Decodable {
            let user: User?
            let session: Session?
        }
        if let pending = try? JSONDecoder().decode(PendingWire.self, from: result.data), pending.mfa_required == true {
            _ = try await finishSignIn(result.data, status: result.status)  // throws mfa_*
        }
        let wire = try Http.decode(Wire.self, from: result.data)
        if let signedIn = wire.session { await save(signedIn, .signedIn) }
        return SignUpResult(user: wire.user, session: wire.session)
    }

    public func signInWithPassword(email: String, password: String) async throws -> Session {
        try guardKey()
        let result = try await post("/auth/v1/token", ["email": email, "password": password])
        return try await finishSignIn(result.data, status: result.status)
    }

    /// Native sign-in sheets: signs in with the identity token an app got from the provider (today: Sign in with Apple).
    /// Give the sheet `AppleNonce().hashed` and pass `AppleNonce().raw` here. The token's audience must be your app's
    /// bundle ID (add it under Authentication › Providers › Apple).
    public func signInWithIdToken(provider: OAuthProvider = .apple, token: String, nonce: String) async throws -> Session {
        try guardKey()
        let result = try await post(
            "/auth/v1/id-token", ["provider": provider.rawValue, "id_token": token, "nonce": nonce])
        return try await finishSignIn(result.data, status: result.status)
    }

    /// Social sign-in with a web page (the provider must be on for the project). Open the returned URL in
    /// `ASWebAuthenticationSession` with your app's callback scheme; the user comes back to `redirectTo` with `?code=…`
    /// (or `?error=…`): pass that code to `exchangeCodeForSession`. The one-time secret stays on this device.
    public func signInWithOAuth(provider: OAuthProvider, redirectTo: String? = nil) async throws -> URL {
        try guardKey()
        let pkce = PKCE.make()
        await storage.set(storageKey + ".code_verifier", value: pkce.verifier)
        var query = [
            URLQueryItem(name: "provider", value: provider.rawValue),
            URLQueryItem(name: "code_challenge", value: pkce.challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "apikey", value: http.key),
        ]
        if let redirectTo { query.append(URLQueryItem(name: "redirect_to", value: redirectTo)) }
        return try http.url("/auth/v1/authorize", query: query)
    }

    /// Finishes a social sign-in: the `code` from the redirect URL plus this device's PKCE verifier.
    public func exchangeCodeForSession(_ code: String) async throws -> Session {
        try guardKey()
        let key = storageKey + ".code_verifier"
        guard let verifier = await storage.get(key) else {
            throw EspobaseError.client("no_code_verifier", "This sign-in wasn't started on this device. Start it again.")
        }
        defer { Task { await storage.remove(key) } }
        let result = try await post("/auth/v1/exchange", ["auth_code": code, "code_verifier": verifier])
        return try await finishSignIn(result.data, status: result.status)
    }

    /// Confirms an email address with the token from the verification link, and signs the user in.
    public func verifyEmail(token: String) async throws -> Session {
        let result = try await post("/auth/v1/verify", ["type": "signup", "token": token])
        return try await finishSignIn(result.data, status: result.status)
    }

    /// Passwordless sign-in (turned on per project): emails a link and a 6-digit code.
    public func signInWithOtp(email: String, redirectTo: String? = nil, shouldCreateUser: Bool = true) async throws {
        try guardKey()
        struct Body: Encodable {
            let email: String
            let redirect_to: String?
            let create_user: Bool
        }
        _ = try await http.send(
            "/auth/v1/otp", method: "POST",
            body: try JSONEncoder().encode(Body(email: email, redirect_to: redirectTo, create_user: shouldCreateUser)))
    }

    /// Finishes a passwordless sign-in with the emailed code.
    public func verifyOtp(email: String, code: String) async throws -> Session {
        let result = try await post("/auth/v1/verify", ["type": "email", "email": email, "code": code])
        return try await finishSignIn(result.data, status: result.status)
    }

    /// Finishes a passwordless sign-in with the link's token.
    public func verifyOtp(token: String) async throws -> Session {
        let result = try await post("/auth/v1/verify", ["type": "magiclink", "token": token])
        return try await finishSignIn(result.data, status: result.status)
    }

    // MARK: Session

    /// Ends the session on this device (`global: true`: on every device). The local session is cleared even when the
    /// network call fails.
    public func signOut(global: Bool = false) async throws {
        await load()
        let token = session?.accessToken
        var failure: Error?
        if let token {
            do {
                _ = try await http.send(
                    "/auth/v1/logout", method: "POST",
                    body: try JSONEncoder().encode(["scope": global ? "global" : "local"]), token: token)
            } catch { failure = error }
        }
        await clear(.signedOut)
        if let failure, (failure as? EspobaseError)?.status != 401 { throw failure }
    }

    /// Swaps the refresh token for a new session. Concurrent callers share one request.
    @discardableResult
    public func refreshSession() async throws -> Session {
        if let refreshing { return try await refreshing.value }
        await load()
        guard let current = session else { throw EspobaseError.notSignedIn }
        let http = self.http
        let task = Task<Session, Error> {
            let result = try await http.send(
                "/auth/v1/refresh", method: "POST",
                body: try JSONEncoder().encode(["refresh_token": current.refreshToken]))
            return try Http.decode(Session.self, from: result.data)
        }
        refreshing = task
        defer { refreshing = nil }
        do {
            let next = try await task.value
            await save(next, .tokenRefreshed)
            return next
        } catch let error as EspobaseError {
            // The refresh token is spent or revoked: the user must sign in again.
            if error.status == 400 || error.status == 401 { await clear(.signedOut) }
            throw error
        }
    }

    // MARK: Account

    public func resetPasswordForEmail(_ email: String, redirectTo: String? = nil) async throws {
        try guardKey()
        _ = try await post("/auth/v1/recover", ["email": email, "redirect_to": redirectTo])
    }

    /// Completes a password reset with the token from the reset link.
    public func resetPassword(token: String, password: String) async throws {
        _ = try await post("/auth/v1/reset-password", ["token": token, "password": password])
    }

    /// Sets a new password and/or asks to change the email address (when the project allows it).
    @discardableResult
    public func updateUser(
        password: String? = nil, email: String? = nil, currentPassword: String? = nil, redirectTo: String? = nil
    ) async throws -> User {
        guard let token = try await accessToken() else { throw EspobaseError.notSignedIn }
        let body = ["password": password, "email": email, "current_password": currentPassword, "redirect_to": redirectTo]
            .compactMapValues { $0 }
        let result = try await http.send(
            "/auth/v1/user", method: "PUT", body: try JSONEncoder().encode(body), token: token)
        struct Wire: Decodable { let user: User }
        let user = try Http.decode(Wire.self, from: result.data).user
        if let current = session { await save(current.with(user: user), .userUpdated) }
        return user
    }

    /// Confirms an email change with the token from the link sent to the new address.
    public func verifyEmailChange(token: String) async throws -> User {
        let result = try await post("/auth/v1/verify", ["type": "email_change", "token": token])
        struct Wire: Decodable { let user: User }
        let user = try Http.decode(Wire.self, from: result.data).user
        if let current = session, current.user.id == user.id { await save(current.with(user: user), .userUpdated) }
        return user
    }
}

/// Two-step sign-in (turned on per project). After `mfa_required`, `verify(code:)` finishes the sign-in with an
/// authenticator code, an emailed code (`challenge()` sends it) or a recovery code.
public final class MfaClient: @unchecked Sendable {
    private let http: Http
    private weak var auth: AuthClient?
    private let lock = NSLock()

    init(http: Http) { self.http = http }

    func attach(_ auth: AuthClient) {
        lock.lock()
        defer { lock.unlock() }
        self.auth = auth
    }

    private func owner() throws -> AuthClient {
        lock.lock()
        defer { lock.unlock() }
        guard let auth else { throw EspobaseError.client("no_client", "The client was released.") }
        return auth
    }

    private static let noPending = EspobaseError.client(
        "no_mfa_sign_in", "No sign-in is waiting for a second step. Sign in again.")

    /// Finishes the waiting sign-in.
    public func verify(code: String, factorId: String? = nil) async throws -> Session {
        let auth = try owner()
        guard let mfaToken = await auth.pendingMfaToken() else { throw Self.noPending }
        let body = ["mfa_token": mfaToken, "code": code, "factor_id": factorId].compactMapValues { $0 }
        do {
            let result = try await http.send("/auth/v1/mfa-verify", method: "POST", body: try JSONEncoder().encode(body))
            return try await auth.finishSignIn(result.data, status: result.status)
        } catch let error as EspobaseError {
            if error.code == "invalid_mfa_token" { await auth.clearPendingMfa() }
            throw error
        }
    }

    /// Emails a code for the email method: for the waiting sign-in, or (signed in) before `unenroll`.
    public func challenge() async throws {
        let auth = try owner()
        let mfaToken = await auth.pendingMfaToken()
        let token = mfaToken == nil ? try await auth.accessToken() : nil
        if mfaToken == nil && token == nil { throw EspobaseError.notSignedIn }
        let body = mfaToken.map { ["mfa_token": $0] } ?? [:]
        _ = try await http.send("/auth/v1/mfa-challenge", method: "POST", body: try JSONEncoder().encode(body), token: token)
    }

    public struct Enrollment: Decodable, Sendable {
        public let factorId: String
        public let type: MfaFactorType
        /// `totp`: the shared secret and an `otpauth://` URI (show it as a QR code).
        public let secret: String?
        public let uri: String?
        enum CodingKeys: String, CodingKey {
            case factorId = "factor_id"
            case type, secret, uri
        }
    }

    /// Starts setting up a method.
    public func enroll(type: MfaFactorType) async throws -> Enrollment {
        let auth = try owner()
        let mfaToken = await auth.pendingMfaToken()
        let token = mfaToken == nil ? try await auth.accessToken() : nil
        if mfaToken == nil && token == nil { throw EspobaseError.notSignedIn }
        let body = ["type": type.rawValue, "mfa_token": mfaToken].compactMapValues { $0 }
        let result = try await http.send("/auth/v1/mfa-enroll", method: "POST", body: try JSONEncoder().encode(body), token: token)
        return try Http.decode(Enrollment.self, from: result.data)
    }

    public struct EnrollmentResult: Sendable {
        /// The first method also returns recovery codes: show them once.
        public let recoveryCodes: [String]?
        public let session: Session?
    }

    /// Confirms a new method with its first code. During a waiting sign-in this signs the user in.
    public func verifyEnrollment(factorId: String, code: String) async throws -> EnrollmentResult {
        let auth = try owner()
        let mfaToken = await auth.pendingMfaToken()
        let token = mfaToken == nil ? try await auth.accessToken() : nil
        if mfaToken == nil && token == nil { throw EspobaseError.notSignedIn }
        let body = ["factor_id": factorId, "code": code, "mfa_token": mfaToken].compactMapValues { $0 }
        let result = try await http.send(
            "/auth/v1/mfa-enroll-verify", method: "POST", body: try JSONEncoder().encode(body), token: token)
        struct Wire: Decodable {
            let recovery_codes: [String]?
            let session: Session?
        }
        let wire = try Http.decode(Wire.self, from: result.data)
        if wire.session != nil { _ = try await auth.finishSignIn(try JSONEncoder().encode(wire.session), status: result.status) }
        return EnrollmentResult(recoveryCodes: wire.recovery_codes, session: wire.session)
    }

    /// The signed-in user's methods and how many recovery codes are left.
    public func listFactors() async throws -> (factors: [MfaFactor], recoveryCodesLeft: Int) {
        guard let token = try await owner().accessToken() else { throw EspobaseError.notSignedIn }
        let result = try await http.send("/auth/v1/mfa-factors", token: token)
        struct Wire: Decodable {
            let factors: [MfaFactor]
            let recovery_codes_left: Int
        }
        let wire = try Http.decode(Wire.self, from: result.data)
        return (wire.factors, wire.recovery_codes_left)
    }

    /// Removes a method; needs a current code (authenticator, emailed code or a recovery code).
    public func unenroll(factorId: String, code: String) async throws {
        guard let token = try await owner().accessToken() else { throw EspobaseError.notSignedIn }
        _ = try await http.send(
            "/auth/v1/mfa-unenroll", method: "POST",
            body: try JSONEncoder().encode(["factor_id": factorId, "code": code]), token: token)
    }
}
