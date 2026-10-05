import Foundation

private func encodePath(_ path: String) -> String {
    path.split(separator: "/", omittingEmptySubsequences: false)
        .map { $0.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-._~"))) ?? String($0) }
        .joined(separator: "/")
}

/// Espobase Storage. Requests carry the project key and, when a user is signed in, their access token, so the project's
/// storage policies decide what each user may do.
public struct StorageClient: Sendable {
    let http: Http
    let auth: AuthClient

    /// Files in one bucket (lowercase letters, digits, `-` and `_`).
    public func from(_ bucket: String) throws -> BucketClient {
        guard bucket.range(of: "^[a-z0-9][a-z0-9_-]{1,62}$", options: .regularExpression) != nil else {
            throw EspobaseError.client(
                "invalid_bucket", "storage.from(): a bucket name (lowercase letters, digits, - and _) is required.")
        }
        return BucketClient(http: http, auth: auth, bucket: bucket)
    }
}

public struct BucketClient: Sendable {
    let http: Http
    let auth: AuthClient
    public let bucket: String

    private func url(_ rest: String) -> String { "/storage/v1" + rest }

    /// Uploads a file to `path` (e.g. `"avatars/me.png"`). Fails with 409 if it exists, unless `upsert` is true.
    public func upload(
        path: String, data: Data, contentType: String = "application/octet-stream", upsert: Bool = false
    ) async throws -> StorageUploadResult {
        let result = try await http.send(
            url("/object/\(bucket)/\(encodePath(path))"), method: "POST", body: data, contentType: contentType,
            token: try await auth.accessToken(), headers: upsert ? ["x-upsert": "true"] : [:])
        return try Http.decode(StorageUploadResult.self, from: result.data)
    }

    /// Downloads a file the caller may read. With `transform`, an image comes back resized (Pro and Group).
    public func download(path: String, transform: ImageTransform? = nil) async throws -> Data {
        let items = transform?.queryItems ?? []
        let route =
            items.isEmpty
            ? url("/object/\(bucket)/\(encodePath(path))")
            : url("/render/image/authenticated/\(bucket)/\(encodePath(path))")
        return try await http.send(route, query: items, token: try await auth.accessToken()).data
    }

    /// Files whose path starts with `prefix` (default: all), by name.
    public func list(prefix: String = "", limit: Int? = nil, offset: Int? = nil) async throws -> [StorageFile] {
        struct Body: Encodable {
            let prefix: String
            let limit: Int?
            let offset: Int?
        }
        return try await http.json(
            url("/object/list/\(bucket)"), method: "POST", body: Body(prefix: prefix, limit: limit, offset: offset),
            token: try await auth.accessToken())
    }

    /// Deletes files (up to 100). Returns what was actually removed.
    @discardableResult
    public func remove(paths: [String]) async throws -> [StorageFile] {
        guard !paths.isEmpty else { throw EspobaseError.client("invalid_paths", "remove(): list at least one path.") }
        return try await http.json(
            url("/object/\(bucket)"), method: "DELETE", body: ["paths": paths], token: try await auth.accessToken())
    }

    /// A link anyone can use to download the file for `expiresIn` seconds (max 7 days). With `transform`, the link serves
    /// a resized image.
    public func createSignedUrl(path: String, expiresIn: Int, transform: ImageTransform? = nil) async throws -> URL {
        struct Wire: Decodable { let signedUrl: String }
        let wire: Wire = try await http.json(
            url("/object/sign/\(bucket)/\(encodePath(path))"), method: "POST", body: ["expiresIn": expiresIn],
            token: try await auth.accessToken())
        var text = wire.signedUrl
        let items = transform?.queryItems ?? []
        if !items.isEmpty {
            text = text.replacingOccurrences(of: "/object/sign/", with: "/render/image/sign/")
            if var parts = URLComponents(string: text) {
                let existing = parts.queryItems ?? []
                parts.queryItems = existing + items
                text = parts.string ?? text
            }
        }
        guard let url = URL(string: text) else { throw EspobaseError.client("invalid_url", "The signed URL was malformed.") }
        return url
    }

    /// The permanent URL of a file in a PUBLIC bucket (no request is made; private buckets answer 404).
    public func publicUrl(path: String, transform: ImageTransform? = nil) throws -> URL {
        let items = transform?.queryItems ?? []
        let route =
            items.isEmpty
            ? url("/object/public/\(bucket)/\(encodePath(path))")
            : url("/render/image/public/\(bucket)/\(encodePath(path))")
        return try http.url(route, query: items)
    }
}
