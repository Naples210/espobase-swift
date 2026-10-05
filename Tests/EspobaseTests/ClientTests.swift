import XCTest

@testable import Espobase

final class ClientTests: XCTestCase {
    func testCreatesAClientAndRefusesBadInput() async throws {
        let ok = try EspobaseClient(url: projectURL, key: publishableKey)
        XCTAssertNotNil(ok)
        // The URL may end in /rest/v1; a query or trailing slash is dropped.
        for text in [
            "https://api.espobase.test/project/abcde12345/rest/v1/", "https://api.espobase.test/project/abcde12345/",
            "https://api.espobase.test/project/abcde12345?x=1",
        ] {
            let transport = MockTransport { _ in (200, jsonBody([]), [:]) }
            var options = ClientOptions()
            options.transport = transport
            options.sessionStorage = MemorySessionStorage()
            let client = try EspobaseClient(url: URL(string: text)!, key: publishableKey, options: options)
            let _: [Int] = try await client.from("t").execute()
            XCTAssertEqual(transport.requests[0].url.absoluteString, "https://api.espobase.test/project/abcde12345/rest/v1/t")
        }
        XCTAssertThrowsError(try EspobaseClient(url: URL(string: "ftp://x.test")!, key: publishableKey)) {
            XCTAssertEqual(($0 as? EspobaseError)?.code, "invalid_url")
        }
        XCTAssertThrowsError(try EspobaseClient(url: projectURL, key: "not-a-key")) {
            XCTAssertEqual(($0 as? EspobaseError)?.code, "invalid_key")
        }
        // A secret key never goes into an app unless the client is explicitly a server-side one.
        XCTAssertThrowsError(try EspobaseClient(url: projectURL, key: secretKey)) {
            XCTAssertEqual(($0 as? EspobaseError)?.code, "secret_key")
        }
        var options = ClientOptions()
        options.serverSide = true
        XCTAssertNoThrow(try EspobaseClient(url: projectURL, key: secretKey, options: options))
    }

    func testSendsTheKeyAndClientInfoAndNormalizesErrors() async throws {
        let (client, transport) = try makeClient(options: { $0.headers = ["x-extra": "1"] }) { seen in
            if seen.path.hasSuffix("/missing") {
                return (404, jsonBody(["code": "PGRST205", "message": "no table", "hint": "check the name"]), [:])
            }
            return (200, jsonBody([["id": 1]]), [:])
        }
        let rows: [[String: Int]] = try await client.from("orders").select().execute()
        XCTAssertEqual(rows, [["id": 1]])
        let seen = transport.requests[0]
        XCTAssertEqual(seen.url.absoluteString, "https://api.espobase.test/project/abcde12345/rest/v1/orders?select=*")
        XCTAssertEqual(seen.headers["apikey"], publishableKey)
        XCTAssertEqual(seen.headers["x-client-info"], "espobase-swift/\(sdkVersion)")
        XCTAssertEqual(seen.headers["x-extra"], "1")
        XCTAssertNil(seen.headers["authorization"], "anonymous until signed in")
        do {
            let _: [[String: Int]] = try await client.from("missing").execute()
            XCTFail("expected an error")
        } catch let error as EspobaseError {
            XCTAssertEqual(error.status, 404)
            XCTAssertEqual(error.code, "PGRST205")
            XCTAssertEqual(error.hint, "check the name")
        }
    }

    func testNetworkFailuresBecomeErrors() async throws {
        struct Down: HTTPTransport {
            func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) { throw URLError(.notConnectedToInternet) }
        }
        var options = ClientOptions()
        options.transport = Down()
        options.sessionStorage = MemorySessionStorage()
        let client = try EspobaseClient(url: projectURL, key: publishableKey, options: options)
        await expectError("network_error", status: 0) { let _: [Int] = try await client.from("t").execute(); return 0 }
    }

    func testRpcCallsTheFunctionWithTheUsersTokenAndValidatesTheName() async throws {
        let (client, transport) = try makeClient { seen in
            seen.path.hasSuffix("/auth/v1/token") ? (200, jsonBody(sessionJSON()), [:]) : (200, jsonBody([["id": 7]]), [:])
        }
        _ = try await client.auth.signInWithPassword(email: "a@b.co", password: "pw")
        struct Args: Encodable { let match_count: Int }
        let rows: [[String: Int]] = try await client.rpc("match_documents", params: Args(match_count: 5))
        XCTAssertEqual(rows, [["id": 7]])
        let call = transport.requests.last!
        XCTAssertEqual(call.path, "/project/abcde12345/rest/v1/rpc/match_documents")
        XCTAssertEqual(call.method, "POST")
        XCTAssertEqual(call.headers["authorization"], "Bearer at1")
        XCTAssertEqual(call.json?["match_count"] as? Int, 5)
        await expectError("invalid_function") { let _: [Int] = try await client.rpc("bad name!"); return 0 }
    }
}
