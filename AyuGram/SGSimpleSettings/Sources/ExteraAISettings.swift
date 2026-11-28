// Native adaptation of exteraGram's AiConfig, Service, Role and bounded conversation history.
// Reference: exteraSquad/exteraGram, GPL-3.0-or-later; see docs/third-party/exteragram-notice.md.
import Foundation
import Security

/// HTTP client identifiers only. API dialect, authentication and model selection remain independent.
public enum ExteraAIUserAgentPreset: String, Codable, CaseIterable {
    case `default`, openCode, claudeCode, zCode, codex, cursor, cline, rooCode, custom

    public var title: String {
        switch self {
        case .default: return "Default"
        case .openCode: return "OpenCode"
        case .claudeCode: return "Claude Code"
        case .zCode: return "ZCode"
        case .codex: return "Codex"
        case .cursor: return "Cursor"
        case .cline: return "Cline"
        case .rooCode: return "Roo Code"
        case .custom: return "Custom"
        }
    }

    public func resolvedUserAgent(customValue: String) throws -> String? {
        switch self {
        case .default: return nil
        case .openCode: return "opencode"
        case .claudeCode: return "claude-cli"
        case .zCode: return "ZCode"
        case .codex: return "codex_cli_rs"
        case .cursor: return "Cursor"
        case .cline: return "Cline"
        case .rooCode: return "RooCode"
        case .custom:
            // Visible ASCII preserves the exact supplied header and rejects CR/LF, NUL and tabs.
            guard !customValue.isEmpty, customValue.utf8.count <= 512,
                  customValue == customValue.trimmingCharacters(in: .whitespacesAndNewlines),
                  customValue.unicodeScalars.allSatisfy({ (32 ... 126).contains($0.value) }) else {
                throw ExteraAIError.configuration("Enter a User-Agent of 1–512 printable ASCII characters without leading or trailing spaces.")
            }
            return customValue
        }
    }
}

public struct ExteraAIService: Codable, Equatable {
    public var id: String
    public var name: String
    public var endpoint: String
    public var model: String
    public var reasoningEnabled: Bool
    public var userAgentPreset: ExteraAIUserAgentPreset
    public var customUserAgent: String

    public init(id: String = UUID().uuidString, name: String, endpoint: String, model: String, reasoningEnabled: Bool = false, userAgentPreset: ExteraAIUserAgentPreset = .default, customUserAgent: String = "") {
        self.id = id
        self.name = name
        self.endpoint = endpoint
        self.model = model
        self.reasoningEnabled = reasoningEnabled
        self.userAgentPreset = userAgentPreset
        self.customUserAgent = customUserAgent
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, endpoint, model, reasoningEnabled, userAgentPreset, customUserAgent
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try values.decode(String.self, forKey: .id)
        self.name = try values.decode(String.self, forKey: .name)
        self.endpoint = try values.decode(String.self, forKey: .endpoint)
        self.model = try values.decode(String.self, forKey: .model)
        self.reasoningEnabled = try values.decodeIfPresent(Bool.self, forKey: .reasoningEnabled) ?? false
        self.userAgentPreset = try values.decodeIfPresent(ExteraAIUserAgentPreset.self, forKey: .userAgentPreset) ?? .default
        self.customUserAgent = try values.decodeIfPresent(String.self, forKey: .customUserAgent) ?? ""
    }

    public static var presets: [ExteraAIService] {
        return [
            .init(name: "Gemini", endpoint: "https://generativelanguage.googleapis.com/v1beta", model: "gemini-3.5-flash"),
            .init(name: "OpenAI", endpoint: "https://api.openai.com/v1", model: "gpt-5.4-mini"),
            .init(name: "OpenRouter", endpoint: "https://openrouter.ai/api/v1", model: "openai/gpt-5.4-mini"),
            .init(name: "Perplexity", endpoint: "https://api.perplexity.ai/v1/agent", model: "perplexity/glm-5.3-flash"),
            .init(name: "Custom", endpoint: "", model: "")
        ]
    }
}

public struct ExteraAIRole: Codable, Equatable {
    public var id: String
    public var name: String
    public var prompt: String

