import XCTest

@testable import Espobase

/// A clock the tests move by hand.
final class Clock: @unchecked Sendable {
    private let lock = NSLock()
    private var time = Date(timeIntervalSince1970: 1_800_000_000)
    var now: Date {
        lock.lock()
        defer { lock.unlock() }
        return time
    }
    func advance(_ seconds: TimeInterval) {
        lock.lock()
        time = time.addingTimeInterval(seconds)
        lock.unlock()
    }
}

final class AuthTests: XCTestCase {
    func testSignInKeepsTheSessionAndAttachesTheTokenToLaterCalls() async throws {
        let (c, t) = try makeClient { seen in
            seen.path.hasSuffix("/auth/v1/token") ? (200, jsonBody(sessionJSON(1)), [:]) : (200, jsonBody([]), [:])
        }
        let events = Task { () -> [AuthEvent] in
            var seen: [AuthEvent] = []
            for await (event, _) in await c.auth.authStateChanges {
                seen.append(event)
                if event == .signedOut { break }
            }
            return seen
        }
        try await Task.sleep(nanoseconds: 50_000_000)  // let the listener register
        let session = try await c.auth.signInWithPassword(email: "a@b.co", password: "pw-123456")
        XCTAssertEqual(session.accessToken, "at1")
        XCTAssertEqual(session.user.email, "a@b.co")
        let body = t.requests[0].json
        XCTAssertEqual(body?["email"] as? String, "a@b.co")
        XCTAssertEqual(body?["password"] as? String, "pw-123456")
        let _: [Int] = try await c.from("orders").execute()
        XCTAssertEqual(t.requests.last?.headers["authorization"], "Bearer at1")
        let user = try await c.auth.currentUser()
        XCTAssertEqual(user?.id, "u1")
        try await c.auth.signOut()
        XCTAssertEqual(t.requests.last?.path, "/project/abcde12345/auth/v1/logout")
        let signedOut = try await c.auth.currentSession()
        XCTAssertNil(signedOut)
        let seen = await events.value
        XCTAssertEqual(seen, [.signedIn, .signedOut])
    }

    func testTheSessionSurvivesARestartThroughTheStorage() async throws {
        let storage = MemorySessionStorage()
        let route: @Sendable (Seen) -> (Int, Data, [String: String]) = { _ in (200, jsonBody(sessionJSON(1)), [:]) }
        let (first, _) = try makeClient(options: { $0.sessionStorage = storage }, route: route)
        _ = try await first.auth.signInWithPassword(email: "a@b.co", password: "pw")
        let (second, _) = try makeClient(options: { $0.sessionStorage = storage }, route: route)
        let restored = try await second.auth.currentSession()
        XCTAssertEqual(restored?.accessToken, "at1")
    }

    func testAnExpiringSessionIsRefreshedOnceEvenForConcurrentCallers() async throws {
        let clock = Clock()
        let counter = Counter()
        let (c, t) = try makeClient(options: { $0.now = { clock.now } }) { seen in
            if seen.path.hasSuffix("/auth/v1/token") {
                return (200, jsonBody(sessionJSON(1, expiresIn: 60, now: clock.now)), [:])
            }
            if seen.path.hasSuffix("/auth/v1/refresh") {
                counter.increment()
                return (200, jsonBody(sessionJSON(2, expiresIn: 900, now: clock.now)), [:])
            }
            return (200, jsonBody([]), [:])
        }
        _ = try await c.auth.signInWithPassword(email: "a@b.co", password: "pw")
        clock.advance(40)  // inside the 30 s margin of a 60 s token
        let tokens = try await withThrowingTaskGroup(of: String?.self) { group -> [String?] in
            group.addTask { try await c.auth.accessToken() }
            group.addTask { try await c.auth.accessToken() }
            var out: [String?] = []
            for try await token in group { out.append(token) }
            return out
        }
        XCTAssertEqual(tokens, ["at2", "at2"])
        XCTAssertEqual(counter.value, 1)
        let refresh = t.requests.first { $0.path.hasSuffix("/refresh") }
        XCTAssertEqual(refresh?.json?["refresh_token"] as? String, "rt1")
    }

    func testARevokedRefreshTokenSignsTheUserOut() async throws {
        let clock = Clock()
        let (c, _) = try makeClient(options: { $0.now = { clock.now } }) { seen in
            if seen.path.hasSuffix("/auth/v1/token") { return (200, jsonBody(sessionJSON(1, expiresIn: 60, now: clock.now)), [:]) }
            return (401, jsonBody(["error": "invalid_grant", "message": "Invalid refresh token."]), [:])
        }
        _ = try await c.auth.signInWithPassword(email: "a@b.co", password: "pw")
        clock.advance(45)
        await expectError("invalid_grant", status: 401) { try await c.auth.accessToken() }
        let after = try await c.auth.currentSession()
        XCTAssertNil(after)
    }

