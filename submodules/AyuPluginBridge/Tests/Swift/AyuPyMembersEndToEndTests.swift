import Foundation
import XCTest
@testable import AyuPluginBridge

/// SDK-served members of host classes (`HOST_MEMBERS`, nested local enums, `Class.getClass()`) against the real
/// Swift host: one synthetic plugin records what each member answers, and the values are written to
/// `AYU_PYMEMBERS_RESULT` for inspection when that variable is set.
@MainActor
final class AyuPyMembersEndToEndTests: XCTestCase {
    static let plugin = AyuEndToEnd.source(id: "e2e_pymembers", """
    import os
    from android.content import Context, Intent
    from android.graphics import Paint
    from android.net import Uri
    from android.view import Gravity, HapticFeedbackConstants, MotionEvent, View
    from android.widget import ScrollView
    from base_plugin import BasePlugin
    from file_utils import get_cache_dir, get_plugins_dir
    from java.io import File
    from org.telegram.messenger import AndroidUtilities, ApplicationLoader, MessagesController, UserConfig
    from org.telegram.ui.ActionBar import Theme

    \(AyuEndToEnd.recorder)


    def below_home(file):
        path, home = file.getAbsolutePath(), os.path.realpath(os.environ.get("HOME", ""))
        return os.path.realpath(path)[len(home):] if os.path.realpath(path).startswith(home + "/") else path


    class PyMembersPlugin(Recorder, BasePlugin):
        def on_plugin_load(self):
            context = ApplicationLoader.applicationContext
            self.record("dirs", lambda: [below_home(item) for item in (
                context.getFilesDir(), context.getCacheDir(), context.getExternalFilesDir(None), context.getExternalCacheDir(),
                context.getCodeCacheDir(), context.getDir("data", 0), ApplicationLoader.getFilesDirFixed(),
                ApplicationLoader.getFilesDirFixed("child"), AndroidUtilities.getCacheDir())])
            self.record("dirs_real", lambda: [context.getFilesDir().isDirectory(), context.getExternalCacheDir().isDirectory(),
                                              File(context.getFilesDir(), "plugins").getAbsolutePath() == get_plugins_dir(),
                                              context.getCacheDir().getAbsolutePath() == get_cache_dir()])
            self.record("dir_bad_name", lambda: context.getDir("a/b", 0))
            self.record("identity", lambda: [context.getPackageName(), ApplicationLoader.getApplicationId(),
                                             context.getApplicationContext().getClass().getName(),
                                             context.getApplicationContext().getPackageName()])
            loader = context.getClassLoader()
            self.record("loader", lambda: [loader.loadClass("android.net.Uri").getName(), loader.loadClass("java.io.File").getName(),
                                           type(loader).__name__])
            self.record("loader_missing", lambda: loader.loadClass("dalvik.system." + "InMemoryDexClassLoader"))
            preferences = context.getSharedPreferences("e2e", Context.MODE_PRIVATE)
            self.record("prefs_before", lambda: [preferences.getString("text", "absent"), preferences.getInt("count", -1)])
            self.record("prefs_write", lambda: [
                preferences.edit().putString("text", "stored").putInt("count", preferences.getInt("count", 0) + 1).commit(),
                preferences.getString("text", None), preferences.getInt("count", 0), sorted(preferences.getAll().keySet()),
                preferences is context.getSharedPreferences("e2e", 0)])
            self.record("prefs_cast", lambda: preferences.getLong("count", 0))
            self.record("prefs_application", lambda: context.getSharedPreferences("main" + "config", 0))
            self.record("density", lambda: [AndroidUtilities.density, AndroidUtilities.dpf2(7.5), AndroidUtilities.dp(10)])
            self.record("display", lambda: [AndroidUtilities.displaySize.x, AndroidUtilities.displaySize.y])
            self.record("typeface_names", lambda: [AndroidUtilities.TYPEFACE_ROBOTO_MEDIUM, AndroidUtilities.TYPEFACE_ROBOTO_MONO])
            config = UserConfig.getInstance(UserConfig.selectedAccount)
            self.record("user", lambda: [UserConfig.MAX_ACCOUNT_COUNT, config.clientUserId == config.getClientUserId(), config.clientUserId])
            self.record("controller", lambda: [MessagesController.UPDATE_MASK_ALL, MessagesController.DIALOG_FILTER_FLAG_BOTS,
                                               type(MessagesController).__name__])
            self.record("constants", lambda: [
                Intent.ACTION_GET_CONTENT, Intent.CATEGORY_OPENABLE, Intent.FLAG_GRANT_READ_URI_PERMISSION, Intent.ACTION_VIEW,
                View.OVER_SCROLL_NEVER, View.VISIBLE, MotionEvent.ACTION_POINTER_DOWN, MotionEvent.ACTION_MASK, MotionEvent.ACTION_DOWN,
                HapticFeedbackConstants.KEYBOARD_TAP, HapticFeedbackConstants.LONG_PRESS, Gravity.FILL, Gravity.CENTER,
                Paint.UNDERLINE_TEXT_FLAG, Paint.ANTI_ALIAS_FLAG, context.MODE_PRIVATE])
            intent = Intent(Intent.ACTION_OPEN_DOCUMENT)
            self.record("intent", lambda: [intent.addCategory(Intent.CATEGORY_OPENABLE) is not None,
                                           intent.addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION) is not None,
                                           intent.getAction(), intent.getFlags()])
            self.record("overscroll", lambda: ScrollView(context).setOverScrollMode(View.OVER_SCROLL_NEVER))
            self.record("enum", lambda: [Paint.Align.CENTER.name(), Paint.Align.CENTER.ordinal(), Paint.Style.STROKE.getClass().getName()])
            self.record("enum_to_host", lambda: Paint().setStyle(Paint.Align.CENTER))
            uri = Uri.fromFile(File("/data/a b/file (1).txt"))
            self.record("uri", lambda: [uri.toString(), uri.getScheme(), uri.getPath(), uri.getLastPathSegment(), uri.getClass().getName()])
            self.record("class_object", lambda: [View.getClass().getName(), View.getClass().getSimpleName(), Uri.getClass().getName(),
                                                 AndroidUtilities.getClass().getName(), context.getClass().getName()])
            self.record("theme", lambda: [Theme.multAlpha(-13408615, 0.5), Theme.multAlpha(-1, 1)])
            self.record("absent", lambda: [hasattr(View, "TRANSLATION_X"), hasattr(context, "getNoBackupFilesDir")])
    """)

