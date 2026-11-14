import Foundation
import Synchronization
import Testing
@testable import WeftKit

private final class MagpieStub: URLProtocol, @unchecked Sendable {
    struct State: Sendable {
        var reply: @Sendable (URLRequest) -> (Int, Data) = { _ in (500, Data()) }
        var requests: [URLRequest] = []
    }
    static let state = Mutex(State())
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let reply = Self.state.withLock { state in
            state.requests.append(request)
            return state.reply
        }
        let (status, data) = reply(request)
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status,
                                                            httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@Suite(.serialized)
struct MagpieClientTests {
    private let date = Date(timeIntervalSince1970: 1_800_000_000)
    private func root() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("weft-magpie-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    private func write(_ value: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(value.utf8).write(to: url)
    }
    private func client(_ root: URL, reply: @escaping @Sendable (URLRequest) -> (Int, Data)) -> MagpieClient {
        MagpieStub.state.withLock { $0 = .init(reply: { request in
            if request.url!.path.hasSuffix("/usage") {
                return (200, Data(#"{"period":"7d","since":"2027-01-09T00:00:00+08:00","calls":2001,"sessionCount":0,"sessions":[]}"#.utf8))
            }
            return reply(request)
        }) }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MagpieStub.self]
        let date = date
        return MagpieClient(endpoint: URL(string: "http://127.0.0.1:3425/v1/magpie/usage/requests")!,
                            session: URLSession(configuration: config),
                            codexRoot: root.appendingPathComponent("codex"),
                            claudeRoot: root.appendingPathComponent("claude"),
                            titleIndex: root.appendingPathComponent("index.jsonl"), now: { date })
    }
    private static func page(rows: [[String: Any]], total: Int, offset: Int) -> Data {
        try! JSONSerialization.data(withJSONObject: ["rows": rows, "total": total, "offset": offset])
    }

    @Test func requestMappingPreservesRawSessionAndReadsTitles() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let id = "11111111-2222-3333-4444-555555555555"
        try write(#"{"type":"session_meta","payload":{"id":"\#(id)","cwd":"/sample/project"}}"# + "\n", to: root.appendingPathComponent("codex/2026/11/session.jsonl"))
        try write(#"{"id":"\#(id)","thread_name":"Synthetic title"}"# + "\n", to: root.appendingPathComponent("index.jsonl"))
        let recent = "2027-01-15T15:59:50.123456+08:00"
        let old = date.addingTimeInterval(-8 * 86400).ISO8601Format()
        let body = Self.page(rows: [
            ["t": recent, "agent": "codex", "session": "custom:\(id)", "ms": 12, "status": 500],
            ["t": old, "agent": "codex", "ms": 1]
        ], total: 2, offset: 0)
        let client = client(root) { _ in (200, body) }
        let batch = try await client.requestsWithMetadata()
        let row = try #require(batch.requests.first)
        #expect(batch.requests.count == 1)
        #expect(row.sessionID == "custom:\(id)")
        #expect(row.projectPath == "/sample/project")
        #expect(row.sessionTitle == "Synthetic title")
        #expect(row.milliseconds == 12)
        #expect(!batch.isTruncated)
        let request = try #require(MagpieStub.state.withLock { $0.requests.first })
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(request.httpMethod == "GET")
        #expect(URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.contains(URLQueryItem(name: "period", value: "7d")) == true)
    }

    @Test func boundedSampleIsNotUsedAsTotal() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let timestamp = date.addingTimeInterval(-1).ISO8601Format()
        let client = client(root) { request in
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
            let offset = Int(query.first { $0.name == "offset" }!.value!)!
            return (200, Self.page(rows: (0..<200).map { _ in ["t": timestamp, "agent": "test", "ms": 1] }, total: 2001, offset: offset))
        }
        let result = try await client.requestsWithMetadata()
        #expect(result.requests.count == 200)
        #expect(result.isTruncated)
        #expect(result.totalAvailable == 2001)
        #expect(MagpieStub.state.withLock { $0.requests.count } == 2)
    }

    @Test func rejectsErrorsMalformedDatesAndIgnoredOffset() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let replies: [(Int, Data)] = [
            (401, Data("private server response".utf8)),
            (200, Self.page(rows: [["t": "bad", "agent": "test", "ms": 1]], total: 1, offset: 0)),
            (200, Self.page(rows: [], total: 1, offset: 7))
        ]
        for reply in replies {
            let client = client(root) { _ in reply }
            await #expect(throws: MagpieClient.ClientError.self) { try await client.requests() }
        }
    }

