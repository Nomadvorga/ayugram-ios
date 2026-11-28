import Foundation
import UIKit

/// Native contract for Group Mentions 1.2. Group storage, validation, word
/// boundaries, chat-type policy and the 60-second cooldown mirror the audited
/// source. The text rewrite is applied before iOS Telegram generates entities.
@MainActor
final class AyuGroupMentionsAdapter: AyuNativePluginAdapter {
    struct Group: Codable, Equatable {
        var id: String
        var command: String
        var usernames: [String]
    }

    private(set) var isEnabled = false
    private var groups: [Group] = []
    private var cooldowns: [String: Date] = [:]
    private let maximumGroups = 5
    private let maximumUsers = 7
    private let cooldown: TimeInterval = 60

    init(defaults: UserDefaults, reportError: @escaping (String?) -> Void) {
        super.init(pluginID: "group_mentions", defaults: defaults, reportError: reportError)
        self.groups = (try? self.loadGroups()) ?? []
    }

    override func enable() throws {
        self.groups = try self.loadGroups()
        self.isEnabled = true
        self.reportError(nil)
        AyuNativePluginRuntime.shared.groupMentions = self
    }

    override func disable() {
        self.isEnabled = false
        self.cooldowns.removeAll()
        if AyuNativePluginRuntime.shared.groupMentions === self {
            AyuNativePluginRuntime.shared.groupMentions = nil
        }
    }

    private func loadGroups() throws -> [Group] {
        let text = self.stringValue("groups_data", default: "[]")
        guard text.utf8.count <= 32_768, let data = text.data(using: .utf8) else {
            throw AyuPluginService.Failure.operation("INVALID_GROUPS")
        }
        guard let parsed = try? JSONDecoder().decode([Group].self, from: data) else { return [] }
        var result: [Group] = []
        for group in parsed {
            let command = group.command.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !command.isEmpty else { continue }
            let usernames = Self.parseUsernames(group.usernames.joined(separator: " ")).prefix(self.maximumUsers)
            guard !usernames.isEmpty else { continue }
            result.append(Group(id: group.id.isEmpty ? String(UUID().uuidString.prefix(10)).lowercased() : group.id,
                                command: command, usernames: Array(usernames)))
            if result.count >= self.maximumGroups { break }
        }
        return result
    }

    private func saveGroups() throws {
        let data = try JSONEncoder().encode(self.groups)
        guard let text = String(data: data, encoding: .utf8) else { throw AyuPluginService.Failure.protocolError }
        try self.setValue(.string(text), for: "groups_data")
    }

    override func settings() throws -> [AyuPluginSetting] {
        self.groups = (try? self.loadGroups()) ?? self.groups
        var chatTypes: [String] = []
        if self.boolValue("enabled_private", default: true) { chatTypes.append("личка") }
        if self.boolValue("enabled_groups", default: true) { chatTypes.append("группы") }
        let chatsPart = chatTypes.isEmpty ? "нигде не работает" : chatTypes.joined(separator: ", ")
        let casePart = self.boolValue("case_sensitive", default: false) ? "с учётом регистра" : "без учёта регистра"
        var rows: [AyuPluginSetting] = [
            self.staticRow("Header", "Group Mentions"),
            self.textRow("Как это работает", subtext: "Слово в сообщении → упоминания",
                         action: "group_mentions.info"),
            self.textRow("Настройки", subtext: "\(chatsPart) · \(casePart)",
                         action: "group_mentions.settings"),
            self.staticRow("Header", "Группы (\(self.groups.count) из \(self.maximumGroups))"),
        ]
        if self.groups.isEmpty {
            rows.append(self.textRow("Групп пока нет", subtext: "Нажмите «Добавить группу» ниже"))
        } else {
            for group in self.groups {
                var preview = group.usernames.prefix(2).map { "@" + $0 }.joined(separator: ", ")
                if group.usernames.count > 2 { preview += " и ещё \(group.usernames.count - 2)" }
                var row = self.textRow(group.command, subtext: "\(group.usernames.count) чел. — \(preview)",
                                       editor: "group_mentions.group")
                if var descriptor = row.descriptor.object {
                    descriptor["native_group"] = .string(group.id)
                    row = AyuPluginSetting(descriptor: .object(descriptor), value: .null)
                }
                rows.append(row)
            }
        }
        if self.groups.count < self.maximumGroups {
            rows.append(self.textRow("Добавить группу", action: "group_mentions.add"))
        } else {
            rows.append(self.textRow("Лимит групп исчерпан", subtext: "Максимум \(self.maximumGroups) групп",
                                     action: "group_mentions.limit"))
        }
        return rows
    }

