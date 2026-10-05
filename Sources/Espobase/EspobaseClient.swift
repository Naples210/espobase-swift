import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(Security) && !os(watchOS)
import Security
#endif

/// Options for `EspobaseClient`. Every field has a default.
public struct ClientOptions: Sendable {
    /// Where the session is kept. Default: the Keychain on Apple platforms, memory elsewhere.
    public var sessionStorage: SessionStorage?
    /// Refresh the access token shortly before it expires (default: true).
    public var autoRefreshToken = true
    /// Extra headers on every request (never put keys here).
    public var headers: [String: String] = [:]
    /// Another way to reach the network (default: `URLSession.shared`).
    public var transport: HTTPTransport?
    /// Allow a secret key (`eb_sk_…`): only for trusted servers, never in an app.
    public var serverSide = false
    var now: @Sendable () -> Date = { Date() }

    public init() {}
}

/// The Espobase client: your project's database (`from`, `rpc`), App Authentication (`auth`), Storage (`storage`) and
/// edge functions (`functions`).
///
///     let client = try EspobaseClient(url: URL(string: "https://api.espobase.com/project/<ref>")!, key: "eb_pk_…")
public final class EspobaseClient: Sendable {
    public let auth: AuthClient
    public let storage: StorageClient
    public let functions: FunctionsClient
    private let http: Http

    /// - Parameters:
    ///   - url: your project's URL (the API page shows it; `/rest/v1` at the end is accepted).
    ///   - key: the project's PUBLISHABLE key (`eb_pk_…`). Secret keys only on trusted servers (`options.serverSide`).
    public init(url: URL, key: String, options: ClientOptions = ClientOptions()) throws {
        guard let scheme = url.scheme, scheme == "https" || scheme == "http", url.host != nil else {
            throw EspobaseError.client("invalid_url", "The project URL must be an absolute http(s) URL.")
        }
        guard key.range(of: "^eb_(pk|sk)_[0-9A-Za-z]{43}$", options: .regularExpression) != nil else {
            throw EspobaseError.client(
                "invalid_key", "That doesn't look like an Espobase API key (eb_pk_… or eb_sk_…).")
        }
        let secret = key.hasPrefix("eb_sk_")
        if secret && !options.serverSide {
            throw EspobaseError.client(
                "secret_key",
                "Espobase secret keys bypass row level security and must never be used in an app. Use the publishable key.")
        }
        var base = url.absoluteString
        if var components = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            components.query = nil
            components.fragment = nil
            base = components.string ?? base
        }
        while base.hasSuffix("/") { base.removeLast() }
        if base.hasSuffix("/rest/v1") { base.removeLast("/rest/v1".count) }
        let http = Http(
            base: base, key: key, transport: options.transport ?? URLSessionTransport(session: .shared),
            headers: options.headers)
        self.http = http
        let auth = AuthClient(
            http: http, storage: options.sessionStorage ?? EspobaseClient.defaultStorage(), secretKey: secret,
            autoRefresh: options.autoRefreshToken, now: options.now)
        self.auth = auth
        self.storage = StorageClient(http: http, auth: auth)
        self.functions = FunctionsClient(http: http, auth: auth)
    }

    static func defaultStorage() -> SessionStorage {
        #if canImport(Security) && !os(watchOS)
        return KeychainSessionStorage()
        #else
        return MemorySessionStorage()
        #endif
    }

    /// A query on a table or view.
    public func from(_ table: String) throws -> QueryBuilder {
        guard !table.isEmpty else { throw EspobaseError.client("invalid_table", "from(): a table name is required.") }
        return QueryBuilder(http: http, auth: auth, table: table)
    }

    /// Calls a database function in your project (`POST /rest/v1/rpc/<fn>`), as the signed-in user, so row level security
    /// applies.
    public func rpc<T: Decodable>(_ function: String, params: some Encodable = EmptyBody()) async throws -> T {
        guard function.range(of: "^[A-Za-z_][A-Za-z0-9_]{0,62}$", options: .regularExpression) != nil else {
            throw EspobaseError.client("invalid_function", "rpc(): a function name is required.")
        }
        return try await http.json(
            "/rest/v1/rpc/\(function)", method: "POST", body: params, token: try await auth.accessToken())
    }
}

#if canImport(Security) && !os(watchOS)
/// Keeps the session in the Keychain (this device only, after the first unlock).
public struct KeychainSessionStorage: SessionStorage {
    private let service: String

    public init(service: String = "com.espobase.client") { self.service = service }

    private func query(_ key: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: key]
    }

    public func get(_ key: String) async -> String? {
        var q = query(key)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public func set(_ key: String, value: String) async {
        let data = Data(value.utf8)
        let update = SecItemUpdate(query(key) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if update == errSecItemNotFound {
            var add = query(key)
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            SecItemAdd(add as CFDictionary, nil)
        }
    }

    public func remove(_ key: String) async { SecItemDelete(query(key) as CFDictionary) }
}
#endif
