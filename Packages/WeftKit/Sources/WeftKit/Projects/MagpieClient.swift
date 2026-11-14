import Foundation

public struct ProjectRequest: Sendable {
    public let date: Date
    public let agent: String
    /// The API's session value, unchanged; native_session is only a metadata lookup alias.
    public let sessionID: String?
    public let projectPath: String?
    public let milliseconds: Int
    public let sessionTitle: String?

    public init(date: Date, agent: String, sessionID: String?, projectPath: String?,
                milliseconds: Int, sessionTitle: String? = nil) {
        self.date = date
        self.agent = agent
        self.sessionID = sessionID
        self.projectPath = projectPath
        self.milliseconds = milliseconds
        self.sessionTitle = sessionTitle
    }
}


/// Complete per-session counts from the summary, never extrapolated from request samples.
public struct ProjectSessionStats: Sendable {
    /// Summary calls includes failures; errors is a subset and must never be added.
    public let count: Int
    public let projectPath: String?
    public let sessionID: String
    public let title: String?

    public init(count: Int, projectPath: String?, sessionID: String, title: String? = nil) {
        self.count = count
        self.projectPath = projectPath
        self.sessionID = sessionID
        self.title = title
    }
}

public struct MagpieClient: Sendable {
    public struct Batch: Sendable {
        public let requests: [ProjectRequest]
        public let isTruncated: Bool
        public let totalAvailable: Int
        public let projectPaths: [String]
        public let sessionStats: [ProjectSessionStats]
        /// Raw server groups (a session ID may appear under more than one agent).
        public let summarySessionCount: Int
        public let period: String
        /// Exact server boundary (including its timezone): today midnight or six midnights ago.
        public let since: Date
        /// Complete summary calls, including requests without a session or project.
        public var totalRequests: Int { totalAvailable }
        public var totalSessions: Int { sessionStats.count }
        public var associatedRequests: Int {
            sessionStats.filter { $0.projectPath != nil }.reduce(0) { $0 + $1.count }
        }
        public var requestsWithoutSession: Int {
            totalRequests - sessionStats.reduce(0) { $0 + $1.count }
        }
    }

    public enum ClientError: LocalizedError, Sendable {
        case httpStatus(Int)
        case invalidResponse
        case invalidPagination

        public var errorDescription: String? {
            switch self {
            case .httpStatus(let status):
                return "Magpie 请求失败（HTTP \(status)）。"
            case .invalidResponse:
                return "Magpie 返回的数据格式无效或统计不完整。"
            case .invalidPagination:
                return "Magpie 返回的分页数据不一致。"
            }
        }
    }

    private let endpoint: URL
    private let session: URLSession
    private let metadata: MagpieMetadataIndex
    private let tokei: TokeiMetadataIndex?
    private let now: @Sendable () -> Date

