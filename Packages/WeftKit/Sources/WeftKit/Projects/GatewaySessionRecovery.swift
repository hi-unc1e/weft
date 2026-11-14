import Foundation
import Darwin

struct RecoveryBatch: Sendable {
    let sessionStats: [ProjectSessionStats]
    let matchedRequests: Int
    let isComplete: Bool
}

/// Exact local response-ID join. Holds metadata only; never retains a JSON line or message body.
internal actor GatewaySessionRecovery {
    struct Limits: Sendable {
        var lineBytes = 8 * 1024 * 1024
        var fileBytes = 128 * 1024 * 1024
        var totalBytes = 512 * 1024 * 1024
    }

    private struct Stamp: Equatable {
        let size: Int64
        let inode: UInt64
        let device: Int32
        let seconds: Int
        let nanos: Int
        let changeSeconds: Int
        let changeNanos: Int
        init(_ s: stat) {
            size = s.st_size; inode = s.st_ino; device = s.st_dev
            seconds = s.st_mtimespec.tv_sec; nanos = s.st_mtimespec.tv_nsec
            changeSeconds = s.st_ctimespec.tv_sec; changeNanos = s.st_ctimespec.tv_nsec
        }
    }
    private struct Session: Hashable {
        let id: String
        let path: String
    }
    private enum RequestKey: Hashable {
        case route(Int64)
        case fallback(String, String, String)
    }
    private struct Request {
        let response: String?
        let date: Date?
    }
    private struct Cached {
        var stamp: Stamp
        var offset: UInt64 = 0
        var complete = true
        var responses: Set<String> = []
        var title: String?
        var titleDate: Date?
        var creationDate: Date?
        // Tombstones are retained too: later ineligible versions must erase earlier candidates.
        var requests: [RequestKey: Request] = [:]
    }

    private let ledger: URL
    private let limits: Limits
    private var rawCache: [URL: Cached] = [:]
    private var ledgerCache: Cached?
    private let decoder = JSONDecoder()
    private let iso = ISO8601DateFormatter()
    private let fractional = ISO8601DateFormatter()
    private(set) var filesRead = 0
    private(set) var bytesRead = 0
    private(set) var malformedRawLines = 0
    private(set) var malformedLedgerLines = 0

    init(ledger: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/magpie/usage.jsonl"), limits: Limits = Limits()) {
        self.ledger = ledger
        self.limits = Limits(lineBytes: max(1, min(limits.lineBytes, 8 * 1024 * 1024)),
                             fileBytes: max(1, min(limits.fileBytes, 128 * 1024 * 1024)),
                             totalBytes: max(1, min(limits.totalBytes, 512 * 1024 * 1024)))
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    }

    func recover(files: [LocalProjectSessionFile], since: Date, until: Date) -> RecoveryBatch {
        guard since < until else {
            return RecoveryBatch(sessionStats: [], matchedRequests: 0, isComplete: since == until)
        }
        var budget = limits.totalBytes
        var complete = true
        let urls = Set(files.map(\.url))
        rawCache = rawCache.filter { urls.contains($0.key) }
        var mapping: [String: Session] = [:]
        var conflicts: Set<String> = []
        var titles: [Session: (Date, String)] = [:]
        var scanned: Set<URL> = []
        for file in files {
            guard !file.sessionID.isEmpty, file.projectPath.hasPrefix("/"),
                  !file.projectPath.contains("\0") else { complete = false; continue }
            if scanned.insert(file.url).inserted {
                rawCache[file.url] = scan(file.url, previous: rawCache[file.url], ledger: false, budget: &budget)
            }
            guard let cached = rawCache[file.url] else { complete = false; continue }
            complete = complete && cached.complete
            let session = Session(id: file.sessionID, path: file.projectPath)
            if let title = cached.title, let date = cached.titleDate,
               titles[session].map({ $0.0 < date || ($0.0 == date && title < $0.1) }) ?? true {
                titles[session] = (date, title)
            }
            for id in cached.responses {
                if let old = mapping[id], old != session { conflicts.insert(id) }
                else { mapping[id] = session }
            }
        }
        ledgerCache = scan(ledger, previous: ledgerCache, ledger: true, budget: &budget)
        complete = complete && ledgerCache?.complete == true
        // An unread tail can contain an upsert or a conflicting export. Never guess through it.
        guard complete, let ledgerCache else {
            return RecoveryBatch(sessionStats: [], matchedRequests: 0, isComplete: false)
        }
        var counts: [Session: Int] = [:]
        for row in ledgerCache.requests.values {
            guard let id = row.response, !conflicts.contains(id), let session = mapping[id],
                  let date = row.date, date >= since, date < until else { continue }
            counts[session, default: 0] += 1
        }
        let stats = counts.keys.sorted { ($0.id, $0.path) < ($1.id, $1.path) }.map {
            ProjectSessionStats(count: counts[$0]!, projectPath: $0.path, sessionID: $0.id,
                                title: titles[$0]?.1)
        }
        return RecoveryBatch(sessionStats: stats, matchedRequests: counts.values.reduce(0, +), isComplete: true)
    }

    private func date(_ text: String?) -> Date? {
        guard let text else { return nil }
        return iso.date(from: text) ?? fractional.date(from: text)
    }

    private func rawDate(_ value: RawTimestamp?) -> Date? {
        switch value {
        case .text(let text): return date(text)
        case .milliseconds(let number): return Date(timeIntervalSince1970: number / 1000)
        case nil: return nil
        }
    }

    private func consume(_ data: Data, ledger: Bool, cache: inout Cached) {
        guard !data.isEmpty else { return }
        if ledger {
            guard let row = try? decoder.decode(LedgerLine.self, from: data) else {
                malformedLedgerLines += 1
                cache.complete = false; return
            }
            let key: RequestKey
            if let id = row.route_id, id > 0 { key = .route(id) }
            else if let response = row.response_id, !response.isEmpty,
                    let time = row.t, let agent = row.agent {
                key = .fallback(response, time, agent)
            } else { return }
            let eligible = row.agent == "dsh" && (row.session ?? "").isEmpty
                && (row.native_session ?? "").isEmpty
                && row.status.map { (200..<300).contains($0) } == true
            cache.requests[key] = Request(response: eligible ? row.response_id : nil,
                                          date: eligible ? date(row.t) : nil)
        } else {
            guard let row = try? decoder.decode(RawLine.self, from: data) else {
                malformedRawLines += 1
                cache.complete = false; return
            }
            if row.type == "session" {
                cache.creationDate = rawDate(row.createdAt)
                return
            }
            // Fork exports copy parent history. Earlier responses cannot belong to this child.
            // With no usable creation time, retain IDs and let the exact-join conflict gate decide.
            guard let time = rawDate(row.time),
                  cache.creationDate.map({ time >= $0 }) ?? true else { return }
            if row.type == "session/title", let title = row.data?.title, !title.isEmpty,
               cache.titleDate.map({ $0 <= time }) ?? true {
                cache.title = String(title.prefix(1024)); cache.titleDate = time
            }
            guard row.type == "assistant/message",
                  let id = row.data?.message?.source?.replayState?.response?.responseId,
                  !id.isEmpty else { return }
            // Raw timestamps validate the record, but only the gateway timestamp bounds requests.
            cache.responses.insert(id)
        }
    }

    private func scan(_ url: URL, previous: Cached?, ledger: Bool, budget: inout Int) -> Cached? {
        guard url.isFileURL else { return nil }
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
              info.st_size >= 0, info.st_size <= limits.fileBytes else { return nil }
        let stamp = Stamp(info)
        if let previous, previous.stamp == stamp { return previous }
        var result = Cached(stamp: stamp)
        // JSONL writers append. Replacement, same-size edits, and truncation restart the index.
        if let previous, previous.complete, previous.stamp.inode == stamp.inode,
           previous.stamp.device == stamp.device, previous.stamp.size < stamp.size {
            result = previous
            result.stamp = stamp
        }
        let start = result.offset
        let needed = Int(stamp.size - Int64(start))
        guard needed <= budget else { return nil }
        do {
            try handle.seek(toOffset: start)
            filesRead += 1
            var position = start
            var pending = Data()
            var oversized = false
            while position < UInt64(stamp.size) {
                let amount = min(64 * 1024, Int(UInt64(stamp.size) - position))
                guard let chunk = try handle.read(upToCount: amount), !chunk.isEmpty else { return nil }
                budget -= chunk.count
                bytesRead += chunk.count
                var cursor = chunk.startIndex
                while cursor < chunk.endIndex {
                    let newline = chunk[cursor...].firstIndex(of: 10)
                    let end = newline ?? chunk.endIndex
                    let part = chunk[cursor..<end]
                    if !oversized {
                        if pending.count + part.count > limits.lineBytes {
                            pending.removeAll(keepingCapacity: true)
                            oversized = true
                            result.complete = false
                        } else { pending.append(contentsOf: part) }
                    }
                    if let newline {
                        if !oversized { consume(pending, ledger: ledger, cache: &result) }
                        pending.removeAll(keepingCapacity: true)
                        oversized = false
                        result.offset = position + UInt64(newline + 1)
                        cursor = newline + 1
                    } else { cursor = end }
                }
                position += UInt64(chunk.count)
            }
            // No body is cached. A final unterminated line is reread on the next append.
            if !pending.isEmpty { consume(pending, ledger: ledger, cache: &result) }
            guard fstat(fd, &info) == 0, Stamp(info) == stamp else { return nil }
            return result
        } catch { return nil }
    }
}

