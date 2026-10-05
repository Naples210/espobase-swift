import XCTest

@testable import Espobase

final class StorageFunctionsTests: XCTestCase {
    func testUploadSendsTheBytesWithTheContentTypeAndUpsert() async throws {
        let result: [String: Any] = ["id": "o1", "bucket": "avatars", "path": "me/pic 1.png", "size": 3, "sha256": String(repeating: "a", count: 64)]
        let (c, t) = try makeClient { _ in (200, jsonBody(result), [:]) }
        let uploaded = try await c.storage.from("avatars").upload(
            path: "me/pic 1.png", data: Data([1, 2, 3]), contentType: "image/png", upsert: true)
        XCTAssertEqual(uploaded.size, 3)
        let seen = t.requests[0]
        XCTAssertEqual(seen.method, "POST")
        XCTAssertEqual(seen.url.absoluteString, "https://api.espobase.test/project/abcde12345/storage/v1/object/avatars/me/pic%201.png")
        XCTAssertEqual(seen.headers["content-type"], "image/png")
        XCTAssertEqual(seen.headers["x-upsert"], "true")
        XCTAssertEqual(seen.body, Data([1, 2, 3]))
    }

    func testDownloadListRemoveAndBucketNames() async throws {
        let (c, t) = try makeClient { seen in
            if seen.path.contains("/object/list/") { return (200, jsonBody([]), [:]) }
            if seen.method == "DELETE" { return (200, jsonBody([]), [:]) }
            return (200, Data([9, 9]), [:])
        }
        let bucket = try c.storage.from("docs")
        let bytes = try await bucket.download(path: "a/b.pdf")
        XCTAssertEqual(bytes, Data([9, 9]))
        _ = try await bucket.list(prefix: "a/", limit: 10)
        XCTAssertEqual(t.requests[1].json?["prefix"] as? String, "a/")
        XCTAssertEqual(t.requests[1].json?["limit"] as? Int, 10)
        _ = try await bucket.remove(paths: ["a/b.pdf"])
        XCTAssertEqual(t.requests[2].json?["paths"] as? [String], ["a/b.pdf"])
        await expectError("invalid_paths") { try await bucket.remove(paths: []) }
        XCTAssertThrowsError(try c.storage.from("Bad Bucket")) { XCTAssertEqual(($0 as? EspobaseError)?.code, "invalid_bucket") }
    }

    func testImageTransformsChangeTheDownloadRouteAndTheLinks() async throws {
        let (c, t) = try makeClient { seen in
            seen.path.contains("/object/sign/")
                ? (200, jsonBody(["signedUrl": "https://api.espobase.test/project/abcde12345/storage/v1/object/sign/photos/a.jpg?token=T"]), [:])
                : (200, Data([1]), [:])
        }
        let photos = try c.storage.from("photos")
        let transform = ImageTransform(width: 200, height: 100, resize: .contain, quality: 70, format: .webp)
        _ = try await photos.download(path: "a.jpg", transform: transform)
        XCTAssertEqual(t.requests[0].path, "/project/abcde12345/storage/v1/render/image/authenticated/photos/a.jpg")
        XCTAssertEqual(t.requests[0].query, ["width": "200", "height": "100", "resize": "contain", "quality": "70", "format": "webp"])
        let signed = try await photos.createSignedUrl(path: "a.jpg", expiresIn: 600, transform: ImageTransform(width: 64))
        XCTAssertEqual(signed.path, "/project/abcde12345/storage/v1/render/image/sign/photos/a.jpg")
        XCTAssertEqual(URLComponents(url: signed, resolvingAgainstBaseURL: false)?.queryItems?.map(\.name), ["token", "width"])
        let publicURL = try photos.publicUrl(path: "a b.jpg")
        XCTAssertEqual(publicURL.absoluteString, "https://api.espobase.test/project/abcde12345/storage/v1/object/public/photos/a%20b.jpg")
        XCTAssertEqual(try photos.publicUrl(path: "a.jpg", transform: ImageTransform(width: 50)).path, "/project/abcde12345/storage/v1/render/image/public/photos/a.jpg")
        XCTAssertEqual(t.requests.count, 2, "building a public URL makes no request")
    }

    func testFunctionsSendJSONAndReturnTheAnswer() async throws {
        let (c, t) = try makeClient { seen in
            seen.path.hasSuffix("/boom")
                ? (500, jsonBody(["error": "function_error", "message": "it broke"]), [:])
                : (200, jsonBody(["message": "Hello"]), ["Content-Type": "application/json"])
        }
        struct Input: Encodable { let name: String }
        struct Output: Decodable, Equatable { let message: String }
        let response = try await c.functions.invoke("hello", body: Input(name: "Ada"), query: ["x": "1"])
        XCTAssertEqual(try response.decode(Output.self), Output(message: "Hello"))
        XCTAssertEqual(response.contentType, "application/json")
        let seen = t.requests[0]
        XCTAssertEqual(seen.path, "/project/abcde12345/functions/v1/hello")
        XCTAssertEqual(seen.query, ["x": "1"])
        XCTAssertEqual(seen.json?["name"] as? String, "Ada")
        await expectError("function_error", status: 500) { try await c.functions.invoke("boom") }
        await expectError("invalid_function") { try await c.functions.invoke("Bad Name") }
        let raw = try await c.functions.invoke("hello", data: Data("hi".utf8), contentType: "text/plain")
        XCTAssertEqual(t.requests.last?.headers["content-type"], "text/plain")
        XCTAssertFalse(raw.text.isEmpty)
    }
}
