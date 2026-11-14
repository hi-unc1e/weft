import Foundation
import Observation

/// One coherent publication of both the loaded data and its refresh state.
/// Retained data may belong to a different selection: gate statistics on matchesSelection.
public struct ProjectRefreshSnapshot: Sendable {
    public fileprivate(set) var enabled: Bool
    public fileprivate(set) var selectedDays: Int
    public fileprivate(set) var loadedDays: Int?
    public fileprivate(set) var batch: MagpieClient.Batch?
    /// Changes only when data is replaced or cleared, not for loading/error transitions.
    public fileprivate(set) var revision: UInt64 = 0
    public fileprivate(set) var updatedAt: Date?
    public fileprivate(set) var isRefreshing = false
    public fileprivate(set) var error: String?

    public var matchesSelection: Bool { enabled && batch != nil && loadedDays == selectedDays }

    fileprivate init(enabled: Bool, selectedDays: Int) {
        self.enabled = enabled
        self.selectedDays = selectedDays
    }
}

/// UI-independent refresh ownership. View tasks only wait; their cancellation never
/// cancels a load. Changing the selection or disabling explicitly invalidates it.
@MainActor @Observable
public final class ProjectRefreshCoordinator {
    public typealias Loader = @Sendable (Int) async throws -> MagpieClient.Batch

    public private(set) var snapshot: ProjectRefreshSnapshot
    @ObservationIgnored private let loader: Loader
    @ObservationIgnored private let now: @Sendable () -> Date
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var requestID: UUID?

    public init(enabled: Bool = true, selectedDays: Int = 7,
                loader: @escaping Loader, now: @escaping @Sendable () -> Date = { .now }) {
        snapshot = ProjectRefreshSnapshot(enabled: enabled, selectedDays: selectedDays)
        self.loader = loader
        self.now = now
    }

    public func setEnabled(_ enabled: Bool) {
        guard snapshot.enabled != enabled else { return }
        invalidate()
        var next = ProjectRefreshSnapshot(enabled: enabled, selectedDays: snapshot.selectedDays)
        next.revision = snapshot.revision &+ 1
        snapshot = next
        if enabled { requestRefresh() }
    }

    /// Registers the selection before any suspension. An in-flight request for the
    /// same selection is shared; a different selection starts immediately, even if
    /// the obsolete loader ignores cancellation. The returned task is for waiting,
    /// not for cancellation; only this coordinator owns the load's lifetime.
    @discardableResult
    public func requestRefresh(days: Int? = nil) -> Task<Void, Never>? {
        let days = days ?? snapshot.selectedDays
        if snapshot.enabled, days == snapshot.selectedDays, let task { return task }
        invalidate()
        var next = snapshot
        next.selectedDays = days
        next.error = nil
        next.isRefreshing = next.enabled
        snapshot = next
        guard next.enabled else { return nil }

        let id = UUID()
        requestID = id
        let loader = self.loader
        task = Task { [weak self] in
            guard !Task.isCancelled else { return }
            do {
                let batch = try await loader(days)
                self?.finish(id: id, days: days, result: .success(batch))
            } catch {
                self?.finish(id: id, days: days, result: .failure(error))
            }
        }
        return task
    }

    public func refresh(days: Int? = nil) async {
        let pending = requestRefresh(days: days)
        await pending?.value
    }

    private func invalidate() {
        requestID = nil
        task?.cancel()
        task = nil
    }

    private func finish(id: UUID, days: Int, result: Result<MagpieClient.Batch, Error>) {
        // A days check alone cannot reject 7 -> 1 -> 7 or disable -> enable races.
        guard requestID == id, snapshot.enabled else { return }
        var next = snapshot
        next.isRefreshing = false
        switch result {
        case .success(let batch):
            next.batch = batch
            next.revision &+= 1
            next.loadedDays = days
            next.updatedAt = now()
            next.error = nil
        case .failure(let error):
            // Cancellation is not a data-source failure. A later refresh can retry.
            if !(error is CancellationError), (error as? URLError)?.code != .cancelled {
                let retained = next.batch == nil ? "稍后可重试。" : "已有结果保留，稍后可重试。"
                next.error = "无法读取 Magpie：\(error.localizedDescription)。\(retained)"
            }
        }
        requestID = nil
        task = nil
        snapshot = next
    }

    deinit { task?.cancel() }
}