private struct LedgerLine: Decodable {
    let route_id: Int64?
    let response_id: String?
    let t: String?
    let agent: String?
    let session: String?
    let native_session: String?
    let status: Int?
}

private struct RawLine: Decodable {
    struct Payload: Decodable {
        let title: String?
        struct Message: Decodable {
            struct Source: Decodable {
                struct Replay: Decodable {
                    struct Response: Decodable { let responseId: String? }
                    let response: Response?
                }
                let replayState: Replay?
            }
            let source: Source?
        }
        let message: Message?
    }
    let type: String?
    let time: RawTimestamp?
    let createdAt: RawTimestamp?
    let data: Payload?
    private enum CodingKeys: String, CodingKey { case type, time, data, createdAt }
    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        type = try values.decodeIfPresent(String.self, forKey: .type)
        createdAt = type == "session" ? try values.decodeIfPresent(RawTimestamp.self, forKey: .createdAt) : nil
        guard type == "assistant/message" || type == "session/title" else {
            time = nil; data = nil; return
        }
        time = try values.decodeIfPresent(RawTimestamp.self, forKey: .time)
        data = try values.decodeIfPresent(Payload.self, forKey: .data)
    }
}

private enum RawTimestamp: Decodable {
    case text(String)
    // Older DSH exports use epoch milliseconds; newer exports use ISO strings.
    case milliseconds(Double)
    init(from decoder: any Decoder) throws {
        let value = try decoder.singleValueContainer()
        if let text = try? value.decode(String.self) { self = .text(text) }
        else { self = .milliseconds(try value.decode(Double.self)) }
    }
}