    public init(id: String = UUID().uuidString, name: String, prompt: String) {
        self.id = id
        self.name = name
        self.prompt = prompt
    }

    /// Immutable Android Suggestions. User roles have independent, persisted IDs.
    public static var suggestions: [ExteraAIRole] {
        return [
            .init(id: "suggestion.assistant", name: "Assistant", prompt: """
                You are a helpful personal assistant inside a chat app.
                Adapt to the user's tone, language, and context. Keep answers practical, concise, and easy to act on.
                Ask a clarifying question only when the request is ambiguous enough that answering directly would likely be wrong.
                """),
            .init(id: "suggestion.summarizer", name: "Summarizer", prompt: """
                Summarize the provided message or conversation without replying to it.
                Preserve the important facts, decisions, requests, names, dates, and next steps. Omit filler and repeated details.
                Keep the summary under 3 short sentences and under 60 words.
                """),
            .init(id: "suggestion.proofreader", name: "Proofreader", prompt: """
                Proofread and improve the user's text while preserving its meaning, language, and intent.
                Fix grammar, spelling, punctuation, awkward phrasing, and clarity issues. Keep the original tone unless a cleaner wording is clearly better.
                Return only the revised text unless the user explicitly asks for explanations.
                """)
        ]
    }

    public static var defaults: [ExteraAIRole] { return self.suggestions }
    public static let defaultId = "suggestion.assistant"
    public static let nameLimit = 64
    public static let promptLimit = 1024

    public var isSuggestion: Bool { return Self.suggestions.contains(where: { $0.id == self.id }) }
}

public struct ExteraAIMessage: Codable, Equatable {
    public enum Role: String, Codable { case user, assistant }
    public var id: String
    public var role: Role
    public var content: String
    public var date: Date

    public init(id: String = UUID().uuidString, role: Role, content: String, date: Date = Date()) {
        self.id = id
        self.role = role
        self.content = content
        self.date = date
    }
}

public struct ExteraAIConfiguration: Codable, Equatable {
    public var services: [ExteraAIService] = []
    /// Custom roles only. Existing v1 roles are retained verbatim during decoding.
    public var roles: [ExteraAIRole] = []
    public var selectedServiceId: String?
    public var selectedRoleId: String? = ExteraAIRole.defaultId
    public var saveHistory: Bool = true
    public var responseStreaming: Bool = true
    public var temperature: Double = 1.0
    /// Android AiConfig defaults. These affect presentation/insertion, never the provider prompt.
    public var showResponseOnly: Bool = false
    public var insertAsQuote: Bool = true
    /// Nil retains Android's account-dependent default: replace for non-Premium.
    public var replaceTelegramSummaries: Bool?

    public func replacesTelegramSummaries(isPremium: Bool) -> Bool {
        return self.replaceTelegramSummaries ?? !isPremium
    }
    /// Feature visibility and execution are independent of the editor's backend routing.
    public var showEditor: Bool = true
    public var showSummaries: Bool = true
    public var showInstantViewSummaries: Bool = true
    /// Missing/null uses Android's account-dependent default; explicit legacy booleans survive.
    public var useForTextProcessing: Bool?

    public func replacesTelegramEditor(isPremium: Bool) -> Bool {
        return self.useForTextProcessing ?? !isPremium
    }

    public init() {}

