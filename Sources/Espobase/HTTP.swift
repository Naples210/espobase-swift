import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// How requests reach the network. The default is URLSession; tests (and apps with their own stack) can provide another.
public protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

struct URLSessionTransport: HTTPTransport {
    let session: URLSession

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw EspobaseError.client("network_error", "The server's answer wasn't HTTP.")
        }
        return (data, http)
    }
}

let sdkVersion = "0.1.0"

struct HTTPResult {
    let data: Data
    let status: Int
    let response: HTTPURLResponse
}

/// Low-level HTTP: adds the API key, the user's token when given, JSON bodies and normalized errors.
final class Http: Sendable {
    let base: String
    let key: String
    private let transport: HTTPTransport
    private let headers: [String: String]

    init(base: String, key: String, transport: HTTPTransport, headers: [String: String]) {
        self.base = base
        self.key = key
        self.transport = transport
        self.headers = headers
    }

    func url(_ path: String, query: [URLQueryItem] = []) throws -> URL {
        guard var components = URLComponents(string: base + path) else {
            throw EspobaseError.client("invalid_url", "Invalid URL: \(path)")
        }
        if !query.isEmpty { components.queryItems = (components.queryItems ?? []) + query }
        guard let url = components.url else { throw EspobaseError.client("invalid_url", "Invalid URL: \(path)") }
        return url
    }

    /// Sends a request. Non-2xx answers throw an `EspobaseError` (Espobase's `{error, message}` or PostgREST's
    /// `{code, message, details, hint}`).
    func send(
        _ path: String,
        query: [URLQueryItem] = [],
        method: String = "GET",
        body: Data? = nil,
        contentType: String? = nil,
        token: String? = nil,
        headers extra: [String: String] = [:]
    ) async throws -> HTTPResult {
        var request = URLRequest(url: try url(path, query: query))
        request.httpMethod = method
        var all: [String: String] = ["x-client-info": "espobase-swift/\(sdkVersion)"]
        all.merge(headers) { _, new in new }
        all.merge(extra) { _, new in new }
        all["apikey"] = key
        if let token { all["authorization"] = "Bearer \(token)" }
        if let body {
            all["content-type"] = contentType ?? "application/json"
            request.httpBody = body
        }
        for (name, value) in all { request.setValue(value, forHTTPHeaderField: name) }
        let data: Data
        let response: HTTPURLResponse
        do {
            (data, response) = try await transport.send(request)
        } catch let error as EspobaseError {
            throw error
        } catch {
            throw EspobaseError(status: 0, code: "network_error", message: error.localizedDescription)
        }
        guard (200..<300).contains(response.statusCode) else { throw Http.error(from: data, status: response.statusCode) }
        return HTTPResult(data: data, status: response.statusCode, response: response)
    }

    func json<T: Decodable>(
        _ path: String, query: [URLQueryItem] = [], method: String = "GET", body: (any Encodable)? = nil,
        token: String? = nil, headers: [String: String] = [:], as type: T.Type = T.self
    ) async throws -> T {
        let encoded = try body.map { try JSONEncoder().encode(AnyEncodable($0)) }
        let result = try await send(path, query: query, method: method, body: encoded, token: token, headers: headers)
        return try Http.decode(type, from: result.data)
    }

    static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw EspobaseError(
                status: 0, code: "decode_error", message: "The answer didn't match \(T.self): \(error.localizedDescription)")
        }
    }

    static func error(from data: Data, status: Int) -> EspobaseError {
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let code = (object?["error"] as? String) ?? (object?["code"] as? String) ?? "http_error"
        let message = (object?["message"] as? String) ?? HTTPURLResponse.localizedString(forStatusCode: status)
        return EspobaseError(
            status: status, code: code, message: message, details: object?["details"] as? String,
            hint: object?["hint"] as? String)
    }
}

/// Type erasure for encoding any `Encodable` request body.
struct AnyEncodable: Encodable {
    private let encodeValue: (Encoder) throws -> Void
    init(_ value: any Encodable) { encodeValue = { try value.encode(to: $0) } }
    func encode(to encoder: Encoder) throws { try encodeValue(encoder) }
}

/// "No parameters" / "no body" (encodes as `{}`).
public struct EmptyBody: Encodable, Sendable {
    public init() {}
}