    func testServedMembersAgainstTheRealHost() async throws {
        let stack = try AyuEndToEnd.shared()
        stack.bindApplication()
        let preview = try await stack.preview(Self.plugin)
        XCTAssertEqual(preview.plugin.blockers, [], "member-aware preflight with the real host's member table")
        let id = try await stack.start(Self.plugin)
        let first = stack.stored(id)
        try await stack.service.disable(id)
        try await stack.service.enable(id)
        let second = stack.stored(id)
        if let path = ProcessInfo.processInfo.environment["AYU_PYMEMBERS_RESULT"] {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(["first": first, "second": second]).write(to: URL(fileURLWithPath: path))
        }
        await stack.remove(id)

        let storage = "/Library/Application Support/AyuPluginFiles", cache = "/Library/Caches/AyuPluginFiles"
        XCTAssertEqual(first["dirs"], .array([storage, cache, storage + "/external", cache + "/external", cache + "/code_cache",
                                               storage + "/app_data", storage, storage + "/child", cache + "/external"].map { .string($0) }))
        XCTAssertEqual(first["dirs_real"], .array([.bool(true), .bool(true), .bool(true), .bool(true)]))
        XCTAssertEqual(first["dir_bad_name"], .string("!IllegalArgumentException: java.lang.IllegalArgumentException: File app_a/b contains a path separator"))
        XCTAssertEqual(first["identity"], .array(["com.exteragram.messenger", "com.exteragram.messenger", "android.content.Context",
                                                   "com.exteragram.messenger"].map { .string($0) }))
        XCTAssertEqual(first["loader"], .array(["android.net.Uri", "java.io.File", "ClassLoader"].map { .string($0) }))
        XCTAssertEqual(first["loader_missing"], .string("!ClassNotFoundException: java.lang.ClassNotFoundException: dalvik.system.InMemoryDexClassLoader"))
        XCTAssertEqual(first["prefs_before"], .array([.string("absent"), .integer(-1)]))
        XCTAssertEqual(first["prefs_write"], .array([.bool(true), .string("stored"), .integer(1), .array([.string("count"), .string("text")]), .bool(true)]))
        XCTAssertEqual(first["prefs_cast"], .string("!ClassCastException: java.lang.ClassCastException: java.lang.Integer cannot be cast to java.lang.Long"))
        XCTAssertEqual(first["prefs_application"]?.string?.hasPrefix("!UnsupportedAPI: "), true)
        // The preferences file outlives the plugin generation.
        XCTAssertEqual(second["prefs_before"], .array([.string("stored"), .integer(1)]))
        XCTAssertEqual(second["prefs_write"], .array([.bool(true), .string("stored"), .integer(2), .array([.string("count"), .string("text")]), .bool(true)]))
        // The host's dp is density 1: dpf2(v) == v and dp(v) == ceil(v).
        XCTAssertEqual(first["density"], .array([.number(1), .number(7.5), .integer(10)]))
        // The test process has no window; the composition reaches the host, which refuses.
        XCTAssertEqual(first["display"], .string("!BridgeError: SCREEN_UNAVAILABLE: No visible display context"))
        XCTAssertEqual(first["typeface_names"], .array([.string("fonts/rmedium.ttf"), .string("fonts/rmono.ttf")]))
        XCTAssertEqual(first["user"], .array([.integer(16), .bool(true), .integer(9_007_199_254_740_993)]))
        XCTAssertEqual(first["controller"], .array([.integer(1535), .integer(16), .string("JavaClass")]))
        XCTAssertEqual(first["constants"], .array([
            .string("android.intent.action.GET_CONTENT"), .string("android.intent.category.OPENABLE"), .integer(1),
            .string("android.intent.action.VIEW"), .integer(2), .integer(0), .integer(5), .integer(255), .integer(0),
            .integer(3), .integer(0), .integer(119), .integer(17), .integer(8), .integer(1), .integer(0)]))
        XCTAssertEqual(first["intent"], .array([.bool(true), .bool(true), .string("android.intent.action.OPEN_DOCUMENT"), .integer(1)]))
        XCTAssertEqual(first["overscroll"], .null)
        XCTAssertEqual(first["enum"], .array([.string("CENTER"), .integer(1), .string("android.graphics.Paint$Style")]))
        XCTAssertEqual(first["enum_to_host"]?.string?.hasPrefix("!UnsupportedAPI: "), true)
        XCTAssertEqual(first["uri"], .array(["file:///data/a%20b/file%20(1).txt", "file", "/data/a b/file (1).txt", "file (1).txt",
                                              "android.net.Uri"].map { .string($0) }))
        XCTAssertEqual(first["class_object"], .array(["android.view.View", "View", "android.net.Uri",
                                                       "org.telegram.messenger.AndroidUtilities", "android.content.Context"].map { .string($0) }))
        XCTAssertEqual(first["theme"], .array([.integer(0x7F336699), .integer(-1)]))
        XCTAssertEqual(first["absent"], .array([.bool(false), .bool(false)]))
    }
}
