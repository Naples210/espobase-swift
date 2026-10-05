import Foundation

/// A value a filter can compare a column with.
public protocol FilterValue {
    /// The value as PostgREST writes it after the operator.
    var postgrestText: String { get }
    /// The value inside an `in (...)` list: numbers as they are, everything else double-quoted.
    var postgrestListText: String { get }
}

private func quoted(_ text: String) -> String {
    "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
}

extension String: FilterValue {
    public var postgrestText: String { self }
    public var postgrestListText: String { quoted(self) }
}
extension Int: FilterValue {
    public var postgrestText: String { String(self) }
    public var postgrestListText: String { String(self) }
}
extension Int64: FilterValue {
    public var postgrestText: String { String(self) }
    public var postgrestListText: String { String(self) }
}
extension Double: FilterValue {
    public var postgrestText: String { String(self) }
    public var postgrestListText: String { String(self) }
}
extension Bool: FilterValue {
    public var postgrestText: String { self ? "true" : "false" }
    public var postgrestListText: String { quoted(postgrestText) }
}
extension UUID: FilterValue {
    public var postgrestText: String { uuidString.lowercased() }
    public var postgrestListText: String { quoted(postgrestText) }
}
extension Date: FilterValue {
    public var postgrestText: String { ISO8601DateFormatter().string(from: self) }
    public var postgrestListText: String { quoted(postgrestText) }
}

/// A query on one table or view of the project's REST API. Nothing is sent until `execute()` / `run()` /
/// `single()`:
///
///     let open: [Order] = try await client.from("orders").select("id,total").eq("status", "open").order("id").limit(10).execute()
///
/// `update()` and `delete()` refuse to run without at least one filter, so a missing `.eq()` can't change every row by
/// accident (row level security still decides which rows a request may touch).
public struct QueryBuilder: Sendable {
    private enum Method: String { case get = "GET", post = "POST", patch = "PATCH", delete = "DELETE" }

    private let http: Http
    private let auth: AuthClient
    private let table: String
    private var method: Method = .get
    private var body: Data?
    private var params: [URLQueryItem] = []
    private var filters = 0
    private var returnRows = false
    private var invalid: String?

    init(http: Http, auth: AuthClient, table: String) {
        self.http = http
        self.auth = auth
        self.table = table
    }

    private func copy(_ change: (inout QueryBuilder) -> Void) -> QueryBuilder {
        var next = self
        change(&next)
        return next
    }

    /// Columns to return (PostgREST select syntax, e.g. `"id,name,orders(total)"`). On writes: return the rows.
    public func select(_ columns: String = "*") -> QueryBuilder {
        copy {
            $0.params.append(URLQueryItem(name: "select", value: columns))
            if $0.method != .get { $0.returnRows = true }
        }
    }

    /// The rows' values are encoded here, so a value that can't be encoded fails the query before anything is sent.
    private func encoded(_ values: some Encodable, _ method: Method) -> QueryBuilder {
        copy {
            $0.method = method
            do { $0.body = try JSONEncoder().encode(values) } catch {
                $0.invalid = "The values can't be encoded as JSON: \(error.localizedDescription)"
            }
        }
    }

    public func insert(_ values: some Encodable) -> QueryBuilder { encoded(values, .post) }

    public func update(_ values: some Encodable) -> QueryBuilder { encoded(values, .patch) }

    public func delete() -> QueryBuilder { copy { $0.method = .delete } }

