"""Static contracts for the four source-pinned native iOS routes plus the
Group Mentions bridge route.

These tests read Swift sources as text. They prove the audited plugin contract
is present in the host and that no supplied .plugin file is vendored. They do
not compile Swift, execute plugin code or claim device behaviour.
"""
from pathlib import Path
import unittest

BRIDGE = Path(__file__).resolve().parents[2]
ROOT = BRIDGE.parents[1]
INTEGRATION = BRIDGE / "Integration"


class NativePluginRouteTests(unittest.TestCase):
    def test_catalog_pins_four_native_sources_and_routes_group_mentions_to_python(self):
        catalog = (INTEGRATION / "AyuNativePluginAdapter.swift").read_text()
        expected = {
            "sand_box": "9bd2c5ffa93e6a866212a4e0fd263b6216dc10080bbd55c79f40625e8942f8e5",
            "ball": "89f079f2a055ba851b6efec90a2c57d233b1f7204102363b2a637fa06579ea8f",
            "screenshot_privacy": "ce11a973f667623b84aadd1fc68d50fedf410e605759c251789383641cbef23e",
            "pull_next_chat": "69975fd768369d2a46d28dbe87f8c580f772d0f974ce8434fca58f65babed709",
        }
        self.assertEqual(catalog.count("AyuNativePluginDescriptor(id: \""), 4)
        for plugin_id, digest in expected.items():
            self.assertIn('id: "%s"' % plugin_id, catalog)
            self.assertIn('sha256: "%s"' % digest, catalog)
        # Group Mentions must execute its original source through the Python
        # bridge instead of taking a host-owned native route.
        self.assertNotIn('id: "group_mentions"', catalog)
        self.assertNotIn("25ae71486b29481d57cc36eaf40e931522a655227d2870dfc898174b8d96f28e", catalog)
        self.assertIn("guard digest == self.sha256 else { return nil }", catalog)
        self.assertIn("AyuNativePluginCatalog.blocker(for:", (INTEGRATION / "AyuPluginService.swift").read_text())

    def test_fail_closed_source_mismatch_is_a_blocker(self):
        catalog = (INTEGRATION / "AyuNativePluginAdapter.swift").read_text()
        self.assertIn("static func declaredID(in source: String)", catalog)
        self.assertIn("не совпадает с проверенной версией", catalog)
        self.assertIn("blockers: [self.blocker(for: id)]", catalog)
        service = (INTEGRATION / "AyuPluginService.swift").read_text()
        self.assertIn("guard inspection.blockers.isEmpty else { throw Failure.operation(\"UNSUPPORTED_API\") }", service)
        self.assertIn("record.nativeAdapter = nil", service)

    def test_sandbox_matches_source_palette_and_defaults(self):
        sand = (INTEGRATION / "AyuSandBoxAdapter.swift").read_text()
        for name in ["Ластик", "Стена", "Камень", "Песок", "Земля", "Порох", "Снег",
                     "Семя", "Пепел", "Вода", "Масло", "Кислота", "Щёлочь", "Ртуть",
                     "Лава", "Пар", "Дым", "Газ", "Дерево", "Уголь", "Динамит",
                     "Лёд", "Растение", "Грибок", "Провод", "Батарея", "Лампа",
                     "Стекло", "Соль", "Огонь", "Молния", "Искра"]:
            self.assertIn('return "%s"' % name, sand)
        self.assertEqual(sand.count("var emoji: String"), 1)
        self.assertIn('var selected: AyuSandElement = .water', sand)
        self.assertIn('var gridWidth: Int { 150 }', sand)
        self.assertIn('var speed: Int { 1 }', sand)
        self.assertIn('self.button("Очистить"', sand)
        self.assertIn('Поле очищено', sand)
        self.assertIn('Демо-сцена построена', sand)
        self.assertIn('Сцена загружена', sand)
        runtime = (INTEGRATION / "AyuNativePluginAdapter.swift").read_text()
        self.assertIn('command.hasPrefix(".sand")', runtime)
        self.assertIn("return true", runtime[runtime.index("public func handleSandCommand"):])

    def test_ball_uses_source_combo_and_honest_gyro_gap(self):
        ball = (INTEGRATION / "AyuBallAdapter.swift").read_text()
        self.assertIn('var gravity: CGFloat { 1300 }', ball)
        self.assertIn('var diameter: CGFloat { 56 }', ball)
        self.assertIn('var restitution: CGFloat { 0.80 }', ball)
        self.assertIn('"counter", "Счётчик комбо"', ball)
        self.assertIn('subtext: "Показывать множитель X при ударах"', ball)
        self.assertIn('"Управление наклоном"', ball)
        self.assertIn("гироскоп не используется", ball)
        self.assertIn('self.comboLabel.text = "X\\(self.combo)"', ball)
        self.assertIn("now - self.lastHit > 1.6", ball)
        self.assertNotIn("Счёт: ", ball)
        self.assertNotIn("private var score", ball)

    def test_group_mentions_bridge_executes_original_source(self):
        # The plugin is absent from the native catalog, so import/inspect/load
        # must take the Python source path.
        catalog = (INTEGRATION / "AyuNativePluginAdapter.swift").read_text()
        self.assertNotIn('id: "group_mentions"', catalog)
        self.assertIn("static func record(for source: Data) -> AyuInstalledPlugin?", catalog)
        self.assertIn("let json = try await self.complete { self.runtime.load(source: source", (INTEGRATION / "AyuPluginService.swift").read_text())
        # Host-side Android/Telegram shims used by the unmodified source.
        host = (BRIDGE / "Sources/AyuPluginNativeHost.swift").read_text()
        for text in ["android.widget.EditText", "setHint", "setHintTextColor", "setSingleLine", "setMinLines",
                     "presentCustomDialog", "org.telegram.ui.ActionBar.AlertDialog"]:
            self.assertIn(text, host)
        app = (INTEGRATION / "AyuPluginApplicationBridge.swift").read_text()
        for text in ['"get_messages_controller":', "org.telegram.messenger.MessagesController",
                     "org.telegram.tgnet.TLRPC$Chat", "org.telegram.ui.ActionBar.Theme",
                     "android.util.TypedValue", "org.telegram.ui.Components.BulletinFactory"]:
            self.assertIn(text, app)
        # Original send hook is dispatched; the native Group Mentions rewrite is not.
        controller = (ROOT / "submodules/TelegramUI/Sources/ChatController.swift").read_text()
        self.assertIn("AyuPluginService.shared.hasSendHooks", controller)
        self.assertIn("AyuPluginService.shared.applySendHooks(", controller)
        self.assertNotIn("self.ayuExpandGroupMentions(in: messages)", controller)
        # Sub-fragment navigation is driven by the plugin callback tag.
        manager = (INTEGRATION / "AyuPluginManagerViewController.swift").read_text()
        self.assertIn('row.descriptor["create_sub_fragment"]["$callback"].string', manager)
        self.assertIn("self.service.subpage(pluginID:", manager)
        settings = (BRIDGE / "Python/ui/settings.py").read_text()
        self.assertIn('"create_sub_fragment"', settings)

    def test_screenshot_privacy_is_honest_ios_shield(self):
        privacy = (INTEGRATION / "AyuScreenshotPrivacyAdapter.swift").read_text()
        self.assertIn('"Когда замазывать"', privacy)
        self.assertIn('items: ["Автоматически", "Только вручную"]', privacy)
        self.assertIn("UIScreen.screens.contains(where: { $0.isCaptured })", privacy)
        self.assertIn("UIApplication.userDidTakeScreenshotNotification", privacy)
        self.assertIn("не Android FLAG_SECURE", privacy)
        self.assertIn("не может удалить системный скриншот", privacy)
        self.assertNotIn('selectorRow("style"', privacy)
        self.assertNotIn('case "style"', privacy)

    def test_pull_next_chat_keeps_source_keys_and_mapping(self):
        pull = (INTEGRATION / "AyuPullNextChatAdapter.swift").read_text()
        for key, default in [("enabled", "true"), ("src_channel", "true"), ("src_group", "true"),
                             ("src_private", "false"), ("src_bot", "false")]:
            self.assertIn('self.boolValue("%s", default: %s)' % (key, default), pull)
        self.assertIn('"Потяните вверх у конца чата, чтобы перейти в следующий непрочитанный чат."', pull)
        self.assertIn("двумя пальцами вверх", pull)
        controller = (ROOT / "submodules/TelegramUI/Sources/ChatController.swift").read_text()
        self.assertIn("minimumNumberOfTouches = 2", controller)
        self.assertIn("maximumNumberOfTouches = 2", controller)
        self.assertIn("AyuNativePluginRuntime.shared.requestNextUnread", controller)
        root = (ROOT / "submodules/TelegramUI/Sources/TelegramRootController.swift").read_text()
        self.assertIn("openNextUnreadChat(", (ROOT / "submodules/TelegramUI/Sources/AyuPluginApplicationBinding.swift").read_text())
        self.assertIn("targetKinds: policy.targetKinds", (ROOT / "submodules/TelegramUI/Sources/AyuPluginApplicationBinding.swift").read_text())
        self.assertIn("currentPeerId: policy.currentPeerId", (ROOT / "submodules/TelegramUI/Sources/AyuPluginApplicationBinding.swift").read_text())
        self.assertIn("selectNextUnreadChat(", root)
        chat_list = (ROOT / "submodules/ChatListUI/Sources/ChatListController.swift").read_text()
        self.assertIn("func selectNextUnreadChat(targetKinds: Set<String>, currentPeerId: Int64?", chat_list)
        self.assertIn("strategy: Int,", chat_list)
        self.assertIn("searchOtherFolders: Bool, countMarkedUnread: Bool", chat_list)

    def test_plugin_send_hooks_run_before_entity_generation(self):
        controller = (ROOT / "submodules/TelegramUI/Sources/ChatController.swift").read_text()
        self.assertIn("handleSandCommand(text, from: strongSelf)", controller)
        self.assertIn("AyuPluginService.shared.hasSendHooks", controller)
        self.assertIn("AyuPluginService.shared.applySendHooks(", controller)
        self.assertIn("self.sendMessagesResolved(resolved", controller)
        self.assertIn("enqueueMessages(messages: ayuMessages)", controller)
        self.assertIn("private func ayuBridgeReplacements(old: String, new: String)", controller)
        self.assertIn("return [AyuNativeTextReplacement(range: NSRange(location: prefix, length: oldLength), length: newLength)]", controller)
        self.assertIn("case let .message(text, attributes, inlineStickers, mediaReference", controller)
        self.assertIn("self.ayuMapTextOffset(entity.range.lowerBound", controller)
        self.assertIn("TextEntitiesMessageAttribute(entities: entities)", controller)
        service = (INTEGRATION / "AyuPluginService.swift").read_text()
        self.assertIn("public func applySendHooks(message: String?, caption: String?", service)
        self.assertIn("[.integer(accountIndex), .object(values)]", service)
        # The chain is an async main-actor loop: CANCEL stops it, MODIFY replaces
        # the mutable params for every later hook.
        self.assertIn("for hook in hooks {", service)
        self.assertIn("if strategy == 1 {", service)
        self.assertIn('completion(values["message"]?.string, values["caption"]?.string, true)', service)
        self.assertIn("if strategy == 2 || strategy == 3, let updated = result[\"params\"]?.object {", service)

    def test_no_supplied_plugin_sources_are_vendored(self):
        names = {"sand_box.plugin", "ball.plugin", "group_mentions.plugin",
                 "screenshot_privacy.plugin", "pull_next_chat.plugin"}
        found = {path.name for path in BRIDGE.rglob("*.plugin")}
        self.assertTrue(names.isdisjoint(found), found)


if __name__ == "__main__":
    unittest.main()