    private enum CodingKeys: String, CodingKey {
        case services, roles, selectedServiceId, selectedRoleId, saveHistory, responseStreaming, temperature, useForTextProcessing
        case showEditor, showSummaries, showInstantViewSummaries
        case showResponseOnly, insertAsQuote, replaceTelegramSummaries
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.services = try values.decodeIfPresent([ExteraAIService].self, forKey: .services) ?? []
        self.roles = try values.decodeIfPresent([ExteraAIRole].self, forKey: .roles) ?? []
        self.selectedServiceId = try values.decodeIfPresent(String.self, forKey: .selectedServiceId)
        // An explicit null preserves the existing "No System Role" choice.
        self.selectedRoleId = values.contains(.selectedRoleId) || values.contains(.roles) ? try values.decodeIfPresent(String.self, forKey: .selectedRoleId) : ExteraAIRole.defaultId
        self.saveHistory = try values.decodeIfPresent(Bool.self, forKey: .saveHistory) ?? true
        self.responseStreaming = try values.decodeIfPresent(Bool.self, forKey: .responseStreaming) ?? true
        self.temperature = try values.decodeIfPresent(Double.self, forKey: .temperature) ?? 1.0
        self.showResponseOnly = try values.decodeIfPresent(Bool.self, forKey: .showResponseOnly) ?? false
        self.insertAsQuote = try values.decodeIfPresent(Bool.self, forKey: .insertAsQuote) ?? true
        self.replaceTelegramSummaries = try values.decodeIfPresent(Bool.self, forKey: .replaceTelegramSummaries)
        self.showEditor = try values.decodeIfPresent(Bool.self, forKey: .showEditor) ?? true
        self.showSummaries = try values.decodeIfPresent(Bool.self, forKey: .showSummaries) ?? true
        self.showInstantViewSummaries = try values.decodeIfPresent(Bool.self, forKey: .showInstantViewSummaries) ?? true
        self.useForTextProcessing = try values.decodeIfPresent(Bool.self, forKey: .useForTextProcessing)
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(self.services, forKey: .services)
        try values.encode(self.roles, forKey: .roles)
        try values.encodeIfPresent(self.selectedServiceId, forKey: .selectedServiceId)
        // Encode nil explicitly: omission means the default role on first launch.
        try values.encode(self.selectedRoleId, forKey: .selectedRoleId)
        try values.encode(self.saveHistory, forKey: .saveHistory)
        try values.encode(self.responseStreaming, forKey: .responseStreaming)
        try values.encode(self.temperature, forKey: .temperature)
        try values.encodeIfPresent(self.useForTextProcessing, forKey: .useForTextProcessing)
        try values.encode(self.showEditor, forKey: .showEditor)
        try values.encode(self.showSummaries, forKey: .showSummaries)
        try values.encode(self.showInstantViewSummaries, forKey: .showInstantViewSummaries)
        try values.encode(self.showResponseOnly, forKey: .showResponseOnly)
        try values.encode(self.insertAsQuote, forKey: .insertAsQuote)
        try values.encodeIfPresent(self.replaceTelegramSummaries, forKey: .replaceTelegramSummaries)
    }

    public var selectedService: ExteraAIService? {
        return self.services.first(where: { $0.id == self.selectedServiceId }) ?? self.services.first
    }

    public var selectedRole: ExteraAIRole? {
        guard let id = self.selectedRoleId else { return nil }
        return self.roles.first(where: { $0.id == id }) ?? ExteraAIRole.suggestions.first(where: { $0.id == id }) ?? ExteraAIRole.suggestions.first
    }

    public mutating func selectRole(id: String?) throws {
        guard id == nil || self.roles.contains(where: { $0.id == id }) || ExteraAIRole.suggestions.contains(where: { $0.id == id }) else {
            throw ExteraAIError.configuration("This AI role no longer exists.")
        }
        self.selectedRoleId = id
    }

    /// Stable IDs keep renaming independent of selection. Editing never creates a deleted role.
    public mutating func saveRole(_ role: ExteraAIRole, existing: Bool) throws {
        let index = self.roles.firstIndex(where: { $0.id == role.id })
        guard !role.isSuggestion, !role.id.isEmpty, existing == (index != nil) else {
            throw ExteraAIError.configuration("This AI role cannot be edited. Reopen the roles list.")
        }
        let name = role.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.utf16.count <= ExteraAIRole.nameLimit,
              !role.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              role.prompt.utf16.count <= ExteraAIRole.promptLimit else {
            throw ExteraAIError.configuration("Enter a role name (up to 64 characters) and a system prompt (up to 1,024 characters).")
        }
        let keepsLegacyName = index.map { self.roles[$0].name == name } ?? false
        guard !self.roles.contains(where: { $0.id != role.id && $0.name == name }),
              keepsLegacyName || !ExteraAIRole.suggestions.contains(where: { $0.name == name }) else {
            throw ExteraAIError.configuration("An AI role with this name already exists.")
        }
        var saved = role
        saved.name = name
        if let index { self.roles[index] = saved } else {
            guard self.roles.count < 100 else { throw ExteraAIError.configuration("The AI role limit has been reached.") }
            self.roles.insert(saved, at: 0)
        }
    }

