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


public struct MagpieClient: Sendable {
    public struct Batch: Sendable {
        public let requests: [ProjectRequest]
        public let isTruncated: Bool
        public let totalAvailable: Int
        public let projectPaths: [String]
    }

    public enum ClientError: Error, Sendable {
        case httpStatus(Int)
        case invalidResponse
        case invalidPagination
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

    /// At most 2,000 API rows; retain this client between refreshes to reuse the metadata cache.
    public func requestsWithMetadata() async throws -> Batch {
        let end = now()
        let start = end.addingTimeInterval(-7 * 24 * 60 * 60)
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        var rows: [(Row, Date)] = []
        var offset = 0
        var total = 0
        while offset < 2_000 {
            try Task.checkCancellation()
            var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)!
            components.queryItems = [
                URLQueryItem(name: "period", value: "7d"),
                URLQueryItem(name: "limit", value: String(min(200, 2_000 - offset))),
                URLQueryItem(name: "offset", value: String(offset))
            ]
            var request = URLRequest(url: components.url!)
            request.httpMethod = "GET"
            request.cachePolicy = .reloadIgnoringLocalCacheData
            let (data, response) = try await session.data(for: request, delegate: NoRedirects())
            guard let http = response as? HTTPURLResponse else { throw ClientError.invalidResponse }
            guard http.statusCode == 200 else { throw ClientError.httpStatus(http.statusCode) }
            let page: Page
            do { page = try JSONDecoder().decode(Page.self, from: data) }
            catch { throw ClientError.invalidResponse }
            guard page.offset == offset, page.total >= 0, page.rows.count <= 200 else {
                throw ClientError.invalidPagination
            }
            total = max(total, page.total)
            if page.rows.isEmpty {
                guard offset >= page.total else { throw ClientError.invalidPagination }
                break
            }
            for row in page.rows {
                guard let date = fractional.date(from: row.t) ?? plain.date(from: row.t), row.ms >= 0 else {
                    throw ClientError.invalidResponse
                }
                if date >= start && date <= end { rows.append((row, date)) }
            }
            offset += page.rows.count
            if offset >= page.total { break }
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
        return Batch(requests: result, isTruncated: offset < total, totalAvailable: total,
                     projectPaths: Array(Set(index.entries.values.compactMap(\.path))).sorted())
    }

    private struct Page: Decodable {
        let rows: [Row]
        let total: Int
        let offset: Int
    }

    private struct Row: Decodable {
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
