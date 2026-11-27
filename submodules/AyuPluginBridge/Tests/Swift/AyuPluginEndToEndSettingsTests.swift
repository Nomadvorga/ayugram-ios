import Foundation
import XCTest
@testable import AyuPluginBridge

/// Settings rows, their callbacks, and the settings/state/log storage of a loaded plugin.
@MainActor
final class AyuPluginEndToEndSettingsTests: XCTestCase {
    func testEveryRowKindIsSerializedAndItsCallbacksRun() async throws {
        let stack = try AyuEndToEnd.shared()
        let id = try await stack.start(AyuEndToEnd.source(id: "e2e_rows", """
        from base_plugin import BasePlugin
        from ui.settings import Divider, EditText, Header, Input, Selector, Switch, Text


        class RowsPlugin(BasePlugin):
            def changed(self, name):
                return lambda value: self.set_setting("changed_" + name, [type(value).__name__, value])

            def clicked(self, view):
                self.set_setting("clicked", self.get_setting("clicked", 0) + 1)

            def create_settings(self):
                return [
                    Header(text="General"),
                    Switch(key="flag", text="Flag", default=True, subtext="Sub", icon="msg_settings", on_change=self.changed("flag")),
                    Selector(key="choice", text="Choice", default=1, items=["a", "b", "c"], on_change=self.changed("choice")),
                    Input(key="name", text="Name", default="anon", subtext="Shown name", on_change=self.changed("name")),
                    EditText(key="note", hint="Note", on_change=self.changed("note")),
                    Divider(text="About"),
                    Divider(),
                    Text(text="Run", accent=True, on_click=self.clicked),
                    Text(text="More", red=True, create_sub_fragment=self.page),
                    Switch(key="dropped", text=None, default=False),
                ]

            def page(self):
                return [Header(text="Nested"), Switch(key="nested", text="Nested flag", default=False, on_change=self.changed("nested"))]
        """))
        var rows = try await stack.service.settings(id)
        XCTAssertEqual(rows.map(\.type), ["Header", "Switch", "Selector", "Input", "Input", "Divider", "Divider", "Text", "Text"], "An incomplete row is dropped as on Android")
        XCTAssertEqual(rows.map(\.key), [nil, "flag", "choice", "name", "note", nil, nil, nil, nil])
        XCTAssertEqual(rows[0].text, "General")
        XCTAssertEqual(rows[1].value, .bool(true))
        XCTAssertEqual(rows[1].descriptor["subtext"], .string("Sub"))
        XCTAssertEqual(rows[1].descriptor["icon"], .string("msg_settings"))
        XCTAssertEqual(rows[2].value, .integer(1))
        XCTAssertEqual(rows[2].descriptor["items"], .array([.string("a"), .string("b"), .string("c")]))
        XCTAssertEqual(rows[3].value, .string("anon"))
        XCTAssertEqual(rows[4].text, "Note")
        XCTAssertEqual(rows[4].descriptor["hint"], .string("Note"))
        XCTAssertEqual(rows[4].descriptor["max_length"], .integer(256))
        XCTAssertEqual(rows[4].descriptor["multiline"], .bool(false))
        XCTAssertEqual(rows[4].value, .string(""))
        XCTAssertEqual(rows[5].descriptor["text"], .string("About"))
        XCTAssertEqual(rows[6].descriptor["text"], .null)
        XCTAssertEqual(rows[7].descriptor["accent"], .bool(true))
        XCTAssertEqual(rows[8].descriptor["destructive"], .bool(true))

        try await stack.service.set(rows[1], value: .bool(false), pluginID: id)
        try await stack.service.set(rows[2], value: .integer(2), pluginID: id)
        try await stack.service.set(rows[3], value: .string("Ünï 😀"), pluginID: id)
        try await stack.service.set(rows[4], value: .string("text"), pluginID: id)
        let flag = await stack.waitForStored(id, "changed_flag")
        let choice = await stack.waitForStored(id, "changed_choice")
        let name = await stack.waitForStored(id, "changed_name")
        let note = await stack.waitForStored(id, "changed_note")
        XCTAssertEqual(flag, .array([.string("bool"), .bool(false)]))
        XCTAssertEqual(choice, .array([.string("int"), .integer(2)]))
        XCTAssertEqual(name, .array([.string("str"), .string("Ünï 😀")]))
        XCTAssertEqual(note, .array([.string("str"), .string("text")]))
        XCTAssertEqual(stack.stored(id, "flag"), .bool(false))
        XCTAssertEqual(stack.stored(id, "choice"), .integer(2))

        stack.service.activate(rows[7], pluginID: id)
        stack.service.activate(rows[7], pluginID: id)
        let clicks = await stack.waitForStored(id, "clicked") { $0 == .integer(2) }
        XCTAssertEqual(clicks, .integer(2))

        let page = try XCTUnwrap(rows[8].descriptor["create_sub_fragment"]["$callback"].string)
        let nested = try await stack.service.subpage(pluginID: id, callbackID: page)
        XCTAssertEqual(nested.map(\.type), ["Header", "Switch"])
        XCTAssertEqual(nested[1].value, .bool(false))
        try await stack.service.set(nested[1], value: .bool(true), pluginID: id)
        let nestedChange = await stack.waitForStored(id, "changed_nested")
        XCTAssertEqual(nestedChange, .array([.string("bool"), .bool(true)]))

        rows = try await stack.service.settings(id)
        XCTAssertEqual(rows[1].value, .bool(false))
        XCTAssertEqual(rows[2].value, .integer(2))
        XCTAssertEqual(rows[3].value, .string("Ünï 😀"))
        XCTAssertNil(stack.record(id)?.error)
        await stack.remove(id)
    }