    private func column(_ name: String) -> String? {
        name.isEmpty || name.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7f }) ? nil : name
    }

    private func filter(_ name: String, _ op: String, _ value: String) -> QueryBuilder {
        copy {
            guard let column = $0.column(name) else {
                $0.invalid = "Invalid column name."
                return
            }
            $0.params.append(URLQueryItem(name: column, value: "\(op).\(value)"))
            $0.filters += 1
        }
    }

    public func eq(_ column: String, _ value: some FilterValue) -> QueryBuilder { filter(column, "eq", value.postgrestText) }
    public func neq(_ column: String, _ value: some FilterValue) -> QueryBuilder { filter(column, "neq", value.postgrestText) }
    public func gt(_ column: String, _ value: some FilterValue) -> QueryBuilder { filter(column, "gt", value.postgrestText) }
    public func gte(_ column: String, _ value: some FilterValue) -> QueryBuilder { filter(column, "gte", value.postgrestText) }
    public func lt(_ column: String, _ value: some FilterValue) -> QueryBuilder { filter(column, "lt", value.postgrestText) }
    public func lte(_ column: String, _ value: some FilterValue) -> QueryBuilder { filter(column, "lte", value.postgrestText) }
    public func like(_ column: String, _ pattern: String) -> QueryBuilder { filter(column, "like", pattern) }
    public func ilike(_ column: String, _ pattern: String) -> QueryBuilder { filter(column, "ilike", pattern) }

    public func `in`(_ column: String, _ values: [some FilterValue]) -> QueryBuilder {
        filter(column, "in", "(" + values.map(\.postgrestListText).joined(separator: ",") + ")")
    }

    /// `isNull(col)` matches NULL; `is(col, true)` / `is(col, false)` match booleans.
    public func isNull(_ column: String) -> QueryBuilder { filter(column, "is", "null") }
    public func `is`(_ column: String, _ value: Bool) -> QueryBuilder { filter(column, "is", value ? "true" : "false") }

    public func order(_ column: String, ascending: Bool = true, nullsFirst: Bool? = nil) -> QueryBuilder {
        copy {
            guard let name = $0.column(column) else {
                $0.invalid = "Invalid column name."
                return
            }
            var value = "\(name).\(ascending ? "asc" : "desc")"
            if let nullsFirst { value += nullsFirst ? ".nullsfirst" : ".nullslast" }
            $0.params.append(URLQueryItem(name: "order", value: value))
        }
    }

    public func limit(_ count: Int) -> QueryBuilder {
        copy {
            if count < 0 { $0.invalid = "limit must be a non-negative integer." } else {
                $0.params.append(URLQueryItem(name: "limit", value: String(count)))
            }
        }
    }

    /// Rows `from` to `to`, inclusive and zero-based.
    public func range(from: Int, to: Int) -> QueryBuilder {
        copy {
            if from < 0 || to < from { $0.invalid = "range needs 0 ≤ from ≤ to." } else {
                $0.params.append(URLQueryItem(name: "offset", value: String(from)))
                $0.params.append(URLQueryItem(name: "limit", value: String(to - from + 1)))
            }
        }
    }

    private func send(single: Bool) async throws -> HTTPResult {
        if let invalid { throw EspobaseError.client("invalid_query", invalid) }
        if (method == .patch || method == .delete) && filters == 0 {
            throw EspobaseError.client(
                "filter_required",
                "Add a filter (for example .eq(\"id\", 1)) before \(method == .patch ? "update" : "delete")().")
        }
        var headers: [String: String] = [:]
        if method != .get { headers["prefer"] = returnRows ? "return=representation" : "return=minimal" }
        if single { headers["accept"] = "application/vnd.pgrst.object+json" }
        return try await http.send(
            "/rest/v1/\(table.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? table)",
            query: params, method: method.rawValue, body: body, token: try await auth.accessToken(), headers: headers)
    }

    /// Runs the query and decodes the rows (`[Row]`).
    public func execute<T: Decodable>(_ type: T.Type = T.self) async throws -> T {
        let result = try await send(single: false)
        return try Http.decode(type, from: result.data)
    }

    /// Exactly one row: an error if there are zero or several.
    public func single<T: Decodable>(_ type: T.Type = T.self) async throws -> T {
        let result = try await send(single: true)
        return try Http.decode(type, from: result.data)
    }

    /// Runs a write (insert / update / delete) when you don't need the rows back.
    public func run() async throws {
        _ = try await send(single: false)
    }
}
