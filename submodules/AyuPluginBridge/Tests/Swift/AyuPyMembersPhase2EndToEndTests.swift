import Foundation
import XCTest
@testable import AyuPluginBridge

/// Phase 2 of the SDK-served members against the real Swift host: the `AlertDialog` facade, `java.lang.Class`
/// lookups over local and host classes, allocated buffers and `PluginsController` statics. Values are written to
/// `AYU_PYMEMBERS_RESULT2` when that variable is set.
@MainActor
final class AyuPyMembersPhase2EndToEndTests: XCTestCase {
    static let plugin = AyuEndToEnd.source(id: "e2e_pymembers2", """
    from android.graphics import Point
    from android.view import View
    from android.widget import FrameLayout
    from base_plugin import BasePlugin
    from com.exteragram.messenger.plugins import PluginsController
    from java import jclass
    from java.lang import Integer
    from java.nio import ByteBuffer
    from org.telegram.messenger import ApplicationLoader
    from org.telegram.ui.ActionBar import AlertDialog

    \(AyuEndToEnd.recorder)


    class PyMembersPlugin(Recorder, BasePlugin):
        def on_plugin_load(self):
            context = ApplicationLoader.applicationContext
            Class = jclass("java.lang.Class")
            self.record("dialog_classes", lambda: [type(AlertDialog).__name__, AlertDialog.Builder is jclass("org.telegram.ui.ActionBar.AlertDialog$Builder"),
                                                   AlertDialog.BUTTON_POSITIVE, AlertDialog.OnButtonClickListener.__name__])
            builder = AlertDialog.Builder(context).setTitle("T").setMessage("M")
            builder.setPositiveButton("OK", lambda dialog, which: None).setNegativeButton("No", None)
            dialog = builder.create()
            self.record("dialog_built", lambda: [dialog.isShowing(), type(dialog) is AlertDialog, builder.create() is dialog,
                                                 dialog.getContext().getClass().getName()])
            self.record("dialog_show", lambda: builder.show())
            self.record("dialog_after", lambda: dialog.isShowing())
            style = AlertDialog.ALERT_TYPE_SPINNER
            self.record("dialog_progress", lambda: AlertDialog(context, style))
            self.record("for_name", lambda: [
                Class.forName("android.graphics.Point").getName(), type(Class.forName("android.graphics.Point")).__name__,
                Class.forName("android.view.View").getName(), type(Class.forName("android.view.View", False, None)).__name__,
                Class.forName("android.graphics.Point") == Point.getClass()])
            self.record("for_name_missing", lambda: Class.forName("org.sample.Missing"))
            point, mirror = Point(3, 4), Point.getClass()
            self.record("local_reflect", lambda: [
                mirror.getDeclaredField("x").get(point), mirror.getDeclaredMethod("offset", Integer.TYPE, Integer.TYPE).invoke(point, 1, 1),
                point.x, [field.getName() for field in mirror.getDeclaredFields()],
                Integer.getClass().getField("MAX_VALUE").get(None)])
            self.record("local_missing_field", lambda: getattr(mirror, "getDeclared" + "Field")("z"))
            self.record("local_missing_method", lambda: mirror.getDeclaredMethod("offset"))
            params = FrameLayout.LayoutParams(10, 20)
            params_class = params.getClass()
            width = params_class.getDeclaredField("width")
            self.record("host_reflect", lambda: [
                type(params_class).__name__, width.get(params), width.set(params, 30), params.width,
                FrameLayout.LayoutParams.getClass().getField("MATCH_PARENT").get(None),
                sorted(field.getName() for field in params_class.getFields())[:3],
                params_class.getMethod("setMargins", Integer.TYPE, Integer.TYPE, Integer.TYPE, Integer.TYPE).getName(),
                width.getDeclaringClass().getName()])
            self.record("host_missing_field", lambda: getattr(params_class, "getDeclared" + "Field")("mPrivate"))
            self.record("host_missing_method", lambda: getattr(params_class, "get" + "Method")("explode"))
            self.record("host_own_lookup", lambda: [View.getClass().getDeclaredMethod("setVisibility").getName(),
                                                    type(View.getClass().getDeclaredMethod("setVisibility")).__name__])
            self.record("not_a_class", lambda: [hasattr(params, "getDeclaredField"), hasattr(params_class, "getDeclaredField")])
            direct = ByteBuffer.allocateDirect(8)
            self.record("buffer", lambda: [type(direct).__name__, direct.capacity(), direct.isDirect(), direct.putInt(7).position(),
                                           type(ByteBuffer).__name__])
            self.record("plugins", lambda: [PluginsController.getInstance().isInitialized(), PluginsController.isPluginEngineSupported(),
                                            PluginsController.runOnPluginsQueue(lambda: self.set_setting("queued", True))])
    """)

