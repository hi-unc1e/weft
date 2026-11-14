import Foundation

/// A project is independent of activity categories: coding and documentation can belong to one project.
public struct TrackedProject: Identifiable, Sendable, Hashable {
    public let id: String
    public let name: String
    public let paths: [String]
    public var sessionTitles: [String] = []

    public static func catalog(requests: [ProjectRequest], paths: [String] = []) -> [Self] {
        catalog(paths: requests.compactMap(\.projectPath) + paths).map { project in
            var project = project
            project.sessionTitles = Array(Set(requests.filter {
                $0.projectPath.map { project.paths.contains($0) } == true
            }.compactMap(\.sessionTitle).filter { $0.count >= 6 })).sorted()
            return project
        }
    }

    public static func catalog(paths: [String]) -> [Self] {
        let grouped = Dictionary(grouping: Set(paths.filter { $0.hasPrefix("/") })) { path in
            let parts = path.split(separator: "/").map(String.init)
            let leaf: String
            let root: String
            if let index = parts.firstIndex(where: { [".worktrees", "worktrees"].contains($0) }), index > 0 {
                if parts[index - 1] == ".codex", index + 2 < parts.count {
                    leaf = parts[index + 2]
                    root = "/" + parts.prefix(index + 3).joined(separator: "/")
                } else {
                    leaf = parts[index - 1]
                    root = "/" + parts.prefix(index).joined(separator: "/")
                }
            } else { leaf = parts.last ?? path; root = path }
            // HaloCam's Android/iOS/backend checkouts are one product.
            return normalized(leaf).hasPrefix("halocam") ? "halocam" : root
        }
        return grouped.map { key, paths in
            Self(id: key, name: key == "halocam" ? "HaloCam（Halo 相机）" : URL(fileURLWithPath: key).lastPathComponent,
                 paths: paths.sorted())
        }.sorted { $0.name < $1.name }
    }

    static func normalized(_ text: String) -> String {
        text.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(String.init).joined()
    }

    /// Only explicit title/URL evidence counts. Concurrent background requests never choose a project.
    public static func match(title: String?, url: String?, projects: [Self]) -> Self? {
        ProjectMatcher(projects: projects).match(title: title, url: url)
    }
}

/// Prepare literal evidence once per catalogue. No regular expressions are compiled per activity.
private struct ProjectMatcher {
    struct Evidence {
        let project: TrackedProject
        let paths: [String]
        let leaves: [String]
        let topics: [String]
    }
    let evidence: [Evidence]

    init(projects: [TrackedProject]) {
        evidence = projects.map { project in
            Evidence(project: project, paths: project.paths.map { $0.lowercased() },
                     leaves: project.paths.map { URL(fileURLWithPath: $0).lastPathComponent.lowercased() }
                        .filter { $0.count >= 3 }, topics: project.sessionTitles.map { $0.lowercased() })
        }
    }

    func match(title: String?, url: String?) -> TrackedProject? {
        let text = [title, url].compactMap { $0 }.joined(separator: " ").lowercased()
        guard !text.isEmpty else { return nil }
        let paths = evidence.compactMap { item -> (TrackedProject, Int)? in
            guard let length = item.paths.filter({ path in
                contains(path, in: text, before: { _ in true }, after: {
                    CharacterSet.whitespacesAndNewlines.contains($0) || "/\"'—–".unicodeScalars.contains($0)
                })
            }).map(\.count).max() else { return nil }
            return (item.project, length)
        }
        if let longest = paths.map(\.1).max() {
            let precise = paths.filter { $0.1 == longest }
            if precise.count == 1 { return precise[0].0 }
        }
        let candidates = evidence.filter { item in
            if item.topics.contains(where: { title in
                contains(title, in: text, before: { !isWord($0) }, after: { !isWord($0) })
            }) { return true }
            if item.project.id == "halocam", TrackedProject.normalized(text).contains("halocam") || text.contains("halo 相机") || text.contains("halo相机") {
                return true
            }
            return item.leaves.contains { leaf in
                contains(leaf, in: text, before: { !isWord($0) && $0 != "." && $0 != "-" },
                         after: { !isWord($0) && $0 != "." && $0 != "-" })
            }
        }
        return candidates.count == 1 ? candidates[0].project : nil
    }

    private func isWord(_ scalar: Unicode.Scalar) -> Bool {
        if scalar == "_" { return true }
        switch scalar.properties.generalCategory {
        case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter,
             .decimalNumber, .letterNumber, .otherNumber: return true
        default: return false
        }
    }

    private func contains(_ literal: String, in text: String,
                          before: (Unicode.Scalar) -> Bool, after: (Unicode.Scalar) -> Bool) -> Bool {
        guard !literal.isEmpty else { return false }
        var start = text.startIndex
        while start < text.endIndex,
              let range = text.range(of: literal, options: .literal, range: start..<text.endIndex) {
            let left = text.unicodeScalars[..<range.lowerBound].last
            let right = text.unicodeScalars[range.upperBound...].first
            if left.map(before) ?? true, right.map(after) ?? true { return true }
            start = text.unicodeScalars.index(after: range.lowerBound)
        }
        return false
    }
}

