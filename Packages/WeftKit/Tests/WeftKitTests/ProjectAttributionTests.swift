import Foundation
import Testing
@testable import WeftKit

struct ProjectAttributionTests {
    let start = Date(timeIntervalSince1970: 1_700_000_000)

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
