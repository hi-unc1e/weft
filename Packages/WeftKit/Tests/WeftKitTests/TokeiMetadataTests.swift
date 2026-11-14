import Foundation
import Testing
@testable import WeftKit

struct TokeiMetadataTests {
    private func fixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("weft-tokei-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
    private func write(_ object: Any, _ name: String, in root: URL) throws {
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            .write(to: root.appendingPathComponent(name), options: .atomic)
    }

    @Test func mappingsAndSessionFallbacks() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let codex = "01234567-89ab-cdef-0123-456789abcdef"
        let claude = "11234567-89ab-cdef-0123-456789abcdef"
        try write(["shards": ["codex": ["c.json"], "claude": "a.json", "pi": "p.json", "deepseek_harness": "d.json", "unknown": "u.json"]], "manifest.json", in: root)
        try write(["items": [
            [0, "/sessions/rollout-2026-11-13-\(codex).jsonl.zst", ["proj": "/sample/codex", "days": [:]]],
            [1, "other", ["session_id": "explicit-codex", "proj": "/sample/explicit"]],
            [2, "empty", ["session_id": "no-project", "proj": ""]]
        ] as [Any]], "c.json", in: root)
        try write(["/projects/\(claude).jsonl": ["proj": "/sample/claude"]], "a.json", in: root)
        try write(["file": ["sid": "pi-id", "proj": "/sample/pi", "title": "Synthetic title"], "bad": ["sid": "relative", "proj": "relative"]], "p.json", in: root)
        try write(["file": ["proj": "/sample/deepseek", "records": [["session": "deepseek-id"]]], "ambiguous": ["proj": "/sample/bad", "records": [["session": "a"], ["session": "b"]]]], "d.json", in: root)
        try write(["file": ["sid": "unknown", "proj": "/sample/unknown"]], "u.json", in: root)
        let index = TokeiMetadataIndex(directory: root)
        let values = await index.snapshot()
        #expect(values.count == 5)
        #expect(values["explicit-codex"]?.path == "/sample/explicit")
        #expect(values["no-project"] == nil)
        #expect(values[codex]?.path == "/sample/codex")
        #expect(values[claude]?.path == "/sample/claude")
        #expect(values["pi-id"]?.title == "Synthetic title")
        #expect(values["deepseek-id"]?.path == "/sample/deepseek")
        #expect(await index.filesRead == 5)
    }

