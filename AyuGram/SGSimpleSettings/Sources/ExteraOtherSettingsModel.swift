import Foundation

/// Frames 66–67, excluding plugins. Support destinations are remote data, never preferences.
public enum ExteraOtherSettingsModel {
    public enum Section: Int32, CaseIterable, Sendable {
        case exteraSupport, ayuSupport, google, account, additional
    }
    public enum SettingsAction: Sendable {
        case exportSettings, resetSettings
    }
    public enum AccountRow: CaseIterable, Sendable {
        case exportSettings, resetSettings, deleteAccount
    }
    public enum Telemetry: String, CaseIterable, Sendable {
        case crashlytics = "Crashlytics", analytics = "Analytics"
        // There are no Firebase collection dependencies in this iOS build. This is a capability,
        // not a persisted opt-in: importing a preference must never enable an absent collector.
        public var canCollect: Bool { return false }
    }
    public enum Project: String, CaseIterable, Sendable {
        case extera, ayu
    }
    public struct SupportEntry: Equatable, Hashable, Sendable {
        public let project: Project
        public let name: String
        public let details: String

        public init(project: Project, name: String, details: String) {
            self.project = project
            self.name = name
            self.details = details
        }
    }
    public struct Bank: Equatable, Sendable {
        public let name: String
        public let details: String
    }
    public struct SupportConfiguration: Equatable, Sendable {
        public let entries: [SupportEntry]
        public let banks: [Bank]
        public static let empty = SupportConfiguration(entries: [], banks: [])
    }
    public enum Route: Equatable {
        case web(URL)
        case wallet(url: URL, address: String, comment: String)
        case banks([Bank])
        case copy(String)
    }

    /// Input is oldest-first from the pinned project's channel, matching Android's overwrite rule.
    /// Only this feature's keys are consumed. Unrelated remote flags cannot change iOS behavior.
    public static func parseSupport(messages: [String], project: Project) -> SupportConfiguration? {
        guard messages.count <= 100, messages.allSatisfy({ $0.utf8.count <= 128 * 1024 }) else { return nil }
        let key = project == .extera ? "donates" : "donates_ayu"
        var values: [String: String] = [:]
        var found = false
        for message in messages {
            let lines = message.components(separatedBy: .newlines)
            guard lines.first == "remote_config" else { continue }
            found = true
            for line in lines.dropFirst() {
                let parts = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                guard parts.count == 2 else { continue }
                let name = parts[0].trimmingCharacters(in: .whitespaces)
                if name == key || (project == .extera && name == "donates_banks") {
                    values[name] = parts[1].trimmingCharacters(in: .whitespaces)
                }
            }
        }
        guard found else { return nil }
        func pairs(_ value: String?) -> [(String, String)] {
            guard let value, value.hasPrefix("["), value.hasSuffix("]") else { return [] }
            let body = value.dropFirst().dropLast()
            guard !body.isEmpty else { return [] }
            return body.split(separator: ",").prefix(32).compactMap { token in
                let parts = token.trimmingCharacters(in: .whitespaces).split(separator: "#", omittingEmptySubsequences: false)
                guard parts.count == 2 else { return nil }
                let name = String(parts[0]), details = String(parts[1])
                guard !name.isEmpty, name.count <= 80, !details.isEmpty, details.count <= 2048,
                    !name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
                    !details.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { return nil }
                return (name, details)
            }
        }
        let banks = pairs(values["donates_banks"]).map { Bank(name: $0.0, details: $0.1) }
        var seen = Set<SupportEntry>()
        let entries = pairs(values[key]).compactMap { name, details -> SupportEntry? in
            let entry = SupportEntry(project: project, name: name, details: details)
            guard route(for: entry, banks: banks, accountId: 1) != nil, seen.insert(entry).inserted else { return nil }
            return entry
        }.sorted { lhs, rhs in
            let order = ["boosty", "keeper", "wallet", "card"]
            func rank(_ name: String) -> Int { return order.firstIndex(where: { name.lowercased().contains($0) }) ?? order.count }
            let left = rank(lhs.name), right = rank(rhs.name)
            if left != right { return left < right }
            if lhs.name != rhs.name { return lhs.name < rhs.name }
            return lhs.details < rhs.details
        }
        return SupportConfiguration(entries: entries, banks: banks)
    }

    public static func route(for entry: SupportEntry, banks: [Bank], accountId: Int64) -> Route? {
        let name = entry.name.lowercased()
        let details = entry.details
        guard !details.isEmpty, details.count <= 2048, !details.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { return nil }
        if name.contains("keeper") || name.contains("wallet") || (entry.project == .ayu && name.contains("ton")) {
            guard accountId > 0, isTONAddress(details) else { return nil }
            var url = URLComponents()
            url.scheme = "ton"
            url.host = "transfer"
            url.path = "/" + details
            let comment = String(accountId)
            url.queryItems = [URLQueryItem(name: "text", value: comment)]
            return url.url.map { .wallet(url: $0, address: details, comment: comment) }
        }
        if entry.project == .extera && name.contains("card"), !banks.isEmpty { return .banks(banks) }
        if let url = URL(string: details), url.scheme?.lowercased() == "https", url.host?.isEmpty == false, url.user == nil, url.password == nil {
            return .web(url)
        }
        // Unknown executable URL schemes must never become links. Plain bank/payment details
        // retain Android's explicit copy flow; "app" is Android's unsupported donation launcher.
        guard !details.contains(":"), details != "app" else { return nil }
        return .copy(details)
    }

    public static func isTONAddress(_ address: String) -> Bool {
        if address.hasPrefix("0:") || address.hasPrefix("-1:") {
            let hex = address.split(separator: ":", omittingEmptySubsequences: false)
            return hex.count == 2 && hex[1].count == 64 && hex[1].allSatisfy { $0.isASCII && $0.isHexDigit }
        }
        guard address.count == 48, address.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "-_=+/".contains($0)) }),
            let data = Data(base64Encoded: address.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")), data.count == 36 else { return false }
        let bytes = [UInt8](data)
        guard [UInt8(0x11), 0x51, 0x91, 0xd1].contains(bytes[0]), bytes[1] == 0 || bytes[1] == 255 else { return false }
        var crc: UInt16 = 0
        for byte in bytes.prefix(34) {
            crc ^= UInt16(byte) << 8
            for _ in 0..<8 { crc = crc & 0x8000 == 0 ? crc << 1 : (crc << 1) ^ 0x1021 }
        }
        return bytes[34] == UInt8(crc >> 8) && bytes[35] == UInt8(crc & 255)
    }
}
