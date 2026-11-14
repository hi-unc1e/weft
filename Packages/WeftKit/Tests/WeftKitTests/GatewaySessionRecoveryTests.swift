import Foundation
import Testing
@testable import WeftKit

struct GatewaySessionRecoveryTests {
    private let lower = ISO8601DateFormatter().date(from: "2026-11-01T00:00:00Z")!
    private let upper = ISO8601DateFormatter().date(from: "2026-11-02T00:00:00Z")!

    private func raw(_ id: String, time: String = "2026-11-01T01:00:00.123Z") -> [String: Any] {
        ["type": "assistant/message", "time": time,
         "data": ["message": ["source": ["replayState": ["response": ["responseId": id]]]]]]
    }

    private func row(_ id: Int = 1, response: String = "response", time: String = "2026-11-01T01:00:00Z",
                     agent: String = "dsh", status: Int = 200, session: String? = nil,
                     native: String? = nil) -> [String: Any] {
        var value: [String: Any] = ["route_id": id, "response_id": response, "t": time,
                                    "agent": agent, "status": status]
        value["session"] = session; value["native_session"] = native
        return value
    }

    private func write(_ rows: [[String: Any]], to url: URL, append: Bool = false) throws {
        var data = Data()
        for row in rows { data.append(try JSONSerialization.data(withJSONObject: row)); data.append(10) }
        if append {
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.seekToEnd(); try handle.write(contentsOf: data)
        } else { try data.write(to: url) }
    }