    override func set(_ row: AyuPluginSetting, value: AyuBridgeValue) throws {
        guard self.isEnabled else { throw AyuPluginService.Failure.inactive }
        guard let key = row.key, ["enabled_private", "enabled_groups", "case_sensitive"].contains(key) else {
            throw AyuPluginService.Failure.operation("INVALID_SETTING")
        }
        guard case .bool = value else { throw AyuPluginService.Failure.operation("INVALID_SETTING_TYPE") }
        try self.setValue(value, for: key)
    }

    override func activate(_ row: AyuPluginSetting, presenter: UIViewController?, completion: @escaping () -> Void) throws {
        guard self.isEnabled else { throw AyuPluginService.Failure.inactive }
        let groupID = row.descriptor["native_group"].string
        let action = row.descriptor["native_action"].string
        if action == "group_mentions.info" {
            guard let presenter else { throw AyuPluginService.Failure.inactive }
            let alert = UIAlertController(title: "Как это работает",
                                          message: "Впишите название группы прямо в текст сообщения или подпись к любому медиа (фото, видео, файл, аудио и др.) и отправьте — оно превратится в упоминания всех участников группы.\n\nПример: группа «Разрабы» → @Is_Kano, @MsPipl.\nСообщение «Разрабы, гляньте баг» уйдёт как «@Is_Kano @MsPipl, гляньте баг».",
                                          preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "Понятно", style: .default))
            presenter.present(alert, animated: true)
            completion()
            return
        }
        if action == "group_mentions.limit" {
            AyuNativePluginRuntime.shared.showMessage("Достигнут лимит: максимум \(self.maximumGroups) групп", style: "error")
            completion()
            return
        }
        if action == "group_mentions.settings" {
            guard let presenter else { throw AyuPluginService.Failure.inactive }
            self.presentSettings(from: presenter, completion: completion)
            return
        }
        if action == "group_mentions.add" || row.descriptor["native_editor"].string == "group_mentions.group" {
            guard let presenter else { throw AyuPluginService.Failure.inactive }
            self.presentEditor(groupID: groupID, from: presenter, completion: completion)
            return
        }
        completion()
    }

    /// Source sub-page: chat-type switches and the case policy. Changes are
    /// written immediately and mirrored by the main list summary.
    private func presentSettings(from presenter: UIViewController, completion: @escaping () -> Void) {
        let alert = UIAlertController(title: "Group Mentions", message: "Где работает плагин", preferredStyle: .alert)
        let privateRow = UIAlertAction(title: "Личные чаты: \(self.boolValue("enabled_private", default: true) ? "вкл" : "выкл")", style: .default) { [weak self] _ in
            guard let self else { return }
            try? self.setValue(.bool(!self.boolValue("enabled_private", default: true)), for: "enabled_private")
            DispatchQueue.main.async { [weak self] in self?.presentSettings(from: presenter, completion: completion) }
        }
        let groupsRow = UIAlertAction(title: "Группы: \(self.boolValue("enabled_groups", default: true) ? "вкл" : "выкл")", style: .default) { [weak self] _ in
            guard let self else { return }
            try? self.setValue(.bool(!self.boolValue("enabled_groups", default: true)), for: "enabled_groups")
            DispatchQueue.main.async { [weak self] in self?.presentSettings(from: presenter, completion: completion) }
        }
        let caseRow = UIAlertAction(title: "Учитывать регистр: \(self.boolValue("case_sensitive", default: false) ? "вкл" : "выкл")", style: .default) { [weak self] _ in
            guard let self else { return }
            try? self.setValue(.bool(!self.boolValue("case_sensitive", default: false)), for: "case_sensitive")
            DispatchQueue.main.async { [weak self] in self?.presentSettings(from: presenter, completion: completion) }
        }
        alert.addAction(privateRow)
        alert.addAction(groupsRow)
        alert.addAction(caseRow)
        alert.addAction(UIAlertAction(title: "Готово", style: .cancel) { _ in completion() })
        presenter.present(alert, animated: true)
    }

    // MARK: - Editor

    private func presentEditor(groupID: String?, from presenter: UIViewController, completion: @escaping () -> Void) {
        let existing = groupID.flatMap { id in self.groups.first { $0.id == id } }
        if existing == nil && self.groups.count >= self.maximumGroups {
            AyuNativePluginRuntime.shared.showMessage("Достигнут лимит: максимум \(self.maximumGroups) групп", style: "error")
            completion()
            return
        }
        let alert = UIAlertController(title: existing == nil ? "Новая группа" : "Изменить группу",
                                      message: "Например: Разрабы. Юзернеймы через запятую или пробел (до \(self.maximumUsers) чел.).",
                                      preferredStyle: .alert)
        alert.addTextField { field in
            field.placeholder = "Название группы"
            field.text = existing?.command
            field.autocorrectionType = .no
            field.clearButtonMode = .whileEditing
        }
        alert.addTextField { field in
            field.placeholder = "@юзернейм1, @юзернейм2"
            field.text = existing?.usernames.map { "@" + $0 }.joined(separator: ", ")
            field.autocorrectionType = .no
            field.autocapitalizationType = .none
            field.clearButtonMode = .whileEditing
        }
        alert.addAction(UIAlertAction(title: "Отмена", style: .cancel) { _ in completion() })
        if let existing {
            alert.addAction(UIAlertAction(title: "Удалить", style: .destructive) { [weak self] _ in
                guard let self else { return }
                self.groups.removeAll { $0.id == existing.id }
                try? self.saveGroups()
                AyuNativePluginRuntime.shared.showMessage("Группа «\(existing.command)» удалена", style: "success")
                completion()
            })
        }
        alert.addAction(UIAlertAction(title: "Сохранить", style: .default) { [weak self, weak alert] _ in
            guard let self else { return }
            let command = alert?.textFields?.first?.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let raw = alert?.textFields?.dropFirst().first?.text ?? ""
            do {
                try self.save(command: command, raw: raw, replacing: existing)
                completion()
            } catch let failure as AyuPluginService.Failure {
                AyuNativePluginRuntime.shared.showMessage(failure.localizedDescription, style: "error")
                completion()
            } catch {
                completion()
            }
        })
        presenter.present(alert, animated: true)
    }

    private func save(command: String, raw: String, replacing existing: Group?) throws {
        let wasExisting = existing != nil
        guard !command.isEmpty else { throw AyuPluginService.Failure.operation("Введите название группы") }
        guard command.count <= 64, !command.contains("\n") else { throw AyuPluginService.Failure.operation("Название слишком длинное") }
        let chunks = raw.components(separatedBy: CharacterSet(charactersIn: ",;\n\r\t "))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "@.,;")) }
            .filter { !$0.isEmpty }
        for chunk in chunks where chunk.range(of: "^[A-Za-z0-9_]+$", options: .regularExpression) == nil {
            throw AyuPluginService.Failure.operation("Юзернейм «\(chunk)» невалиден: разрешена только латиница")
        }
        let usernames = Self.parseUsernames(raw)
        guard !usernames.isEmpty else { throw AyuPluginService.Failure.operation("Добавьте хотя бы одного участника") }
        guard usernames.count <= self.maximumUsers else { throw AyuPluginService.Failure.operation("Максимум \(self.maximumUsers) участников в группе") }
        let caseSensitive = self.boolValue("case_sensitive", default: false)
        let duplicate = self.groups.contains { group in
            group.id != existing?.id && (caseSensitive ? group.command == command : group.command.lowercased() == command.lowercased())
        }
        guard !duplicate else { throw AyuPluginService.Failure.operation("Группа «\(command)» уже существует") }
        if existing == nil && self.groups.count >= self.maximumGroups {
            throw AyuPluginService.Failure.operation("Лимит: максимум \(self.maximumGroups) групп")
        }
        if let existing, let index = self.groups.firstIndex(where: { $0.id == existing.id }) {
            self.groups[index].command = command
            self.groups[index].usernames = usernames
        } else {
            self.groups.append(Group(id: String(UUID().uuidString.prefix(10)).lowercased(), command: command, usernames: usernames))
            self.groups = Array(self.groups.prefix(self.maximumGroups))
        }
        try self.saveGroups()
        let message = wasExisting
            ? "Группа «\(command)» сохранена"
            : "Группа «\(command)» добавлена (\(usernames.count) чел.)"
        AyuNativePluginRuntime.shared.showMessage(message, style: "success")
    }

    static func parseUsernames(_ raw: String) -> [String] {
        var seen: Set<String> = []
        var result: [String] = []
        let separators = CharacterSet(charactersIn: ",;\n\r\t ")
        for chunk in raw.components(separatedBy: separators) {
            var value = chunk.trimmingCharacters(in: .whitespacesAndNewlines)
            value = value.trimmingCharacters(in: CharacterSet(charactersIn: "@.,;"))
            guard !value.isEmpty, value.range(of: "^[A-Za-z0-9_]+$", options: .regularExpression) != nil else { continue }
            let key = value.lowercased()
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            result.append(value)
        }
        return result
    }

    // MARK: - Rewrite

    func expand(_ text: String, accountKey: String, peerID: Int64, isGroup: Bool, isChannel: Bool) -> String {
        self.expandDetailed(text, accountKey: accountKey, peerID: peerID, isGroup: isGroup, isChannel: isChannel).text
    }

    /// Mirrors `_expand_groups`: one combined alternation, longer commands first,
    /// the same word-boundary rules, all matches replaced in one pass, then the
    /// per-chat 60-second cooldown.
    func expandDetailed(_ text: String, accountKey: String, peerID: Int64, isGroup: Bool, isChannel: Bool) -> AyuNativeTextRewrite {
        let unchanged = AyuNativeTextRewrite(text: text, replacements: [])
        guard self.isEnabled, !text.isEmpty, !isChannel else { return unchanged }
        self.groups = (try? self.loadGroups()) ?? self.groups
        guard !self.groups.isEmpty else { return unchanged }
        if isGroup && !self.boolValue("enabled_groups", default: true) { return unchanged }
        if !isGroup && !self.boolValue("enabled_private", default: true) { return unchanged }

        let caseSensitive = self.boolValue("case_sensitive", default: false)
        var patterns: [String] = []
        var lookup: [String: String] = [:]
        for group in self.groups.sorted(by: { $0.command.count > $1.command.count }) {
            let command = group.command.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !command.isEmpty, let first = command.first, let last = command.last, !group.usernames.isEmpty else { continue }
            let clean = group.usernames.prefix(self.maximumUsers).map { username -> String in
                username.hasPrefix("@") ? String(username.dropFirst()) : username
            }.filter { username in
                !username.isEmpty && username.range(of: "^[A-Za-z0-9_]+$", options: .regularExpression) != nil
            }
            guard !clean.isEmpty else { continue }
            let mention = clean.map { "@" + $0 }.joined(separator: " ")
            lookup[caseSensitive ? command : command.lowercased()] = mention

            let escaped = NSRegularExpression.escapedPattern(for: command)
            let left: String
            if Self.isWordCharacter(first) {
                left = "(?<![\\w@])"
            } else {
                left = "(?<![\\w" + NSRegularExpression.escapedPattern(for: String(first)) + "])"
            }
            let right: String
            if Self.isWordCharacter(last) {
                right = "(?!\\w)"
            } else {
                right = "(?![\\w" + NSRegularExpression.escapedPattern(for: String(last)) + "])"
            }
            patterns.append(left + escaped + right)
        }
        guard !patterns.isEmpty else { return unchanged }
        let options: NSRegularExpression.Options = caseSensitive ? [] : [.caseInsensitive]
        guard let expression = try? NSRegularExpression(pattern: patterns.joined(separator: "|"), options: options) else {
            return unchanged
        }
        let source = text as NSString
        let fullRange = NSRange(location: 0, length: source.length)
        let matches = expression.matches(in: text, range: fullRange)
        guard !matches.isEmpty else { return unchanged }

        var output = ""
        var replacements: [AyuNativeTextReplacement] = []
        var cursor = 0
        for match in matches {
            let range = match.range
            guard range.location >= cursor, range.length > 0 else { continue }
            let matched = source.substring(with: range)
            guard let mention = lookup[caseSensitive ? matched : matched.lowercased()] else { continue }
            if range.location > cursor {
                output += source.substring(with: NSRange(location: cursor, length: range.location - cursor))
            }
            output += mention
            replacements.append(AyuNativeTextReplacement(range: range, length: (mention as NSString).length))
            cursor = range.location + range.length
        }
        guard !replacements.isEmpty else { return unchanged }
        if cursor < source.length {
            output += source.substring(from: cursor)
        }

        let key = "\(accountKey):\(peerID)"
        if let last = self.cooldowns[key], Date().timeIntervalSince(last) < self.cooldown {
            let remaining = Int(self.cooldown - Date().timeIntervalSince(last)) + 1
            AyuNativePluginRuntime.shared.showMessage("Кулдаун: подождите ещё \(max(1, remaining)) сек. перед повторным упоминанием", style: "error")
            return unchanged
        }
        self.cooldowns[key] = Date()
        return AyuNativeTextRewrite(text: output, replacements: replacements)
    }

    private static func isWordCharacter(_ character: Character) -> Bool {
        guard let scalar = character.unicodeScalars.first else { return false }
        return scalar == "_" || CharacterSet.alphanumerics.contains(scalar)
    }
}