    func testRowsTheNativeScreenCannotDrawAreRefused() async throws {
        let stack = try AyuEndToEnd.shared()
        let id = try await stack.start(AyuEndToEnd.source(id: "e2e_rows_refused", """
        from base_plugin import BasePlugin
        from ui.settings import Custom, EditText, Header


        class RefusedRowsPlugin(BasePlugin):
            def create_settings(self):
                mode = self.get_setting("mode", "none")
                if mode == "mask":
                    return [EditText(key="masked", hint="Masked", mask="##-##")]
                if mode == "length":
                    return [EditText(key="short", hint="Short", max_length=8)]
                if mode == "custom":
                    return [Custom(view=object())]
                if mode == "not_rows":
                    return "rows"
                return None
        """))
        let none = try await stack.service.settings(id)
        XCTAssertEqual(none.count, 0, "None means no settings")
        for mode in ["mask", "length", "custom", "not_rows"] {
            _ = try await stack.host(id, "settings.set", ["key": .string("mode"), "value": .string(mode)])
            do {
                let rows = try await stack.service.settings(id)
                XCTFail("\(mode) produced \(rows.map(\.type))")
            } catch {}
        }
        _ = try await stack.host(id, "settings.set", ["key": .string("mode"), "value": .string("none")])
        let recovered = try await stack.service.settings(id)
        XCTAssertEqual(recovered.count, 0, "A refused page does not break the plugin")
        XCTAssertEqual(stack.record(id)?.isEnabled, true)
        await stack.remove(id)
    }

