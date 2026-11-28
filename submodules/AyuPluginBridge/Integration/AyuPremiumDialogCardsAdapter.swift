import Foundation
import UIKit
import AyuDialogCards

/// Host-owned native route for Premium Dialog Cards 2.1.1.
///
/// The audited source hooks `DialogCell.onDraw` and paints a rounded card from a
/// 90 px blurred avatar bitmap, a dark tint, a vertical white stroke gradient and
/// optional muted/online overlays. Android Canvas is not available here, so this
/// route reproduces the same geometry, colours and settings in the real iOS chat
/// list. It never imports or executes the plugin's Python/Android code.
@MainActor
final class AyuPremiumDialogCardsAdapter: AyuNativePluginAdapter {
    nonisolated static let pluginID = "premium_dialog_cards"
    nonisolated static let sourceSHA256 = "0bb3f720881d6921101c17691127ed4833ebcde0a10ac8ee1dd8fecb55ef4180"

    private(set) var isEnabled = false
    override var actionTitle: String? { nil }

    init(defaults: UserDefaults, reportError: @escaping (String?) -> Void) {
        super.init(pluginID: Self.pluginID, defaults: defaults, reportError: reportError)
    }

    override func enable() throws {
        self.isEnabled = true
        self.reportError(nil)
        AyuDialogCardsState.shared.setStyle(self.makeStyle())
    }

    override func disable() {
        self.isEnabled = false
        AyuDialogCardsState.shared.setStyle(nil)
    }

    // MARK: - Settings (source keys and order)

    override func settings() throws -> [AyuPluginSetting] {
        let values = (try? self.loadValues()) ?? [:]
        func boolean(_ key: String, _ fallback: Bool) -> Bool {
            if case let .bool(flag)? = values[key] { return flag }
            return fallback
        }
        func text(_ key: String, _ fallback: String) -> String {
            if case let .string(value)? = values[key] { return value }
            if case let .number(number)? = values[key] { return String(format: "%g", number) }
            if case let .integer(number)? = values[key] { return String(number) }
            return fallback
        }
        return [
            self.staticRow("Header", "Основные настройки"),
            self.switchRow("rcards.enable", "Включить карточки",
                           subtext: "Включает плавающий стеклянный дизайн для карточек чатов.",
                           value: boolean("rcards.enable", true)),
            self.inputRow("rcards.rounding", "Радиус скругления карточек (dp)",
                          subtext: "Число от 0 (прямоугольные) до 30. По умолчанию: 15.",
                          value: text("rcards.rounding", "15")),
            self.staticRow("Header", "Индикация онлайна"),
            self.switchRow("rcards.online_badge", "Системная точка на аватаре",
                           subtext: "Стандартная зеленая точка Telegram на аватаре собеседника.",
                           value: boolean("rcards.online_badge", true)),
            self.switchRow("rcards.online_border", "Неоновая обводка карточки",
                           subtext: "Подсвечивает контур карточки собеседника в сети мягким неоновым свечением.",
                           value: boolean("rcards.online_border", false)),
            self.staticRow("Header", "Стиль и эффекты"),
            self.inputRow("rcards.blur", "Сила размытия фона",
                          subtext: "Число от 1 до 25. Одинаково для всех чатов. По умолчанию: 7.",
                          value: text("rcards.blur", "7")),
            self.inputRow("rcards.darken", "Сила затемнения (%)",
                          subtext: "Число от 0 до 100. По умолчанию: 55.",
                          value: text("rcards.darken", "55")),
            self.inputRow("rcards.stroke_width", "Толщина обводки карточки (dp)",
                          subtext: "Толщина обводки карточек в dp. 0 отключает обводку. По умолчанию: 0.5.",
                          value: text("rcards.stroke_width", "0.5")),
            self.inputRow("rcards.stroke_alpha", "Непрозрачность обводки (0-100%)",
                          subtext: "Число от 0 до 100. Яркость верхней грани карточки. По умолчанию: 24.",
                          value: text("rcards.stroke_alpha", "24")),
            self.staticRow("Header", "Чаты без звука (Muted)"),
            self.switchRow("rcards.mute_dim", "Затемнять замьюченные чаты",
                           subtext: "Включите, чтобы приглушать их карточки.",
                           value: boolean("rcards.mute_dim", false)),
            self.inputRow("rcards.mute_opacity", "Яркость замьюченных чатов (0-100%)",
                          subtext: "Работает только при включённом затемнении. По умолчанию: 30.",
                          value: text("rcards.mute_opacity", "30")),
            self.switchRow("rcards.mute_stroke", "Обводка для замьюченных чатов",
                           subtext: "Работает только при включённом затемнении.",
                           value: boolean("rcards.mute_stroke", false)),
        ]
    }

