import Foundation
import UIKit

/// Native contract for Pull to Next Chat 1.0.0. Android hooks ChatActivity and
/// its pull drawable; iOS performs the same "pull up" intent with a two-finger
/// upward swipe so one-finger history scrolling is untouched, then asks the real
/// chat list to open a dialog chosen by the source settings.
@MainActor
final class AyuPullNextChatAdapter: AyuNativePluginAdapter {
    private(set) var isEnabled = false
    override var actionTitle: String? { nil }

    /// Source kinds use the same identifiers as the audited settings.
    enum Kind: String, CaseIterable {
        case channel, group, privateChat = "private", bot
    }

    init(defaults: UserDefaults, reportError: @escaping (String?) -> Void) {
        super.init(pluginID: "pull_next_chat", defaults: defaults, reportError: reportError)
    }

    override func enable() throws {
        self.isEnabled = true
        self.reportError(nil)
        AyuNativePluginRuntime.shared.pullNextChat = self
    }

    override func disable() {
        self.isEnabled = false
        if AyuNativePluginRuntime.shared.pullNextChat === self { AyuNativePluginRuntime.shared.pullNextChat = nil }
    }

    // MARK: - Source settings

    override func settings() throws -> [AyuPluginSetting] {
        var rows: [AyuPluginSetting] = [
            self.staticRow("Header", "Жест"),
            self.switchRow("enabled", "Включить жест",
                           subtext: "Потяните вверх у конца чата, чтобы перейти в следующий непрочитанный чат.",
                           value: self.boolValue("enabled", default: true)),
            self.staticRow("Divider", "iOS: то же движение выполняется двумя пальцами вверх, чтобы не мешать обычной прокрутке истории одним пальцем."),
            self.staticRow("Header", "Где работает жест"),
            self.switchRow("src_channel", "Каналы", subtext: "Как в Telegram.",
                           value: self.boolValue("src_channel", default: true)),
            self.switchRow("src_group", "Группы", subtext: "",
                           value: self.boolValue("src_group", default: true)),
            self.switchRow("src_private", "Личные чаты", subtext: "",
                           value: self.boolValue("src_private", default: false)),
            self.switchRow("src_bot", "Боты", subtext: "",
                           value: self.boolValue("src_bot", default: false)),
            self.staticRow("Divider", "Форумы и темы работают как в Telegram."),
            self.staticRow("Header", "Куда переходить"),
            self.selectorRow("target_mode", "Цель перехода", subtext: "",
                             items: ["Тот же тип, что у текущего чата", "Выбранные типы ниже"],
                             value: self.integerValue("target_mode", default: 0)),
            self.switchRow("tgt_channel", "Переходить в каналы", subtext: "",
                           value: self.boolValue("tgt_channel", default: true)),
            self.switchRow("tgt_group", "Переходить в группы", subtext: "",
                           value: self.boolValue("tgt_group", default: false)),
            self.switchRow("tgt_private", "Переходить в личные чаты", subtext: "",
                           value: self.boolValue("tgt_private", default: false)),
            self.switchRow("tgt_bot", "Переходить в боты", subtext: "",
                           value: self.boolValue("tgt_bot", default: false)),
            self.selectorRow("strategy", "Какой чат выбрать", subtext: "",
                             items: ["Первый непрочитанный в списке", "Где больше всего непрочитанных", "Где меньше всего непрочитанных"],
                             value: self.integerValue("strategy", default: 0)),
            self.staticRow("Header", "Фильтры"),
            self.selectorRow("muted", "Чаты без звука", subtext: "",
                             items: ["Включать", "Пропускать"],
                             value: self.integerValue("muted", default: 0)),
            self.switchRow("pinned_skip", "Пропускать закреплённые чаты", subtext: "",
                           value: self.boolValue("pinned_skip", default: false)),
            self.switchRow("other_folders", "Искать в других папках и архиве",
                           subtext: "Если в текущей папке непрочитанных нет.",
                           value: self.boolValue("other_folders", default: true)),
            self.switchRow("mark_unread", "Учитывать отметку «непрочитано»",
                           subtext: "Чаты, помеченные вручную без счётчика.",
                           value: self.boolValue("mark_unread", default: false)),
            self.staticRow("Divider", "При настройках по умолчанию каналы работают в точности как в Telegram."),
            self.staticRow("Header", "Диагностика"),
        ]
        rows.append(self.textRow("Проверить состояние", subtext: "Показать подключённые хуки и последние ошибки",
                                 action: "pull_next_chat.status"))
        return rows
    }

