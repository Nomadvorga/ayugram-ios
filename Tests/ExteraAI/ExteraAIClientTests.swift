import Foundation
import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// Compiled with the exact production store/settings/client. Never read the real
// application's shared preferences or Keychain from this host test process.
let APP_GROUP_IDENTIFIER = "ExteraAIClientTests.\(UUID().uuidString)"

private final class ExteraAIURLProtocol: URLProtocol, @unchecked Sendable {
    static var onStart: ((ExteraAIURLProtocol) -> Void)?
    static var onStop: (() -> Void)?
    override class func canInit(with request: URLRequest) -> Bool { return true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { return request }
    override func startLoading() { Self.onStart?(self) }
    override func stopLoading() { Self.onStop?() }

    func respond(_ body: String, status: Int = 200, type: String = "application/json", finish: Bool = true) {
        let response = HTTPURLResponse(url: self.request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": type])!
        self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        self.client?.urlProtocol(self, didLoad: Data(body.utf8))
        if finish { self.client?.urlProtocolDidFinishLoading(self) }
    }

    func body() -> [String: Any] {
        let data: Data
        if let body = self.request.httpBody { data = body }
        else if let stream = self.request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var result = Data()
            var bytes = [UInt8](repeating: 0, count: 4096)
            let capacity = bytes.count
            while stream.hasBytesAvailable {
                let count = stream.read(&bytes, maxLength: capacity)
                if count <= 0 { break }
                result.append(contentsOf: bytes.prefix(count))
            }
            data = result
        } else { data = Data() }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }
}

final class ExteraAIClientTests: XCTestCase {
    private let service = ExteraAIService(name: "Fixture", endpoint: "https://fixture.invalid/v1", model: "fixture-model")

    private func configuration() -> URLSessionConfiguration {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ExteraAIURLProtocol.self]
        return config
    }

    override func tearDown() {
        ExteraAIURLProtocol.onStart = nil
        ExteraAIURLProtocol.onStop = nil
        super.tearDown()
    }

    func testLegacyConfigurationUsesExactAndroidGenerationDefaults() throws {
        let config = try JSONDecoder().decode(ExteraAIConfiguration.self, from: Data("{}".utf8))
        XCTAssertTrue(config.responseStreaming)
        XCTAssertFalse(config.showResponseOnly)
        XCTAssertTrue(config.insertAsQuote)
        XCTAssertEqual(config.temperature, 1)
        XCTAssertTrue(config.replacesTelegramSummaries(isPremium: false))
        XCTAssertFalse(config.replacesTelegramSummaries(isPremium: true))
        var explicit = config
        explicit.showResponseOnly = true
        explicit.insertAsQuote = false
        explicit.replaceTelegramSummaries = true
        explicit.temperature = 1.4
        let roundTrip = try JSONDecoder().decode(ExteraAIConfiguration.self, from: JSONEncoder().encode(explicit))
        XCTAssertEqual(explicit, roundTrip)
        XCTAssertTrue(roundTrip.replacesTelegramSummaries(isPremium: true))
        explicit.replaceTelegramSummaries = false
        let disabled = try JSONDecoder().decode(ExteraAIConfiguration.self, from: JSONEncoder().encode(explicit))
        XCTAssertFalse(disabled.replacesTelegramSummaries(isPremium: false))
    }

