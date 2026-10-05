import XCTest

@testable import Espobase

final class QueryTests: XCTestCase {
    private func client(_ answer: @escaping @Sendable (Seen) -> (Int, Data, [String: String]) = { _ in (200, jsonBody([]), [:]) })
        throws -> (EspobaseClient, MockTransport)
    {
        try makeClient(route: answer)
    }

    func testFiltersOrderingAndRangeBecomePostgrestParameters() async throws {
        let (c, t) = try client()
        let _: [[String: Int]] = try await c.from("orders")
            .select("id,total")
            .eq("status", "open")
            .neq("kind", "gift")
            .gt("total", 10)
            .gte("score", 1.5)
            .lt("n", 3)
            .lte("m", 4)
            .like("name", "a*")
            .ilike("email", "%@x.com")
            .in("id", [1, 2, 3])
            .in("tag", ["a,b", "say \"hi\""])
            .isNull("deleted_at")
            .is("active", true)
            .order("created_at", ascending: false, nullsFirst: false)
            .range(from: 10, to: 19)
            .execute()
        let items = URLComponents(url: t.requests[0].url, resolvingAgainstBaseURL: false)!.queryItems!.map { "\($0.name)=\($0.value ?? "")" }
        XCTAssertEqual(
            items,
            [
                "select=id,total", "status=eq.open", "kind=neq.gift", "total=gt.10", "score=gte.1.5", "n=lt.3", "m=lte.4",
                "name=like.a*", "email=ilike.%@x.com", "id=in.(1,2,3)", #"tag=in.("a,b","say \"hi\"")"#,
                "deleted_at=is.null", "active=is.true", "order=created_at.desc.nullslast", "offset=10", "limit=10",
            ])
    }

    func testInsertSendsJSONAndAsksForNoRowsUnlessSelected() async throws {
        let (c, t) = try client { _ in (201, Data(), [:]) }
        struct Todo: Encodable { let title: String }
        try await c.from("todos").insert(Todo(title: "Buy milk")).run()
        let minimal = t.requests[0]
        XCTAssertEqual(minimal.method, "POST")
        XCTAssertEqual(minimal.headers["prefer"], "return=minimal")
        XCTAssertEqual(minimal.json?["title"] as? String, "Buy milk")
        let (c2, t2) = try client { _ in (201, jsonBody([["id": 1, "title": "x"]]), [:]) }
        struct Row: Decodable, Equatable { let id: Int; let title: String }
        let rows: [Row] = try await c2.from("todos").insert([Todo(title: "x")]).select().execute()
        XCTAssertEqual(rows, [Row(id: 1, title: "x")])
        XCTAssertEqual(t2.requests[0].headers["prefer"], "return=representation")
        XCTAssertEqual(t2.requests[0].headers["content-type"], "application/json")
    }

    func testUpdateAndDeleteNeedAFilter() async throws {
        let (c, t) = try client { _ in (204, Data(), [:]) }
        struct Patch: Encodable { let done: Bool }
        await expectError("filter_required") { try await c.from("todos").update(Patch(done: true)).run() }
        await expectError("filter_required") { try await c.from("todos").delete().run() }
        XCTAssertTrue(t.requests.isEmpty, "nothing is sent without a filter")
        try await c.from("todos").update(Patch(done: true)).eq("id", 5).run()
        try await c.from("todos").delete().eq("id", 5).run()
        XCTAssertEqual(t.requests.map(\.method), ["PATCH", "DELETE"])
        XCTAssertEqual(t.requests[0].query["id"], "eq.5")
    }

    func testSingleAsksForOneObjectAndBadInputIsRefusedBeforeSending() async throws {
        let (c, t) = try client { _ in (200, jsonBody(["id": 3]), [:]) }
        struct Row: Decodable, Equatable { let id: Int }
        let row: Row = try await c.from("todos").select().eq("id", 3).single()
        XCTAssertEqual(row, Row(id: 3))
        XCTAssertEqual(t.requests[0].headers["accept"], "application/vnd.pgrst.object+json")
        await expectError("invalid_query") { let _: [Row] = try await c.from("todos").eq("bad\ncolumn", 1).execute(); return 0 }
        await expectError("invalid_query") { let _: [Row] = try await c.from("todos").limit(-1).execute(); return 0 }
        await expectError("invalid_query") { let _: [Row] = try await c.from("todos").range(from: 5, to: 2).execute(); return 0 }
        XCTAssertEqual(t.requests.count, 1)
        XCTAssertThrowsError(try c.from("")) { XCTAssertEqual(($0 as? EspobaseError)?.code, "invalid_table") }
    }

    func testTableNamesAreEncodedAndTheBuilderIsImmutable() async throws {
        let (c, t) = try client()
        let base = try c.from("my table").select()
        let filtered = base.eq("id", 1)
        let _: [Int] = try await base.execute()
        let _: [Int] = try await filtered.execute()
        XCTAssertEqual(t.requests[0].url.absoluteString.contains("/rest/v1/my%20table?select=*"), true)
        XCTAssertNil(t.requests[0].query["id"], "a filter added later doesn't change the earlier query")
        XCTAssertEqual(t.requests[1].query["id"], "eq.1")
    }
}
