"""Offline source/transport contracts only; not Swift, UI or device execution."""
import ast
from pathlib import Path
import unittest

BRIDGE = Path(__file__).resolve().parents[2]
ROOT = BRIDGE.parents[1]


class ApplicationBridgeWiringTests(unittest.TestCase):
    def test_singleton_installs_real_provider_without_changing_snow_route(self):
        service = (BRIDGE / "Integration/AyuPluginService.swift").read_text()
        for text in ["let application = AyuPluginApplicationBridge.shared",
                     "let provider = AyuPluginMenuHostProvider(application: application)",
                     "AyuPluginService(provider: provider, classRegistry: try application.classRegistry())",
                     "if let record = AyuAtmosphericPluginAdapter.record(for: data)", "adapter.enable()",
                     "try await self.prepareRuntime()", "self.runtime.load(source: source, filename: id + \".plugin\", completion: $0)"]:
            self.assertIn(text, service)
        menu = (BRIDGE / "Integration/AyuPluginMenuBridge.swift").read_text()
        self.assertIn('"MESSAGE_CONTEXT_MENU"', menu)
        self.assertIn("self.menus.detach(pluginID: pluginID); self.application.detach(pluginID: pluginID)", menu)
        binding = (ROOT / "submodules/TelegramUI/Sources/Chat/ChatControllerOpenMessageContextMenu.swift").read_text()
        self.assertIn("AyuPluginMessageContextMenu.appending(to: actionsSignal", binding)
        menu_ui = (ROOT / "submodules/TelegramUI/Sources/Chat/AyuPluginMessageContextMenu.swift").read_text()
        self.assertIn("AyuPluginContextMenu.appending(to: signal, request: request, isPresented: { invocation.isCurrentMenu() })", menu_ui)
        # Every plugin menu shares one helper: native rows first, plugin rows when the bridge answers.
        helper = (ROOT / "submodules/TelegramUI/Components/PeerInfo/PeerInfoScreen/Sources/AyuPluginContextMenu.swift").read_text()
        self.assertLess(helper.index("subscriber.putNext(items)"), helper.index("AyuPluginMenuBridge.shared.open(request"))
        self.assertIn('"//submodules/AyuPluginBridge:AyuPluginBridge"',
                      (ROOT / "submodules/TelegramUI/Components/PeerInfo/PeerInfoScreen/BUILD").read_text())
        for path, kind in (("submodules/TelegramUI/Sources/ChatController.swift", ".chatActionMenu"),
                           ("submodules/TelegramUI/Components/PeerInfo/PeerInfoScreen/Sources/PeerInfoScreenPerformButtonAction.swift",
                            ".profileActionMenu")):
            source = (ROOT / path).read_text()
            self.assertIn("AyuPluginContextMenu.appending(to:", source)
            self.assertIn("AyuPluginMenuRequest(kind: " + kind, source)
            self.assertIn("ayuPluginMenu.controller = contextController", source)
        self.assertIn("AyuPluginMenuBridge.shared.bindLocations(resolve:",
                      (ROOT / "submodules/TelegramUI/Sources/AyuPluginApplicationBinding.swift").read_text())

    def test_app_binding_uses_real_signals_and_explicit_authorized_root(self):
        binding = (ROOT / "submodules/TelegramUI/Sources/AyuPluginApplicationBinding.swift").read_text()
        for text in ["sharedContext.activeAccountContexts", "sharedContext.activeAccountsWithInfo", "appLock.isCurrentlyLocked",
                     "applicationBindings.applicationInForeground", "applicationBindings.applicationIsActive",
                     "id == self.primaryID", "self.identities = self.identities.filter", "self.nextSlot += 1",
                     "case Namespaces.Peer.CloudUser", "case Namespaces.Peer.CloudGroup: dialogID = -id; isGroup = true",
                     "isChannel: isChannel", "isGroup: isGroup", "ayuNativePluginChatKind()"]:
            self.assertIn(text, binding)
        app = (ROOT / "submodules/TelegramUI/Sources/AppDelegate.swift").read_text()
        self.assertIn("self.pluginApplicationBinding = AyuTelegramPluginApplicationBinding", app)
        self.assertIn("return (context.context.account.id, context.rootController)", app)
        self.assertIn("sharedContext?.mainWindow?.presentNative(alert)", binding)
        for forbidden in ["import TelegramApi", "keyWindow", "UIApplication.shared.windows", "dlsym", "NSClassFromString"]:
            self.assertNotIn(forbidden, binding)

    def test_provider_effects_are_prepared_validated_then_committed(self):
        host = (BRIDGE / "Sources/AyuPluginNativeHost.swift").read_text()
        prepared = host.index("let prepared = try self.provider.prepareCall")
        validated = host.index("let result = try self.adapterResult(prepared.result", prepared)
        commit = host.index("prepared.commit(result)", validated)
        self.assertLess(prepared, validated); self.assertLess(validated, commit)
        self.assertIn("catch { prepared.rollback(); throw error }", host)
        self.assertIn("validateReferences(.array(arguments), owner: owner, registerCallbacks: false)", host)
        registry = (BRIDGE / "Sources/AyuBridgeClassRegistry.swift").read_text()
        self.assertIn("public let staticFields", registry)
        self.assertIn("Set(adapter.staticFields.keys).isDisjoint", registry)
        self.assertIn("public struct AyuBridgeNativeCallback: Sendable", registry)
        self.assertIn('"org.telegram.messenger.NotificationCenter$NotificationCenterDelegate": ["didReceivedNotification"]', host)
        self.assertIn('remote.kind == "adapter" || remote.kind == "array" || remote.kind == "proxy"', host)

    def test_application_scope_is_partial_and_has_real_cleanup(self):
        app = (BRIDGE / "Integration/AyuPluginApplicationBridge.swift").read_text()
        for text in ["Requested account is not active", "Account identity expired", "Screen context expired", "context.snapshot(of: reference)",
                     "self.reservations.count < 16", ".count < 4", "rollback: { self.cancelReservation(token) }",
                     "self.ownerGenerations.removeValue(forKey: pluginID)", "public func invalidatePresentations()",
                     'throw AyuBridgeFailure.unsupported("client_utils." + name)',
                     "NotificationCenter$NotificationCenterDelegate", "commitObservation", "accountChanged(selectedIndex)"]:
            self.assertIn(text, app)
        self.assertIn('"get_messages_controller":', app)
        self.assertIn("org.telegram.messenger.MessagesController", app)
        self.assertNotIn('"access_hash":', app)
        self.assertNotIn('"phone":', app)

    def test_android_utilities_callback_uses_bounded_host_scheduler(self):
        app = (BRIDGE / "Integration/AyuPluginApplicationBridge.swift").read_text()
        self.assertIn('"runOnUIThread": { args, context in', app)
        self.assertIn('runnable.className == "java.lang.Runnable"', app)
        self.assertIn('(0...60_000).contains(value)', app)
        self.assertIn('context.schedule(callback, delayMilliseconds: delay)', app)
        self.assertIn('"cancelRunOnUIThread"', (BRIDGE / "Tests/Swift/AyuPluginApplicationBridgeTests.swift").read_text())

    def test_finish_fragment_pops_the_visible_screen_through_the_apps_close_route(self):
        app = (BRIDGE / "Integration/AyuPluginApplicationBridge.swift").read_text()
        self.assertIn('"finishFragment": { state, args, _ in .prepared(try self.prepareFinishFragment(state: state, arguments: args)) }', app)
        finish = app[app.index("private func prepareFinishFragment("):app.index("private func prepareBrowserOpenURL(")]
        self.assertIn('guard bound else { throw AyuBridgeFailure("screen_unavailable"', finish)
        self.assertIn("return AyuBridgeProviderResult(.value(.bool(false)))", finish)
        self.assertIn("DispatchQueue.main.async {", finish)
        self.assertNotIn("DispatchQueue.main.sync", finish)
        self.assertIn("current.identity == screen.identity", finish)
        self.assertIn("self.screenCloserSource?(screen, animated)", finish)
        self.assertIn("self.lock.lock(); self.closeRouteBound = closeScreen != nil; self.lock.unlock()", app)

        binding = (ROOT / "submodules/TelegramUI/Sources/AyuPluginApplicationBinding.swift").read_text()
        self.assertIn("self?.closePluginScreen(screen, animated: animated)", binding)
        close = binding[binding.index("private func closePluginScreen("):binding.index("private func openPluginURL(")]
        for text in ("guard self.active, !self.locked,", "current.identity == expected.identity", "accountID == self.primaryID",
                     "navigationController.viewControllers.count > 1", "navigationController.popViewController(animated: animated)"):
            self.assertIn(text, close)
        self.assertNotIn("dismiss(", close)


    def test_browser_open_url_is_narrow_queued_and_uses_telegram_route(self):
        app = (BRIDGE / "Integration/AyuPluginApplicationBridge.swift").read_text()
        self.assertIn('private static let browser = "org.telegram.messenger.browser.Browser"', app)
        self.assertIn('"openUrl": { args, context in', app)
        self.assertIn('guard args.count == 2 else { throw Self.invalid() }', app)
        self.assertIn('uri.className == "android.net.Uri"', app)
        self.assertIn('scheme == "http" || scheme == "https"', app)
        browser = app[app.index("private func prepareBrowserOpenURL"):app.index("private func prepareSendHook")]
        self.assertIn('DispatchQueue.main.async {', browser)
        self.assertNotIn('DispatchQueue.main.sync', browser)
        self.assertNotIn('self.screen(state:', browser)
        self.assertNotIn('self.currentScreen()', browser)
        self.assertIn('guard self.isURLRouteBound()', browser)
        self.assertIn('self.lock.lock(); self.urlRouteBound = openURL != nil; self.lock.unlock()', app)
        self.assertIn('self.accounts[reservation.account.index]?.identity == reservation.account.identity', browser)
        self.assertIn('current.identity == reservation.screen.identity', browser)
        self.assertIn('current.accountIndex == reservation.screen.accountIndex', browser)
        self.assertIn('self.urlOpenerSource?(reservation.screen, reservation.url)', app)
        self.assertIn('rollback:', app[app.index("private func prepareBrowserOpenURL"):app.index("private func prepareSendHook")])

        binding = (ROOT / "submodules/TelegramUI/Sources/AyuPluginApplicationBinding.swift").read_text()
        self.assertIn('private var accountContexts: [AccountRecordId: AccountContext]', binding)
        self.assertIn('self?.openPluginURL(url, screen: screen)', binding)
        self.assertIn('current.identity == expected.identity', binding)
        self.assertIn('guard self.active, !self.locked,', binding)
        self.assertIn('current.accountIndex == expected.accountIndex', binding)
        self.assertIn('accountID == self.primaryID', binding)
        self.assertIn('self.slots[accountID] == expected.accountIndex', binding)
        # Below the plugins' ``url.open`` hooks: a plugin is not asked about a URL a plugin opens.
        self.assertIn('openExternalUrlImpl(context: accountContext, urlContext: .generic', binding)
        self.assertIn('forceExternal: false', binding)
        self.assertIn('navigationController: navigationController', binding)
        self.assertNotIn('UIApplication.shared.open', binding)

        swift_tests = (BRIDGE / "Tests/Swift/AyuPluginApplicationBridgeTests.swift").read_text()
        self.assertIn('testBrowserOpenURLStringAndUriOverloadsUseQueuedAppRoute', swift_tests)
        self.assertIn('testPreparedBrowserOpenURLRollsBackAndRevokesOnOwnerScreenAndAccountChanges', swift_tests)
        self.assertIn('testBrowserOpenURLRequiresBoundApplicationRoute', swift_tests)
        self.assertIn('testBrowserOpenURLPreparationDoesNotReadMainAndCommitQueuesEffect', swift_tests)

    def test_locale_controller_uses_bounded_presentation_locale_snapshot(self):
        app = (BRIDGE / "Integration/AyuPluginApplicationBridge.swift").read_text()
        binding = (ROOT / "submodules/TelegramUI/Sources/AyuPluginApplicationBinding.swift").read_text()
        self.assertIn('private static let localeController = "org.telegram.messenger.LocaleController"', app)
        self.assertIn('"getCurrentLocale"', app)
        self.assertIn('"getCurrentLocaleInfo"', app)
        self.assertIn('"pluralLangCode"', app)
        self.assertIn('"isRTL"', app)
        self.assertIn('validateLocaleControllerState', app)
        self.assertIn('localeIdentifierSource', app)
        self.assertIn('Locale.current.identifier', app)
        self.assertIn('baseLanguageCode', binding)
        self.assertNotIn('setLocale', app)
        self.assertNotIn('getString', app[app.index('let localeControllerAdapter'):app.index('let accountAdapter')])
        swift_tests = (BRIDGE / "Tests/Swift/AyuPluginApplicationBridgeTests.swift").read_text()
        self.assertIn('testLocaleControllerUsesBoundedTelegramPresentationLocaleSnapshot', swift_tests)

    def test_class_for_name_stays_inside_the_registered_exact_class_set(self):
        host = (BRIDGE / "Sources/AyuPluginNativeHost.swift").read_text()
        self.assertIn('remote.className == "java.lang.Class", method == "forName"', host)
        self.assertIn('guard self.knownClass(name) else { throw AyuBridgeFailure.unsupported(name) }', host)
        self.assertIn('"java.lang.Class": [:]', host)
        self.assertIn('private static let classFactoryMethods: Set<String> = ["forName"]', host)
        swift_tests = (BRIDGE / "Tests/Swift/AyuPluginNativeHostTests.swift").read_text()
        self.assertIn('testClassForNameResolvesOnlyExactRegisteredClasses', swift_tests)

    def test_event_transport_has_generation_and_never_starts_python_on_lifecycle(self):
        service = (BRIDGE / "Integration/AyuPluginService.swift").read_text()
        relay = (BRIDGE / "Integration/AyuPluginDeliveryQueue.swift").read_text()
        self.assertIn('let generation: String; let name = "app"', relay)
        self.assertIn("self.pythonGenerations[owner] == generation", service)
        lifecycle = service[service.index("public func applicationDidChange"):service.index("private func inspect(")]
        self.assertNotIn("prepareRuntime", lifecycle)
        self.assertIn('self.emitApplicationEvent("PAUSE")', lifecycle)
        self.assertIn('self.emitApplicationEvent("STOP")', lifecycle)
        self.assertIn('self.emitApplicationEvent("RESUME")', lifecycle)
        tree = ast.parse((BRIDGE / "Python/ayu_bridge.py").read_text())
        runtime = next(node for node in tree.body if isinstance(node, ast.ClassDef) and node.name == "Runtime")
        method = next(node for node in runtime.body if isinstance(node, ast.FunctionDef) and node.name == "emit_event_json")
        self.assertIn('event[\'generation\'] != scope.generation', ast.unparse(method))

    def test_bundled_smoke_is_synthetic_read_only_and_has_dismissal_callback(self):
        tree = ast.parse((BRIDGE / "Resources/bridge_smoke.plugin").read_text())
        methods = {node.name for node in ast.walk(tree) if isinstance(node, ast.FunctionDef)}
        self.assertTrue({"on_app_event", "_show_context", "_dialog_clicked"}.issubset(methods))
        attributes = {node.attr for node in ast.walk(tree) if isinstance(node, ast.Attribute)}
        self.assertIn("getClientUserId", attributes)
        self.assertIn("dismiss", attributes)
        self.assertTrue(attributes.isdisjoint({"send_message", "send_request", "deleteMessages", "edit_message"}))


if __name__ == "__main__":
    unittest.main()
