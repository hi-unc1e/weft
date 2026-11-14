import Foundation
import Testing
@testable import WeftKit

struct ProjectAttributionTests {
    let start = Date(timeIntervalSince1970: 1_700_000_000)

    @Test func literalEvidencePreservesBoundariesAndLongestPath() {
        let projects = TrackedProject.catalog(paths: ["/work/demo", "/work/demo/tools", "/work/demo.extra", "/work/a+b[1]"])
        #expect(TrackedProject.match(title: "/work/demo/tools/file.swift", url: nil, projects: projects)?.id == "/work/demo/tools")
        #expect(TrackedProject.match(title: "/work/demo.extra — Editor", url: nil, projects: projects)?.id == "/work/demo.extra")
        #expect(TrackedProject.match(title: "demo-helper", url: nil, projects: projects) == nil)
        #expect(TrackedProject.match(title: "中demo文", url: nil, projects: projects) == nil)
        #expect(TrackedProject.match(title: "a+b[1] — Editor", url: nil, projects: projects)?.id == "/work/a+b[1]")
        #expect(TrackedProject.match(title: "/work/demoSuffix then /work/demo/file", url: nil, projects: projects)?.id == "/work/demo")
    }

    @Test func expandedActivityIDsUseFullCatalogAndSameClippedEvidenceAsTotals() {
        let activities = [
            ProjectActivity(start: start - 90, end: start - 1, title: "demo"),
            ProjectActivity(start: start - 30, end: start + 30, title: "demo"),
            ProjectActivity(start: start + 30, end: start + 60, title: "demo"),
            ProjectActivity(start: start, end: start + 60, title: "News"),
            ProjectActivity(start: start + 60, end: start + 90, title: "ambiguous")
        ]
        let report = ProjectReport.build(activities: activities, requests: [],
            interval: DateInterval(start: start, end: start + 60),
            projectPaths: ["/work/demo", "/work/ambiguous", "/other/ambiguous"])
        #expect(report.activityProjectIDs == [nil, "/work/demo", "/work/demo", nil, nil])
        #expect(report.projects.first?.activeTime == 60)
        #expect(report.unattributedTime == 60)
    }

    @Test func sevenDayReportStaysWithinInteractiveBudget() async throws {
        let paths = (0..<80).map { "/work/project-\($0)" }
        let stats = (0..<160).map {
            ProjectSessionStats(count: 80, projectPath: paths[$0 % paths.count], sessionID: "session-\($0)",
                                title: "Investigate feature \($0)")
        }
        let activities = (0..<2_200).map {
            ProjectActivity(start: start + Double($0 * 60), end: start + Double($0 * 60 + 60),
                            title: "project-\($0 % paths.count) — Editor \($0)")
        }
        let input = ProjectReportInput(activities: activities, requests: [],
            interval: DateInterval(start: start, end: start + 7 * 86_400), projectPaths: paths,
            sessionStats: stats, requestsWithoutSession: 0, localSessions: [])
        let clock = ContinuousClock()
        let began = clock.now
        let report = try await input.buildInBackground()
        let elapsed = began.duration(to: clock.now)
        print("Seven-day fixture: 2200 distinct activities / 80 projects / 160 topics in \(elapsed)")
        #expect(report.projects.count == 80)
        #expect(report.activityProjectIDs.compactMap { $0 }.count == activities.count)
        #expect(report.projects.reduce(0) { $0 + $1.requests } == 12_800)
        // Generous for debug CI; the previous regex-per-activity approach took many seconds.
        #expect(elapsed < .seconds(5))
    }

