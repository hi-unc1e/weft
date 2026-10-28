import Testing
@testable import WeftKit

struct LocalModelTests {
    @Test func olderSystemsHaveAnUnavailableBackendWithoutLoadingAppleModels() async {
        if #available(macOS 26.0, *) { return }
        let model = LocalModel.make()
        if case .unavailable(let reason) = model.availability() { #expect(reason.contains("macOS 26")) }
        else { Issue.record("Local model must be unavailable on macOS 15") }
        await #expect(throws: (any Error).self) { try await model.summarize("test") }
    }
}