    /// The same lookups spelled as literals: static preflight names each member the model lacks.
    static let blocked = AyuEndToEnd.source(id: "e2e_pymembers2_blocked", """
    from android.graphics import Point
    from android.widget import FrameLayout
    from base_plugin import BasePlugin
    from org.telegram.ui.ActionBar import AlertDialog


    class BlockedPlugin(BasePlugin):
        def on_plugin_load(self):
            Point.getClass().getDeclaredField("x")
            Point.getClass().getDeclaredField("z")
            params = FrameLayout.LayoutParams(10, 20)
            params.getClass().getDeclaredField("width")
            params.getClass().getDeclaredField("mPrivate")
            params.getClass().getMethod("explode")
            AlertDialog.Builder(None).setTitle("T").create().getButton(-1)
            AlertDialog(None, 3)
    """)

    func testPhase2MembersAgainstTheRealHost() async throws {
        let stack = try AyuEndToEnd.shared()
        stack.bindApplication()
        let refused = try await stack.preview(Self.blocked)
        XCTAssertEqual(refused.plugin.blockers, [
            "MEMBER: android.graphics.Point.z", "MEMBER: android.widget.FrameLayout$LayoutParams.explode",
            "MEMBER: android.widget.FrameLayout$LayoutParams.mPrivate", "MEMBER: org.telegram.ui.ActionBar.AlertDialog.<init>",
            "MEMBER: org.telegram.ui.ActionBar.AlertDialog.getButton"])
        let preview = try await stack.preview(Self.plugin)
        XCTAssertEqual(preview.plugin.blockers, [], "member-aware preflight with the real host's member table")
        let id = try await stack.start(Self.plugin)
        let first = stack.stored(id)
        try await stack.service.disable(id)
        try await stack.service.enable(id)
        let second = stack.stored(id)
        if let path = ProcessInfo.processInfo.environment["AYU_PYMEMBERS_RESULT2"] {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(["first": first, "second": second]).write(to: URL(fileURLWithPath: path))
        }
        await stack.remove(id)
        func strings(_ values: [String]) -> AyuBridgeValue { .array(values.map { .string($0) }) }
        // The class is the Python-local facade on this host, which declares `ui.present`.
        XCTAssertEqual(first["dialog_classes"], .array([.string("JavaMeta"), .bool(true), .integer(-1), .string("_OnButtonClickListener")]))
        XCTAssertEqual(first["dialog_built"], .array([.bool(false), .bool(true), .bool(true), .string("android.content.Context")]))
        // The test process has no window: the description reaches the host's presentation, which refuses.
        XCTAssertEqual(first["dialog_show"], .string("!BridgeError: SCREEN_UNAVAILABLE: Presentation root is not visible"))
        XCTAssertEqual(first["dialog_after"], .bool(false))
        XCTAssertEqual(first["dialog_progress"], .string("!UnsupportedAPI: UNSUPPORTED_API: Progress dialogs require a native adapter"))
        XCTAssertEqual(first["for_name"], .array([.string("android.graphics.Point"), .string("Class"), .string("android.view.View"),
                                                   .string("RemoteObject"), .bool(true)]))
        XCTAssertEqual(first["for_name_missing"], .string("!ClassNotFoundException: java.lang.ClassNotFoundException: org.sample.Missing"))
        XCTAssertEqual(first["local_reflect"], .array([.integer(3), .null, .integer(4), strings(["x", "y"]), .integer(2_147_483_647)]))
        XCTAssertEqual(first["local_missing_field"], .string("!NoSuchFieldException: java.lang.NoSuchFieldException: z"))
        XCTAssertEqual(first["local_missing_method"], .string("!NoSuchMethodException: java.lang.NoSuchMethodException: android.graphics.Point.offset []"))
        // The host's class object of LayoutParams: fields and methods from its published member table.
        XCTAssertEqual(first["host_reflect"], .array([.string("RemoteObject"), .integer(10), .null, .integer(30), .integer(-1),
                                                       strings(["MATCH_PARENT", "WRAP_CONTENT", "bottomMargin"]), .string("setMargins"),
                                                       .string("android.widget.FrameLayout$LayoutParams")]))
        XCTAssertEqual(first["host_missing_field"], .string("!NoSuchFieldException: java.lang.NoSuchFieldException: mPrivate"))
        XCTAssertEqual(first["host_missing_method"],
                       .string("!NoSuchMethodException: java.lang.NoSuchMethodException: android.widget.FrameLayout$LayoutParams.explode []"))
        XCTAssertEqual(first["host_own_lookup"], .array([.string("setVisibility"), .string("RemoteObject")]))
        XCTAssertEqual(first["not_a_class"], .array([.bool(false), .bool(true)]))
        XCTAssertEqual(first["buffer"], .array([.string("ByteBuffer"), .integer(8), .bool(true), .integer(4), .string("JavaClass")]))
        XCTAssertEqual(first["plugins"], .array([.bool(true), .bool(true), .null]))
        XCTAssertEqual(second["queued"], .bool(true))
    }
}
