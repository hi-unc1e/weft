import Foundation
import Testing
@testable import WeftKit

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct ProjectRefreshCoordinatorTests {
    private let timestamp = Date(timeIntervalSince1970: 1_700_000_000)

    @Test func publishesCompleteSnapshotAndPreservesValueCopies() async throws {
        let loader = ControlledProjectLoader()
        let timestamp = timestamp
        let coordinator = ProjectRefreshCoordinator(loader: { try await loader.load($0) }, now: { timestamp })
        let initial = coordinator.snapshot
        let task = try #require(coordinator.requestRefresh())
        await loader.waitForCalls(1)
        #expect(coordinator.snapshot.isRefreshing)
        #expect(!coordinator.snapshot.matchesSelection)
        loader.succeed(0, batch: batch(days: 7, total: 42))
        await task.value

        let snapshot = coordinator.snapshot
        let data = try #require(snapshot.batch)
        #expect(snapshot.loadedDays == 7)
        #expect(snapshot.selectedDays == 7)
        #expect(snapshot.matchesSelection)
        #expect(!snapshot.isRefreshing)
        #expect(snapshot.error == nil)
        #expect(snapshot.updatedAt == timestamp)
        #expect(snapshot.revision == 1)
        #expect(data.requests.first?.agent == "fixture")
        #expect(data.projectPaths == ["/work/fixture"])
        #expect(data.sessionStats.first?.count == 39)
        #expect(data.localSessions.first?.sessionID == "local")
        #expect(data.recoveredRequests == 2)
        #expect(!data.recoveryComplete)
        #expect(data.isTruncated)
        #expect(data.totalAvailable == 42)
        #expect(data.requestsWithoutSession == 3)
        #expect(data.summarySessionCount == 1)
        #expect(data.period == "7d")
        #expect(data.since == timestamp)
        #expect(initial.batch == nil)
        #expect(initial.revision == 0)
        #expect(!initial.isRefreshing)
    }

    @Test(arguments: [false, true])
    func latestSelectionWinsRegardlessOfCompletionOrder(oldFinishesFirst: Bool) async throws {
        let loader = ControlledProjectLoader()
        let coordinator = ProjectRefreshCoordinator(loader: { try await loader.load($0) })
        let old = try #require(coordinator.requestRefresh(days: 7))
        await loader.waitForCalls(1)
        let latest = try #require(coordinator.requestRefresh(days: 1))
        await loader.waitForCalls(2)
        #expect(loader.days == [7, 1])
        if oldFinishesFirst {
            loader.succeed(0, batch: batch(days: 7, total: 70))
            await old.value
            #expect(coordinator.snapshot.batch == nil)
            #expect(coordinator.snapshot.isRefreshing)
        }
        loader.succeed(1, batch: batch(days: 1, total: 10))
        await latest.value
        if !oldFinishesFirst {
            loader.succeed(0, batch: batch(days: 7, total: 70))
            await old.value
        }
        #expect(coordinator.snapshot.loadedDays == 1)
        #expect(coordinator.snapshot.batch?.totalAvailable == 10)
        #expect(coordinator.snapshot.revision == 1)
        #expect(coordinator.snapshot.matchesSelection)
        #expect(!coordinator.snapshot.isRefreshing)
        #expect(loader.cancelledOnCompletion[0] == true)
    }

    @Test func switchingBackRejectsOldSameRangeSuccessAndObsoleteFailure() async throws {
        let loader = ControlledProjectLoader()
        let coordinator = ProjectRefreshCoordinator(loader: { try await loader.load($0) })
        let first = try #require(coordinator.requestRefresh(days: 7))
        await loader.waitForCalls(1)
        let second = try #require(coordinator.requestRefresh(days: 1))
        await loader.waitForCalls(2)
        let third = try #require(coordinator.requestRefresh(days: 7))
        await loader.waitForCalls(3)
        loader.succeed(2, batch: batch(days: 7, total: 77))
        await third.value
        loader.succeed(0, batch: batch(days: 7, total: 70))
        loader.fail(1, error: URLError(.timedOut))
        await first.value
        await second.value
        #expect(coordinator.snapshot.batch?.totalAvailable == 77)
        #expect(coordinator.snapshot.loadedDays == 7)
        #expect(coordinator.snapshot.error == nil)
        #expect(coordinator.snapshot.revision == 1)
        #expect(!coordinator.snapshot.isRefreshing)
    }

    @Test(arguments: [false, true])
    func callerCancellationDoesNotCancelOrLoseLoad(cancelBeforeRegistration: Bool) async {
        let loader = ControlledProjectLoader()
        let coordinator = ProjectRefreshCoordinator(loader: { try await loader.load($0) })
        let caller = Task { await coordinator.refresh(days: 1) }
        if cancelBeforeRegistration { caller.cancel() }
        await loader.waitForCalls(1)
        if !cancelBeforeRegistration { caller.cancel() }
        loader.succeed(0, batch: batch(days: 1, total: 10))
        await caller.value
        #expect(loader.cancelledOnStart == [false])
        #expect(loader.cancelledOnCompletion[0] == false)
        #expect(coordinator.snapshot.loadedDays == 1)
        #expect(coordinator.snapshot.matchesSelection)
        #expect(coordinator.snapshot.error == nil)
    }

    @Test(arguments: [1, 7])
    func failureRetainsCompletePriorRangeAndRetryReplacesIt(selectedDays: Int) async throws {
        let loader = ControlledProjectLoader()
        let timestamp = timestamp
        let coordinator = ProjectRefreshCoordinator(loader: { try await loader.load($0) }, now: { timestamp })
        let first = try #require(coordinator.requestRefresh(days: 7))
        await loader.waitForCalls(1)
        loader.succeed(0, batch: batch(days: 7, total: 70))
        await first.value
        let failed = try #require(coordinator.requestRefresh(days: selectedDays))
        await loader.waitForCalls(2)
        #expect(coordinator.snapshot.batch?.totalAvailable == 70)
        #expect(coordinator.snapshot.loadedDays == 7)
        #expect(coordinator.snapshot.matchesSelection == (selectedDays == 7))
        loader.fail(1, error: URLError(.timedOut))
        await failed.value
        #expect(coordinator.snapshot.batch?.totalAvailable == 70)
        #expect(coordinator.snapshot.updatedAt == timestamp)
        #expect(coordinator.snapshot.revision == 1)
        #expect(coordinator.snapshot.error != nil)
        #expect(!coordinator.snapshot.isRefreshing)

        let retry = try #require(coordinator.requestRefresh())
        await loader.waitForCalls(3)
        #expect(coordinator.snapshot.error == nil)
        loader.succeed(2, batch: batch(days: selectedDays, total: 20))
        await retry.value
        #expect(coordinator.snapshot.loadedDays == selectedDays)
        #expect(coordinator.snapshot.batch?.totalAvailable == 20)
        #expect(coordinator.snapshot.matchesSelection)
        #expect(coordinator.snapshot.revision == 2)
    }

    @Test(arguments: [false, true])
    func cancellationIsNotDisplayedAsFailureAndCanRetry(urlCancellation: Bool) async throws {
        let loader = ControlledProjectLoader()
        let coordinator = ProjectRefreshCoordinator(loader: { try await loader.load($0) })
        let task = try #require(coordinator.requestRefresh())
        await loader.waitForCalls(1)
        loader.fail(0, error: urlCancellation ? URLError(.cancelled) : CancellationError())
        await task.value
        #expect(coordinator.snapshot.error == nil)
        #expect(!coordinator.snapshot.isRefreshing)
        #expect(coordinator.snapshot.loadedDays == nil)
        let retry = try #require(coordinator.requestRefresh())
        await loader.waitForCalls(2)
        loader.succeed(1, batch: batch(days: 7, total: 70))
        await retry.value
        #expect(coordinator.snapshot.matchesSelection)
    }

    @Test(arguments: [false, true])
    func disableClearsEverythingAndReenableRejectsPreviousGeneration(oldFails: Bool) async throws {
        let loader = ControlledProjectLoader()
        let coordinator = ProjectRefreshCoordinator(loader: { try await loader.load($0) })
        let first = try #require(coordinator.requestRefresh())
        await loader.waitForCalls(1)
        loader.succeed(0, batch: batch(days: 7, total: 70))
        await first.value
        let old = try #require(coordinator.requestRefresh())
        await loader.waitForCalls(2)
        coordinator.setEnabled(false)
        #expect(!coordinator.snapshot.enabled)
        #expect(coordinator.snapshot.batch == nil)
        #expect(coordinator.snapshot.loadedDays == nil)
        #expect(coordinator.snapshot.updatedAt == nil)
        #expect(coordinator.snapshot.error == nil)
        #expect(!coordinator.snapshot.matchesSelection)
        #expect(!coordinator.snapshot.isRefreshing)
        #expect(coordinator.snapshot.revision == 2)
        coordinator.setEnabled(true)
        await loader.waitForCalls(3)
        let latest = try #require(coordinator.requestRefresh()) // Shares the automatic enable load.
        if oldFails { loader.fail(1, error: URLError(.timedOut)) }
        else { loader.succeed(1, batch: batch(days: 7, total: 700)) }
        await old.value
        #expect(coordinator.snapshot.batch == nil)
        #expect(coordinator.snapshot.error == nil)
        #expect(coordinator.snapshot.isRefreshing)
        loader.succeed(2, batch: batch(days: 7, total: 77))
        await latest.value
        #expect(loader.days == [7, 7, 7])
        #expect(coordinator.snapshot.batch?.totalAvailable == 77)
        #expect(coordinator.snapshot.matchesSelection)
        #expect(coordinator.snapshot.revision == 4)
    }

    @Test func disabledLoadCannotPublishOrScheduleAnotherRequest() async throws {
        let loader = ControlledProjectLoader()
        let coordinator = ProjectRefreshCoordinator(loader: { try await loader.load($0) })
        let old = try #require(coordinator.requestRefresh(days: 7))
        await loader.waitForCalls(1)
        coordinator.setEnabled(false)
        await coordinator.refresh(days: 1)
        loader.succeed(0, batch: batch(days: 7, total: 70))
        await old.value
        #expect(loader.days == [7])
        #expect(!coordinator.snapshot.enabled)
        #expect(coordinator.snapshot.selectedDays == 1)
        #expect(coordinator.snapshot.batch == nil)
        #expect(coordinator.snapshot.error == nil)
        #expect(!coordinator.snapshot.isRefreshing)
    }

    @Test func firstLoadFailureDoesNotClaimToHaveRetainedResults() async throws {
        let loader = ControlledProjectLoader()
        let coordinator = ProjectRefreshCoordinator(loader: { try await loader.load($0) })
        let task = try #require(coordinator.requestRefresh())
        await loader.waitForCalls(1)
        loader.fail(0, error: URLError(.cannotConnectToHost))
        await task.value
        #expect(coordinator.snapshot.error != nil)
        #expect(coordinator.snapshot.error?.contains("已有结果保留") == false)
        #expect(coordinator.snapshot.batch == nil)
        #expect(coordinator.snapshot.loadedDays == nil)
        #expect(coordinator.snapshot.updatedAt == nil)
        #expect(coordinator.snapshot.revision == 0)
        #expect(!coordinator.snapshot.matchesSelection)
        #expect(!coordinator.snapshot.isRefreshing)
    }

    @Test func disabledSelectionIsRememberedAndEnableLoadsIt() async throws {
        let loader = ControlledProjectLoader()
        let coordinator = ProjectRefreshCoordinator(enabled: false, loader: { try await loader.load($0) })
        await coordinator.refresh(days: 1)
        #expect(coordinator.snapshot.selectedDays == 1)
        #expect(!coordinator.snapshot.isRefreshing)
        #expect(loader.days.isEmpty)
        coordinator.setEnabled(true)
        let task = try #require(coordinator.requestRefresh())
        await loader.waitForCalls(1)
        loader.succeed(0, batch: batch(days: 1, total: 10))
        await task.value
        #expect(loader.days == [1])
        #expect(coordinator.snapshot.matchesSelection)
    }

    @Test func sameSelectionSharesLoadAndIdleRefreshLoadsAgain() async throws {
        let loader = ControlledProjectLoader()
        let coordinator = ProjectRefreshCoordinator(loader: { try await loader.load($0) })
        let first = try #require(coordinator.requestRefresh())
        await loader.waitForCalls(1)
        let shared = try #require(coordinator.requestRefresh(days: 7))
        loader.succeed(0, batch: batch(days: 7, total: 70))
        await first.value
        await shared.value
        #expect(loader.days == [7])
        let fresh = try #require(coordinator.requestRefresh())
        await loader.waitForCalls(2)
        loader.succeed(1, batch: batch(days: 7, total: 77))
        await fresh.value
        #expect(loader.days == [7, 7])
        #expect(coordinator.snapshot.batch?.totalAvailable == 77)
        #expect(coordinator.snapshot.revision == 2)
    }

    private func batch(days: Int, total: Int) -> MagpieClient.Batch {
        MagpieClient.Batch(
            requests: [ProjectRequest(date: timestamp, agent: "fixture", sessionID: "session",
                                      projectPath: "/work/fixture", milliseconds: 1)],
            isTruncated: true, totalAvailable: total, projectPaths: ["/work/fixture"],
            sessionStats: [ProjectSessionStats(count: total - 3, projectPath: "/work/fixture", sessionID: "session")],
            localSessions: [LocalProjectSession(sessionID: "local", projectPath: "/work/fixture", lastDay: "2023-11-14")],
            recoveredRequests: 2, recoveryComplete: false, summarySessionCount: 1,
            period: days == 1 ? "today" : "7d", since: timestamp
        )
    }
}

