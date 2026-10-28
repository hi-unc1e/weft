import Foundation
import Testing
@testable import WeftKit

/// Answers every request with `StubProtocol.reply` and keeps the last request.
private final class StubProtocol: URLProtocol {
    nonisolated(unsafe) static var reply: (status: Int, body: String) = (200, "")
    nonisolated(unsafe) static var lastRequest: URLRequest?
    nonisolated(unsafe) static var lastBody: Data?

    nonisolated(unsafe) static var requests = 0

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.requests += 1
        Self.lastRequest = request
        Self.lastBody = request.httpBodyStream.map { stream in
            stream.open()
            defer { stream.close() }
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                data.append(buffer, count: count)
            }
            return data
        } ?? request.httpBody
        let response = HTTPURLResponse(url: request.url!, statusCode: Self.reply.status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(Self.reply.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@Suite(.serialized)
struct RemoteModelTests {
    let categories = CategoryDefinition.defaults

    private func classifier(apiKey: String = "sk-test") -> OpenAICompatibleClassifier {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubProtocol.self]
        return OpenAICompatibleClassifier(
            config: RemoteModelConfig(baseURL: "https://api.example.com/v1/", model: "small-model", apiKey: apiKey),
            session: URLSession(configuration: configuration)
        )
    }

    private func chatReply(_ content: String) -> String {
        let escaped = String(data: try! JSONEncoder().encode(content), encoding: .utf8)!
        return #"{"choices": [{"message": {"role": "assistant", "content": \#(escaped)}}]}"#
    }

    @Test func endpointAcceptsTheUsualBaseURLs() {
        func endpoint(_ base: String) -> String? {
            RemoteModelConfig(baseURL: base, model: "m", apiKey: "").endpoint?.absoluteString
        }
        #expect(endpoint("https://api.openai.com/v1") == "https://api.openai.com/v1/chat/completions")
        #expect(endpoint(" http://localhost:11434/v1/ ") == "http://localhost:11434/v1/chat/completions")
        #expect(endpoint("https://openrouter.ai/api/v1/chat/completions") == "https://openrouter.ai/api/v1/chat/completions")
        #expect(endpoint("api.openai.com/v1") == nil)
        #expect(endpoint("") == nil)
    }

    @Test func availabilityNeedsAURLAndAModelButNoKey() {
        #expect(OpenAICompatibleClassifier(config: .init(baseURL: "http://localhost:1234/v1", model: "qwen3", apiKey: "")).availability() == .available)
        #expect(OpenAICompatibleClassifier(config: .init(baseURL: "http://localhost:1234/v1", model: " ", apiKey: "")).availability() != .available)
        #expect(OpenAICompatibleClassifier(config: .init(baseURL: "nonsense", model: "qwen3", apiKey: "")).availability() != .available)
    }

    @Test func parsesRepliesWrappedInProseOrFences() throws {
        let fenced = "```json\n{\"category\": \"design\", \"confidence\": \"High\"}\n```"
        #expect(try OpenAICompatibleClassifier.parseClassification(fenced, candidates: categories)
                == AIClassification(categoryKey: "design", confidence: .high))
        let byName = #"Sure! {"category": "Customer Support"}"#
        #expect(try OpenAICompatibleClassifier.parseClassification(byName, candidates: categories)
                == AIClassification(categoryKey: "customer_support", confidence: .low))
        #expect(throws: (any Error).self) {
            try OpenAICompatibleClassifier.parseClassification(#"{"category": "cooking"}"#, candidates: categories)
        }
        #expect(throws: (any Error).self) {
            try OpenAICompatibleClassifier.parseClassification("code", candidates: categories)
        }
    }

    @Test func classifySendsAChatRequestAndReadsTheAnswer() async throws {
        StubProtocol.reply = (200, chatReply("<think>Xcode is an IDE.</think>\n{\"category\": \"code\", \"confidence\": \"high\"}"))
        let result = try await classifier().classify(ActivityContext(bundleID: "com.example.ide", appName: "Some IDE"), categories: categories)
        #expect(result == AIClassification(categoryKey: "code", confidence: .high))

        let request = try #require(StubProtocol.lastRequest)
        #expect(request.url?.absoluteString == "https://api.example.com/v1/chat/completions")
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer sk-test")
        let body = try #require(StubProtocol.lastBody.flatMap { try JSONSerialization.jsonObject(with: $0) as? [String: Any] })
        #expect(body["model"] as? String == "small-model")
        let messages = try #require(body["messages"] as? [[String: String]])
        #expect(messages.map { $0["role"] } == ["system", "user"])
        #expect(messages[1]["content"]?.contains("Some IDE") == true)
    }

    @Test func noKeyMeansNoAuthorizationHeader() async throws {
        StubProtocol.reply = (200, chatReply("Wrote the release notes."))
        let text = try await classifier(apiKey: "").describeActivity("facts", language: "English")
        #expect(text == "Wrote the release notes.")
        #expect(StubProtocol.lastRequest?.value(forHTTPHeaderField: "Authorization") == nil)
    }

    @Test func serverErrorsCarryTheirMessage() async {
        StubProtocol.reply = (401, #"{"error": {"message": "Incorrect API key provided."}}"#)
        do {
            _ = try await classifier().summarize("facts")
            Issue.record("expected an error")
        } catch {
            #expect(error.localizedDescription == "The server answered 401: 请求失败，请检查模型名称、接口配置或服务商状态。")
        }
    }
    @Test func rejectsCredentialsQueriesAndFragmentsInBaseURL() {
        for base in ["https://user:secret@example.com/v1", "https://example.com/v1?key=secret", "https://example.com/v1#fragment"] {
            #expect(RemoteModelConfig(baseURL: base, model: "m", apiKey: "").endpoint == nil)
        }
    }

    @Test func transientFailuresRetryAtMostThreeTimes() async {
        StubProtocol.reply = (503, "{}")
        StubProtocol.requests = 0
        do { _ = try await classifier().summarize("facts"); Issue.record("expected failure") }
        catch { #expect(StubProtocol.requests == 3) }
    }

    @Test func authenticationFailuresAreNotRetriedOrEchoed() async {
        StubProtocol.reply = (401, #"{"error":{"message":"sensitive-provider-response"}}"#)
        StubProtocol.requests = 0
        do { _ = try await classifier().summarize("facts"); Issue.record("expected failure") }
        catch {
            #expect(StubProtocol.requests == 1)
            #expect(!error.localizedDescription.contains("sensitive-provider-response"))
        }
    }

    @Test func malformedAndEmptyAnswersDoNotRetry() async {
        for body in ["{}", chatReply(""), chatReply("not json") ] {
            StubProtocol.reply = (200, body)
            StubProtocol.requests = 0
            do {
                _ = try await classifier().classify(ActivityContext(bundleID: "unknown", appName: "unknown"), categories: categories)
                Issue.record("expected invalid response")
            } catch { #expect(StubProtocol.requests == 1) }
        }
    }

}
