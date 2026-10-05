import Foundation
import XCTest

@testable import Espobase

let projectURL = URL(string: "https://api.espobase.test/project/abcde12345")!
let publishableKey = "eb_pk_" + String(repeating: "a", count: 43)
let secretKey = "eb_sk_" + String(repeating: "b", count: 43)

/// A request as the transport saw it.
struct Seen: Sendable {
    let method: String
    let url: URL
    let headers: [String: String]
    let body: Data?

    var path: String { url.path }
    var query: [String: String] {
        Dictionary(
            uniqueKeysWithValues: (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []).map {
                ($0.name, $0.value ?? "")
            })
    }
    var json: [String: Any]? { body.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } }
}

/// Answers requests from a script (`route` returns status and body for a request) and remembers them.
final class MockTransport: HTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [Seen] = []
    private let route: @Sendable (Seen) -> (Int, Data, [String: String])

    init(route: @escaping @Sendable (Seen) -> (Int, Data, [String: String])) { self.route = route }

    var requests: [Seen] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let seen = Seen(
            method: request.httpMethod ?? "GET", url: request.url!,
            // URLRequest canonicalizes some header names (Authorization, Content-Type): compare in lowercase.
            headers: Dictionary(
                uniqueKeysWithValues: (request.allHTTPHeaderFields ?? [:]).map { ($0.key.lowercased(), $0.value) }),
            body: request.httpBody)
        lock.lock()
        recorded.append(seen)
        lock.unlock()
        let (status, body, headers) = route(seen)
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
        return (body, response)
    }
}

func jsonBody(_ object: Any) -> Data { try! JSONSerialization.data(withJSONObject: object) }

func sessionJSON(_ n: Int = 1, expiresIn: Int = 900, now: Date = Date(), userId: String = "u1") -> [String: Any] {
    [
        "access_token": "at\(n)", "refresh_token": "rt\(n)", "token_type": "bearer", "expires_in": expiresIn,
        "expires_at": Int(now.timeIntervalSince1970) + expiresIn,
        "user": [
            "id": userId, "email": "a@b.co", "emailVerified": true, "appRole": "authenticated", "provider": "email",
            "providers": ["email"], "createdAt": "2026-10-01T00:00:00Z", "lastSignInAt": NSNull(),
        ] as [String: Any],
    ]
}

func makeClient(
    options: (inout ClientOptions) -> Void = { _ in }, key: String = publishableKey,
    route: @escaping @Sendable (Seen) -> (Int, Data, [String: String])
) throws -> (EspobaseClient, MockTransport) {
    let transport = MockTransport(route: route)
    var o = ClientOptions()
    o.transport = transport
    o.sessionStorage = MemorySessionStorage()
    options(&o)
    return (try EspobaseClient(url: projectURL, key: key, options: o), transport)
}

func expectError<T>(
    _ code: String, status: Int? = nil, file: StaticString = #filePath, line: UInt = #line,
    _ body: () async throws -> T
) async {
    do {
        _ = try await body()
        XCTFail("expected an error with code \(code)", file: file, line: line)
    } catch let error as EspobaseError {
        XCTAssertEqual(error.code, code, "\(error)", file: file, line: line)
        if let status { XCTAssertEqual(error.status, status, file: file, line: line) }
    } catch {
        XCTFail("unexpected error \(error)", file: file, line: line)
    }
}