    @Test func manifestAuthorityAndCacheInvalidation() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try write(["shards": ["pi": "active.json"]], "manifest.json", in: root)
        try write(["file": ["sid": "active", "proj": "/sample/a"]], "active.json", in: root)
        try write(["file": ["sid": "old", "proj": "/sample/old"]], "obsolete.json", in: root)
        let index = TokeiMetadataIndex(directory: root)
        #expect(await index.snapshot().count == 1)
        #expect(await index.snapshot()["old"] == nil)
        #expect(await index.filesRead == 2)
        try write(["file": ["sid": "active", "proj": "/sample/updated"]], "active.json", in: root)
        #expect(await index.snapshot()["active"]?.path == "/sample/updated")
        #expect(await index.filesRead == 3)
        try write(["shards": [:]], "manifest.json", in: root)
        #expect(await index.snapshot().isEmpty)
        try FileManager.default.removeItem(at: root.appendingPathComponent("manifest.json"))
        #expect(await index.snapshot().isEmpty)
    }

    @Test func rejectsTraversalSymlinksAndOversizedFiles() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("cache")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try write(["file": ["sid": "escaped", "proj": "/sample/outside"]], "outside.json", in: root)
        try FileManager.default.createSymbolicLink(at: directory.appendingPathComponent("link.json"), withDestinationURL: root.appendingPathComponent("outside.json"))
        try Data(repeating: 32, count: 4 * 1024 * 1024 + 1).write(to: directory.appendingPathComponent("large.json"))
        try write(["shards": ["pi": ["../outside.json", root.appendingPathComponent("outside.json").path, "link.json", "large.json"]]], "manifest.json", in: directory)
        let index = TokeiMetadataIndex(directory: directory)
        #expect(await index.snapshot().isEmpty)
        #expect(await index.filesRead == 1)
    }

    @Test func missingOrMalformedCacheIsOptional() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(await TokeiMetadataIndex(directory: root.appendingPathComponent("missing")).snapshot().isEmpty)
        try Data("invalid".utf8).write(to: root.appendingPathComponent("manifest.json"))
        #expect(await TokeiMetadataIndex(directory: root).snapshot().isEmpty)
    }

    private func date(_ value: String) -> Date {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: value)!
    }

    @Test func localSessionsDeduplicateVersionsFilterDatesAndRejectConflicts() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try write(["shards": ["deepseek_harness": "d.json"]], "manifest.json", in: root)
        try write(["items": [
            [0, "v1", ["sid": "shared", "proj": "/sample/a", "records": [["date": "2026-11-08", "turn": 1, "step": 1]]]],
            [1, "v2", ["sid": "shared", "proj": "/sample/a", "records": [["date": "2026-11-08", "turn": 1, "step": 1], ["date": "2026-11-13", "turn": 2, "step": 1], ["date": "2026-11-15"]]]],
            [2, "old", ["sid": "old", "proj": "/sample/a", "records": [["date": "2026-11-07"]]]],
            [3, "conflict1", ["sid": "conflict", "proj": "/sample/a", "records": [["date": "2026-11-13"]]]],
            [4, "conflict2", ["sid": "conflict", "proj": "/sample/b", "records": [["date": "2026-10-01"]]]]
        ] as [Any]], "d.json", in: root)
        let index = TokeiMetadataIndex(directory: root)
        let sessions = await index.localSessions(since: date("2026-11-08"), until: date("2026-11-14"))
        #expect(sessions.count == 1)
        #expect(sessions.first?.sessionID == "shared")
        #expect(sessions.first?.lastDay == "2026-11-13")
        #expect(sessions.first?.responseCount == nil)
        #expect(await index.localSessionConflictCount == 1)
        #expect(await index.localSessions(since: date("2026-11-09"), until: date("2026-11-12")).isEmpty)
        #expect(await index.filesRead == 2)
    }

    @Test func localSessionsUseDaysWithoutTimestampsForEveryOrdinaryTool() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let tools = ["codex", "claude", "pi", "prime", "prime_agent"]
        try write(["shards": Dictionary(uniqueKeysWithValues: tools.map { ($0, "\($0).json") })], "manifest.json", in: root)
        for tool in tools {
            try write([
                "file": ["sid": tool, "proj": "/sample/a", "days": ["2026-11-08": [:], "2026-11-14": [:], "2026-11-15": [:]]],
                "subagent": ["sid": "child-\(tool)", "proj": "/sample/a", "proj_nosession": true, "days": ["2026-11-14": [:]]],
                "invalid": ["sid": "invalid-\(tool)", "proj": "/sample/a", "days": ["invalid": [:]]]
            ], "\(tool).json", in: root)
        }
        let index = TokeiMetadataIndex(directory: root)
        let sessions = await index.localSessions(since: date("2026-11-08"), until: date("2026-11-14"))
        #expect(Set(sessions.map(\.sessionID)) == Set(tools + tools.map { "child-\($0)" }))
        #expect(sessions.allSatisfy { $0.lastDay == "2026-11-14" && $0.responseCount == nil })
        try write(["shards": [:]], "manifest.json", in: root)
        #expect(await index.localSessions(since: date("2026-11-08"), until: date("2026-11-14")).isEmpty)
    }

    @Test func activeDSHFilesPreserveVersionsAndRejectUnsafePaths() async throws {
        // Use the physical macOS temporary directory, not the /var or /tmp symlink aliases.
        let root = URL(fileURLWithPath: "/private/tmp/weft-dsh-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = root.appendingPathComponent("cache/scan_cache.d")
        let raw = root.appendingPathComponent("cache/dsh-sessions")
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: raw.appendingPathComponent("nested"), withIntermediateDirectories: true)
        let names = ["v1.jsonl", "nested/v2.jsonl", "old.jsonl", "future.jsonl", "days-only.jsonl", "conflict1.jsonl", "conflict2.jsonl", "unlisted.jsonl"]
        for name in names { try Data().write(to: raw.appendingPathComponent(name)) }
        let outside = root.appendingPathComponent("outside.jsonl")
        try Data().write(to: outside)
        try FileManager.default.createSymbolicLink(at: raw.appendingPathComponent("link.jsonl"), withDestinationURL: outside)
        try FileManager.default.createSymbolicLink(at: raw.appendingPathComponent("dir-link"), withDestinationURL: raw.appendingPathComponent("nested"))
        try FileManager.default.createDirectory(at: raw.appendingPathComponent("directory.jsonl"), withIntermediateDirectories: true)
        func entry(_ sid: String = "shared", _ day: String = "2026-11-14", _ project: String = "/sample/a") -> [String: Any] {
            ["sid": sid, "proj": project, "records": [["date": day]]]
        }
        var values: [String: Any] = [:]
        for name in ["v1.jsonl", "nested/v2.jsonl", "link.jsonl", "dir-link/v2.jsonl", "missing.jsonl", "directory.jsonl"] {
            values[raw.path + "/" + name] = entry()
        }
        values[outside.path] = entry()
        values[raw.path + "/nested/../v1.jsonl"] = entry()
        values[raw.path + "-other/v1.jsonl"] = entry()
        values[raw.path + "/old.jsonl"] = entry("old", "2026-11-07")
        values[raw.path + "/future.jsonl"] = entry("future", "2026-11-15")
        values[raw.path + "/days-only.jsonl"] = ["sid": "days-only", "proj": "/sample/a", "days": ["2026-11-14": [:]]]
        values[raw.path + "/conflict1.jsonl"] = entry("conflict")
        values[raw.path + "/conflict2.jsonl"] = entry("conflict", "2026-11-01", "/sample/b")
        try write(["shards": ["deepseek_harness": "d.json"]], "manifest.json", in: cache)
        try write(values, "d.json", in: cache)
        try write([raw.path + "/unlisted.jsonl": entry()], "obsolete.json", in: cache)
        let index = TokeiMetadataIndex(directory: cache)
        let files = await index.activeDSHFiles(since: date("2026-11-08"), until: date("2026-11-14"))
        #expect(Set(files.map { $0.url.path }) == Set([raw.path + "/v1.jsonl", raw.path + "/nested/v2.jsonl"]))
        #expect(files.allSatisfy { $0.sessionID == "shared" && $0.projectPath == "/sample/a" })
        #expect(await index.filesRead == 2)
        #expect(await index.activeDSHFiles(since: date("2026-11-15"), until: date("2026-11-14")).isEmpty)
        try FileManager.default.moveItem(at: raw, to: root.appendingPathComponent("moved"))
        try FileManager.default.createSymbolicLink(at: raw, withDestinationURL: root.appendingPathComponent("moved"))
        #expect(await index.activeDSHFiles(since: date("2026-11-08"), until: date("2026-11-14")).isEmpty)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["WEFT_TOKEI_TESTS"] == "1"))
    func liveLocalSessionUnion() async throws {
        let batch = try await MagpieClient().requestsWithMetadata(days: 7)
        let index = TokeiMetadataIndex()
        let sessions = await index.localSessions(since: batch.since, until: Date())
        let local = Set(sessions.filter { $0.projectPath.lowercased().contains("halo-cam") }.map(\.sessionID))
        let gateway = Set(batch.sessionStats.filter { $0.projectPath?.lowercased().contains("halo-cam") == true }.map(\.sessionID))
        print("HaloCam 7d: localSessions=\(local.count), Magpie=\(gateway.count), union=\(local.union(gateway).count), localOnly=\(local.subtracting(gateway).count), conflicts=\(await index.localSessionConflictCount)")
        let files = await index.activeDSHFiles(since: batch.since, until: Date())
        let haloFiles = files.filter { $0.projectPath.lowercased().contains("halo-cam") }
        print("DSH active files=\(files.count), HaloCam files=\(haloFiles.count), HaloCam unique SIDs=\(Set(haloFiles.map(\.sessionID)).count)")
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["WEFT_TOKEI_TESTS"] == "1"))
    func liveMappingCount() async {
        let mapping = await TokeiMetadataIndex().snapshot()
        print("Tokei mappings=\(mapping.count)")
    }
}