    @Test func cancelledReportCannotPublishAResult() async {
        let input = ProjectReportInput(activities: [], requests: [],
            interval: DateInterval(start: start, end: start + 60), projectPaths: [],
            sessionStats: [], requestsWithoutSession: 0, localSessions: [])
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await input.buildInBackground()
        }
        do {
            _ = try await cancelled.value
            Issue.record("Cancelled report returned a publishable result")
        } catch {
            #expect(error is CancellationError)
        }
    }

    @Test func localSessionsOutsideGatewayAreIncludedWithoutDuplicatingSharedIDs() {
        let stats = [ProjectSessionStats(count: 261, projectPath: "/work/halo-cam", sessionID: "shared")]
        let local = [
            LocalProjectSession(sessionID: "shared", projectPath: "/work/halo-cam", lastDay: "2023-11-14"),
            LocalProjectSession(sessionID: "local-only", projectPath: "/work/HaloCam-Android", lastDay: "2023-11-14")
        ]
        let report = ProjectReport.build(activities: [], requests: [], interval: DateInterval(start: start, end: start + 120),
                                         sessionStats: stats, localSessions: local)
        #expect(report.projects.count == 1)
        #expect(report.projects[0].sessions == 2)
        #expect(report.projects[0].localSessions == 2)
        #expect(report.projects[0].gatewaySessions == 1)
        #expect(report.projects[0].requests == 261)
        #expect(report.projects[0].measuredActiveTime == nil)
    }

    @Test func completeSummaryOverridesTruncatedSamplesAndIncludesMissingSessions() {
        let stats = [
            ProjectSessionStats(count: 3000, projectPath: "/work/halo-cam", sessionID: "a", title: "相机完整会话标题"),
            ProjectSessionStats(count: 123, projectPath: "/work/HaloCam-Android", sessionID: "b"),
            ProjectSessionStats(count: 10, projectPath: nil, sessionID: "unknown")
        ]
        let report = ProjectReport.build(activities: [], requests: [], interval: DateInterval(start: start, end: start + 120),
                                         sessionStats: stats, requestsWithoutSession: 20)
        #expect(report.projects.count == 1)
        #expect(report.projects[0].requests == 3123)
        #expect(report.projects[0].sessions == 2)
        #expect(report.projects[0].measuredActiveTime == nil)
        #expect(report.projects[0].project.sessionTitles == ["相机完整会话标题"])
        #expect(report.unresolvedRequests == 30)
    }

    @Test func haloCheckoutsAndWorktreesAreOneProject() {
        let projects = TrackedProject.catalog(paths: ["/work/halo-cam", "/work/HaloCam-Android", "/work/halo-cam/.worktrees/fix"])
        #expect(projects.count == 1)
        #expect(projects.first?.name == "HaloCam（Halo 相机）")
        #expect(TrackedProject.match(title: "Halo 相机调试", url: nil, projects: projects)?.id == "halocam")
    }

    @Test func ambiguousAndSubstringTitlesRemainUnknown() {
        let projects = TrackedProject.catalog(paths: ["/work/duck", "/work/duckee", "/other/duck"])
        #expect(TrackedProject.match(title: "duckee — Editor", url: nil, projects: projects)?.name == "duckee")
        #expect(TrackedProject.match(title: "duck — Editor", url: nil, projects: projects) == nil)
        #expect(TrackedProject.match(title: "/other/duck — Editor", url: nil, projects: projects)?.id == "/other/duck")
        #expect(TrackedProject.match(title: "Just coding", url: nil, projects: projects) == nil)
    }

    @Test func ordinaryWorktreesShareRepositoryIdentity() {
        let catalog = TrackedProject.catalog(paths: ["/work/demo", "/work/demo/.worktrees/feature"])
        #expect(catalog.count == 1)
        #expect(catalog.first?.id == "/work/demo")
        let managed = TrackedProject.catalog(paths: ["/user/.codex/worktrees/abc/demo"])
        #expect(managed.first?.name == "demo")
        #expect(managed.first?.id == "/user/.codex/worktrees/abc/demo")
    }

    @Test func localCatalogFindsForegroundProjectOutsideRequestSample() {
        let report = ProjectReport.build(activities: [ProjectActivity(start: start, end: start + 90, title: "demo — Editor")],
                                         requests: [], interval: DateInterval(start: start, end: start + 120),
                                         projectPaths: ["/work/demo"])
        #expect(report.projects.first?.project.name == "demo")
        #expect(report.projects.first?.activeTime == 90)
        #expect(report.projects.first?.requests == 0)
    }

    @Test func backgroundRequestsCannotCreateHumanWorkTime() {
        let requests = [ProjectRequest(date: start, agent: "codex", sessionID: "a", projectPath: "/work/halo-cam", milliseconds: 90_000)]
        let report = ProjectReport.build(activities: [ProjectActivity(start: start, end: start + 60, title: "News")],
                                         requests: requests, interval: DateInterval(start: start, end: start + 120))
        #expect(report.projects.first?.requests == 1)
        #expect(report.projects.first?.activeTime == 0)
        #expect(report.projects.first?.measuredActiveTime == nil)
        #expect(report.unattributedTime == 60)
    }

    @Test func sessionTopicCanIdentifyForegroundWithoutProjectName() {
        let requests = [ProjectRequest(date: start, agent: "codex", sessionID: "a", projectPath: "/work/halo-cam",
                                       milliseconds: 10, sessionTitle: "修复相机启动速度")]
        let catalog = TrackedProject.catalog(requests: requests)
        #expect(TrackedProject.match(title: "修复相机启动速度 — Codex", url: nil, projects: catalog)?.id == "halocam")
        #expect(TrackedProject.match(title: nil, url: nil, projects: catalog) == nil)
    }

    @Test func duplicateTopicCannotPickBetweenProjects() {
        let requests = ["/work/one", "/work/two"].map {
            ProjectRequest(date: start, agent: "codex", sessionID: "a", projectPath: $0,
                           milliseconds: 10, sessionTitle: "Performance investigation")
        }
        #expect(TrackedProject.match(title: "Performance investigation", url: nil,
                                    projects: TrackedProject.catalog(requests: requests)) == nil)
    }

    @Test func clipsDaysAndCountsSessionsWithoutAddingRequestDurations() {
        let requests = [
            ProjectRequest(date: start + 1, agent: "codex", sessionID: "a", projectPath: "/work/halo-cam", milliseconds: 100_000),
            ProjectRequest(date: start + 2, agent: "codex", sessionID: "a", projectPath: "/work/halo-cam", milliseconds: 100_000),
            ProjectRequest(date: start + 3, agent: "pi", sessionID: nil, projectPath: nil, milliseconds: 100),
            ProjectRequest(date: start + 120, agent: "codex", sessionID: "b", projectPath: "/work/halo-cam", milliseconds: 100),
        ]
        let report = ProjectReport.build(activities: [ProjectActivity(start: start - 60, end: start + 180, title: "halo-cam — Xcode")],
                                         requests: requests, interval: DateInterval(start: start, end: start + 120))
        #expect(report.projects.first?.activeTime == 120)
        #expect(report.projects.first?.measuredActiveTime == 120)
        #expect(report.projects.first?.requests == 2)
        #expect(report.projects.first?.sessions == 1)
        #expect(report.unresolvedRequests == 1)
        #expect(report.unattributedTime == 0)
    }
}