    public init() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 30
        self.init(
            endpoint: URL(string: "http://127.0.0.1:3425/v1/magpie/usage/requests")!,
            session: URLSession(configuration: configuration),
            codexRoot: home.appendingPathComponent(".codex/sessions"),
            claudeRoot: home.appendingPathComponent(".claude/projects"),
            titleIndex: home.appendingPathComponent(".codex/session_index.jsonl"),
            tokeiDirectory: home.appendingPathComponent(".tokei/cache/scan_cache.d")
        )
    }

    init(endpoint: URL, session: URLSession, codexRoot: URL, claudeRoot: URL,
         titleIndex: URL? = nil, tokeiDirectory: URL? = nil,
         now: @escaping @Sendable () -> Date = { Date() }) {
        self.endpoint = endpoint
        self.session = session
        self.metadata = MagpieMetadataIndex(codexRoot: codexRoot, claudeRoot: claudeRoot, titleIndex: titleIndex)
        self.tokei = tokeiDirectory.map { TokeiMetadataIndex(directory: $0) }
        self.now = now
    }

    public func requests() async throws -> [ProjectRequest] {
        try await requestsWithMetadata().requests
    }

    /// `requests` is a single-page detail sample; all statistics MUST use sessionStats/totalRequests.
    /// Magpie periods are calendar days: 7d starts six midnights ago, today at local midnight.
    /// Fetching one page avoids unstable offset pagination as new requests arrive.
    public func requestsWithMetadata(days: Int = 7) async throws -> Batch {
        guard days == 1 || days == 7 else { throw ClientError.invalidResponse }
        let period = days == 1 ? "today" : "7d"
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        func date(_ value: String) -> Date? { fractional.date(from: value) ?? plain.date(from: value) }
        // deletingLastPathComponent produces a directory URL (/usage/), which Magpie rejects.
        // URL.path can hide that trailing slash; normalize the actual encoded URL path instead.
        var summaryURL = URLComponents(url: endpoint.deletingLastPathComponent(), resolvingAgainstBaseURL: false)!
        while summaryURL.percentEncodedPath.hasSuffix("/") {
            summaryURL.percentEncodedPath.removeLast()
        }
        let summary: Summary = try await fetch(summaryURL.url!, query: [
            URLQueryItem(name: "period", value: period)
        ])
        guard summary.period == period, let start = date(summary.since), summary.calls >= 0,
              summary.sessionCount == summary.sessions.count,
              Set(summary.sessions.map { [$0.id, $0.agent ?? ""] }).count == summary.sessions.count else {
            throw ClientError.invalidResponse
        }
        var sessionCalls = 0
        for item in summary.sessions {
            guard !item.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  item.calls >= 0, item.calls <= summary.calls - sessionCalls else {
                throw ClientError.invalidResponse
            }
            sessionCalls += item.calls
        }
        let page: Page = try await fetch(endpoint, query: [
            URLQueryItem(name: "period", value: period),
            URLQueryItem(name: "limit", value: "200"),
            URLQueryItem(name: "offset", value: "0")
        ])
        guard page.offset == 0, page.total >= page.rows.count, page.rows.count <= 200 else {
            throw ClientError.invalidPagination
        }
        var rows: [(Row, Date)] = []
        var seen: Set<Int64> = []
        for row in page.rows {
            guard let timestamp = date(row.t), row.ms >= 0 else { throw ClientError.invalidResponse }
            // Only positive gateway route IDs identify requests. Zero/missing IDs can be
            // independent imported requests; never deduplicate them by timestamp/session.
            if let id = row.route_id, id > 0, !seen.insert(id).inserted { continue }
            if timestamp >= start { rows.append((row, timestamp)) }
        }
        var index = await metadata.snapshot()
        if let supplemental = await tokei?.snapshot() {
            for (id, entry) in supplemental {
                let primary = index.entries[id]
                index.entries[id] = MagpieMetadataIndex.Entry(path: primary?.path ?? entry.path,
                                                              title: primary?.title ?? entry.title)
            }
        }
        let result = rows.map { row, date in
            // Exact API session takes precedence; native_session is an explicit alias, never a time guess.
            let candidates = [row.session, row.native_session].compactMap { $0 }.filter { !$0.isEmpty }
            let matches = candidates.compactMap { index.lookup($0) }
            return ProjectRequest(date: date, agent: row.agent,
                                  sessionID: row.session ?? row.native_session,
                                  projectPath: matches.compactMap(\.path).first, milliseconds: row.ms,
                                  sessionTitle: matches.compactMap(\.title).first)
        }
        // The API groups by (id, agent); one logical session can span agents.
        let groups = Dictionary(grouping: summary.sessions, by: \.id)
        let stats = groups.keys.sorted().map { id in
            let match = index.lookup(id)
            return ProjectSessionStats(count: groups[id]!.reduce(0) { $0 + $1.calls },
                                       projectPath: match?.path, sessionID: id, title: match?.title)
        }
        return Batch(requests: result, isTruncated: page.rows.count < page.total,
                     totalAvailable: summary.calls,
                     projectPaths: Array(Set(index.entries.values.compactMap(\.path))).sorted(),
                     sessionStats: stats, summarySessionCount: summary.sessionCount, period: period, since: start)
    }

    private func fetch<T: Decodable>(_ url: URL, query: [URLQueryItem]) async throws -> T {
        try Task.checkCancellation()
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        components.queryItems = query
        var request = URLRequest(url: components.url!)
        request.httpMethod = "GET"
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let (data, response) = try await session.data(for: request, delegate: NoRedirects())
        guard let http = response as? HTTPURLResponse else { throw ClientError.invalidResponse }
        guard http.statusCode == 200 else { throw ClientError.httpStatus(http.statusCode) }
        do { return try JSONDecoder().decode(T.self, from: data) }
        catch { throw ClientError.invalidResponse }
    }

    private struct Summary: Decodable {
        struct Session: Decodable { let id: String; let agent: String?; let calls: Int }
        let period: String
        let since: String
        let calls: Int
        let sessionCount: Int
        let sessions: [Session]
    }

    private struct Page: Decodable {
        let rows: [Row]
        let total: Int
        let offset: Int
    }

    private struct Row: Decodable {
        let route_id: Int64?
        let t: String
        let agent: String
        let session: String?
        let native_session: String?
        let ms: Int
    }
}

private final class NoRedirects: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