    @Test func metadataCacheUpdatesAndDoesNotReadPast64KB() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("codex/a.jsonl")
        try write(#"{"type":"session_meta","payload":{"id":"one","cwd":"/sample/one"}}"# + "\n", to: file)
        try write(String(repeating: " ", count: 65536) + "\n" + #"{"sessionId":"hidden","cwd":"/sample/hidden"}"#, to: root.appendingPathComponent("claude/project/large.jsonl"))
        try write(#"{"type":"mode","sessionId":"two"}"# + "\n" + #"{"type":"attachment","sessionId":"two","cwd":"/sample/two"}"# + "\n" + #"{"type":"custom-title","sessionId":"two","customTitle":"Local title"}"#, to: root.appendingPathComponent("claude/project/a.jsonl"))
        let index = MagpieMetadataIndex(codexRoot: root.appendingPathComponent("codex"), claudeRoot: root.appendingPathComponent("claude"), titleIndex: nil)
        let first = await index.snapshot()
        #expect(first.lookup("one")?.path == "/sample/one")
        #expect(first.lookup("two")?.title == "Local title")
        #expect(first.lookup("hidden") == nil)
        let reads = await index.filesRead
        _ = await index.snapshot()
        #expect(await index.filesRead == reads)
        try write(#"{"type":"session_meta","payload":{"id":"one","cwd":"/sample/updated"}}"# + "\n", to: file)
        #expect(await index.snapshot().lookup("one")?.path == "/sample/updated")
        #expect(await index.filesRead == reads + 1)
        try FileManager.default.removeItem(at: file)
        #expect(await index.snapshot().lookup("one") == nil)
    }

    @Test func titleIndexReadsRecentTailBeyond64KB() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("index.jsonl")
        try write(String(repeating: "x", count: 4 * 1024 * 1024 + 10) + "\n" + #"{"id":"recent","thread_name":"Newest title","updated_at":"2026-11-13T00:00:00Z"}"# + "\n", to: file)
        let index = MagpieMetadataIndex(codexRoot: root.appendingPathComponent("codex"), claudeRoot: root.appendingPathComponent("claude"), titleIndex: file)
        #expect(await index.snapshot().lookup("recent")?.title == "Newest title")
    }

    @Test func completeSummaryBeyondSampleAndCalendarPeriods() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        try write(#"{"type":"session_meta","payload":{"id":"halo","cwd":"/sample/halo-cam"}}"# + "\n", to: root.appendingPathComponent("codex/session.jsonl"))
        let client = client(root) { _ in (500, Data()) }
        MagpieStub.state.withLock { $0.reply = { request in
            let period = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!.first { $0.name == "period" }!.value!
            if request.url!.path.hasSuffix("/usage") {
                let today = period == "today"
                return (200, try! JSONSerialization.data(withJSONObject: [
                    "period": period, "since": today ? "2027-01-15T00:00:00+08:00" : "2027-01-09T00:00:00+08:00",
                    "calls": today ? 100 : 9000, "sessionCount": 3,
                    "sessions": [["id": "halo", "agent": "codex", "calls": today ? 18 : 4998],
                                 ["id": "halo", "agent": "claude", "calls": 2],
                                 ["id": "unknown", "calls": 10]]
                ]))
            }
            // Same route twice is an overlapping/update duplicate; equal timestamps alone are not.
            return (200, Self.page(rows: [1, 1, 2].map {
                ["route_id": $0, "t": "2027-01-15T01:00:00+08:00", "agent": "test", "ms": 1]
            }, total: 9100, offset: 0))
        } }
        for days in [1, 7] {
            let batch = try await client.requestsWithMetadata(days: days)
            #expect(batch.period == (days == 1 ? "today" : "7d"))
            #expect(batch.since.ISO8601Format() == (days == 1 ? "2027-01-14T16:00:00Z" : "2027-01-08T16:00:00Z"))
            #expect(batch.requests.count == 2)
            #expect(batch.requests.allSatisfy { $0.projectPath == nil && $0.sessionID == nil })
            #expect(batch.totalRequests == (days == 1 ? 100 : 9000))
            #expect(batch.associatedRequests == (days == 1 ? 20 : 5000))
            #expect(batch.requestsWithoutSession == (days == 1 ? 70 : 3990))
            #expect(batch.totalSessions == 2)
            #expect(batch.summarySessionCount == 3)
            #expect(batch.sessionStats.first { $0.sessionID == "unknown" }?.projectPath == nil)
            #expect(batch.isTruncated)
        }
    }

    @Test func callsIncludeFailuresWithoutAddingErrorsAgain() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        try write(#"{"type":"session_meta","payload":{"id":"halo","cwd":"/sample/halo-cam"}}"# + "\n", to: root.appendingPathComponent("codex/session.jsonl"))
        let client = client(root) { _ in (500, Data()) }
        for statuses in [[200, 500, 502], [503]] {
            let calls = statuses.count
            let errors = statuses.filter { $0 >= 400 }.count
            let summary = try JSONSerialization.data(withJSONObject: [
                "period": "7d", "since": "2027-01-09T00:00:00+08:00",
                "calls": calls, "errors": errors, "sessionCount": 1,
                "sessions": [["id": "halo", "agent": "codex", "calls": calls, "errors": errors]]
            ])
            let page = Self.page(rows: statuses.enumerated().map { i, status in
                ["route_id": i, "t": "2027-01-15T01:00:00+08:00", "agent": "codex",
                 "session": "halo", "ms": 1, "status": status]
            }, total: calls, offset: 0)
            MagpieStub.state.withLock { $0.reply = { request in
                (200, request.url!.path.hasSuffix("/usage") ? summary : page)
            } }
            let batch = try await client.requestsWithMetadata()
            #expect(batch.totalRequests == calls)
            #expect(batch.sessionStats.first?.count == calls)
            #expect(batch.associatedRequests == calls)
            #expect(batch.requests.count == calls)
            #expect(batch.requestsWithoutSession == 0)
        }
    }

    @Test func rejectsIncompleteOrDuplicateSummary() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let client = client(root) { _ in (500, Data()) }
        for sessions in ["[]", #"[{"id":"a","calls":1},{"id":"a","calls":1}]"#,
                         #"[{"id":"a","calls":9},{"id":"b","calls":9}]"#] {
            let body = Data("{\"period\":\"7d\",\"since\":\"2027-01-09T00:00:00+08:00\",\"calls\":10,\"sessionCount\":2,\"sessions\":\(sessions)}".utf8)
            MagpieStub.state.withLock { $0.reply = { _ in (200, body) } }
            await #expect(throws: MagpieClient.ClientError.self) { try await client.requestsWithMetadata() }
        }
    }

    @Test func summaryURLHasNoTrailingSlashAndErrorsAreReadable() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let client = client(root) { _ in (500, Data()) }
        MagpieStub.state.withLock { $0.reply = { request in
            switch request.url!.absoluteString {
            case "http://127.0.0.1:3425/v1/magpie/usage?period=7d":
                return (200, Data(#"{"period":"7d","since":"2027-01-09T00:00:00+08:00","calls":0,"sessionCount":0,"sessions":[]}"#.utf8))
            case "http://127.0.0.1:3425/v1/magpie/usage/requests?period=7d&limit=200&offset=0":
                return (200, Self.page(rows: [], total: 0, offset: 0))
            default: return (404, Data())
            }
        } }
        #expect(try await client.requestsWithMetadata().totalRequests == 0)
        #expect(MagpieClient.ClientError.httpStatus(404).localizedDescription == "Magpie 请求失败（HTTP 404）。")
        #expect(MagpieClient.ClientError.invalidResponse.localizedDescription.contains("统计不完整"))
        #expect(MagpieClient.ClientError.invalidPagination.localizedDescription.contains("分页"))
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["WEFT_MAGPIE_TESTS"] == "1"))
    func liveDefaultClientUsesRealSummaryEndpoint() async throws {
        // No URLProtocol stub: exercise production URL construction, transport and NoRedirects.
        let client = MagpieClient()
        for days in [1, 7] {
            let batch = try await client.requestsWithMetadata(days: days)
            #expect(batch.period == (days == 1 ? "today" : "7d"))
            #expect(batch.totalRequests > 0)
            #expect(!batch.sessionStats.isEmpty)
            let halo = batch.sessionStats.filter { $0.projectPath?.lowercased().contains("halo-cam") == true }
            #expect(!halo.isEmpty)
            print("Direct MagpieClient \(batch.period): calls=\(batch.totalRequests), HaloCam sessions=\(halo.count) calls=\(halo.reduce(0) { $0 + $1.count })")
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["WEFT_MAGPIE_TESTS"] == "1"))
    func liveLoopbackMetadataCoverage() async throws {
        // Freeze the two real API responses so concurrent new traffic cannot invalidate equality.
        let home = FileManager.default.homeDirectoryForCurrentUser
        let base = URL(string: "http://127.0.0.1:3425/v1/magpie/usage")!
        for days in [1, 7] {
            let period = days == 1 ? "today" : "7d"
            let (summary, _) = try await URLSession(configuration: .ephemeral).data(from: URL(string: base.absoluteString + "?period=" + period)!)
            let (page, _) = try await URLSession(configuration: .ephemeral).data(from: URL(string: base.absoluteString + "/requests?limit=200&period=" + period)!)
            MagpieStub.state.withLock { $0 = .init(reply: { request in
                (200, request.url!.path.hasSuffix("/usage") ? summary : page)
            }) }
            let config = URLSessionConfiguration.ephemeral
            config.protocolClasses = [MagpieStub.self]
            let client = MagpieClient(endpoint: base.appendingPathComponent("requests"),
                session: URLSession(configuration: config), codexRoot: home.appendingPathComponent(".codex/sessions"),
                claudeRoot: home.appendingPathComponent(".claude/projects"),
                titleIndex: home.appendingPathComponent(".codex/session_index.jsonl"),
                tokeiDirectory: home.appendingPathComponent(".tokei/cache/scan_cache.d"))
            let batch = try await client.requestsWithMetadata(days: days)
            let raw = try #require(JSONSerialization.jsonObject(with: summary) as? [String: Any])
            let sessions = try #require(raw["sessions"] as? [[String: Any]])
            let expected = Dictionary(sessions.map { ($0["id"] as! String, $0["calls"] as! Int) }, uniquingKeysWith: +)
            #expect(batch.totalRequests == raw["calls"] as? Int)
            #expect(batch.summarySessionCount == raw["sessionCount"] as? Int)
            #expect(batch.totalSessions == expected.count)
            #expect(Dictionary(uniqueKeysWithValues: batch.sessionStats.map { ($0.sessionID, $0.count) }) == expected)
            let halo = batch.sessionStats.filter { $0.projectPath?.lowercased().contains("halo-cam") == true }
            #expect(!halo.isEmpty)
            #expect(halo.reduce(0) { $0 + $1.count } == halo.reduce(0) { $0 + expected[$1.sessionID]! })
            print("Magpie \(period): total=\(batch.totalRequests), sessions=\(batch.totalSessions), associated=\(batch.associatedRequests), noSession=\(batch.requestsWithoutSession), HaloCam sessions=\(halo.count) calls=\(halo.reduce(0) { $0 + $1.count }), sample=\(batch.requests.count)")
        }
    }
}