    func testSettingsStateAndLogStorage() async throws {
        let stack = try AyuEndToEnd.shared()
        let id = try await stack.start(AyuEndToEnd.source(id: "e2e_storage", """
        import plugin_settings
        from base_plugin import BasePlugin

        \(AyuEndToEnd.recorder)

        VALUES = {
            "none": None, "true": True, "false": False, "int": 42, "big": 9007199254740993,
            "min": -(2 ** 63), "max": 2 ** 63 - 1, "float": 1.5, "text": "héllo ✓ 😀", "empty": "",
            "list": [1, "two", [3.5, None]], "dict": {"a": {"b": [True]}},
        }


        class StoragePlugin(Recorder, BasePlugin):
            def on_plugin_load(self):
                self.set_setting("stale", 1)
                self.import_settings({"only": 1}, reload_settings=False)
                imported = self.get_all_settings()
                plugin_settings.clear_settings()
                cleared = self.get_all_settings()
                self.set_setting("imported", imported)
                self.set_setting("cleared", cleared)

                for key, value in VALUES.items():
                    self.set_setting("v_" + key, value)
                self.record("same", lambda: {key: self.get_setting("v_" + key) == value for key, value in VALUES.items()})
                self.record("types", lambda: {key: type(self.get_setting("v_" + key)).__name__ for key in VALUES})
                self.record("whole_type", lambda: [self.set_setting("v_whole", 2.0), type(self.get_setting("v_whole")).__name__][1])
                self.record("defaults", lambda: [self.get_setting("missing"), self.get_setting("missing", 7), plugin_settings.get_setting("missing", "d")])
                self.record("module_forms", lambda: [plugin_settings.set_setting(self.id, "via_module", 5), plugin_settings.get_setting(self.id, "via_module", None), plugin_settings.get_setting("via_module")])
                self.record("foreign", lambda: plugin_settings.get_setting("another_plugin", "via_module", None))
                self.record("too_big", lambda: self.set_setting("huge", 2 ** 63))
                self.record("not_json", lambda: self.set_setting("object", object()))
                self.record("not_finite", lambda: self.set_setting("nan", float("nan")))
                self.record("long_key", lambda: self.set_setting("k" * 257, 1))
                self.record("exported", lambda: self.export_settings() == self.get_all_settings())
                self.record("state", lambda: [self.set_state("s", {"n": [1, 2]}), self.get_state("s"), self.get_state("absent", "fallback")])
                self.record("state_is_not_a_setting", lambda: "s" in self.get_all_settings())
                self.record("log", lambda: [self.log("plain"), self.log({"k": [1, 2]}), self.log("x" * 9000), self.log(None)])
                self.record("logger", lambda: [self.logger.info("info"), self.logger.warning("warning"), self.logger.error("error"), self.logger.debug("debug")])
        """))
        XCTAssertEqual(stack.stored(id, "imported"), .object(["only": .integer(1)]), "import_settings replaces the namespace")
        XCTAssertEqual(stack.stored(id, "cleared"), .object([:]))
        XCTAssertEqual(stack.stored(id, "same").object?.filter { $0.value != .bool(true) }, [:])
        XCTAssertEqual(stack.stored(id, "types"), .object([
            "none": .string("NoneType"), "true": .string("bool"), "false": .string("bool"), "int": .string("int"), "big": .string("int"),
            "min": .string("int"), "max": .string("int"), "float": .string("float"), "text": .string("str"),
            "empty": .string("str"), "list": .string("list"), "dict": .string("dict"),
        ]))
        XCTAssertEqual(stack.stored(id, "whole_type"), .string("float"))
        XCTAssertEqual(stack.stored(id, "v_whole"), .number(2), "The stored value keeps its type across a restart")
        XCTAssertEqual(stack.stored(id, "v_float"), .number(1.5))
        XCTAssertEqual(stack.stored(id, "v_int"), .integer(42))
        XCTAssertEqual(stack.stored(id, "v_big"), .integer(9_007_199_254_740_993), "Int64 stays exact")
        XCTAssertEqual(stack.stored(id, "v_min"), .integer(Int64.min))
        XCTAssertEqual(stack.stored(id, "v_max"), .integer(Int64.max))
        XCTAssertEqual(stack.stored(id, "v_text"), .string("héllo ✓ 😀"))
        XCTAssertEqual(stack.stored(id, "v_dict"), .object(["a": .object(["b": .array([.bool(true)])])]))
        XCTAssertEqual(stack.stored(id, "defaults"), .array([.null, .integer(7), .string("d")]))
        XCTAssertEqual(stack.stored(id, "module_forms"), .array([.null, .integer(5), .integer(5)]))
        XCTAssertEqual(stack.stored(id, "foreign").string?.hasPrefix("!BridgeError: OWNERSHIP"), true, "\(stack.stored(id, "foreign"))")
        XCTAssertEqual(stack.stored(id, "too_big").string?.hasPrefix("!ValueError"), true, "\(stack.stored(id, "too_big"))")
        XCTAssertEqual(stack.stored(id, "not_json").string?.hasPrefix("!TypeError"), true, "\(stack.stored(id, "not_json"))")
        XCTAssertEqual(stack.stored(id, "not_finite").string?.hasPrefix("!ValueError"), true, "\(stack.stored(id, "not_finite"))")
        XCTAssertEqual(stack.stored(id, "long_key").string?.hasPrefix("!ValueError"), true, "\(stack.stored(id, "long_key"))")
        XCTAssertEqual(stack.stored(id, "huge"), .null)
        XCTAssertEqual(stack.stored(id, "exported"), .bool(true))
        XCTAssertEqual(stack.stored(id, "state"), .array([.null, .object(["n": .array([.integer(1), .integer(2)])]), .string("fallback")]))
        XCTAssertEqual(stack.stored(id, "state_is_not_a_setting"), .bool(false))
        XCTAssertEqual(stack.stored(id, "log"), .array([.null, .null, .null, .null]))
        XCTAssertEqual(stack.stored(id, "logger"), .array([.null, .null, .null, .null]))
        await stack.remove(id)
    }
}