    func testResponseOnlyAndQuoteArePresentationPoliciesWithUTF16Ranges() {
        let full = ExteraAIResponsePresentation(prompt: "Hello 😀", response: "Answer\nNext", showResponseOnly: false, insertAsQuote: true)
        XCTAssertEqual(full.text, "→ Hello 😀\n\nAnswer\nNext")
        XCTAssertEqual(full.quoteRange, 0..<full.text.utf16.count)
        XCTAssertEqual(full.markdownText, "> → Hello 😀\n> \n> Answer\n> Next")
        let answer = ExteraAIResponsePresentation(prompt: "Private question", response: "Only answer", showResponseOnly: true, insertAsQuote: false)
        XCTAssertEqual(answer.text, "Only answer")
        XCTAssertNil(answer.quoteRange)
        XCTAssertEqual(answer.markdownText, "Only answer")
        let quotedAnswer = ExteraAIResponsePresentation(prompt: "Private question", response: "😀 Answer", showResponseOnly: true, insertAsQuote: true)
        XCTAssertEqual(quotedAnswer.text, "😀 Answer")
        XCTAssertEqual(quotedAnswer.quoteRange, 0..<9)
        XCTAssertEqual(quotedAnswer.markdownText, "> 😀 Answer")
        let unquotedFull = ExteraAIResponsePresentation(prompt: "Question", response: "Answer", showResponseOnly: false, insertAsQuote: false)
        XCTAssertEqual(unquotedFull.markdownText, "→ Question\n\nAnswer")
        XCTAssertNil(unquotedFull.quoteRange)
        XCTAssertEqual(ExteraAIResponsePresentation(prompt: "", response: "Answer", showResponseOnly: false, insertAsQuote: false).text, "Answer")
    }

    func testTranscriptKeepsUnsavedPromptAndDeduplicatesOnlyTheSavedResponse() {
        let user = ExteraAIMessage(role: .user, content: "Question")
        let answer = ExteraAIMessage(role: .assistant, content: "Answer")
        func sections(_ history: [ExteraAIMessage], response: String? = "Answer", status: String? = nil, savedId: String? = nil, only: Bool = false) -> [String] {
            return ExteraAITranscriptPresentation.sections(history: history, prompt: "Question", response: response, status: status, savedResponseId: savedId, showResponseOnly: only, userLabel: "You", assistantLabel: "AI")
        }
        XCTAssertEqual(sections([]), ["You:\nQuestion", "AI:\nAnswer"])
        XCTAssertEqual(sections([user, answer], savedId: answer.id), ["You:\nQuestion", "AI:\nAnswer"])
        XCTAssertEqual(sections([], savedId: answer.id), ["You:\nQuestion", "AI:\nAnswer"])
        XCTAssertEqual(sections([user, answer], savedId: answer.id, only: true), ["Answer"])
        XCTAssertEqual(sections([user, answer], response: nil, status: "Generating", only: true), ["Generating"])
        XCTAssertEqual(sections([], response: "Partial", status: "Stopped"), ["You:\nQuestion", "AI:\nPartial", "Stopped"])
        XCTAssertEqual(sections([], response: nil, status: "Failed"), ["You:\nQuestion", "Failed"])
    }