    private func root() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func exactJoinDuplicatesUpsertsAndKnownSessions() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let ledger = root.appendingPathComponent("usage.jsonl"), a = root.appendingPathComponent("a.jsonl")
        let b = root.appendingPathComponent("b.jsonl")
        try write([raw("response"), raw("response"), raw("older", time: "2025-01-01T00:00:00Z"),
                   ["type": "session/title", "time": "2026-11-01T02:00:00Z", "data": ["title": "Topic"]]], to: a)
        try write([raw("response")], to: b)
        var rows = [row(), row(), row(2, session: "known"), row(3, native: "known"),
                    row(4, status: 502), row(5, agent: "codex"), row(6, response: "unmatched"),
                    row(7), row(7, session: "later-known"), row(8, status: 0), row(8),
                    row(9, response: "older", session: "old-known"), row(10), row(10, status: 499),
                    row(11), ["route_id": 11], row(12, session: "was-known"), row(12)]
        rows += [row(0), row(0), row(-1, response: "fallback"), row(-1, response: "fallback")]
        try write(rows, to: ledger)
        let recovery = GatewaySessionRecovery(ledger: ledger)
        let batch = await recovery.recover(files: [
            .init(sessionID: "s", projectPath: "/p", url: a),
            .init(sessionID: "s", projectPath: "/p", url: b)
        ], since: lower, until: upper)
        #expect(batch.isComplete)
        #expect(batch.matchedRequests == 4)
        #expect(batch.sessionStats.count == 1)
        #expect(batch.sessionStats.first?.count == 4)
        #expect(batch.sessionStats.first?.title == "Topic")
    }

    @Test func conflictingSessionOrPathNeverGuessed() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let ledger = root.appendingPathComponent("usage"), a = root.appendingPathComponent("a")
        try write([raw("response"), raw("safe")], to: a)
        let b = root.appendingPathComponent("b")
        try write([raw("response")], to: b)
        try write([row(), row(2, response: "safe")], to: ledger)
        for other in [("other", "/p"), ("s", "/different")] {
            let batch = await GatewaySessionRecovery(ledger: ledger).recover(files: [
                .init(sessionID: "s", projectPath: "/p", url: a),
                .init(sessionID: other.0, projectPath: other.1, url: b)
            ], since: lower, until: upper)
            #expect(batch.isComplete)
            #expect(batch.matchedRequests == 1)
        }
    }

    @Test func boundsMissingFieldsAndGatewayTimeAuthority() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let ledger = root.appendingPathComponent("usage"), rawURL = root.appendingPathComponent("raw")
        try write([raw("response", time: "2025-01-01T00:00:00Z"), ["type": "assistant/message"],
                   raw("bad-time", time: "bad"), ["type": "user/message", "time": 123, "data": "ignored"]], to: rawURL)
        try write([row(time: "2026-11-01T00:00:00Z"), row(2, time: "2026-11-02T00:00:00Z"),
                   row(3, time: "2026-10-31T23:59:59Z"), row(4, time: "2026-11-02T07:59:59.999+08:00"),
                   row(5, time: "bad"), row(6, response: "bad-time"), [:],
                   ["route_id": 7, "agent": "dsh", "response_id": "response"]], to: ledger)
        let batch = await GatewaySessionRecovery(ledger: ledger).recover(files: [
            .init(sessionID: "s", projectPath: "/p", url: rawURL)
        ], since: lower, until: upper)
        #expect(batch.isComplete)
        #expect(batch.matchedRequests == 2)
    }

    @Test func cacheAppendUpsertTruncateAndAuthorityRemoval() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let ledger = root.appendingPathComponent("usage"), rawURL = root.appendingPathComponent("raw")
        try write([raw("response")], to: rawURL); try write([row()], to: ledger)
        let file = LocalProjectSessionFile(sessionID: "s", projectPath: "/p", url: rawURL)
        let recovery = GatewaySessionRecovery(ledger: ledger)
        #expect(await recovery.recover(files: [file], since: lower, until: upper).matchedRequests == 1)
        let initial = await recovery.bytesRead
        #expect(await recovery.recover(files: [file], since: lower, until: upper).matchedRequests == 1)
        #expect(await recovery.bytesRead == initial)
        try write([raw("new")], to: rawURL, append: true)
        try write([row(session: "now-known"), row(2, response: "new")], to: ledger, append: true)
        #expect(await recovery.recover(files: [file], since: lower, until: upper).matchedRequests == 1)
        let fileSizes = try [rawURL, ledger].reduce(0) { sum, url in
            sum + (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
        }
        #expect(await recovery.bytesRead == fileSizes)
        try write([raw("gone")], to: rawURL)
        #expect(await recovery.recover(files: [file], since: lower, until: upper).matchedRequests == 0)
        #expect(await recovery.recover(files: [], since: lower, until: upper).matchedRequests == 0)
    }

    @Test func budgetsMalformedMissingAndSymlinkFailClosed() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let ledger = root.appendingPathComponent("usage"), rawURL = root.appendingPathComponent("raw")
        try write([raw("response")], to: rawURL); try write([row()], to: ledger)
        let files = [LocalProjectSessionFile(sessionID: "s", projectPath: "/p", url: rawURL)]
        for limits in [GatewaySessionRecovery.Limits(lineBytes: 10), .init(fileBytes: 10), .init(totalBytes: 10)] {
            let batch = await GatewaySessionRecovery(ledger: ledger, limits: limits)
                .recover(files: files, since: lower, until: upper)
            #expect(!batch.isComplete); #expect(batch.matchedRequests == 0)
        }
        try Data("{broken\n".utf8).write(to: rawURL)
        #expect(await !GatewaySessionRecovery(ledger: ledger).recover(files: files, since: lower, until: upper).isComplete)
        try FileManager.default.removeItem(at: rawURL)
        #expect(await !GatewaySessionRecovery(ledger: ledger).recover(files: files, since: lower, until: upper).isComplete)
        try FileManager.default.createSymbolicLink(at: rawURL, withDestinationURL: ledger)
        #expect(await !GatewaySessionRecovery(ledger: ledger).recover(files: files, since: lower, until: upper).isComplete)
    }

    @Test func chunkBoundariesAndPartialAppend() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let ledger = root.appendingPathComponent("usage"), rawURL = root.appendingPathComponent("raw")
        var big = raw("response"); big["ignoredBody"] = String(repeating: "x", count: 150_000)
        try write([big], to: rawURL)
        let data = try JSONSerialization.data(withJSONObject: row())
        try data.prefix(data.count / 2).write(to: ledger)
        let recovery = GatewaySessionRecovery(ledger: ledger)
        let files = [LocalProjectSessionFile(sessionID: "s", projectPath: "/p", url: rawURL)]
        #expect(await !recovery.recover(files: files, since: lower, until: upper).isComplete)
        let handle = try FileHandle(forWritingTo: ledger)
        try handle.seekToEnd(); try handle.write(contentsOf: data.dropFirst(data.count / 2)); try handle.close()
        let batch = await recovery.recover(files: files, since: lower, until: upper)
        #expect(batch.isComplete); #expect(batch.matchedRequests == 1)
    }

    @Test func seededParentHistoryIsNotChildOwnership() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let ledger = root.appendingPathComponent("usage"), parent = root.appendingPathComponent("parent")
        let child = root.appendingPathComponent("child")
        try write([raw("response")], to: parent)
        var owned = raw("child")
        owned["time"] = lower.addingTimeInterval(3 * 3600).timeIntervalSince1970 * 1000
        try write([["type": "session", "createdAt": lower.addingTimeInterval(2 * 3600).timeIntervalSince1970 * 1000,
                    "isSeeded": true], raw("response"), ["type": "session/end-seed"], owned], to: child)
        try write([row(), row(2, response: "child")], to: ledger)
        let batch = await GatewaySessionRecovery(ledger: ledger).recover(files: [
            .init(sessionID: "parent", projectPath: "/p", url: parent),
            .init(sessionID: "child", projectPath: "/p", url: child)
        ], since: lower, until: upper)
        #expect(batch.isComplete); #expect(batch.matchedRequests == 2)
        #expect(batch.sessionStats.count == 2)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["WEFT_MAGPIE_TESTS"] == "1"))
    func liveMetadataOnlyRecovery() async {
        let until = Date(), since = Date().addingTimeInterval(-7 * 86400)
        let files = await TokeiMetadataIndex().activeDSHFiles(since: since, until: until)
        #expect(!files.isEmpty)
        let recovery = GatewaySessionRecovery()
        let batch = await recovery.recover(files: files, since: since, until: until)
        let complete = batch.isComplete
        #expect(complete)
        #expect(batch.matchedRequests > 0)
        let aggregatedCount = batch.sessionStats.reduce(0) { $0 + $1.count }
        #expect(aggregatedCount == batch.matchedRequests)
        let read = await recovery.bytesRead
        let cached = await recovery.recover(files: files, since: since, until: until)
        let cachedComplete = cached.isComplete
        #expect(cachedComplete)
        // Live writers may append while testing; a repeated call must not rescan the corpus.
        let repeatedBytes = await recovery.bytesRead - read
        #expect(repeatedBytes < 8 * 1024 * 1024)
        let halo = batch.sessionStats.filter {
            let path = $0.projectPath?.lowercased() ?? ""
            return path.contains("halo-cam") || path.contains("halocam")
        }.reduce(0) { $0 + $1.count }
        print("Gateway recovery: files=\(files.count), requests=\(batch.matchedRequests), sessions=\(batch.sessionStats.count), halo=\(halo), complete=\(batch.isComplete), bytes=\(read), repeatedBytes=\(repeatedBytes), malformedRaw=\(await recovery.malformedRawLines), malformedLedger=\(await recovery.malformedLedgerLines)")
    }
}
