import Foundation
import Darwin

public struct LocalProjectSessionFile: Sendable {
    public let sessionID: String
    public let projectPath: String
    public let url: URL

    public init(sessionID: String, projectPath: String, url: URL) {
        self.sessionID = sessionID
        self.projectPath = projectPath
        self.url = url
    }
}

public struct LocalProjectSession: Sendable, Hashable {
    public let sessionID: String
    public let projectPath: String
    public let lastDay: String
    /// Deduplicated local responses, not HTTP requests. Unknown remains nil.
    public let responseCount: Int?

    public init(sessionID: String, projectPath: String, lastDay: String, responseCount: Int? = nil) {
        self.sessionID = sessionID
        self.projectPath = projectPath
        self.lastDay = lastDay
        self.responseCount = responseCount
    }
}

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
    private(set) var localSessionConflictCount = 0

    init(directory: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".tokei/cache/scan_cache.d")) {
        self.directory = directory
    }

    func snapshot() -> [String: MagpieMetadataIndex.Entry] {
        var result: [String: MagpieMetadataIndex.Entry] = [:]
        var conflicts: Set<String> = []
        visitEntries { tool, key, entry in
            guard let path = entry["proj"] as? String, path.hasPrefix("/"),
                  !path.contains("\0"), let id = sessionID(tool: tool, key: key, entry: entry),
                  !conflicts.contains(id) else { return }
            if let old = result[id], old.path != path {
                result.removeValue(forKey: id)
                conflicts.insert(id)
                return
            }
            result[id] = .init(path: path, title: nonempty(entry["title"]) ?? result[id]?.title)
        }
        return result
    }

    /// Inclusive local calendar days, matching Tokei's date-keyed cache (not precise instants).
    /// Only manifest-listed shards participate; duplicate versions contribute at most one ID.
    func localSessions(since: Date, until: Date) -> [LocalProjectSession] {
        localSessionConflictCount = 0
        guard since <= until else { return [] }
        let validDay = dayFilter(since: since, until: until)
        var paths: [String: String] = [:]
        var lastDays: [String: String] = [:]
        var conflicts: Set<String> = []
        visitEntries(includePrimeAgent: true) { tool, key, entry in
            guard let path = entry["proj"] as? String, path.hasPrefix("/"), !path.contains("\0"),
                  let id = sessionID(tool: tool, key: key, entry: entry) else { return }
            // Include child sessions: this is the complete local ID directory, not Tokei's
            // top-level session metric (which suppresses proj_nosession entries).
            // Conflicts across all current versions are unsafe even when one version is older.
            if let previous = paths[id], previous != path { conflicts.insert(id) }
            paths[id] = path
            let days = (entry["days"] as? [String: Any] ?? [:]).compactMap { day, value in
                value is [String: Any] && validDay(day) ? day : nil
            }
            let recordDays = (entry["records"] as? [[String: Any]] ?? []).compactMap { record in
                (record["date"] as? String).flatMap { validDay($0) ? $0 : nil }
            }
            if let latest = (days + recordDays).max() {
                lastDays[id] = max(lastDays[id] ?? latest, latest)
            }
        }
        localSessionConflictCount = conflicts.count
        return lastDays.keys.sorted().compactMap { id in
            guard !conflicts.contains(id), let path = paths[id], let day = lastDays[id] else { return nil }
            // Usage records are not HTTP request counts; do not sum duplicate cache versions.
            return LocalProjectSession(sessionID: id, projectPath: path, lastDay: day)
        }
    }

    /// Selects manifest-keyed DSH files with records in the inclusive local-day window.
    /// Preserves distinct versions of the same SID. Does not read response bodies.
    /// URLs are checked now; consumers must reopen safely against subsequent symlink replacement.
    func activeDSHFiles(since: Date, until: Date) -> [LocalProjectSessionFile] {
        guard since <= until else { return [] }
        let projects = Dictionary(uniqueKeysWithValues: localSessions(since: since, until: until)
            .map { ($0.sessionID, $0.projectPath) })
        let validDay = dayFilter(since: since, until: until)
        let allowedRoot = directory.deletingLastPathComponent()
            .appendingPathComponent("dsh-sessions", isDirectory: true).path
        var files: [String: LocalProjectSessionFile] = [:]
        var conflicts: Set<String> = []
        visitEntries { tool, key, entry in
            guard tool == "deepseek_harness",
                  let id = sessionID(tool: tool, key: key, entry: entry),
                  let path = projects[id], entry["proj"] as? String == path,
                  let records = entry["records"] as? [[String: Any]],
                  records.contains(where: { ($0["date"] as? String).map(validDay) == true }),
                  safeDSHFile(key, beneath: allowedRoot) else { return }
            if let old = files[key], old.sessionID != id { conflicts.insert(key) }
            files[key] = LocalProjectSessionFile(sessionID: id, projectPath: path,
                                                url: URL(fileURLWithPath: key))
        }
        return files.keys.sorted().filter { !conflicts.contains($0) }.compactMap { files[$0] }
    }

    private func safeDSHFile(_ path: String, beneath root: String) -> Bool {
        guard path.hasPrefix(root + "/"), path.hasSuffix(".jsonl"),
              !path.contains("\\"), !path.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
        else { return false }
        let parts = path.dropFirst().split(separator: "/", omittingEmptySubsequences: false)
        guard parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else { return false }
        // Walk every component with openat: neither parent directories nor the leaf may be links.
        var descriptor = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard descriptor >= 0 else { return false }
        defer { close(descriptor) }
        for (index, part) in parts.enumerated() {
            let isLeaf = index == parts.count - 1
            let next = openat(descriptor, String(part), O_RDONLY | O_NOFOLLOW | O_CLOEXEC
                              | O_NONBLOCK | (isLeaf ? 0 : O_DIRECTORY))
            guard next >= 0 else { return false }
            close(descriptor)
            descriptor = next
        }
        var info = stat()
        return fstat(descriptor, &info) == 0 && (info.st_mode & S_IFMT) == S_IFREG
    }

    private func dayFilter(since: Date, until: Date) -> (String) -> Bool {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.isLenient = false
        let lower = formatter.string(from: since), upper = formatter.string(from: until)
        return { value in
            guard value.count == 10, value >= lower, value <= upper,
                  let date = formatter.date(from: value) else { return false }
            return formatter.string(from: date) == value
        }
    }

    private func visitEntries(includePrimeAgent: Bool = false,
                              _ visit: (String, String, [String: Any]) -> Void) {
        let root = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard root >= 0 else { cache.removeAll(); return }
        defer { close(root) }
        var budget = Self.totalLimit
        var retained: Set<String> = []
        defer { cache = cache.filter { retained.contains($0.key) } }
        guard let manifest = read("manifest.json", root: root, budget: &budget, retained: &retained),
              let shards = manifest["shards"] as? [String: Any] else { return }
        var visited: Set<String> = []
        for tool in Self.supported + (includePrimeAgent ? ["prime_agent"] : []) {
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
                    visit(tool, key, entry)
                }
            }
        }
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
