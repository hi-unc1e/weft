import Foundation
import Observation
import WeftKit

@MainActor @Observable
final class ProjectStore {
    var requests: [ProjectRequest] = []
    var projectPaths: [String] = []
    var isRefreshing = false
    var error: String?
    var updatedAt: Date?
    var isTruncated = false
    var totalAvailable = 0
    var enabled: Bool {
        didSet {
            UserDefaults.standard.set(!enabled, forKey: "magpieProjectsDisabled")
            if !enabled { requests = []; projectPaths = []; updatedAt = nil; error = nil }
        }
    }
    @ObservationIgnored private let client = MagpieClient()

    init() { enabled = !UserDefaults.standard.bool(forKey: "magpieProjectsDisabled") }

    func refresh() async {
        guard enabled, !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            let result = try await client.requestsWithMetadata()
            guard enabled else { return }
            requests = result.requests
            projectPaths = result.projectPaths
            isTruncated = result.isTruncated
            totalAvailable = result.totalAvailable
            updatedAt = .now
            error = nil
        } catch {
            guard enabled else { return }
            self.error = "无法读取 Magpie：\(error.localizedDescription)。已有结果保留，稍后可重试。"
        }
    }
}