public struct ProjectActivity: Sendable, Hashable {
    public let start: Date
    public let end: Date
    public let title: String?
    public let url: String?

    public init(start: Date, end: Date, title: String?, url: String? = nil) {
        self.start = start; self.end = end; self.title = title; self.url = url
    }
}

public struct ProjectUsage: Identifiable, Sendable {
    public var id: String { project.id }
    public let project: TrackedProject
    public let activeTime: TimeInterval
    public let requests: Int
    public let sessions: Int
    public let localSessions: Int
    public let gatewaySessions: Int
    public let lastRequest: Date?
    /// A matched duration is a lower bound. No matches means unknown, never a measured zero.
    public var measuredActiveTime: TimeInterval? { activeTime > 0 ? activeTime : nil }
}

public struct ProjectReport: Sendable {
    public let projects: [ProjectUsage]
    public let unattributedTime: TimeInterval
    public let unresolvedRequests: Int
    /// Same order as the input activities; reused by expanded rows without matching again.
    public let activityProjectIDs: [String?]

    public static func build(activities: [ProjectActivity], requests: [ProjectRequest], interval: DateInterval,
                             projectPaths: [String] = [], sessionStats: [ProjectSessionStats]? = nil,
                             requestsWithoutSession: Int = 0, localSessions: [LocalProjectSession] = []) -> Self {
        let topicRequests = (sessionStats ?? []).map {
            ProjectRequest(date: interval.start, agent: "", sessionID: $0.sessionID, projectPath: $0.projectPath,
                           milliseconds: 0, sessionTitle: $0.title)
        }
        let localRequests = localSessions.map {
            ProjectRequest(date: interval.start, agent: "", sessionID: $0.sessionID, projectPath: $0.projectPath, milliseconds: 0)
        }
        let catalog = TrackedProject.catalog(requests: requests + topicRequests + localRequests, paths: projectPaths)
        let matcher = ProjectMatcher(projects: catalog)
        var durations: [String: TimeInterval] = [:]
        var unknown: TimeInterval = 0
        var matches: [String: String] = [:]
        var activityProjectIDs: [String?] = []
        for activity in activities {
            let duration = max(0, min(activity.end, interval.end).timeIntervalSince(max(activity.start, interval.start)))
            guard duration > 0 else { activityProjectIDs.append(nil); continue }
            let key = (activity.title ?? "") + "\0" + (activity.url ?? "")
            let projectID: String
            if let cached = matches[key] { projectID = cached }
            else {
                projectID = matcher.match(title: activity.title, url: activity.url)?.id ?? ""
                matches[key] = projectID
            }
            activityProjectIDs.append(projectID.isEmpty ? nil : projectID)
            if !projectID.isEmpty {
                durations[projectID, default: 0] += duration
            } else { unknown += duration }
        }
        let relevant = requests.filter { $0.date >= interval.start && $0.date < interval.end }
        let allUsage: [ProjectUsage] = catalog.map { project -> ProjectUsage in
            let rows = relevant.filter { row in row.projectPath.map { project.paths.contains($0) } ?? false }
            let stats = sessionStats?.filter { $0.projectPath.map { project.paths.contains($0) } ?? false }
            let requestCount: Int = stats?.reduce(0) { $0 + $1.count } ?? rows.count
            let gatewayIDs: Set<String> = Set(stats?.map(\.sessionID) ?? rows.compactMap(\.sessionID))
            let projectLocalSessions = localSessions.filter { project.paths.contains($0.projectPath) }
            let localIDs: Set<String> = Set(projectLocalSessions.map(\.sessionID))
            return ProjectUsage(project: project, activeTime: durations[project.id, default: 0],
                                requests: requestCount,
                                sessions: gatewayIDs.union(localIDs).count, localSessions: localIDs.count,
                                gatewaySessions: gatewayIDs.count,
                                lastRequest: rows.map(\.date).max())
        }
        let usage = allUsage.filter { $0.activeTime > 0 || $0.requests > 0 || $0.sessions > 0 }.sorted {
            if $0.activeTime != $1.activeTime { return $0.activeTime > $1.activeTime }
            if $0.requests != $1.requests { return $0.requests > $1.requests }
            return $0.project.name < $1.project.name
        }
        return Self(projects: usage, unattributedTime: unknown,
                    unresolvedRequests: sessionStats.map { $0.filter { $0.projectPath == nil }.reduce(requestsWithoutSession) { $0 + $1.count } }
                        ?? relevant.filter { $0.projectPath == nil }.count,
                    activityProjectIDs: activityProjectIDs)
    }
}
