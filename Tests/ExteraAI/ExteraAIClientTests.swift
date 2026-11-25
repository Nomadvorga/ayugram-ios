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

    func testUserAgentLegacyServiceAndAllPresetsRoundTrip() throws {
        let legacy = #"{"id":"legacy","name":"Existing","endpoint":"https://fixture.invalid/v1","model":"fixture-model","reasoningEnabled":true}"#
        let decoded = try JSONDecoder().decode(ExteraAIService.self, from: Data(legacy.utf8))
        XCTAssertEqual(decoded.userAgentPreset, .default)
        XCTAssertEqual(decoded.customUserAgent, "")
        XCTAssertTrue(decoded.reasoningEnabled)
        XCTAssertNil(try decoded.userAgentPreset.resolvedUserAgent(customValue: ""))
        for preset in ExteraAIUserAgentPreset.allCases {
            var service = decoded
            service.userAgentPreset = preset
            service.customUserAgent = "MyClient/2.0 (iOS)"
            XCTAssertEqual(service, try JSONDecoder().decode(ExteraAIService.self, from: JSONEncoder().encode(service)))
        }
    }

    func testCustomUserAgentRejectsHeaderInjectionAndInvalidValues() throws {
        for invalid in ["", " ", " leading", "trailing ", "client\r\nAuthorization: bad", "client\u{0}", "client\tversion", "клиент", String(repeating: "a", count: 513)] {
            XCTAssertThrowsError(try ExteraAIUserAgentPreset.custom.resolvedUserAgent(customValue: invalid), invalid)
        }
        XCTAssertEqual(try ExteraAIUserAgentPreset.custom.resolvedUserAgent(customValue: String(repeating: "a", count: 512)), String(repeating: "a", count: 512))
        XCTAssertEqual(try ExteraAIUserAgentPreset.custom.resolvedUserAgent(customValue: "Client/2.0 (iOS; arm64)"), "Client/2.0 (iOS; arm64)")
        let before = ExteraAISettings.shared.configuration
        var invalid = self.service
        invalid.userAgentPreset = .custom
        invalid.customUserAgent = "client\r\ninjected: value"
        XCTAssertThrowsError(try ExteraAISettings.shared.update { $0.services = [invalid] })
        XCTAssertEqual(ExteraAISettings.shared.configuration, before)
    }

    func testInvalidUserAgentFailsBothRequestPathsBeforeTransport() throws {
        var service = self.service
        service.userAgentPreset = .custom
        service.customUserAgent = "client\r\ninjected: value"
        ExteraAIURLProtocol.onStart = { _ in XCTFail("An invalid header must never reach transport") }
        XCTAssertThrowsError(try ExteraAIClient.generate(service: service, apiKey: "fixture-key", role: nil, prompt: "hello", configuration: self.configuration(), completion: { _ in XCTFail("Synchronous validation must throw") }))
        XCTAssertThrowsError(try ExteraAIClient.fetchModels(service: service, apiKey: "fixture-key", configuration: self.configuration(), completion: { _ in XCTFail("Synchronous validation must throw") }))
    }

    func testEveryUserAgentIsSentForGenerationAndModelDiscovery() throws {
        let fixtures: [(ExteraAIUserAgentPreset, String)] = [
            (.openCode, "opencode"), (.claudeCode, "claude-cli"), (.zCode, "ZCode"),
            (.codex, "codex_cli_rs"), (.cursor, "Cursor"), (.cline, "Cline"),
            (.rooCode, "RooCode"), (.custom, "MyClient/2.0 (iOS)")
        ]
        for (preset, expected) in fixtures {
            var service = self.service
            service.userAgentPreset = preset
            service.customUserAgent = "MyClient/2.0 (iOS)"
            let generation = self.expectation(description: "generation \(preset.rawValue)")
            ExteraAIURLProtocol.onStart = { transport in
                XCTAssertEqual(transport.request.value(forHTTPHeaderField: "User-Agent"), expected)
                XCTAssertEqual(transport.request.value(forHTTPHeaderField: "Authorization"), "Bearer fixture-key")
                XCTAssertEqual(transport.request.url?.path, "/v1/chat/completions")
                transport.respond(#"{"choices":[{"message":{"content":"hello"}}]}"#)
            }
            let request = try ExteraAIClient.generate(service: service, apiKey: "fixture-key", role: nil, prompt: "hello", stream: false, configuration: self.configuration(), completion: { result in
                if case let .success(text) = result { XCTAssertEqual(text, "hello") } else { XCTFail("Generation failed: \(result)") }
                generation.fulfill()
            })
            withExtendedLifetime(request) { self.wait(for: [generation], timeout: 5) }
            let discovery = self.expectation(description: "models \(preset.rawValue)")
            ExteraAIURLProtocol.onStart = { transport in
                XCTAssertEqual(transport.request.value(forHTTPHeaderField: "User-Agent"), expected)
                XCTAssertEqual(transport.request.value(forHTTPHeaderField: "Authorization"), "Bearer fixture-key")
                XCTAssertEqual(transport.request.url?.path, "/v1/models")
                transport.respond(#"{"data":[{"id":"fixture-model"}]}"#)
            }
            let modelRequest = try ExteraAIClient.fetchModels(service: service, apiKey: "fixture-key", configuration: self.configuration(), completion: { result in
                if case let .success(models) = result { XCTAssertEqual(models, ["fixture-model"]) } else { XCTFail("Model discovery failed: \(result)") }
                discovery.fulfill()
            })
            withExtendedLifetime(modelRequest) { self.wait(for: [discovery], timeout: 5) }
        }
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

    func testRoleSuggestionsAndFreshDefaultsMatchAndroidWithoutPersistingSuggestions() throws {
        let config = try JSONDecoder().decode(ExteraAIConfiguration.self, from: Data("{}".utf8))
        XCTAssertEqual(config, ExteraAIConfiguration())
        XCTAssertTrue(config.roles.isEmpty)
        XCTAssertEqual(config.selectedRole?.id, ExteraAIRole.defaultId)
        XCTAssertEqual(ExteraAIRole.suggestions.map { $0.name }, ["Assistant", "Summarizer", "Proofreader"])
        XCTAssertEqual(ExteraAIRole.suggestions[0].prompt, "You are a helpful personal assistant inside a chat app.\nAdapt to the user's tone, language, and context. Keep answers practical, concise, and easy to act on.\nAsk a clarifying question only when the request is ambiguous enough that answering directly would likely be wrong.")
        XCTAssertEqual(ExteraAIRole.suggestions[1].prompt, "Summarize the provided message or conversation without replying to it.\nPreserve the important facts, decisions, requests, names, dates, and next steps. Omit filler and repeated details.\nKeep the summary under 3 short sentences and under 60 words.")
        XCTAssertEqual(ExteraAIRole.suggestions[2].prompt, "Proofread and improve the user's text while preserving its meaning, language, and intent.\nFix grammar, spelling, punctuation, awkward phrasing, and clarity issues. Keep the original tone unless a cleaner wording is clearly better.\nReturn only the revised text unless the user explicitly asks for explanations.")
        var role = ExteraAIRole.suggestions[0]
        role.prompt = "Local edit"
        XCTAssertNotEqual(role.prompt, ExteraAIRole.suggestions[0].prompt)
        XCTAssertEqual(try JSONDecoder().decode(ExteraAIConfiguration.self, from: JSONEncoder().encode(config)), config)
    }

    func testLegacyRoleEditsAndOmittedNoRoleSelectionSurviveRoundTrip() throws {
        let legacy = #"{"roles":[{"id":"assistant","name":"Assistant","prompt":"My edited legacy instruction"},{"id":"translator","name":"Translator","prompt":"Keep my translation role"}],"selectedRoleId":"assistant","useForTextProcessing":false}"#
        let config = try JSONDecoder().decode(ExteraAIConfiguration.self, from: Data(legacy.utf8))
        XCTAssertEqual(config.selectedRole?.prompt, "My edited legacy instruction")
        XCTAssertEqual(config.roles.count, 2)
        XCTAssertFalse(config.replacesTelegramEditor(isPremium: false))
        XCTAssertEqual(try JSONDecoder().decode(ExteraAIConfiguration.self, from: JSONEncoder().encode(config)), config)
        // Old synthesized Codable omitted nil selectedRoleId, but always encoded roles.
        var none = try JSONDecoder().decode(ExteraAIConfiguration.self, from: Data(#"{"roles":[]}"#.utf8))
        XCTAssertNil(none.selectedRole)
        none = try JSONDecoder().decode(ExteraAIConfiguration.self, from: JSONEncoder().encode(none))
        XCTAssertNil(none.selectedRoleId)
        XCTAssertNil(none.selectedRole)
    }

    func testEditorAutomaticAndExplicitPoliciesUseTheCurrentAccount() throws {
        var config = ExteraAIConfiguration()
        XCTAssertTrue(config.replacesTelegramEditor(isPremium: false))
        XCTAssertFalse(config.replacesTelegramEditor(isPremium: true))
        for value in [false, true] {
            config.useForTextProcessing = value
            let decoded = try JSONDecoder().decode(ExteraAIConfiguration.self, from: JSONEncoder().encode(config))
            XCTAssertEqual(decoded.replacesTelegramEditor(isPremium: false), value)
            XCTAssertEqual(decoded.replacesTelegramEditor(isPremium: true), value)
        }
        config.useForTextProcessing = nil
        let automatic = try JSONDecoder().decode(ExteraAIConfiguration.self, from: JSONEncoder().encode(config))
        XCTAssertNil(automatic.useForTextProcessing)
        XCTAssertTrue(automatic.replacesTelegramEditor(isPremium: false))
    }

    func testRoleCRUDKeepsSelectionStableAndRejectsDuplicateAndStaleEdits() throws {
        var config = ExteraAIConfiguration()
        var role = ExteraAIRole(name: "My role", prompt: "Original instruction")
        try config.saveRole(role, existing: false)
        XCTAssertEqual(config.selectedRoleId, ExteraAIRole.defaultId)
        try config.selectRole(id: role.id)
        role.name = "Renamed"
        role.prompt = "Updated instruction"
        try config.saveRole(role, existing: true)
        XCTAssertEqual(config.selectedRole, role)
        XCTAssertThrowsError(try config.saveRole(.init(name: "Renamed", prompt: "Duplicate"), existing: false))
        XCTAssertThrowsError(try config.saveRole(.init(name: "Assistant", prompt: "Reserved name"), existing: false))
        XCTAssertThrowsError(try config.saveRole(ExteraAIRole.suggestions[0], existing: false))
        XCTAssertThrowsError(try config.selectRole(id: "deleted"))
        let selected = config
        XCTAssertThrowsError(try config.saveRole(.init(name: String(repeating: "😀", count: 33), prompt: "Too long"), existing: false))
        XCTAssertThrowsError(try config.saveRole(.init(name: "Long prompt", prompt: String(repeating: "x", count: 1025)), existing: false))
        XCTAssertEqual(config, selected)
        try config.deleteRole(id: role.id)
        XCTAssertEqual(config.selectedRoleId, ExteraAIRole.defaultId)
        XCTAssertThrowsError(try config.saveRole(role, existing: true))
        XCTAssertTrue(config.roles.isEmpty)
        try config.saveRole(role, existing: false)
        try config.selectRole(id: nil)
        try config.deleteRole(id: role.id)
        XCTAssertNil(config.selectedRoleId)
        XCTAssertThrowsError(try config.deleteRole(id: ExteraAIRole.defaultId))
    }

    func testThrowingRoleMutationDoesNotPublishPartialConfiguration() throws {
        let settings = ExteraAISettings.shared
        let before = settings.configuration
        XCTAssertThrowsError(try settings.update { config in
            config.temperature = 0.2
            try config.selectRole(id: "missing-role")
        })
        XCTAssertEqual(settings.configuration, before)
    }

    func testProviderPresetsMatchReferenceAndDoNotConfigureAServiceOrSecret() throws {
        let presets = ExteraAIService.presets
        XCTAssertEqual(presets.map { $0.name }, ["Gemini", "OpenAI", "OpenRouter", "Perplexity", "Custom"])
        XCTAssertEqual(presets.map { $0.model }, ["gemini-3.5-flash", "gpt-5.4-mini", "openai/gpt-5.4-mini", "perplexity/glm-5.3-flash", ""])
        XCTAssertEqual(try presets.prefix(4).map { try ExteraAIClient.endpoint(for: $0).absoluteString }, ["https://generativelanguage.googleapis.com/v1beta/openai/chat/completions", "https://api.openai.com/v1/chat/completions", "https://openrouter.ai/api/v1/chat/completions", "https://api.perplexity.ai/v1/agent"])
        XCTAssertTrue(presets.allSatisfy { !$0.reasoningEnabled })
        XCTAssertNil(ExteraAIConfiguration().selectedService)
        XCTAssertTrue(ExteraAIConfiguration().services.isEmpty)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(presets)) as? [[String: Any]])
        XCTAssertTrue(object.allSatisfy { $0["apiKey"] == nil && $0["key"] == nil })
    }

    func testProviderPayloadMatrixUsesFixedBudgetAndExactReasoningPolicy() throws {
        let fixtures: [(String, String, String?)] = [
            ("https://api.openai.com/v1", "gpt-5.4-mini", "none"),
            ("https://api.openai.com/v1", "gpt-5", "minimal"),
            ("https://api.openai.com/v1", "gpt-5-chat-latest", nil),
            ("https://api.openai.com/v1", "o3", "low"),
            ("https://generativelanguage.googleapis.com/v1beta", "gemini-2.5-flash", "none"),
            ("https://generativelanguage.googleapis.com/v1beta", "gemini-2.5-pro", "minimal"),
            ("https://generativelanguage.googleapis.com/v1beta", "gemini-3-flash", "minimal"),
            ("https://generativelanguage.googleapis.com/v1beta", "gemini-3-pro", "low"),
            ("https://api.perplexity.ai/v1/agent", "openai/gpt-5.4-mini", "minimal"),
            ("https://api.perplexity.ai/v1/agent", "perplexity/glm-5.3-flash", nil),
            ("https://fixture.invalid/responses", "custom-model", nil)
        ]
        let finished = self.expectation(description: "Provider payload matrix")
        finished.expectedFulfillmentCount = fixtures.count
        ExteraAIURLProtocol.onStart = { mock in
            XCTAssertEqual(mock.request.value(forHTTPHeaderField: "User-Agent"), "opencode")
            let body = mock.body()
            let model = body["model"] as? String
            let fixture = fixtures.first(where: { $0.1 == model })
            let responses = mock.request.url?.path.hasSuffix("/agent") == true || mock.request.url?.path.hasSuffix("/responses") == true
            let effort = responses ? (body["reasoning"] as? [String: String])?["effort"] : body["reasoning_effort"] as? String
            XCTAssertEqual(effort, fixture?.2)
            if responses { XCTAssertNil(body["reasoning_effort"]) } else { XCTAssertNil(body["reasoning"]) }
            let tokenKey = responses ? "max_output_tokens" : (mock.request.url?.host == "api.openai.com" ? "max_completion_tokens" : "max_tokens")
            XCTAssertEqual(body[tokenKey] as? Int, 4096)
            XCTAssertEqual(body["temperature"] as? Double, 1)
            XCTAssertNil(mock.request.value(forHTTPHeaderField: "Authorization"))
            if responses { mock.respond(#"{"status":"completed","output":[{"type":"message","content":[{"type":"output_text","text":"Answer"}]}]}"#) }
            else { mock.respond(#"{"choices":[{"message":{"content":"Answer"},"finish_reason":"stop"}]}"#) }
        }
        var requests: [ExteraAIRequest] = []
        for (endpoint, model, _) in fixtures {
            let service = ExteraAIService(name: "Matrix", endpoint: endpoint, model: model, userAgentPreset: .openCode)
            requests.append(try ExteraAIClient.generate(service: service, apiKey: "", role: ExteraAIConfiguration().selectedRole, prompt: "Question", stream: false, configuration: self.configuration(), completion: { result in
                XCTAssertEqual(try? result.get(), "Answer")
                finished.fulfill()
            }))
        }
        self.wait(for: [finished], timeout: 5)
        requests.forEach { $0.cancel() }
    }

    func testModelDiscoveryUsesDraftEndpointAndKeyAndReturnsSortedUniqueCatalog() throws {
        let finished = self.expectation(description: "Model discovery")
        ExteraAIURLProtocol.onStart = { mock in
            XCTAssertEqual(mock.request.url?.absoluteString, "https://fixture.invalid/v1/models")
            XCTAssertEqual(mock.request.value(forHTTPHeaderField: "Authorization"), "Bearer draft-key")
            XCTAssertNil(mock.request.httpBody)
            mock.respond(#"{"data":[{"id":"z"},{"id":"a"},{"id":"z"},{"id":""},{}]}"#)
        }
        let request = try ExteraAIClient.fetchModels(service: self.service, apiKey: "draft-key", configuration: self.configuration(), completion: { result in
            XCTAssertTrue(Thread.isMainThread)
            XCTAssertEqual(try? result.get(), ["a", "z"])
            finished.fulfill()
        })
        self.wait(for: [finished], timeout: 3)
        request.cancel()
    }

    func testReasoningFallbackStepsAreFiniteAndPreserveRoleAndOutputBudget() throws {
        let finished = self.expectation(description: "Finite rejected-option fallback")
        var count = 0
        ExteraAIURLProtocol.onStart = { mock in
            count += 1
            let body = mock.body()
            XCTAssertEqual(body["max_tokens"] as? Int, 4096)
            XCTAssertEqual((body["messages"] as? [[String: String]])?.first?["content"], "Instruction")
            let effort = (body["reasoning"] as? [String: String])?["effort"]
            XCTAssertEqual(effort, ["none", "minimal", "low", nil][min(count - 1, 3)])
            mock.respond(#"{"error":{"message":"Unsupported reasoning effort"}}"#, status: 400)
        }
        let service = ExteraAIService(name: "Router", endpoint: "https://openrouter.ai/api/v1", model: "fixture")
        let request = try ExteraAIClient.generate(service: service, apiKey: "", role: .init(name: "Role", prompt: "Instruction"), prompt: "Question", stream: false, configuration: self.configuration(), completion: { result in
            guard case .failure(.http(400, _)) = result else { XCTFail("Expected terminal provider error"); finished.fulfill(); return }
            finished.fulfill()
        })
        self.wait(for: [finished], timeout: 3)
        XCTAssertEqual(count, 4)
        request.cancel()
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
        var service = self.service
        service.userAgentPreset = .claudeCode
        var count = 0
        ExteraAIURLProtocol.onStart = { mock in
            count += 1
            XCTAssertEqual(mock.request.value(forHTTPHeaderField: "User-Agent"), "claude-cli")
            if count == 1 {
                XCTAssertEqual(mock.body()["temperature"] as? Double, 1.2)
                mock.respond(#"{"error":{"message":"Unsupported temperature option"}}"#, status: 400)
            } else {
                XCTAssertNil(mock.body()["temperature"])
                mock.respond(#"{"choices":[{"message":{"content":"Answer"},"finish_reason":"stop"}]}"#)
            }
        }
        let request = try ExteraAIClient.generate(service: service, apiKey: "", role: nil, prompt: "Question", temperature: 1.2, stream: false, configuration: self.configuration(), completion: { result in
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
