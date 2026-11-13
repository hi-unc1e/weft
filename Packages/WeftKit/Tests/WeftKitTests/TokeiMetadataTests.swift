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

    @Test(.enabled(if: ProcessInfo.processInfo.environment["WEFT_TOKEI_TESTS"] == "1"))
    func liveMappingCount() async {
        let mapping = await TokeiMetadataIndex().snapshot()
        print("Tokei mappings=\(mapping.count)")
    }
}