    public mutating func deleteRole(id: String) throws {
        guard let index = self.roles.firstIndex(where: { $0.id == id }) else {
            throw ExteraAIError.configuration("This AI role no longer exists.")
        }
        self.roles.remove(at: index)
        if self.selectedRoleId == id { self.selectedRoleId = ExteraAIRole.defaultId }
    }
}

public enum ExteraAIError: Error, LocalizedError {
    case configuration(String)
    case keychain(Int32)
    case http(Int, String)
    case transport(String)
    case invalidResponse(String)
    case cancelled

    public var errorDescription: String? {
        switch self {
        case let .configuration(message), let .transport(message), let .invalidResponse(message): return message
        case let .keychain(code): return "The API key could not be accessed in Keychain (\(code)). Unlock your device and try again."
        case let .http(code, detail):
            let message: String
            switch code {
            case 401: message = "The service rejected the API key."
            case 402: message = "The service requires credits or billing."
            case 403: message = "The service denied access to this model or request."
            case 404: message = "The service endpoint or model was not found."
            case 429: message = "The service rate limit or quota was reached. Try again later."
            case 500...599: message = "The AI service is temporarily unavailable."
            default: message = "The AI service returned HTTP \(code)."
            }
            return detail.isEmpty ? message : message + "\n\n" + detail
        case .cancelled: return "Generation stopped."
        }
    }
}

/// Shared service/role preferences, with conversation history isolated by Telegram account.
/// API secrets never enter UserDefaults, configuration Codable values or settings backups.
public final class ExteraAISettings {
    public static let shared = ExteraAISettings()
    public static let didChangeNotification = Notification.Name("ExteraAISettingsDidChange")
    private let lock = NSRecursiveLock()
    private let store = AyuSettingsStore.shared
    private let configurationKey = "extera.ai.configuration.v1"
    private let keychainService = (Bundle.main.bundleIdentifier ?? "exteragram") + ".custom-ai"
    private var cachedConfiguration: ExteraAIConfiguration?

    private init() {}

    public var configuration: ExteraAIConfiguration {
        self.lock.lock()
        defer { self.lock.unlock() }
        if let value = self.cachedConfiguration { return value }
        guard let data = self.store.string(self.configurationKey).data(using: .utf8),
              let value = try? JSONDecoder().decode(ExteraAIConfiguration.self, from: data) else {
            let value = ExteraAIConfiguration()
            self.cachedConfiguration = value
            return value
        }
        self.cachedConfiguration = value
        return value
    }

    /// Serialize read/modify/write so service edits cannot overwrite a simultaneous role change.
    public func update(_ body: (inout ExteraAIConfiguration) throws -> Void) throws {
        try self.persist {
            var value = self.configuration
            try body(&value)
            guard value.temperature.isFinite, (0.0...2.0).contains(value.temperature), value.services.count <= 100, value.roles.count <= 100 else {
                throw ExteraAIError.configuration("AI preferences exceed their allowed limits.")
            }
            guard Set(value.services.map { $0.id }).count == value.services.count,
                  Set(value.roles.map { $0.id }).count == value.roles.count else {
                throw ExteraAIError.configuration("AI service and role identifiers must be unique.")
            }
            for service in value.services {
                _ = try service.userAgentPreset.resolvedUserAgent(customValue: service.customUserAgent)
                if !service.customUserAgent.isEmpty {
                    _ = try ExteraAIUserAgentPreset.custom.resolvedUserAgent(customValue: service.customUserAgent)
                }
            }
            let data = try JSONEncoder().encode(value)
            guard data.count <= 1024 * 1024, let json = String(data: data, encoding: .utf8) else {
                throw ExteraAIError.configuration("AI preferences are too large.")
            }
            // All configuration writes use this wrapper. Publish only after validation/encoding
            // succeeds, before the nonthrowing store write so synchronous readers see the new value.
            self.cachedConfiguration = value
            self.store.setString(json, self.configurationKey)
        }
    }