/// Explicit handshakes control every start/completion: no sleeps, polling or network.
/// Intentionally ignores cancellation so stale-write protection is actually exercised.
@MainActor
private final class ControlledProjectLoader {
    private(set) var days: [Int] = []
    private(set) var cancelledOnStart: [Bool] = []
    private(set) var cancelledOnCompletion: [Int: Bool] = [:]
    private var pending: [Int: CheckedContinuation<MagpieClient.Batch, Error>] = [:]
    private var waiters: [(Int, CheckedContinuation<Void, Never>)] = []

    func load(_ days: Int) async throws -> MagpieClient.Batch {
        let index = self.days.count
        self.days.append(days)
        cancelledOnStart.append(Task.isCancelled)
        defer { cancelledOnCompletion[index] = Task.isCancelled }
        return try await withCheckedThrowingContinuation { continuation in
            pending[index] = continuation
            let ready = waiters.filter { $0.0 <= self.days.count }
            waiters.removeAll { $0.0 <= self.days.count }
            for (_, waiter) in ready { waiter.resume() }
        }
    }

    func waitForCalls(_ count: Int) async {
        if days.count >= count { return }
        await withCheckedContinuation { waiters.append((count, $0)) }
    }

    func succeed(_ index: Int, batch: MagpieClient.Batch) {
        pending.removeValue(forKey: index)!.resume(returning: batch)
    }

    func fail(_ index: Int, error: Error) {
        pending.removeValue(forKey: index)!.resume(throwing: error)
    }
}
