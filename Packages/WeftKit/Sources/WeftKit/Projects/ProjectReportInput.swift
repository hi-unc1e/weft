import Foundation

/// Immutable values cross the worker boundary; SwiftData objects stay on the main actor.
public struct ProjectReportInput: Sendable, Hashable {
    public let activities: [ProjectActivity]
    public let requests: [ProjectRequest]
    public let interval: DateInterval
    public let projectPaths: [String]
    public let sessionStats: [ProjectSessionStats]
    public let requestsWithoutSession: Int
    public let localSessions: [LocalProjectSession]

    public init(activities: [ProjectActivity], requests: [ProjectRequest], interval: DateInterval,
                projectPaths: [String], sessionStats: [ProjectSessionStats],
                requestsWithoutSession: Int, localSessions: [LocalProjectSession]) {
        self.activities = activities
        self.requests = requests
        self.interval = interval
        self.projectPaths = projectPaths
        self.sessionStats = sessionStats
        self.requestsWithoutSession = requestsWithoutSession
        self.localSessions = localSessions
    }

    /// Explicit detachment also works when called by a SwiftUI task on the main actor.
    public func buildInBackground() async throws -> ProjectReport {
        let work = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            let report = ProjectReport.build(activities: activities, requests: requests, interval: interval,
                                             projectPaths: projectPaths, sessionStats: sessionStats,
                                             requestsWithoutSession: requestsWithoutSession, localSessions: localSessions)
            try Task.checkCancellation()
            return report
        }
        return try await withTaskCancellationHandler {
            try await work.value
        } onCancel: {
            work.cancel()
        }
    }
}