    /// Batch store notifications so a main-queue observer never waits on our mutation lock.
    private func persist(_ body: () throws -> Void) throws {
        var failure: Error?
        self.store.performBatchUpdates {
            self.lock.lock()
            defer { self.lock.unlock() }
            do { try body() } catch { failure = error }
        }
        if let failure { throw failure }
        NotificationCenter.default.post(name: Self.didChangeNotification, object: nil)
    }

    public func apiKey(serviceId: String) throws -> String {
        var query = self.keychainQuery(serviceId)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return "" }
        guard status == errSecSuccess, let data = result as? Data, let key = String(data: data, encoding: .utf8) else {
            throw ExteraAIError.keychain(status)
        }
        return key
    }

    public func setAPIKey(_ key: String, serviceId: String) throws {
        let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard key.utf8.count <= 16384, !key.contains("\n"), !key.contains("\r") else {
            throw ExteraAIError.configuration("The API key is invalid.")
        }
        let query = self.keychainQuery(serviceId)
        if key.isEmpty {
            let status = SecItemDelete(query as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw ExteraAIError.keychain(status) }
            return
        }
        let attributes: [String: Any] = [
            kSecValueData as String: Data(key.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]
        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            for (key, value) in attributes { item[key] = value }
            status = SecItemAdd(item as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw ExteraAIError.keychain(status) }
    }

    private func keychainQuery(_ id: String) -> [String: Any] {
        return [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: self.keychainService, kSecAttrAccount as String: id]
    }

    private func historyKey(_ accountId: String) -> String { return "extera.ai.history.v1." + accountId }

    public func history(accountId: String) -> [ExteraAIMessage] {
        self.lock.lock()
        defer { self.lock.unlock() }
        guard let data = self.store.string(self.historyKey(accountId)).data(using: .utf8),
              let messages = try? JSONDecoder().decode([ExteraAIMessage].self, from: data) else { return [] }
        return messages
    }

    public func setHistory(_ messages: [ExteraAIMessage], accountId: String) throws {
        try self.persist { try self.writeHistory(messages, accountId: accountId) }
    }

    private func writeHistory(_ messages: [ExteraAIMessage], accountId: String) throws {
        var messages = Array(messages.suffix(64))
        var count = messages.reduce(0) { $0 + $1.content.count }
        while messages.count > 2 && count > 64000 {
            count -= messages.removeFirst().content.count
        }
        // Keep complete user/assistant turns; a single oversized turn is not persisted.
        while messages.first?.role == .assistant { messages.removeFirst() }
        if count > 64000 { messages = [] }
        let data = try JSONEncoder().encode(messages)
        self.store.setString(String(decoding: data, as: UTF8.self), self.historyKey(accountId))
    }

    public func appendTurn(prompt: String, response: String, accountId: String) throws {
        try self.persist {
            var messages = self.history(accountId: accountId)
            messages.append(.init(role: .user, content: prompt))
            messages.append(.init(role: .assistant, content: response))
            try self.writeHistory(messages, accountId: accountId)
        }
    }

    /// Match Android's REST limits, retaining recent complete turns rather than cutting a message.
    public func requestHistory(accountId: String) -> [ExteraAIMessage] {
        let history = self.history(accountId: accountId)
        var result: [ExteraAIMessage] = []
        var count = 0
        guard history.count >= 2 else { return [] }
        var index = history.count - 1
        while index > 0 && result.count < 32 {
            let assistant = history[index]
            let user = history[index - 1]
            let length = user.content.count + assistant.content.count
            if user.role == .user && assistant.role == .assistant && !user.content.isEmpty && !assistant.content.isEmpty && count + length <= 24000 {
                result.insert(contentsOf: [user, assistant], at: 0)
                count += length
                index -= 2
            } else {
                index -= 1
            }
        }
        return result
    }
}
