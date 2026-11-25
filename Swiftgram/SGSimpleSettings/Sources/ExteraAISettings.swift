// Native adaptation of exteraGram's AiConfig, Service, Role and bounded conversation history.
// Reference: exteraSquad/exteraGram, GPL-3.0-or-later; see docs/third-party/exteragram-notice.md.
import Foundation
import Security

public struct ExteraAIService: Codable, Equatable {
    public var id: String
    public var name: String
    public var endpoint: String
    public var model: String
    public var reasoningEnabled: Bool

    public init(id: String = UUID().uuidString, name: String, endpoint: String, model: String, reasoningEnabled: Bool = false) {
        self.id = id
        self.name = name
        self.endpoint = endpoint
        self.model = model
        self.reasoningEnabled = reasoningEnabled
    }

    public static var presets: [ExteraAIService] {
        return [
            .init(name: "OpenAI", endpoint: "https://api.openai.com/v1", model: "gpt-4.1-mini"),
            .init(name: "Google Gemini", endpoint: "https://generativelanguage.googleapis.com/v1beta/openai", model: "gemini-2.5-flash"),
            .init(name: "OpenRouter", endpoint: "https://openrouter.ai/api/v1", model: ""),
            .init(name: "DeepSeek", endpoint: "https://api.deepseek.com/v1", model: "deepseek-chat"),
            .init(name: "Groq", endpoint: "https://api.groq.com/openai/v1", model: ""),
            .init(name: "Mistral", endpoint: "https://api.mistral.ai/v1", model: "mistral-small-latest"),
            .init(name: "Perplexity", endpoint: "https://api.perplexity.ai/chat/completions", model: "sonar"),
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

    public static var defaults: [ExteraAIRole] {
        return [
            .init(id: "assistant", name: "Assistant", prompt: "You are a helpful assistant. Respond in the user's language."),
            .init(id: "editor", name: "Editor", prompt: "Improve the grammar, spelling and clarity of the supplied text while preserving its meaning, language and formatting. Return only the improved text."),
            .init(id: "summary", name: "Summarizer", prompt: "Summarize the supplied text accurately and concisely in the same language. Preserve important facts. Return only the summary."),
            .init(id: "translator", name: "Translator", prompt: "Translate the supplied text into the language requested by the user. Preserve meaning and formatting. Return only the translation.")
        ]
    }
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
    public var roles: [ExteraAIRole] = ExteraAIRole.defaults
    public var selectedServiceId: String?
    public var selectedRoleId: String? = "assistant"
    public var saveHistory: Bool = true
    public var responseStreaming: Bool = true
    public var temperature: Double = 1.0
    public var useForTextProcessing: Bool = false

    public init() {}

    private enum CodingKeys: String, CodingKey {
        case services, roles, selectedServiceId, selectedRoleId, saveHistory, responseStreaming, temperature, useForTextProcessing
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.services = try values.decodeIfPresent([ExteraAIService].self, forKey: .services) ?? []
        self.roles = try values.decodeIfPresent([ExteraAIRole].self, forKey: .roles) ?? ExteraAIRole.defaults
        self.selectedServiceId = try values.decodeIfPresent(String.self, forKey: .selectedServiceId)
        self.selectedRoleId = try values.decodeIfPresent(String.self, forKey: .selectedRoleId)
        self.saveHistory = try values.decodeIfPresent(Bool.self, forKey: .saveHistory) ?? true
        self.responseStreaming = try values.decodeIfPresent(Bool.self, forKey: .responseStreaming) ?? true
        self.temperature = try values.decodeIfPresent(Double.self, forKey: .temperature) ?? 1.0
        self.useForTextProcessing = try values.decodeIfPresent(Bool.self, forKey: .useForTextProcessing) ?? false
    }

    public var selectedService: ExteraAIService? {
        return self.services.first(where: { $0.id == self.selectedServiceId }) ?? self.services.first
    }

    public var selectedRole: ExteraAIRole? {
        return self.roles.first(where: { $0.id == self.selectedRoleId })
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

    private init() {}

    public var configuration: ExteraAIConfiguration {
        self.lock.lock()
        defer { self.lock.unlock() }
        guard let data = self.store.string(self.configurationKey).data(using: .utf8),
              let value = try? JSONDecoder().decode(ExteraAIConfiguration.self, from: data) else {
            return ExteraAIConfiguration()
        }
        return value
    }

    /// Serialize read/modify/write so service edits cannot overwrite a simultaneous role change.
    public func update(_ body: (inout ExteraAIConfiguration) -> Void) throws {
        try self.persist {
            var value = self.configuration
            body(&value)
            guard value.temperature.isFinite, (0.0...2.0).contains(value.temperature), value.services.count <= 100, value.roles.count <= 100 else {
                throw ExteraAIError.configuration("AI preferences exceed their allowed limits.")
            }
            guard Set(value.services.map { $0.id }).count == value.services.count,
                  Set(value.roles.map { $0.id }).count == value.roles.count else {
                throw ExteraAIError.configuration("AI service and role identifiers must be unique.")
            }
            let data = try JSONEncoder().encode(value)
            guard data.count <= 1024 * 1024, let json = String(data: data, encoding: .utf8) else {
                throw ExteraAIError.configuration("AI preferences are too large.")
            }
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