/// Only explicitly decoded metadata is retained; no messages, prompts or tool output are modeled.
actor MagpieMetadataIndex {
    struct Entry: Sendable {
        var path: String?
        var title: String?
    }
    struct Snapshot: Sendable {
        var entries: [String: Entry]
        func lookup(_ id: String) -> Entry? {
            if let exact = entries[id] { return exact }
            // Custom namespaces may wrap a native UUID. Require a complete, unique UUID suffix.
            guard id.count > 36 else { return nil }
            let suffix = String(id.suffix(36))
            let prefix = id.dropLast(36)
            guard UUID(uuidString: suffix) != nil,
                  let separator = prefix.last, ":/|_-".contains(separator) else { return nil }
            return entries[suffix]
        }
    }
    private struct Stamp: Equatable {
        let size: Int
        let modified: Date?
        let created: Date?
    }
    private struct Cached {
        let stamp: Stamp
        let entries: [String: Entry]
    }
    private let codexRoot: URL
    private let claudeRoot: URL
    private let titleIndex: URL?
    private var cache: [URL: Cached] = [:]
    private(set) var filesRead = 0

    init(codexRoot: URL, claudeRoot: URL, titleIndex: URL?) {
        self.codexRoot = codexRoot
        self.claudeRoot = claudeRoot
        self.titleIndex = titleIndex
    }

    func snapshot() -> Snapshot {
        var entries: [String: Entry] = [:]
        var visited: Set<URL> = []
        for (root, codex) in [(codexRoot, true), (claudeRoot, false)] {
            guard let iterator = FileManager.default.enumerator(
                at: root, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
                options: [.skipsHiddenFiles]) else { continue }
            for case let url as URL in iterator {
                if !codex && iterator.level > 2 { iterator.skipDescendants(); continue }
                guard url.pathExtension == "jsonl" else { continue }
                visited.insert(url)
                for (id, entry) in read(url, kind: codex ? .codex : .claude) {
                    if let existing = entries[id], existing.path != entry.path {
                        // Ambiguous duplicate IDs must not attribute work to an arbitrary directory.
                        entries[id] = Entry(path: nil, title: existing.title)
                    } else { entries[id] = entry }
                }
            }
        }
        if let titleIndex {
            visited.insert(titleIndex)
            for (id, entry) in read(titleIndex, kind: .titles) {
                var existing = entries[id] ?? Entry()
                existing.title = entry.title
                entries[id] = existing
            }
        }
        cache = cache.filter { visited.contains($0.key) }
        return Snapshot(entries: entries)
    }

    private enum Kind { case codex, claude, titles }
    private struct MetadataLine: Decodable {
        struct Payload: Decodable { let id: String?; let cwd: String? }
        let type: String?
        let payload: Payload?
        let sessionId: String?
        let cwd: String?
        let customTitle: String?
        let id: String?
        let thread_name: String?
    }

    private func read(_ url: URL, kind: Kind) -> [String: Entry] {
        guard let attributes = try? url.resourceValues(forKeys: [
            .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey, .creationDateKey
        ]), attributes.isRegularFile == true, attributes.isSymbolicLink != true else { return [:] }
        let stamp = Stamp(size: attributes.fileSize ?? 0, modified: attributes.contentModificationDate,
                          created: attributes.creationDate)
        if let cached = cache[url], cached.stamp == stamp { return cached.entries }
        guard let handle = try? FileHandle(forReadingFrom: url) else { return [:] }
        defer { try? handle.close() }
        let limit = kind == .titles ? 4 * 1_024 * 1_024 : 65_536
        let startOffset = kind == .titles ? max(0, stamp.size - limit) : 0
        if startOffset > 0 {
            do { try handle.seek(toOffset: UInt64(startOffset)) }
            catch { return [:] }
        }
        guard let data = try? handle.read(upToCount: limit) else { return [:] }
        filesRead += 1
        var result: [String: Entry] = [:]
        let lines = data.split(separator: 10, omittingEmptySubsequences: false)
        for (position, line) in lines.enumerated() {
            // Tail reads start inside a record; conservatively discard that first fragment.
            if startOffset > 0 && position == 0 { continue }
            // A truncated record must never be interpreted as complete metadata.
            if position == lines.count - 1 && stamp.size > startOffset + data.count { break }
            guard let value = try? JSONDecoder().decode(MetadataLine.self, from: Data(line)) else {
                if kind == .codex { break }
                continue
            }
            switch kind {
            case .codex:
                if value.type == "session_meta", let id = value.payload?.id,
                   let cwd = value.payload?.cwd, cwd.hasPrefix("/") {
                    result[id] = Entry(path: cwd)
                }
            case .claude:
                if let id = value.sessionId {
                    var entry = result[id] ?? Entry()
                    if entry.path == nil, let cwd = value.cwd, cwd.hasPrefix("/") { entry.path = cwd }
                    if value.type == "custom-title" { entry.title = value.customTitle }
                    if entry.path != nil || entry.title != nil { result[id] = entry }
                }
            case .titles:
                if let id = value.id, let title = value.thread_name, !title.isEmpty {
                    result[id] = Entry(title: title)
                }
            }
            if kind == .codex { break }
        }
        cache[url] = Cached(stamp: stamp, entries: result)
        return result
    }
}
