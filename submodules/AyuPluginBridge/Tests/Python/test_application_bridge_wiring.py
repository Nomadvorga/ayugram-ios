"""Offline source/transport contracts only; not Swift, UI or device execution."""
import ast
from pathlib import Path
import unittest

BRIDGE = Path(__file__).resolve().parents[2]
ROOT = BRIDGE.parents[1]


class ApplicationBridgeWiringTests(unittest.TestCase):
    def test_singleton_installs_real_provider_without_changing_snow_route(self):
        service = (BRIDGE / "Integration/AyuPluginService.swift").read_text()
        for text in ["let application = AyuPluginApplicationBridge.shared", "provider: application, classRegistry: try application.classRegistry()",
                     "if let record = AyuAtmosphericPluginAdapter.record(for: data)", "adapter.enable()",
                     "throw Failure.unsupportedPlugin", "guard id == Self.groupMentionsID else { throw Failure.unsupportedPlugin }"]:
            self.assertIn(text, service)

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

    def test_event_transport_has_generation_and_never_starts_python_on_lifecycle(self):
        service = (BRIDGE / "Integration/AyuPluginService.swift").read_text()
        self.assertIn('let generation: String; let name = "app"', service)
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
