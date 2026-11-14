import Foundation
import Observation
import WeftKit

@MainActor @Observable
final class ProjectStore {
    @ObservationIgnored private let coordinator: ProjectRefreshCoordinator

    /// Read once when constructing a report. Only show statistics if matchesSelection
    /// (and selectedDays == the view's picker value); batch may retain an older range.
    var snapshot: ProjectRefreshSnapshot { coordinator.snapshot }
    var selectedDays: Int { snapshot.selectedDays }
    var loadedDays: Int? { snapshot.loadedDays }
    var revision: UInt64 { snapshot.revision }
    var matchesSelection: Bool { snapshot.matchesSelection }
    var requests: [ProjectRequest] { snapshot.batch?.requests ?? [] }
    var projectPaths: [String] { snapshot.batch?.projectPaths ?? [] }
    var sessionStats: [ProjectSessionStats] { snapshot.batch?.sessionStats ?? [] }
    var localSessions: [LocalProjectSession] { snapshot.batch?.localSessions ?? [] }
    var recoveredRequests: Int { snapshot.batch?.recoveredRequests ?? 0 }
    var recoveryComplete: Bool { snapshot.batch?.recoveryComplete ?? true }
    var since: Date? { snapshot.batch?.since }
    var requestsWithoutSession: Int { snapshot.batch?.requestsWithoutSession ?? 0 }
    var isRefreshing: Bool { snapshot.isRefreshing }
    var error: String? { snapshot.error }
    var updatedAt: Date? { snapshot.updatedAt }
    var isTruncated: Bool { snapshot.batch?.isTruncated ?? false }
    var totalAvailable: Int { snapshot.batch?.totalAvailable ?? 0 }
    var enabled: Bool {
        get { snapshot.enabled }
        set {
            UserDefaults.standard.set(!newValue, forKey: "magpieProjectsDisabled")
            coordinator.setEnabled(newValue)
        }
    }

    init(loader: ProjectRefreshCoordinator.Loader? = nil) {
        let client = MagpieClient()
        coordinator = ProjectRefreshCoordinator(
            enabled: !UserDefaults.standard.bool(forKey: "magpieProjectsDisabled"),
            loader: loader ?? { try await client.requestsWithMetadata(days: $0) }
        )
    }

    func refresh(days: Int? = nil) async {
        await coordinator.refresh(days: days)
    }
}