    func testSignUpWithConfirmationReturnsNoSessionAndPassesTheAppLink() async throws {
        let (c, t) = try makeClient { _ in
            (200, jsonBody(["user": sessionJSON()["user"]!, "session": NSNull()]), [:])
        }
        let result = try await c.auth.signUp(email: "a@b.co", password: "pw-123456", redirectTo: "myapp://auth/callback")
        XCTAssertNotNil(result.user)
        XCTAssertNil(result.session)
        XCTAssertEqual(t.requests[0].json?["redirect_to"] as? String, "myapp://auth/callback")
        let none = try await c.auth.currentSession()
        XCTAssertNil(none)
    }

    func testSignInWithAppleSendsTheIdentityTokenAndTheRawNonce() async throws {
        let (c, t) = try makeClient { _ in (200, jsonBody(sessionJSON(3)), [:]) }
        let nonce = AppleNonce()
        let session = try await c.auth.signInWithIdToken(token: String(repeating: "x", count: 40), nonce: nonce.raw)
        XCTAssertEqual(session.accessToken, "at3")
        XCTAssertEqual(t.requests[0].path, "/project/abcde12345/auth/v1/id-token")
        let body = t.requests[0].json
        XCTAssertEqual(body?["provider"] as? String, "apple")
        XCTAssertEqual(body?["nonce"] as? String, nonce.raw)
        XCTAssertEqual(body?["id_token"] as? String, String(repeating: "x", count: 40))
        XCTAssertNotEqual(body?["nonce"] as? String, nonce.hashed, "the raw nonce goes to Espobase, the hash to Apple")
    }

    func testSocialSignInBuildsTheAuthorizeURLAndExchangesTheCodeWithThisDevicesVerifier() async throws {
        let (c, t) = try makeClient { _ in (200, jsonBody(sessionJSON(4)), [:]) }
        let url = try await c.auth.signInWithOAuth(provider: .google, redirectTo: "myapp://auth/callback")
        let parts = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        XCTAssertEqual(parts.path, "/project/abcde12345/auth/v1/authorize")
        let q = Dictionary(uniqueKeysWithValues: parts.queryItems!.map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(q["provider"], "google")
        XCTAssertEqual(q["code_challenge_method"], "S256")
        XCTAssertEqual(q["apikey"], publishableKey)
        XCTAssertEqual(q["redirect_to"], "myapp://auth/callback")
        XCTAssertEqual(q["code_challenge"]?.count, 43)
        _ = try await c.auth.exchangeCodeForSession("one-time-code")
        let exchange = t.requests[0]
        XCTAssertEqual(exchange.path, "/project/abcde12345/auth/v1/exchange")
        let verifier = exchange.json?["code_verifier"] as? String ?? ""
        XCTAssertEqual(Base64URL.encode(SHA256Hash.hash(Array(verifier.utf8))), q["code_challenge"])
        // One attempt per sign-in: the verifier is gone.
        await expectError("no_code_verifier") { try await c.auth.exchangeCodeForSession("again") }
    }

    func testTwoStepSignInWaitsForTheSecondStepAndFinishesWithTheMfaToken() async throws {
        let (c, t) = try makeClient { seen in
            if seen.path.hasSuffix("/auth/v1/token") {
                return (
                    200,
                    jsonBody([
                        "mfa_required": true, "enrollment_required": false, "mfa_token": "mfa-token-1",
                        "factors": [["id": "f1", "type": "totp"]], "recovery_codes": true,
                    ]), [:]
                )
            }
            return (200, jsonBody(sessionJSON(5)), [:])
        }
        do {
            _ = try await c.auth.signInWithPassword(email: "a@b.co", password: "pw")
            XCTFail("expected mfa_required")
        } catch let error as EspobaseError {
            XCTAssertEqual(error.code, "mfa_required")
            XCTAssertEqual(error.mfa?.factors, [MfaPending.Factor(id: "f1", type: .totp)])
            XCTAssertEqual(error.mfa?.recoveryCodes, true)
        }
        let waiting = try await c.auth.currentSession()
        XCTAssertNil(waiting, "no session until the second step")
        let session = try await c.auth.mfa.verify(code: "123456")
        XCTAssertEqual(session.accessToken, "at5")
        XCTAssertEqual(t.requests.last?.json?["mfa_token"] as? String, "mfa-token-1")
        await expectError("no_mfa_sign_in") { try await c.auth.mfa.verify(code: "123456") }
    }

    func testAPublishableKeyIsRequiredForAuthAndUpdateUserNeedsASession() async throws {
        var options = ClientOptions()
        options.serverSide = true
        let transport = MockTransport { _ in (200, jsonBody(sessionJSON()), [:]) }
        options.transport = transport
        options.sessionStorage = MemorySessionStorage()
        let server = try EspobaseClient(url: projectURL, key: secretKey, options: options)
        await expectError("secret_key") { try await server.auth.signInWithPassword(email: "a@b.co", password: "pw") }
        XCTAssertTrue(transport.requests.isEmpty)
        let (c, _) = try makeClient { _ in (200, jsonBody(["user": sessionJSON()["user"]!]), [:]) }
        await expectError("no_session", status: 401) { try await c.auth.updateUser(password: "new-password-1") }
    }
}

final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    func increment() { lock.lock(); n += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return n }
}
