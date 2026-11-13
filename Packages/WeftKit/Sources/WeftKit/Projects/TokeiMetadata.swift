import Foundation
import Darwin

/// Optional, read-only metadata. The manifest is the sole authority; never scan source sessions.
actor TokeiMetadataIndex {
    private static let fileLimit = 4 * 1024 * 1024
    private static let totalLimit = 64 * 1024 * 1024
    // Verified in usage.30s.py. OpenCode's cache currently has no project directory.
    private static let supported = ["codex", "claude", "deepseek_harness", "pi", "prime"]
    private struct Stamp: Equatable {
        let size: Int64
        let seconds: Int
        let nanos: Int
        let inode: UInt64
        init(_ value: stat) {
            size = value.st_size
            seconds = value.st_mtimespec.tv_sec
            nanos = value.st_mtimespec.tv_nsec
            inode = UInt64(value.st_ino)
        }
    }
    private struct Cached {
        let stamp: Stamp
        let object: [String: Any]
    }
    private let directory: URL
    private var cache: [String: Cached] = [:]
    private(set) var filesRead = 0

    init(directory: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".tokei/cache/scan_cache.d")) {
        self.directory = directory
    }

    func snapshot() -> [String: MagpieMetadataIndex.Entry] {
        let root = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard root >= 0 else { cache.removeAll(); return [:] }
        defer { close(root) }
        var budget = Self.totalLimit
        var retained: Set<String> = []
        defer { cache = cache.filter { retained.contains($0.key) } }
        guard let manifest = read("manifest.json", root: root, budget: &budget, retained: &retained),
              let shards = manifest["shards"] as? [String: Any] else { return [:] }
        var result: [String: MagpieMetadataIndex.Entry] = [:]
        var conflicts: Set<String> = []
        var visited: Set<String> = []
        for tool in Self.supported {
            let names = (shards[tool] as? [String]) ?? (shards[tool] as? String).map { [$0] } ?? []
            for name in names.prefix(4096) {
                guard visited.count < 4096, visited.insert(name).inserted,
                      let object = read(name, root: root, budget: &budget, retained: &retained) else { continue }
                let entries: [(String, [String: Any])]
                if let items = object["items"] as? [[Any]] {
                    entries = items.compactMap { item in
                        guard item.count == 3, item[0] is NSNumber,
                              let key = item[1] as? String, let entry = item[2] as? [String: Any] else { return nil }
                        return (key, entry)
                    }
                } else {
                    entries = object.keys.sorted().compactMap { key in
                        (object[key] as? [String: Any]).map { (key, $0) }
                    }
                }
                for (key, entry) in entries {
                    guard let path = entry["proj"] as? String, path.hasPrefix("/"),
                          !path.contains("\0"), let id = sessionID(tool: tool, key: key, entry: entry),
                          !conflicts.contains(id) else { continue }
                    if let old = result[id], old.path != path {
                        result.removeValue(forKey: id)
                        conflicts.insert(id)
                        continue
                    }
                    result[id] = .init(path: path, title: nonempty(entry["title"]) ?? result[id]?.title)
                }
            }
        }
        return result
    }

    private func read(_ name: String, root: Int32, budget: inout Int,
                      retained: inout Set<String>) -> [String: Any]? {
        // Basenames only; openat + O_NOFOLLOW also closes the symlink replacement race.
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/"),
              !name.contains("\\"), !name.contains("\0"), name.hasSuffix(".json") else { return nil }
        let descriptor = openat(root, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { return nil }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
              info.st_size >= 0, info.st_size <= Self.fileLimit, info.st_size <= budget else { return nil }
        budget -= Int(info.st_size)
        let stamp = Stamp(info)
        retained.insert(name)
        if let old = cache[name], old.stamp == stamp { return old.object }
        cache.removeValue(forKey: name)
        guard let data = try? handle.read(upToCount: Int(stamp.size)), data.count == Int(stamp.size),
              fstat(descriptor, &info) == 0, Stamp(info) == stamp else { return nil }
        filesRead += 1
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        cache[name] = Cached(stamp: stamp, object: object)
        return object
    }

    private func nonempty(_ value: Any?) -> String? {
        guard let text = value as? String, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !text.contains("\0") else { return nil }
        return text
    }

    private func sessionID(tool: String, key: String, entry: [String: Any]) -> String? {
        if let sid = nonempty(entry["sid"]) { return sid }
        if tool == "codex", let sid = nonempty(entry["session_id"]) { return sid }
        let basename = (key as NSString).lastPathComponent
        let uuid = "[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}"
        if tool == "codex", basename.range(of: "^rollout-.*-" + uuid + "\\.jsonl(?:\\.zst)?$", options: .regularExpression) != nil {
            let stem = basename.replacingOccurrences(of: "\\.jsonl(?:\\.zst)?$", with: "", options: .regularExpression)
            return String(stem.suffix(36))
        }
        if tool == "claude", basename.range(of: "^" + uuid + "\\.jsonl$", options: .regularExpression) != nil {
            return String(basename.dropLast(6))
        }
        if tool == "deepseek_harness", let records = entry["records"] as? [[String: Any]] {
            let ids = Set(records.compactMap { nonempty($0["session"]) })
            if ids.count == 1 { return ids.first }
        }
        return nil
    }
}