    func testChatRequestPreservesRoleHistoryPromptAndExactTemperature() throws {
        let finished = self.expectation(description: "Validated requests complete")
        finished.expectedFulfillmentCount = 3
        ExteraAIURLProtocol.onStart = { mock in
            let body = mock.body()
            XCTAssertEqual(mock.request.url?.absoluteString, "https://fixture.invalid/v1/chat/completions")
            XCTAssertEqual(mock.request.value(forHTTPHeaderField: "Authorization"), "Bearer test-key")
            XCTAssertEqual(body["model"] as? String, "fixture-model")
            XCTAssertEqual(body["stream"] as? Bool, false)
            let messages = body["messages"] as? [[String: String]]
            let prompt = messages?.last?["content"] ?? ""
            let expectedTemperature = ["Exact original prompt 0.0": 0.0, "Exact original prompt 1.4": 1.4, "Exact original prompt 2.0": 2.0][prompt]
            XCTAssertNotNil(expectedTemperature)
            XCTAssertEqual(body["temperature"] as? Double, expectedTemperature)
            XCTAssertEqual(messages, [["role": "system", "content": "Instruction"], ["role": "user", "content": "Earlier"], ["role": "assistant", "content": "Previous answer"], ["role": "user", "content": prompt]])
            XCTAssertNil(body["showResponseOnly"])
            XCTAssertNil(body["insertAsQuote"])
            mock.respond(#"{"choices":[{"message":{"content":"Answer"},"finish_reason":"stop"}]}"#)
        }
        var requests: [ExteraAIRequest] = []
        for temperature in [0.0, 1.4, 2.0] {
            requests.append(try ExteraAIClient.generate(service: self.service, apiKey: "test-key", role: .init(name: "Role", prompt: "Instruction"), prompt: "Exact original prompt \(temperature)", history: [.init(role: .user, content: "Earlier"), .init(role: .assistant, content: "Previous answer")], temperature: temperature, stream: false, configuration: self.configuration(), completion: { result in
                XCTAssertTrue(Thread.isMainThread)
                XCTAssertEqual(try? result.get(), "Answer")
                finished.fulfill()
            }))
        }
        self.wait(for: [finished], timeout: 3)
        requests.forEach { $0.cancel() }
    }

    func testNativeSummaryValidatesRoutingReadinessAndPolicyChangesBeforeTransport() throws {
        var config = ExteraAIConfiguration()
        XCTAssertThrowsError(try ExteraAISummaryPlan(configuration: config, isPremium: false, text: "Source", language: nil, contentAllowed: true))
        config.services = [self.service]
        let plan = try ExteraAISummaryPlan(configuration: config, isPremium: false, text: "Source", language: "ru", contentAllowed: true)
        XCTAssertTrue(plan.matches(configuration: config, isPremium: false))
        XCTAssertFalse(plan.matches(configuration: config, isPremium: true))
        XCTAssertThrowsError(try ExteraAISummaryPlan(configuration: config, isPremium: true, text: "Source", language: nil, contentAllowed: true))
        XCTAssertThrowsError(try ExteraAISummaryPlan(configuration: config, isPremium: false, text: "Source", language: nil, contentAllowed: false))
        XCTAssertThrowsError(try ExteraAISummaryPlan(configuration: config, isPremium: false, text: " ", language: nil, contentAllowed: true))
        XCTAssertThrowsError(try ExteraAISummaryPlan(configuration: config, isPremium: false, text: "Source", language: String(repeating: "a", count: 101), contentAllowed: true))
        var changed = config
        changed.replaceTelegramSummaries = false
        XCTAssertFalse(plan.matches(configuration: changed, isPremium: false))
        changed = config
        changed.showSummaries = false
        XCTAssertFalse(plan.matches(configuration: changed, isPremium: false))
        changed = config
        changed.services[0].model = "Other model"
        XCTAssertFalse(plan.matches(configuration: changed, isPremium: false))
        changed = config
        changed.services[0].endpoint = "https://another.invalid/v1"
        XCTAssertFalse(plan.matches(configuration: changed, isPremium: false))
        changed = config
        changed.services = []
        XCTAssertFalse(plan.matches(configuration: changed, isPremium: false))
        config.replaceTelegramSummaries = true
        XCTAssertNoThrow(try ExteraAISummaryPlan(configuration: config, isPremium: true, text: "Source", language: nil, contentAllowed: true))
        config.services[0].model = ""
        XCTAssertThrowsError(try ExteraAISummaryPlan(configuration: config, isPremium: true, text: "Source", language: nil, contentAllowed: true))
    }

    func testNativeSummaryUsesIsolatedInstructionsAndExactSourceForBothProviderAPIs() throws {
        let finished = self.expectation(description: "Isolated native summaries")
        finished.expectedFulfillmentCount = 2
        let source = "😀 Message to summarize\nKeep the source verbatim"
        ExteraAIURLProtocol.onStart = { mock in
            let body = mock.body()
            XCTAssertEqual(body["temperature"] as? Double, 0.6)
            XCTAssertEqual(body["stream"] as? Bool, false)
            var instructions: String?
            if mock.request.url?.path.hasSuffix("/responses") == true {
                XCTAssertEqual(body["input"] as? [[String: String]], [["role": "user", "content": source]])
                XCTAssertEqual(body["store"] as? Bool, false)
                instructions = body["instructions"] as? String
                mock.respond(#"{"status":"completed","output":[{"type":"message","content":[{"type":"output_text","text":"Summary"}]}]}"#)
            } else {
                let messages = body["messages"] as? [[String: String]]
                XCTAssertEqual(messages?.count, 2)
                XCTAssertEqual(messages?.last, ["role": "user", "content": source])
                XCTAssertEqual(messages?.first?["role"], "system")
                instructions = messages?.first?["content"]
                mock.respond(#"{"choices":[{"message":{"content":"Summary"},"finish_reason":"stop"}]}"#)
            }
            XCTAssertTrue(instructions?.contains("Summarize the supplied text") == true)
            XCTAssertTrue(instructions?.contains("ru") == true)
            XCTAssertFalse(instructions?.contains("Conversation role must not be sent") == true)
            XCTAssertNil(body["showResponseOnly"])
            XCTAssertNil(body["insertAsQuote"])
        }
        var requests: [ExteraAIRequest] = []
        for endpoint in ["https://fixture.invalid/v1", "https://fixture.invalid/v1/responses"] {
            var config = ExteraAIConfiguration()
            var service = self.service
            service.endpoint = endpoint
            config.services = [service]
            config.roles = [.init(id: "conversation", name: "Conversation", prompt: "Conversation role must not be sent")]
            config.selectedRoleId = "conversation"
            config.temperature = 0.6
            config.responseStreaming = false
            config.showResponseOnly = true
            config.insertAsQuote = true
            let plan = try ExteraAISummaryPlan(configuration: config, isPremium: false, text: source, language: "ru", contentAllowed: true)
            XCTAssertEqual(plan.text, source)
            requests.append(try plan.generate(apiKey: "test-key", configuration: self.configuration(), completion: { result in
                XCTAssertEqual(try? result.get(), "Summary")
                finished.fulfill()
            }))
        }
        self.wait(for: [finished], timeout: 3)
        requests.forEach { $0.cancel() }
    }

    func testResponsesAPIDoesNotStoreAndKeepsInstructionOutsideInput() throws {
        let finished = self.expectation(description: "Responses result")
        var service = self.service
        service.endpoint = "https://fixture.invalid/v1/responses"
        ExteraAIURLProtocol.onStart = { mock in
            let body = mock.body()
            XCTAssertEqual(body["instructions"] as? String, "Instruction")
            XCTAssertEqual(body["store"] as? Bool, false)
            XCTAssertEqual(body["temperature"] as? Double, 1.7)
            XCTAssertEqual(body["input"] as? [[String: String]], [["role": "user", "content": "Question"]])
            XCTAssertNil(body["messages"])
            mock.respond(#"{"status":"completed","output":[{"type":"message","content":[{"type":"output_text","text":"Response answer"}]}]}"#)
        }
        let request = try ExteraAIClient.generate(service: service, apiKey: "", role: .init(name: "Role", prompt: "Instruction"), prompt: "Question", temperature: 1.7, stream: false, configuration: self.configuration(), completion: { result in
            XCTAssertEqual(try? result.get(), "Response answer")
            finished.fulfill()
        })
        self.wait(for: [finished], timeout: 3)
        request.cancel()
    }

    func testSSEFiltersReasoningAndCompletesWithoutWaitingForSocketClose() throws {
        let finished = self.expectation(description: "SSE done event")
        ExteraAIURLProtocol.onStart = { mock in
            XCTAssertEqual(mock.body()["stream"] as? Bool, true)
            mock.respond("data: {\"choices\":[{\"delta\":{\"content\":\"<think>hidden</think>Answer\"}}]}\n\ndata: [DONE]\n\n", type: "text/event-stream", finish: false)
        }
        let request = try ExteraAIClient.generate(service: self.service, apiKey: "", role: nil, prompt: "Question", stream: true, configuration: self.configuration(), update: { value in
            XCTAssertFalse(value.contains("hidden"))
        }, completion: { result in
            XCTAssertEqual(try? result.get(), "Answer")
            finished.fulfill()
        })
        self.wait(for: [finished], timeout: 3)
        request.cancel()
    }

    func testServiceReasoningOptionReachesOnlyTheSupportedProviderField() throws {
        let finished = self.expectation(description: "Reasoning preferences")
        finished.expectedFulfillmentCount = 2
        ExteraAIURLProtocol.onStart = { mock in
            let body = mock.body()
            if body["model"] as? String == "disabled" {
                XCTAssertEqual(body["reasoning"] as? [String: String], ["effort": "none"])
            } else {
                XCTAssertEqual(body["model"] as? String, "enabled")
                XCTAssertNil(body["reasoning"])
            }
            XCTAssertNil(body["reasoning_effort"])
            mock.respond(#"{"choices":[{"message":{"content":"Answer"},"finish_reason":"stop"}]}"#)
        }
        var requests: [ExteraAIRequest] = []
        for enabled in [false, true] {
            let service = ExteraAIService(name: "OpenRouter fixture", endpoint: "https://openrouter.ai/api/v1", model: enabled ? "enabled" : "disabled", reasoningEnabled: enabled)
            requests.append(try ExteraAIClient.generate(service: service, apiKey: "", role: nil, prompt: "Question", stream: false, configuration: self.configuration(), completion: { result in
                XCTAssertEqual(try? result.get(), "Answer")
                finished.fulfill()
            }))
        }
        self.wait(for: [finished], timeout: 3)
        requests.forEach { $0.cancel() }
    }

    func testAuthenticationErrorIsRedactedAndNeverRetried() throws {
        let finished = self.expectation(description: "Authentication failure")
        var count = 0
        ExteraAIURLProtocol.onStart = { mock in
            count += 1
            mock.respond(#"{"error":{"message":"Rejected test-secret temperature"}}"#, status: 401)
        }
        let request = try ExteraAIClient.generate(service: self.service, apiKey: "test-secret", role: nil, prompt: "Question", configuration: self.configuration(), completion: { result in
            guard case let .failure(.http(code, detail)) = result else { XCTFail("Expected HTTP failure"); finished.fulfill(); return }
            XCTAssertEqual(code, 401)
            XCTAssertFalse(detail.contains("test-secret"))
            XCTAssertTrue(detail.contains("[redacted]"))
            finished.fulfill()
        })
        self.wait(for: [finished], timeout: 3)
        XCTAssertEqual(count, 1)
        request.cancel()
    }

    func testRejectedTemperatureRetriesOnlyAfterExplicitProviderError() throws {
        let finished = self.expectation(description: "Retry unsupported temperature")
        var count = 0
        ExteraAIURLProtocol.onStart = { mock in
            count += 1
            if count == 1 {
                XCTAssertEqual(mock.body()["temperature"] as? Double, 1.2)
                mock.respond(#"{"error":{"message":"Unsupported temperature option"}}"#, status: 400)
            } else {
                XCTAssertNil(mock.body()["temperature"])
                mock.respond(#"{"choices":[{"message":{"content":"Answer"},"finish_reason":"stop"}]}"#)
            }
        }
        let request = try ExteraAIClient.generate(service: self.service, apiKey: "", role: nil, prompt: "Question", temperature: 1.2, stream: false, configuration: self.configuration(), completion: { result in
            XCTAssertEqual(try? result.get(), "Answer")
            finished.fulfill()
        })
        self.wait(for: [finished], timeout: 3)
        XCTAssertEqual(count, 2)
        request.cancel()
    }

    func testCancellationHasOneCompletionAndNoSuccessfulOutput() throws {
        let started = self.expectation(description: "Started")
        let finished = self.expectation(description: "Cancelled")
        finished.assertForOverFulfill = true
        ExteraAIURLProtocol.onStart = { _ in started.fulfill() }
        let request = try ExteraAIClient.generate(service: self.service, apiKey: "", role: nil, prompt: "Question", configuration: self.configuration(), completion: { result in
            guard case .failure(.cancelled) = result else { XCTFail("Cancellation returned output"); return }
            finished.fulfill()
        })
        self.wait(for: [started], timeout: 3)
        request.cancel()
        request.cancel()
        self.wait(for: [finished], timeout: 3)
    }

    func testInvalidRequestAndUntrustedEndpointsAreRejectedBeforeTransport() {
        for endpoint in ["http://untrusted.example/v1", "https://user:secret@example.com", "https://example.com/v1?key=secret", "https://example.com/#fragment"] {
            var service = self.service
            service.endpoint = endpoint
            XCTAssertThrowsError(try ExteraAIClient.endpoint(for: service))
        }
        for temperature in [Double.nan, -.infinity, -0.1, 2.1] {
            XCTAssertThrowsError(try ExteraAIClient.generate(service: self.service, apiKey: "", role: nil, prompt: "Question", temperature: temperature, configuration: self.configuration(), completion: { _ in XCTFail("Invalid request started") }))
        }
    }
}
