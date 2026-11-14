import Foundation
import Observation
import WeftKit

@MainActor @Observable
final class ProjectStore {
    var requests: [ProjectRequest] = []
    var projectPaths: [String] = []
    var sessionStats: [ProjectSessionStats] = []
    var since: Date?
    var selectedDays = 7
    var requestsWithoutSession = 0
    var isRefreshing = false
    var error: String?
    var updatedAt: Date?
    var isTruncated = false
    var totalAvailable = 0
    var enabled: Bool {
        didSet {
            UserDefaults.standard.set(!enabled, forKey: "magpieProjectsDisabled")
            if !enabled { requests = []; projectPaths = []; sessionStats = []; requestsWithoutSession = 0; since = nil; updatedAt = nil; error = nil }
        }
    }
    @ObservationIgnored private let client = MagpieClient()

    init() { enabled = !UserDefaults.standard.bool(forKey: "magpieProjectsDisabled") }

    func refresh(days: Int? = nil) async {
        if let days, days != selectedDays {
            selectedDays = days
            requests = []; sessionStats = []; requestsWithoutSession = 0; since = nil; updatedAt = nil
        }
        guard enabled, !isRefreshing else { return }
        let requestedDays = selectedDays
        isRefreshing = true
        defer {
            isRefreshing = false
            if selectedDays != requestedDays { Task { await refresh() } }
        }
        do {
            let result = try await client.requestsWithMetadata(days: requestedDays)
            guard enabled, selectedDays == requestedDays else { return }
            requests = result.requests
            projectPaths = result.projectPaths
            sessionStats = result.sessionStats
            requestsWithoutSession = result.requestsWithoutSession
            since = result.since
            isTruncated = result.isTruncated
            totalAvailable = result.totalAvailable
            updatedAt = .now
            error = nil
        } catch {
            guard enabled, selectedDays == requestedDays else { return }
            self.error = "无法读取 Magpie：\(error.localizedDescription)。已有结果保留，稍后可重试。"
        }
    }
}
