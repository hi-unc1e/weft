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
        MagpieStub.state.withLock { $0 = .init(reply: reply) }
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

    @Test func boundedPaginationAndTruncation() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let timestamp = date.addingTimeInterval(-1).ISO8601Format()
        let client = client(root) { request in
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
            let offset = Int(query.first { $0.name == "offset" }!.value!)!
            return (200, Self.page(rows: (0..<200).map { _ in ["t": timestamp, "agent": "test", "ms": 1] }, total: 2001, offset: offset))
        }
        let result = try await client.requestsWithMetadata()
        #expect(result.requests.count == 2000)
        #expect(result.isTruncated)
        #expect(result.totalAvailable == 2001)
        #expect(MagpieStub.state.withLock { $0.requests.count } == 10)
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

    @Test(.enabled(if: ProcessInfo.processInfo.environment["WEFT_MAGPIE_TESTS"] == "1"))
    func liveLoopbackMetadataCoverage() async throws {
        let result = try await MagpieClient().requestsWithMetadata()
        #expect(!result.requests.isEmpty)
        #expect(result.requests.count <= 2000)
        let mapped = result.requests.filter { $0.projectPath != nil }
        let halo = mapped.filter { $0.projectPath!.lowercased().contains("halo-cam") }
        print("Magpie rows=\(result.requests.count) mapped=\(mapped.count) titled=\(result.requests.filter { $0.sessionTitle != nil }.count) HaloCam=\(halo.count) truncated=\(result.isTruncated)")
        #expect(!mapped.isEmpty)
    }
}
