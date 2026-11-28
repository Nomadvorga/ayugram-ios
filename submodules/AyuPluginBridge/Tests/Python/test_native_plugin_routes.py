"""Static contracts for the source-pinned native iOS routes plus the
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
    def test_catalog_pins_five_native_sources_and_routes_group_mentions_to_python(self):
        catalog = (INTEGRATION / "AyuNativePluginAdapter.swift").read_text()
        expected = {
            "sand_box": "9bd2c5ffa93e6a866212a4e0fd263b6216dc10080bbd55c79f40625e8942f8e5",
            "ball": "89f079f2a055ba851b6efec90a2c57d233b1f7204102363b2a637fa06579ea8f",
            "screenshot_privacy": "ce11a973f667623b84aadd1fc68d50fedf410e605759c251789383641cbef23e",
            "pull_next_chat": "69975fd768369d2a46d28dbe87f8c580f772d0f974ce8434fca58f65babed709",
            "premium_dialog_cards": "0bb3f720881d6921101c17691127ed4833ebcde0a10ac8ee1dd8fecb55ef4180",
        }
        self.assertEqual(catalog.count("AyuNativePluginDescriptor(id: \""), 5)
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

    def test_sandbox_runs_original_game_html_in_wkwebview(self):
        sand = (INTEGRATION / "AyuSandBoxAdapter.swift").read_text()
        # The audited literal is extracted from the pinned source, never vendored.
        self.assertIn(r'let marker = "GAME_HTML = \"\"\""', sand)
        self.assertIn('source.range(of: marker, range: opening.upperBound..<source.endIndex) == nil', sand)
        self.assertIn('literal.hasPrefix("<!DOCTYPE html>")', sand)
        self.assertIn('literal.hasSuffix("</html>")', sand)
        self.assertIn(r'!literal.contains("\\")', sand)
        self.assertIn('.replacingOccurrences(of: "__GW__", with: String(Self.defaultGridWidth))', sand)
        self.assertIn('.replacingOccurrences(of: "__SP__", with: String(Self.defaultSpeed))', sand)
        self.assertIn("static let defaultGridWidth = 150", sand)
        self.assertIn("static let defaultSpeed = 1", sand)
        # Real WebView host, same base URL, poll cadence and close event as Android.
        self.assertIn("import WebKit", sand)
        self.assertIn("let webView = WKWebView(frame: .zero, configuration: configuration)", sand)
        self.assertIn("configuration.websiteDataStore = .default()", sand)
        self.assertIn('URL(string: "https://localhost/")', sand)
        self.assertIn("Timer(timeInterval: 0.3", sand)
        self.assertIn("window.__ev && window.__ev.length", sand)
        self.assertIn('sand://close', sand)
        self.assertIn("modalPresentationStyle = .fullScreen", sand)
        self.assertIn("document.getElementById('cv') !== null", sand)
        # The Swift reimplementation of the game must not return.
        for forbidden in ["AyuSandCanvas", "AyuSandElement", "requestAnimationFrame", "grid.fill"]:
            self.assertNotIn(forbidden, sand)
        runtime = (INTEGRATION / "AyuNativePluginAdapter.swift").read_text()
        self.assertIn('command.hasPrefix(".sand")', runtime)
        self.assertIn("return true", runtime[runtime.index("public func handleSandCommand"):])
        # Verified bytes are handed to the adapter; the route never re-reads disk.
        service = (INTEGRATION / "AyuPluginService.swift").read_text()
        self.assertIn("adapter.verifiedSource = source", service)

    def test_ball_uses_source_combo_and_coremotion_tilt(self):
        ball = (INTEGRATION / "AyuBallAdapter.swift").read_text()
        self.assertIn('var gravity: CGFloat { 1300 }', ball)
        self.assertIn('var diameter: CGFloat { 56 }', ball)
        self.assertIn('var restitution: CGFloat { 0.80 }', ball)
        self.assertIn('"counter", "Счётчик комбо"', ball)
        self.assertIn('subtext: "Показывать множитель X при ударах"', ball)
        self.assertIn('"gyro", "Управление наклоном"', ball)
        self.assertIn('usesTilt: self.boolValue("gyro", default: true)', ball)
        self.assertIn("import CoreMotion", ball)
        self.assertIn("startDeviceMotionUpdates(to: .main", ball)
        self.assertIn("self.motion.stopDeviceMotionUpdates()", ball)
        self.assertIn("self.velocity.dx += self.gravity * self.tiltX", ball)
        self.assertIn("self.velocity.dy += self.gravity * self.tiltY", ball)
        self.assertIn("self.filteredTiltX += (x - self.filteredTiltX) * 0.2", ball)
        self.assertIn("let dead = abs(self.filteredTiltX) - 0.05", ball)
        self.assertIn("self.tiltY = max(-1.5, min(self.filteredTiltY, 1.5))", ball)
        self.assertNotIn("гироскоп не используется", ball)
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
        # The Theme adapter lives in its own file of the application bridge.
        app = (INTEGRATION / "AyuPluginApplicationBridge.swift").read_text() + (INTEGRATION / "AyuPluginTheme.swift").read_text()
        for text in ['"get_messages_controller":', "org.telegram.messenger.MessagesController",
                     "org.telegram.tgnet.TLRPC$Chat", "org.telegram.ui.ActionBar.Theme",
                     "android.util.TypedValue", "org.telegram.ui.Components.BulletinFactory"]:
            self.assertIn(text, app)
        # Original send hook is dispatched; the native Group Mentions rewrite is not.
        controller = (ROOT / "submodules/TelegramUI/Sources/ChatController.swift").read_text()
        self.assertIn("AyuPluginTelegramAdapter.shared.hasSendMessageHooks", controller)
        self.assertIn("AyuPluginTelegramAdapter.shared.applySendHooks(", controller)
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
        self.assertIn('"Потяните вверх у последнего сообщения', pull)
        self.assertIn("одним пальцем", pull)
        self.assertNotIn("двумя пальцами", pull)
        controller = (ROOT / "submodules/TelegramUI/Sources/ChatController.swift").read_text()
        # One finger, Android direction (up), only at the newest message.
        self.assertIn("minimumNumberOfTouches = 1", controller)
        self.assertIn("maximumNumberOfTouches = 1", controller)
        self.assertIn("self.chatDisplayNode.historyNode.isScrollAtBottomPosition", controller)
        self.assertIn("self.chatLocation.threadId == nil", controller)
        self.assertIn("!self.chatDisplayNode.historyNode.offerNextChannelToRead", controller)
        self.assertIn("gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch)", controller)
        self.assertIn("AyuNativePluginRuntime.shared.requestNextUnread", controller)
        runtime = (INTEGRATION / "AyuNativePluginAdapter.swift").read_text()
        self.assertIn("self.nextUnread?(resolved, { [weak self] found in", runtime)
        self.assertIn('"Нет непрочитанных " + label', runtime)
        binding = (ROOT / "submodules/TelegramUI/Sources/AyuPluginApplicationBinding.swift").read_text()
        self.assertIn("openNextUnreadChat(", binding)
        self.assertIn("targetKinds: policy.targetKinds", binding)
        self.assertIn("currentPeerId: policy.currentPeerId", binding)
        self.assertIn("completion: completion", binding)
        root = (ROOT / "submodules/TelegramUI/Sources/TelegramRootController.swift").read_text()
        self.assertIn("selectNextUnreadChat(", root)
        self.assertIn("completion: completion", root)
        chat_list = (ROOT / "submodules/ChatListUI/Sources/ChatListController.swift").read_text()
        self.assertIn("func selectNextUnreadChat(targetKinds: Set<String>, currentPeerId: Int64?", chat_list)
        self.assertIn("strategy: Int,", chat_list)
        self.assertIn("searchOtherFolders: Bool, countMarkedUnread: Bool", chat_list)
        self.assertIn("AyuNextUnreadSelection.resolve(", chat_list)
        self.assertIn("public var ayuCurrentChatListFilterData: ChatListFilterData?", chat_list)
        self.assertNotIn("let archiveSignal = self.context.engine.messages.chatList", chat_list)
        self.assertIn("completion(false)", chat_list)
        self.assertIn("completion(true)", chat_list)
        # One shared transaction resolver for both navigation and the preview.
        selection = (ROOT / "submodules/ChatListUI/Sources/ChatListController.swift").read_text()
        self.assertIn("public static func resolve(transaction: Transaction, accountPeerId: PeerId,", selection)
        self.assertIn("transaction.getUnreadChatListPeerIds(", selection)
        self.assertIn("chatListFilterPredicate(filter: currentFilterData, accountPeerId: accountPeerId)", selection)
        self.assertIn("Namespaces.PeerGroup.archive", selection)
        self.assertIn("resolvedIsRemovedFromTotalUnreadCount(globalSettings:", selection)
        # The chat screen shows the same stock overscroll control channels use.
        self.assertIn("AyuNativePluginRuntime.shared.nextUnreadPolicy(sourceKind: raw)", controller)
        self.assertIn("private func ayuRefreshNextUnreadOffer()", controller)
        self.assertIn("self.ayuNextUnreadOfferDisposable.set(", controller)
        self.assertIn("AyuNextUnreadSelection.resolve(", controller)
        self.assertIn("self.chatDisplayNode.historyNode.nextChannelToRead = (offer.peer, nil, offer.unreadCount, offer.location)", controller)
        self.assertIn("self.chatDisplayNode.historyNode.offerNextChannelToRead = (stockOffer || ayuOffer)", controller)
        self.assertIn("self.ayuNextUnreadOffer = (target.peer, target.unreadCount, target.isArchived ? .archived : .same)", controller)
        self.assertIn("private func ayuCurrentChatListFilterData() -> ChatListFilterData?", controller)
        self.assertIn("self.ayuRefreshNextUnreadOffer() // MARK: AyuGram", controller)
        runtime = (INTEGRATION / "AyuNativePluginAdapter.swift").read_text()
        self.assertIn("public func nextUnreadPolicy(sourceKind: String) -> AyuPullNextChatPolicy?", runtime)

    def test_premium_dialog_cards_native_chat_list_route(self):
        cards = (INTEGRATION / "AyuPremiumDialogCardsAdapter.swift").read_text()
        for key in ["rcards.enable", "rcards.rounding", "rcards.online_badge", "rcards.online_border",
                    "rcards.blur", "rcards.darken", "rcards.stroke_width", "rcards.stroke_alpha",
                    "rcards.mute_dim", "rcards.mute_opacity", "rcards.mute_stroke"]:
            self.assertIn('"%s"' % key, cards)
        self.assertIn('"Основные настройки"', cards)
        self.assertIn("AyuDialogCardsState.shared.setStyle(self.makeStyle())", cards)
        self.assertIn("clamped(\"rcards.rounding\", 15.0, 0.0 ... 30.0)", cards)
        self.assertIn("clamped(\"rcards.blur\", 7.0, 1.0 ... 25.0)", cards)

        style = (ROOT / "submodules/AyuDialogCards/Sources/AyuDialogCards.swift").read_text()
        self.assertIn("public static let marginX: CGFloat = 6.0", style)
        self.assertIn("public static let marginY: CGFloat = 5.0", style)
        self.assertIn("public static let blurSourceSize: CGFloat = 90.0", style)
        self.assertIn("public static let servicePeerId: Int64 = 1271266957", style)

        row = (ROOT / "submodules/ChatListUI/Sources/Node/AyuDialogCardRow.swift").read_text()
        self.assertIn("import CoreImage", row)
        self.assertIn("CIGaussianBlur", row)
        self.assertIn("while self.order.count > 64", row)
        self.assertIn("ObjectIdentifier(source)", row)
        self.assertIn("hostView.layer.insertSublayer(self.backgroundView.layer, above: separatorLayer)", row)
        # The chat list links only the lightweight style module, never the
        # Python bridge or its runtime.
        self.assertIn("import AyuDialogCards", row)
        self.assertNotIn("import AyuPluginBridge", row)

        item = (ROOT / "submodules/ChatListUI/Sources/Node/ChatListItem.swift").read_text()
        self.assertIn("AyuDialogCardsState.shared.style", item)
        self.assertIn("AyuDialogCardsMetrics.marginX", item)
        self.assertIn("ayuDialogCardRow?.update(nil)", item)
        self.assertIn("self.avatarNode.contentNode.imageUpdated = { [weak self] _ in", item)
        self.assertIn("updateAvatarImage(self.avatarNode.imageNode.image)", item)
        self.assertIn("strongSelf.onlineNode.isHidden = !style.showsOnlineBadge", item)
        controller = (ROOT / "submodules/ChatListUI/Sources/ChatListController.swift").read_text()
        self.assertIn("AyuDialogCardsState.didChange", controller)
        self.assertIn("refreshAyuDialogCards()", controller)

    def test_request_and_update_hook_points_player_and_actions_are_wired(self):
        """Wiring only: `telegram.hooks.set`, `telegram.player` and `telegram.action.*` are listed by the
        app's backend because these call sites exist; none of it has run in the app."""
        core = ROOT / "submodules/TelegramCore/Sources"
        network = (core / "Network/Network.swift").read_text()
        self.assertIn("let ayuPluginRequestService = AyuPluginHookedRequestService(mainSession.requestService)", network)
        self.assertIn("self.requestService = ayuPluginRequestService", network)
        self.assertIn("ayuPluginRequestService.network = self", network)
        service = (core / "State/UpdateMessageService.swift").read_text()
        self.assertIn("if !ayuPluginHooksApplied, ayuPluginDefersUpdates(updates, peerId: self.peerId, gate: self.ayuPluginGate", service)
        for name in ("State/Sync/SyncDifference.swift", "State/Sync/ChannelPolling.swift"):
            self.assertIn("ayuPluginHookedDifferenceUpdates(accountPeerId: accountPeerId, updates: ", (core / name).read_text())
        hooks = (core / "AyuPlugins/AyuPluginHooks.swift").read_text()
        self.assertIn("public let ayuPluginInterceptsAllHookStreams = true", hooks)
        raw = (core / "AyuPlugins/AyuPluginRawRequest.swift").read_text()
        self.assertIn("disposable = service.add(request, plugin: events)", raw)
        adapter = (ROOT / "submodules/AyuPluginTelegramAdapter/Sources/AyuPluginTelegramAdapter.swift").read_text()
        self.assertIn('if ayuPluginInterceptsAllHookStreams { result.insert("telegram.hooks.set") }', adapter)
        self.assertIn('if state.player != nil { result.insert("telegram.player") }', adapter)
        self.assertIn("var result = Self.coreOperations.union(Self.actionOperations)", adapter)
        actions = (core / "AyuPlugins/AyuPluginActions.swift").read_text()
        for call in ("ayuPluginDeleteMessages(account:", "ayuPluginReadDialog(account:", "ayuPluginReadAllDialogs(account:",
                     "ayuPluginProcessUpdates(account:",
                     "ayuPluginStorePeers(account:", "ayuPluginLoadFullPeer(account:", "ayuPluginAddDialogsToFolder(account:"):
            self.assertIn("public func " + call, actions)
            self.assertIn(call + " target, ", adapter)
        bridge = (INTEGRATION / "AyuPluginTelegramActions.swift").read_text()
        # Read-all goes dialog by dialog through the chat list's own "Mark as Read" and leaves a bare unread mark alone.
        read_all = actions[actions.index("public func ayuPluginReadAllDialogs("):actions.index("public func ayuPluginProcessUpdates(")]
        self.assertIn("transaction.getUnreadChatListPeerIds(groupId: groupId, filterPredicate: nil", read_all)
        self.assertIn("state.count == 0, state.markedUnread", read_all)
        self.assertIn("_internal_togglePeerUnreadMarkInteractively(transaction: transaction", read_all)
        self.assertIn("setToValue: false)", read_all)
        # A move goes through the chat list's own archive call; a dialog outside the list and the chats Android keeps out are skipped.
        move = actions[actions.index("public func ayuPluginAddDialogsToFolder("):actions.index("public func ayuPluginProcessUpdates(")]
        self.assertIn("_internal_updatePeerGroupIdInteractively(transaction: transaction, peerId: peerId, groupId: groupId)", move)
        self.assertIn("guard transaction.getPeerChatListIndex(peerId) != nil else", move)
        self.assertIn("peerId == accountPeerId || dialogId == 777000 || promoted.contains(peerId)", move)
        self.assertIn("return !added ? 0 : (createsArchive ? 2 : 1)", move)
        self.assertIn("completion(.success(result))", adapter)
        # The chat list comes from one transaction over both lists and is bounded by the bridge's limit.
        self.assertIn('"telegram.peer", "telegram.messages", "telegram.dialogs",', adapter)
        self.assertIn("ayuPluginDialogsTL(account: target, limit: AyuPluginTelegramBridge.dialogListLimit)", adapter)
        postbox = (core / "AyuPlugins/AyuPluginTLFromPostbox.swift").read_text()
        dialogs = postbox[postbox.index("private func ayuPluginDialogRows("):postbox.index("public func ayuPluginMessageTL(")]
        self.assertIn("transaction.getTopChatListEntries(groupId: groupId, count: limit)", dialogs)
        self.assertIn("public func ayuPluginDialogsTL(account: Account, limit: Int) -> Signal<[AyuPluginDialogEntry], NoError>", dialogs)
        self.assertIn("groupId: archiveGroup, folderId: archiveGroup.rawValue", dialogs)
        self.assertIn("rows[position].pinnedNumber = Int32(lowest - pinningIndex) + 1", dialogs)
        self.assertIn("rows.removeSubrange((limit - result.count)...)", dialogs)
        self.assertIn("AyuPluginTL.serialize(AyuPluginTL.folderRow(row))", dialogs)
        for operation in ("delete_messages", "read_dialog", "read_all_dialogs", "process_updates", "store_peers", "load_full_peer",
                          "add_dialogs_to_folder"):
            self.assertIn('"telegram.action.' + operation + '"', bridge)
        binding = (ROOT / "submodules/TelegramUI/Sources/AyuPluginApplicationBinding.swift").read_text()
        self.assertIn("self.installPluginPlayer()", binding)
        self.assertIn("AyuPluginTelegramAdapter.shared.setPlayer { [weak self] action, completion in", binding)
        self.assertIn("ayuPluginMessageTL(item.message)", binding)

    def test_plugin_send_hooks_run_before_entity_generation(self):
        controller = (ROOT / "submodules/TelegramUI/Sources/ChatController.swift").read_text()
        self.assertIn("handleSandCommand(text, from: strongSelf)", controller)
        self.assertIn("AyuPluginTelegramAdapter.shared.hasSendMessageHooks", controller)
        self.assertIn("AyuPluginTelegramAdapter.shared.applySendHooks(", controller)
        self.assertIn("self.sendMessagesResolved(resolved", controller)
        self.assertIn("enqueueMessages(messages: ayuMessages)", controller)
        # The chat screen hands the batch to the adapter; the typed and the three-field hooks run as
        # one chain in the bridge, and TelegramCore writes the result back into the queued message.
        adapter = (ROOT / "submodules/AyuPluginTelegramAdapter/Sources/AyuPluginTelegramAdapter.swift").read_text()
        self.assertIn("ayuPluginDescribeOutgoingMessages(account: account, peerId: peerId, messages: messages)", adapter)
        self.assertIn("self.bridge.interceptSendMessage(account: self.accountIndex", adapter)
        self.assertIn("ayuPluginApplySendHook(peerId: peerId, original: original, described: described, result: result, "
                      "remapEntities: remapEntities)", adapter)
        core = (ROOT / "submodules/TelegramCore/Sources/AyuPlugins/AyuPluginSendHook.swift").read_text()
        self.assertIn("private func ayuPluginRemappedEntities(_ entities: [MessageTextEntity], from old: String, to new: String)", core)
        self.assertIn("case let .message(text, originalAttributes, inlineStickers, mediaReference", core)
        self.assertIn("TextEntitiesMessageAttribute(entities: entities)", core)
        service = (INTEGRATION / "AyuPluginService.swift").read_text()
        self.assertIn("public func applySendHooks(message: String?, caption: String?", service)
        self.assertIn("AyuBridgeSendHookChain(message: message, caption: caption, peerID: peerID, accountIndex: accountIndex)", service)
        # Wiring only: behavioral strategy/validation tests live in Swift.
        self.assertIn("for hook in hooks {", service)
        self.assertIn("guard !chain.isFinished else { break }", service)
        self.assertIn("chain.apply(result)", service)
        self.assertIn("completion(chain.message, chain.caption, chain.isCancelled)", service)
        self.assertIn("self.pythonGenerations[hook.pluginID] == generation", service)

    def test_url_open_hooks_gate_the_urls_the_app_opens_but_not_a_plugins_own(self):
        shared = (ROOT / "submodules/TelegramUI/Sources/SharedAccountContext.swift").read_text()
        gate = shared[shared.index("public func openExternalUrl(context: AccountContext"):]
        gate = gate[:gate.index("public func chatAvailableMessageActions")]
        self.assertIn("AyuPluginTelegramAdapter.shared.applyURLOpenHooks(url: url, systemBrowser: forceExternal) { url in", gate)
        self.assertIn("guard let url else { return }", gate)
        self.assertEqual(gate.count("openExternalUrlImpl("), 1)
        # The implementation has no other caller that would pass the hooks by, except the plugins' own opener.
        sources = {path: path.read_text() for path in (ROOT / "submodules/TelegramUI/Sources").glob("*.swift")}
        callers = sorted(path.name for path, text in sources.items() if "openExternalUrlImpl(" in text)
        self.assertEqual(callers, ["AyuPluginApplicationBinding.swift", "OpenUrl.swift", "SharedAccountContext.swift"])
        binding = (ROOT / "submodules/TelegramUI/Sources/AyuPluginApplicationBinding.swift").read_text()
        self.assertIn("bind(describesScreen: true, routesSendHook: true, routesURLOpen: true)", binding)
        opener = binding[binding.index("private func openPluginURL("):]
        self.assertIn("openExternalUrlImpl(context: accountContext", opener)
        self.assertNotIn("sharedContext.openExternalUrl(", opener)
        # The operation is declared only by a caller that routes the URLs, and costs nothing while nobody hooks.
        adapter = (ROOT / "submodules/AyuPluginTelegramAdapter/Sources/AyuPluginTelegramAdapter.swift").read_text()
        self.assertIn('if state.routesURLOpen { result.insert("hooks.url_open") }', adapter)
        self.assertIn("guard let bridge = self.read({ $0.routesURLOpen ? $0.bridge : nil }), bridge.hasURLOpenHooks else {\n"
                      "            completion(url)\n            return", adapter)

    def test_no_supplied_plugin_sources_are_vendored(self):
        names = {"sand_box.plugin", "ball.plugin", "group_mentions.plugin",
                 "screenshot_privacy.plugin", "pull_next_chat.plugin",
                 "premium_dialog_cards.plugin"}
        found = {path.name for path in BRIDGE.rglob("*.plugin")}
        self.assertTrue(names.isdisjoint(found), found)


if __name__ == "__main__":
    unittest.main()
