import Foundation

/// A function's answer.
public struct FunctionResponse: Sendable {
    public let data: Data
    public let status: Int
    public let contentType: String?

    /// Decodes a JSON answer.
    public func decode<T: Decodable>(_ type: T.Type = T.self) throws -> T { try Http.decode(type, from: data) }
    /// The answer as text.
    public var text: String { String(decoding: data, as: UTF8.self) }
}

/// Edge functions: calls carry the project key and, when a user is signed in, their access token, so the function
/// receives the verified user (`x-espobase-user-id`, `x-espobase-user-email`, `x-espobase-user-role`).
public struct FunctionsClient: Sendable {
    let http: Http
    let auth: AuthClient

    private func name(_ name: String) throws -> String {
        guard name.range(of: "^[a-z0-9][a-z0-9-]{0,62}$", options: .regularExpression) != nil else {
            throw EspobaseError.client(
                "invalid_function", "functions.invoke(): a function name (lowercase, digits, -) is required.")
        }
        return name
    }

    private func call(
        _ name: String, method: String, body: Data?, contentType: String?, headers: [String: String],
        query: [String: String]
    ) async throws -> FunctionResponse {
        let items = query.sorted(by: { $0.key < $1.key }).map { URLQueryItem(name: $0.key, value: $0.value) }
        let result = try await http.send(
            "/functions/v1/\(try self.name(name))", query: items, method: method, body: body, contentType: contentType,
            token: try await auth.accessToken(), headers: headers)
        return FunctionResponse(
            data: result.data, status: result.status, contentType: result.response.value(forHTTPHeaderField: "content-type"))
    }

    /// Calls the function with a JSON body (any `Encodable`) and returns its answer. Error statuses throw an
    /// `EspobaseError` (the function's own JSON `{ error, message }` is used when present).
    public func invoke(
        _ name: String, method: String = "POST", body: (some Encodable)? = nil as EmptyBody?,
        headers: [String: String] = [:], query: [String: String] = [:]
    ) async throws -> FunctionResponse {
        let encoded = try body.map { try JSONEncoder().encode($0) }
        return try await call(name, method: method, body: encoded, contentType: nil, headers: headers, query: query)
    }

    /// Calls the function with raw bytes (for example text or an image).
    public func invoke(
        _ name: String, method: String = "POST", data: Data, contentType: String, headers: [String: String] = [:],
        query: [String: String] = [:]
    ) async throws -> FunctionResponse {
        try await call(name, method: method, body: data, contentType: contentType, headers: headers, query: query)
    }
}