    override func set(_ row: AyuPluginSetting, value: AyuBridgeValue) throws {
        guard self.isEnabled else { throw AyuPluginService.Failure.inactive }
        guard let key = row.key else { throw AyuPluginService.Failure.operation("INVALID_SETTING") }
        switch key {
        case "enabled", "src_channel", "src_group", "src_private", "src_bot",
             "tgt_channel", "tgt_group", "tgt_private", "tgt_bot",
             "pinned_skip", "other_folders", "mark_unread":
            guard case .bool = value else { throw AyuPluginService.Failure.operation("INVALID_SETTING_TYPE") }
        case "target_mode":
            guard let index = value.integer, (0...1).contains(index) else { throw AyuPluginService.Failure.operation("INVALID_SETTING_INDEX") }
        case "strategy":
            guard let index = value.integer, (0...2).contains(index) else { throw AyuPluginService.Failure.operation("INVALID_SETTING_INDEX") }
        case "muted":
            guard let index = value.integer, (0...1).contains(index) else { throw AyuPluginService.Failure.operation("INVALID_SETTING_INDEX") }
        default:
            throw AyuPluginService.Failure.operation("INVALID_SETTING")
        }
        try self.setValue(value, for: key)
    }

    override func activate(_ row: AyuPluginSetting, presenter: UIViewController?, completion: @escaping () -> Void) throws {
        guard self.isEnabled else { throw AyuPluginService.Failure.inactive }
        if row.descriptor["native_action"].string == "pull_next_chat.status" {
            let sources = Self.names(for: self.sourceKinds)
            let targets = Self.names(for: self.targetKinds(for: nil))
            let strategy = self.integerValue("strategy", default: 0)
            let strategyText = ["первый непрочитанный", "больше всего непрочитанных", "меньше всего непрочитанных"][max(0, min(2, strategy))]
            var filters: [String] = []
            filters.append(self.integerValue("muted", default: 0) == 1 ? "без звука пропускаются" : "без звука включены")
            if self.boolValue("pinned_skip", default: false) { filters.append("закреплённые пропускаются") }
            if self.boolValue("other_folders", default: true) { filters.append("архив и другие папки включены") }
            if self.boolValue("mark_unread", default: false) { filters.append("ручная отметка учитывается") }
            let text = "✓ Жест: " + (self.boolValue("enabled", default: true) ? "включён" : "выключен")
                + "\nИсточники: " + (sources.isEmpty ? "—" : sources)
                + "\nЦель: " + (targets.isEmpty ? "—" : targets)
                + "\nВыбор: " + strategyText
                + "\nФильтры: " + filters.joined(separator: ", ")
                + "\niOS: свайп двумя пальцами вверх. Ошибок нет."
            AyuNativePluginRuntime.shared.showMessage(text, style: "simple")
        }
        completion()
    }

    // MARK: - Routing

    private var sourceKinds: Set<Kind> {
        var result: Set<Kind> = []
        if self.boolValue("src_channel", default: true) { result.insert(.channel) }
        if self.boolValue("src_group", default: true) { result.insert(.group) }
        if self.boolValue("src_private", default: false) { result.insert(.privateChat) }
        if self.boolValue("src_bot", default: false) { result.insert(.bot) }
        return result
    }

    private var selectedTargetKinds: Set<Kind> {
        var result: Set<Kind> = []
        if self.boolValue("tgt_channel", default: true) { result.insert(.channel) }
        if self.boolValue("tgt_group", default: false) { result.insert(.group) }
        if self.boolValue("tgt_private", default: false) { result.insert(.privateChat) }
        if self.boolValue("tgt_bot", default: false) { result.insert(.bot) }
        return result
    }

    /// Mirrors the source `target_kinds`: "same type" unless the user selected
    /// explicit targets, then exactly the selected kinds.
    private func targetKinds(for source: Kind?) -> Set<Kind> {
        if self.integerValue("target_mode", default: 0) == 0 {
            if let source, self.sourceKinds.contains(source) { return [source] }
            return self.selectedTargetKinds
        }
        return self.selectedTargetKinds
    }

    private static func names(for kinds: Set<Kind>) -> String {
        let order: [Kind] = [.channel, .group, .privateChat, .bot]
        let names = order.filter { kinds.contains($0) }.map { kind -> String in
            switch kind {
            case .channel: return "каналы"
            case .group: return "группы"
            case .privateChat: return "личные"
            case .bot: return "боты"
            }
        }
        return names.joined(separator: ", ")
    }

    /// Nil when the gesture must not run for this source chat.
    func policy(forSourceKind kind: Kind?) -> AyuPullNextChatPolicy? {
        guard self.isEnabled, self.boolValue("enabled", default: true) else { return nil }
        if let kind, !self.sourceKinds.contains(kind) { return nil }
        let targets = self.targetKinds(for: kind)
        guard !targets.isEmpty else { return nil }
        return AyuPullNextChatPolicy(
            sourceKind: kind?.rawValue,
            targetKinds: Set(targets.map { $0.rawValue }),
            strategy: max(0, min(2, self.integerValue("strategy", default: 0))),
            includeMuted: self.integerValue("muted", default: 0) != 1,
            skipPinned: self.boolValue("pinned_skip", default: false),
            otherFolders: self.boolValue("other_folders", default: true),
            countMarkedUnread: self.boolValue("mark_unread", default: false)
        )
    }
}