    override func set(_ row: AyuPluginSetting, value: AyuBridgeValue) throws {
        guard self.isEnabled else { throw AyuPluginService.Failure.inactive }
        guard let key = row.key, let kind = Self.types[key], kind == row.type else {
            throw AyuPluginService.Failure.operation("INVALID_SETTING")
        }
        switch kind {
        case "Switch":
            guard case .bool = value else { throw AyuPluginService.Failure.operation("INVALID_SETTING_TYPE") }
        case "Input":
            guard Self.number(from: value) != nil else { throw AyuPluginService.Failure.operation("INVALID_SETTING_TYPE") }
        default:
            throw AyuPluginService.Failure.operation("INVALID_SETTING_TYPE")
        }
        try self.setValue(value, for: key)
        AyuDialogCardsState.shared.setStyle(self.makeStyle())
    }

    // MARK: - Source ranges

    nonisolated private static let types: [String: String] = [
        "rcards.enable": "Switch",
        "rcards.rounding": "Input",
        "rcards.online_badge": "Switch",
        "rcards.online_border": "Switch",
        "rcards.blur": "Input",
        "rcards.darken": "Input",
        "rcards.stroke_width": "Input",
        "rcards.stroke_alpha": "Input",
        "rcards.mute_dim": "Switch",
        "rcards.mute_opacity": "Input",
        "rcards.mute_stroke": "Switch",
    ]

    nonisolated private static func number(from value: AyuBridgeValue) -> Double? {
        switch value {
        case let .string(text):
            return Double(text.replacingOccurrences(of: ",", with: ".").trimmingCharacters(in: .whitespacesAndNewlines))
        case let .integer(number):
            return Double(number)
        case let .number(number):
            return number
        default:
            return nil
        }
    }

    private func makeStyle() -> AyuDialogCardsStyle {
        let values = (try? self.loadValues()) ?? [:]
        func boolean(_ key: String, _ fallback: Bool) -> Bool {
            if case let .bool(flag)? = values[key] { return flag }
            return fallback
        }
        func clamped(_ key: String, _ fallback: Double, _ range: ClosedRange<Double>) -> CGFloat {
            let raw = values[key].flatMap(Self.number(from:)) ?? fallback
            return CGFloat(max(range.lowerBound, min(range.upperBound, raw)))
        }
        return AyuDialogCardsStyle(
            isEnabled: boolean("rcards.enable", true),
            rounding: clamped("rcards.rounding", 15.0, 0.0 ... 30.0),
            blur: clamped("rcards.blur", 7.0, 1.0 ... 25.0),
            darken: clamped("rcards.darken", 55.0, 0.0 ... 100.0),
            strokeWidth: clamped("rcards.stroke_width", 0.5, 0.0 ... 6.0),
            strokeAlpha: clamped("rcards.stroke_alpha", 24.0, 0.0 ... 100.0),
            onlineBorder: boolean("rcards.online_border", false),
            showsOnlineBadge: boolean("rcards.online_badge", true),
            muteDim: boolean("rcards.mute_dim", false),
            muteOpacity: clamped("rcards.mute_opacity", 30.0, 0.0 ... 100.0),
            muteStroke: boolean("rcards.mute_stroke", false)
        )
    }

    private func inputRow(_ key: String, _ text: String, subtext: String, value: String) -> AyuPluginSetting {
        AyuPluginSetting(descriptor: .object([
            "type": .string("Input"), "key": .string(key), "text": .string(text),
            "subtext": .string(subtext), "default": .string(value),
        ]), value: .string(value))
    }
}
