import Foundation
@preconcurrency import XCTest
@testable import AyuPluginBridge

@MainActor
final class AyuPluginTypedMenusTests: XCTestCase {
    private static let generation = "typed-menu-generation"
    private let accountIdentity = UUID()
    private let userTL = Data([1, 0, 0, 0, 5, 0, 0, 0])
    private let chatTL = Data([2, 0, 0, 0, 6, 0, 0, 0])
    private let userFullTL = Data([3, 0, 0, 0, 7, 0, 0, 0])
    private let chatFullTL = Data([4, 0, 0, 0, 8, 0, 0, 0])
    private let messageTL = Data([9, 0, 0, 0, 1, 0, 0, 0, 2, 0, 0, 0])

    private func tl(_ data: Data) -> AyuBridgeValue { .object(["tl": .string(data.base64EncodedString())]) }

    /// A fake cache: user 77 and chat 91 are known, message 12 of either dialog is stored.
    private func source(accountIdentity: UUID? = nil, full: Bool = true, peers: Bool = true) -> AyuPluginTypedMenus.TLSource {
        let identity = accountIdentity ?? self.accountIdentity
        let user = self.userTL, chat = self.chatTL, userFull = self.userFullTL, chatFull = self.chatFullTL, message = self.messageTL
        return AyuPluginTypedMenus.TLSource(account: { index in
            index == 3 ? AyuPluginTelegramAccount(index: 3, identity: identity, userID: 1000) : nil
        }, peer: { _, kind, id, completion in
            precondition(!Thread.isMainThread)
            switch (kind, id) {
            case (.user, 77): completion(.success(peers ? user : nil))
            case (.chat, 91): completion(.success(peers ? chat : nil))
            case (.userFull, 77): completion(.success(full ? userFull : nil))
            case (.chatFull, 91): completion(.success(full ? chatFull : nil))
            default: completion(.success(nil))
            }
        }, messages: { _, dialogID, ids, completion in
            precondition(!Thread.isMainThread)
            completion(.success(ids.map { (dialogID == 77 || dialogID == -91) && $0 == 12 ? message : nil }))
        })
    }

    private func bridge(source: AyuPluginTypedMenus.TLSource?, conditionTimeout: TimeInterval = 2, contextPayloadBytes: Int = 1_048_576) -> AyuPluginMenuBridge {
        var limits = AyuPluginTypedMenus.Limits()
        limits.conditionTimeout = conditionTimeout
        limits.contextPayloadBytes = contextPayloadBytes
        let menus = AyuPluginMenuBridge(typed: AyuPluginTypedMenus(limits: limits))
        if let source { menus.typed.setTLSource { source } }
        return menus
    }

    private func host(_ menus: AyuPluginMenuBridge) -> AyuPluginNativeHost {
        AyuPluginNativeHost(defaults: UserDefaults(suiteName: "AyuPluginTypedMenusTests." + UUID().uuidString)!,
            provider: menus, trustedOwner: { "alpha" }, callback: { _, _, _ in })
    }

    private func call(_ host: AyuPluginNativeHost, _ operation: String, _ arguments: [String: AyuBridgeValue] = [:]) async throws -> AyuBridgeValue {
        let request = AyuBridgeValue.object(["version": .integer(1), "id": .string("1"), "plugin_id": .string("alpha"),
            "operation": .string(operation), "arguments": .object(arguments)])
        let text = String(data: try JSONEncoder().encode(request), encoding: .utf8)!
        let response: String = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async { continuation.resume(returning: host.dispatch(text, owner: "alpha")) }
        }
        return try JSONDecoder().decode(AyuBridgeValue.self, from: Data(response.utf8))
    }

    private func activate(_ host: AyuPluginNativeHost) async throws {
        let authorized = try await self.call(host, "plugin.authorize", ["metadata": .object([:]), "classes": .array([]),
            "requirements": .array([]), "imports": .array([])])
        XCTAssertEqual(authorized["result"], .bool(true))
        let active = try await self.call(host, "plugin.activate", ["generation": .string(Self.generation)])
        XCTAssertEqual(active["result"], .null)
    }

    private func callback(_ name: String) -> AyuBridgeValue { .object(["$callback": .string(Self.generation + ":" + name)]) }

    private func item(_ type: String = "chat_action_menu", id: String = "item", text: String = "Item", priority: Int64 = 0,
                      extra: [String: AyuBridgeValue] = [:]) -> [String: AyuBridgeValue] {
        var arguments: [String: AyuBridgeValue] = ["type": .string(type), "item_id": .string(id), "text": .string(text),
            "priority": .integer(priority), "on_click": self.callback("click." + id)]
        for (key, value) in extra { arguments[key] = value }
        return arguments
    }

    private func screen(dialogID: Int64?) -> AyuPluginScreenSnapshot {
        AyuPluginScreenSnapshot(identity: UUID(), accountIndex: 3, dialogID: dialogID)
    }

    /// Binds a resolver that pins every request to `screen`; `current` plays the app's revalidation.
    private func bind(_ menus: AyuPluginMenuBridge, screen: AyuPluginScreenSnapshot, dialogID: Int64?, current: AyuTestBox<Bool> = AyuTestBox(true)) {
        let identity = self.accountIdentity
        menus.bindLocations(resolve: { request in
            AyuPluginMenuLocation(kind: request.kind, screen: screen, accountIdentity: identity, dialogID: dialogID, messageID: request.messageID)
        }, isCurrent: { location, _ in
            current.value && location.isCurrent(screen: screen, accountIdentity: identity)
        })
    }

    func testOperationIsDeclaredOnlyWhileBothReadsAreServed() async throws {
        let unbound = self.bridge(source: nil)
        XCTAssertEqual(unbound.capabilities, ["menus.register", "menus.unregister", "resources.resolve"])
        let unboundHost = self.host(unbound)
        try await self.activate(unboundHost)
        let refused = try await self.call(unboundHost, "menus.add", self.item())
        XCTAssertEqual(refused["error"]["code"], .string("UNSUPPORTED_API"))

        let bound = self.bridge(source: self.source())
        XCTAssertTrue(bound.capabilities.contains("menus.add"))
        bound.typed.setTLSource { nil }
        XCTAssertFalse(bound.capabilities.contains("menus.add"))

        let telegram = AyuPluginTelegramBridge()
        XCTAssertNil(telegram.menuContextSource())
    }

    func testArgumentsAreClosedBoundedAndTyped() async throws {
        let menus = self.bridge(source: self.source())
        let host = self.host(menus)
        try await self.activate(host)
        func code(_ arguments: [String: AyuBridgeValue]) async throws -> AyuBridgeValue { try await self.call(host, "menus.add", arguments)["error"]["code"] }
        let invalid = AyuBridgeValue.string("INVALID_ARGUMENTS")
        var result = try await code(self.item(extra: ["menu_type": .string("chat_action_menu")]))
        XCTAssertEqual(result, invalid)
        result = try await code(self.item("CHAT_ACTION_MENU"))
        XCTAssertEqual(result, invalid)
        result = try await code(self.item("dialog_action_menu"))
        XCTAssertEqual(result, invalid)
        var missing = self.item()
        missing["on_click"] = nil
        result = try await code(missing)
        XCTAssertEqual(result, invalid)
        result = try await code(self.item(text: ""))
        XCTAssertEqual(result, invalid)
        result = try await code(self.item(text: String(repeating: "я", count: 129)))
        XCTAssertEqual(result, invalid)
        result = try await code(self.item(id: String(repeating: "i", count: 129)))
        XCTAssertEqual(result, invalid)
        result = try await code(self.item(extra: ["subtext": .string(String(repeating: "s", count: 257))]))
        XCTAssertEqual(result, invalid)
        result = try await code(self.item(priority: Int64(Int32.max) + 1))
        XCTAssertEqual(result, invalid)
        result = try await code(self.item(extra: ["icon": .integer(7)]))
        XCTAssertEqual(result, invalid)
        result = try await code(self.item(extra: ["on_long_click": .string("x")]))
        XCTAssertEqual(result, invalid)
        result = try await code(self.item(extra: ["condition": .string("message != null")]))
        XCTAssertEqual(result, .string("UNSUPPORTED_API"))
        XCTAssertTrue(menus.typed.entries(shownIn: .chatActionMenu).isEmpty)

        let longest = try await self.call(host, "menus.add", self.item(id: String(repeating: "i", count: 128), text: String(repeating: "я", count: 128),
            priority: Int64(Int32.min), extra: ["subtext": .string(String(repeating: "s", count: 256)), "icon": .string("no_such_drawable"),
                                                "on_click": self.callback("click")]))
        XCTAssertNotNil(longest["result"].string)
        let duplicate = try await code(self.item(id: String(repeating: "i", count: 128)))
        XCTAssertEqual(duplicate, invalid)
        let stored = try XCTUnwrap(menus.typed.entries(shownIn: .chatActionMenu).first)
        XCTAssertNil(stored.icon)
        XCTAssertEqual(stored.priority, Int32.min)
    }

    func testItemsPerGenerationAreLimitedAndUnregisterFreesAnId() async throws {
        let menus = self.bridge(source: self.source())
        let host = self.host(menus)
        try await self.activate(host)
        var tokens: [String] = []
        for index in 0..<64 {
            let added = try await self.call(host, "menus.add", self.item(id: "item\(index)", extra: ["on_click": self.callback("click")]))
            tokens.append(try XCTUnwrap(added["result"].string))
        }
        XCTAssertEqual(Set(tokens).count, 64)
        let over = try await self.call(host, "menus.add", self.item(id: "item64", extra: ["on_click": self.callback("click")]))
        XCTAssertEqual(over["error"]["code"], .string("RESOURCE_LIMIT"))
        let removed = try await self.call(host, "menus.unregister", ["token": .string(tokens[0])])
        XCTAssertEqual(removed["result"], .null)
        let again = try await self.call(host, "menus.add", self.item(id: "item0", extra: ["on_click": self.callback("click")]))
        XCTAssertNotNil(again["result"].string)
        XCTAssertEqual(menus.typed.entries(shownIn: .chatActionMenu).count, 64)

        let unloaded = try await self.call(host, "plugin.deactivate", ["generation": .string(Self.generation)])
        XCTAssertEqual(unloaded["result"], .null)
        XCTAssertTrue(menus.typed.entries(shownIn: .chatActionMenu).isEmpty)
    }

    func testChatMenuIsOrderedAndCarriesTheContractContext() async throws {
        let menus = self.bridge(source: self.source())
        let host = self.host(menus)
        try await self.activate(host)
        for (id, priority) in [("low", Int64(-5)), ("first", 9), ("second", 9), ("top", 100)] {
            let added = try await self.call(host, "menus.add", self.item(id: id, text: id.uppercased(), priority: priority,
                extra: id == "top" ? ["icon": .string("msg_settings_solar"), "subtext": .string("sub"), "on_long_click": self.callback("long")] : [:]))
            XCTAssertNotNil(added["result"].string)
        }
        _ = try await self.call(host, "menus.add", self.item("profile_action_menu", id: "profile"))
        _ = try await self.call(host, "menus.add", self.item("message_context_menu", id: "message"))
        let calls = AyuTestBox<[(String, [AyuBridgeValue])]>([])
        menus.invokeCallback = { _, callbackID, arguments in
            calls.update { $0.append((callbackID, arguments)) }
            return .null
        }
        let screen = self.screen(dialogID: 77)
        self.bind(menus, screen: screen, dialogID: 77)
        let session = await menus.open(AyuPluginMenuRequest(kind: .chatActionMenu, accountKey: 1), isPresented: { true })
        XCTAssertEqual(session.entries.map(\.identifier), ["alpha:top", "alpha:first", "alpha:second", "alpha:low"])
        let top = try XCTUnwrap(session.entries.first)
        XCTAssertEqual(top.text, "TOP")
        XCTAssertEqual(top.subtext, "sub")
        XCTAssertEqual(top.icon, .asset("Chat/Context Menu/Settings"))
        XCTAssertTrue(top.hasLongClick)
        XCTAssertFalse(session.entries[1].hasLongClick)
        XCTAssertTrue(calls.value.isEmpty)

        let expected = AyuBridgeValue.object(["account": .integer(3), "dialog_id": .integer(77),
            "user": self.tl(self.userTL), "user_full": self.tl(self.userFullTL)])
        session.activate(top)
        session.activate(session.entries[1], longClick: true)
        session.activate(top, longClick: true)
        for _ in 0..<200 where calls.value.count < 2 { try await Task.sleep(nanoseconds: 5_000_000) }
        XCTAssertEqual(calls.value.map { $0.0 }, [Self.generation + ":click.top", Self.generation + ":long"])
        XCTAssertEqual(calls.value.map { $0.1 }, [[expected], [expected]])
    }

    func testContextPerMenuType() async throws {
        let menus = self.bridge(source: self.source())
        let host = self.host(menus)
        try await self.activate(host)
        for type in AyuPluginMenuKind.allCases {
            let added = try await self.call(host, "menus.add", self.item(type.rawValue, id: type.rawValue, priority: type == .drawerMenu ? 5 : 1))
            XCTAssertNotNil(added["result"].string)
        }
        menus.invokeCallback = { _, _, _ in .null }

        self.bind(menus, screen: self.screen(dialogID: -91), dialogID: -91)
        let message = await menus.open(AyuPluginMenuRequest(kind: .messageContextMenu, accountKey: 1, messageID: 12), isPresented: { true })
        XCTAssertEqual(message.entries.map(\.identifier), ["alpha:message_context_menu"])
        XCTAssertEqual(message.entries.first?.arguments, [.object(["account": .integer(3), "dialog_id": .integer(-91),
            "chat": self.tl(self.chatTL), "message": self.tl(self.messageTL)])])
        let unknownMessage = await menus.open(AyuPluginMenuRequest(kind: .messageContextMenu, accountKey: 1, messageID: 13), isPresented: { true })
        XCTAssertTrue(unknownMessage.entries.isEmpty)

        let group = await menus.open(AyuPluginMenuRequest(kind: .chatActionMenu, accountKey: 1), isPresented: { true })
        XCTAssertEqual(group.entries.first?.arguments, [.object(["account": .integer(3), "dialog_id": .integer(-91),
            "chat": self.tl(self.chatTL), "chat_full": self.tl(self.chatFullTL)])])

        // A profile is not the visible chat: its screen has no dialog of its own.
        self.bind(menus, screen: self.screen(dialogID: nil), dialogID: 77)
        let profile = await menus.open(AyuPluginMenuRequest(kind: .profileActionMenu, accountKey: 1), isPresented: { true })
        XCTAssertEqual(profile.entries.map(\.identifier), ["alpha:profile_action_menu"])
        XCTAssertEqual(profile.entries.first?.arguments, [.object(["account": .integer(3), "dialog_id": .integer(77),
            "user": self.tl(self.userTL), "user_full": self.tl(self.userFullTL)])])
        let chatElsewhere = await menus.open(AyuPluginMenuRequest(kind: .chatActionMenu, accountKey: 1), isPresented: { true })
        XCTAssertTrue(chatElsewhere.entries.isEmpty)

        self.bind(menus, screen: self.screen(dialogID: nil), dialogID: nil)
        let main = await menus.open(AyuPluginMenuRequest(kind: .mainMenu, accountKey: nil), isPresented: { true })
        XCTAssertEqual(main.entries.map(\.identifier), ["alpha:drawer_menu", "alpha:main_menu"])
        XCTAssertEqual(main.entries.first?.arguments, [.object(["account": .integer(3)])])
    }

    func testMissingCacheValuesHideItemsOrOmitOptionalOnes() async throws {
        let withoutFull = self.bridge(source: self.source(full: false))
        var host = self.host(withoutFull)
        try await self.activate(host)
        _ = try await self.call(host, "menus.add", self.item())
        withoutFull.invokeCallback = { _, _, _ in .null }
        self.bind(withoutFull, screen: self.screen(dialogID: 77), dialogID: 77)
        var session = await withoutFull.open(AyuPluginMenuRequest(kind: .chatActionMenu, accountKey: 1), isPresented: { true })
        XCTAssertEqual(session.entries.first?.arguments, [.object(["account": .integer(3), "dialog_id": .integer(77), "user": self.tl(self.userTL)])])

        for menus in [self.bridge(source: self.source(peers: false)), self.bridge(source: self.source(accountIdentity: UUID())),
                      self.bridge(source: self.source(), contextPayloadBytes: 16)] {
            host = self.host(menus)
            try await self.activate(host)
            _ = try await self.call(host, "menus.add", self.item())
            menus.invokeCallback = { _, _, _ in .null }
            self.bind(menus, screen: self.screen(dialogID: 77), dialogID: 77)
            session = await menus.open(AyuPluginMenuRequest(kind: .chatActionMenu, accountKey: 1), isPresented: { true })
            XCTAssertTrue(session.entries.isEmpty)
        }

        // A full object too large for one callback is left out; the item stays.
        let tight = self.bridge(source: self.source(), contextPayloadBytes: 80)
        host = self.host(tight)
        try await self.activate(host)
        _ = try await self.call(host, "menus.add", self.item())
        tight.invokeCallback = { _, _, _ in .null }
        self.bind(tight, screen: self.screen(dialogID: 77), dialogID: 77)
        session = await tight.open(AyuPluginMenuRequest(kind: .chatActionMenu, accountKey: 1), isPresented: { true })
        XCTAssertEqual(session.entries.first?.arguments, [.object(["account": .integer(3), "dialog_id": .integer(77), "user": self.tl(self.userTL)])])
    }

    func testConditionsShowOnlyTrueAndAnUnansweredOneIsHiddenAfterTheBound() async throws {
        let menus = self.bridge(source: self.source(), conditionTimeout: 0.3)
        let host = self.host(menus)
        try await self.activate(host)
        for id in ["yes", "no", "truthy", "never", "plain"] {
            let added = try await self.call(host, "menus.add", self.item(id: id, extra: id == "plain" ? [:] : ["condition": self.callback("condition." + id)]))
            XCTAssertNotNil(added["result"].string)
        }
        let asked = AyuTestBox<[String]>([])
        menus.invokeCallback = { _, callbackID, arguments in
            asked.update { $0.append(callbackID) }
            XCTAssertEqual(arguments.count, 1)
            switch callbackID {
            case Self.generation + ":condition.yes": return .bool(true)
            case Self.generation + ":condition.no": return .bool(false)
            case Self.generation + ":condition.truthy": return .integer(1)
            default:
                try? await Task.sleep(nanoseconds: 30_000_000_000)
                return .bool(true)
            }
        }
        self.bind(menus, screen: self.screen(dialogID: 77), dialogID: 77)
        let started = Date()
        let session = await menus.open(AyuPluginMenuRequest(kind: .chatActionMenu, accountKey: 1), isPresented: { true })
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
        XCTAssertEqual(session.entries.map(\.identifier), ["alpha:yes", "alpha:plain"])
        XCTAssertEqual(Set(asked.value), Set(["yes", "no", "truthy", "never"].map { Self.generation + ":condition." + $0 }))
    }

    func testAClickIsNotDeliveredAfterRemovalOrWhenTheScreenChanged() async throws {
        let menus = self.bridge(source: self.source())
        let host = self.host(menus)
        try await self.activate(host)
        let first = try await self.call(host, "menus.add", self.item(id: "first"))
        _ = try await self.call(host, "menus.add", self.item(id: "second"))
        let clicks = AyuTestBox<[String]>([])
        menus.invokeCallback = { _, callbackID, _ in
            clicks.update { $0.append(callbackID) }
            return .null
        }
        let current = AyuTestBox(true)
        self.bind(menus, screen: self.screen(dialogID: 77), dialogID: 77, current: current)
        let session = await menus.open(AyuPluginMenuRequest(kind: .chatActionMenu, accountKey: 1), isPresented: { true })
        XCTAssertEqual(session.entries.count, 2)
        _ = try await self.call(host, "menus.unregister", ["token": .string(try XCTUnwrap(first["result"].string))])
        session.activate(session.entries[0])
        session.activate(session.entries[1])
        for _ in 0..<200 where clicks.value.isEmpty { try await Task.sleep(nanoseconds: 5_000_000) }
        XCTAssertEqual(clicks.value, [Self.generation + ":click.second"])

        current.value = false
        session.activate(session.entries[1])
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(clicks.value.count, 1)
        let hidden = await menus.open(AyuPluginMenuRequest(kind: .chatActionMenu, accountKey: 1), isPresented: { true })
        XCTAssertTrue(hidden.entries.isEmpty)
        current.value = true
        let dismissed = await menus.open(AyuPluginMenuRequest(kind: .chatActionMenu, accountKey: 1), isPresented: { false })
        XCTAssertTrue(dismissed.entries.isEmpty)
        menus.unbindLocations()
        let unbound = await menus.open(AyuPluginMenuRequest(kind: .chatActionMenu, accountKey: 1), isPresented: { true })
        XCTAssertTrue(unbound.entries.isEmpty)
    }

    func testMessageMenuAlsoServesRegisterItems() async throws {
        let menus = self.bridge(source: nil)
        let host = self.host(menus)
        try await self.activate(host)
        let registered = try await self.call(host, "menus.register", ["type": .string("MESSAGE_CONTEXT_MENU"), "text": .string("Legacy"),
            "priority": .integer(1), "on_click": self.callback("legacy"), "item_id": .string("legacy"), "icon": .string("msg_copy")])
        XCTAssertNotNil(registered["result"].string)
        let calls = AyuTestBox<[(String, [AyuBridgeValue])]>([])
        menus.invokeCallback = { _, callbackID, arguments in
            calls.update { $0.append((callbackID, arguments)) }
            return .null
        }
        self.bind(menus, screen: self.screen(dialogID: 77), dialogID: 77)
        let session = await menus.open(AyuPluginMenuRequest(kind: .messageContextMenu, accountKey: 1, messageID: 12), isPresented: { true })
        XCTAssertEqual(session.entries.map(\.identifier), ["alpha:legacy"])
        XCTAssertEqual(session.entries.first?.icon, .symbol("doc.on.doc"))
        session.activate(try XCTUnwrap(session.entries.first))
        for _ in 0..<200 where calls.value.isEmpty { try await Task.sleep(nanoseconds: 5_000_000) }
        XCTAssertEqual(calls.value.map { $0.0 }, [Self.generation + ":legacy"])
        XCTAssertEqual(calls.value.first?.1, [.object(["account": .integer(3), "dialog_id": .integer(77), "message_id": .integer(12)])])
    }

    func testLocationsFitTheirKind() {
        let identity = UUID()
        let chat = self.screen(dialogID: 77)
        XCTAssertNotNil(AyuPluginMenuLocation(kind: .chatActionMenu, screen: chat, accountIdentity: identity, dialogID: 77, messageID: nil))
        XCTAssertNil(AyuPluginMenuLocation(kind: .chatActionMenu, screen: chat, accountIdentity: identity, dialogID: 78, messageID: nil))
        XCTAssertNil(AyuPluginMenuLocation(kind: .chatActionMenu, screen: chat, accountIdentity: identity, dialogID: 77, messageID: 4))
        XCTAssertNil(AyuPluginMenuLocation(kind: .chatActionMenu, screen: chat, accountIdentity: identity, dialogID: nil, messageID: nil))
        XCTAssertNil(AyuPluginMenuLocation(kind: .messageContextMenu, screen: chat, accountIdentity: identity, dialogID: 77, messageID: nil))
        XCTAssertNil(AyuPluginMenuLocation(kind: .messageContextMenu, screen: chat, accountIdentity: identity, dialogID: 77, messageID: 0))
        XCTAssertNil(AyuPluginMenuLocation(kind: .profileActionMenu, screen: chat, accountIdentity: identity, dialogID: 0, messageID: nil))
        XCTAssertNil(AyuPluginMenuLocation(kind: .mainMenu, screen: chat, accountIdentity: identity, dialogID: 77, messageID: nil))
        let location = try? XCTUnwrap(AyuPluginMenuLocation(kind: .messageContextMenu, screen: chat, accountIdentity: identity, dialogID: 77, messageID: 4))
        XCTAssertEqual(location?.isCurrent(screen: chat, accountIdentity: identity), true)
        XCTAssertEqual(location?.isCurrent(screen: chat, accountIdentity: UUID()), false)
        XCTAssertEqual(location?.isCurrent(screen: self.screen(dialogID: 77), accountIdentity: identity), false)
        XCTAssertEqual(location?.isCurrent(screen: nil, accountIdentity: identity), false)
    }

    func testImageViewTakesAMappedDrawableResourceAndRefusesAnyOther() async throws {
        let host = self.host(self.bridge(source: nil))
        try await self.activate(host)
        let image = try await self.call(host, "java.construct", ["class_name": .string("android.widget.ImageView"), "args": .array([])])
        func setResource(_ value: AyuBridgeValue) async throws -> AyuBridgeValue {
            try await self.call(host, "java.invoke", ["target": image["result"], "name": .string("setImageResource"), "args": .array([value])])
        }
        let mapped = try await setResource(.object(["resource": .string("drawable"), "name": .string("msg_send")]))
        XCTAssertEqual(mapped["error"], .null)
        let unmapped = try await setResource(.object(["resource": .string("drawable"), "name": .string("no_such_drawable")]))
        XCTAssertEqual(unmapped["error"]["code"], .string("INVALID_ARGUMENTS"))
        let otherKind = try await setResource(.object(["resource": .string("string"), "name": .string("AppName")]))
        XCTAssertEqual(otherKind["error"]["code"], .string("INVALID_ARGUMENTS"))
        let malformed = try await setResource(.object(["resource": .string("drawable")]))
        XCTAssertEqual(malformed["error"]["code"], .string("INVALID_ARGUMENTS"))
        let androidInteger = try await setResource(.integer(0x7f080001))
        XCTAssertEqual(androidInteger["error"]["code"], .string("UNSUPPORTED_API"))
        let cleared = try await setResource(.integer(0))
        XCTAssertEqual(cleared["error"], .null)
    }

    func testResourcesResolveOnlyMappedNames() async throws {
        let menus = self.bridge(source: nil)
        let host = self.host(menus)
        try await self.activate(host)
        func resolve(_ kind: AyuBridgeValue, _ name: AyuBridgeValue) async throws -> AyuBridgeValue {
            try await self.call(host, "resources.resolve", ["resource": kind, "name": name])
        }
        var answer = try await resolve(.string("drawable"), .string("msg_settings"))
        XCTAssertEqual(answer["result"], .bool(true))
        answer = try await resolve(.string("drawable"), .string("msg_settings_hw_remix"))
        XCTAssertEqual(answer["result"], .bool(true))
        answer = try await resolve(.string("drawable"), .string("no_such_drawable"))
        XCTAssertEqual(answer["result"], .bool(false))
        answer = try await resolve(.string("raw"), .string("info"))
        XCTAssertEqual(answer["result"], .bool(true))
        answer = try await resolve(.string("string"), .string("AppName"))
        XCTAssertEqual(answer["result"], .bool(false))
        answer = try await resolve(.string("drawable"), .integer(1))
        XCTAssertEqual(answer["error"]["code"], .string("INVALID_ARGUMENTS"))
        answer = try await resolve(.string("drawable"), .string("../x"))
        XCTAssertEqual(answer["error"]["code"], .string("INVALID_ARGUMENTS"))
        answer = try await self.call(host, "resources.resolve", ["resource": .string("drawable"), "name": .string("msg_info"), "id": .integer(1)])
        XCTAssertEqual(answer["error"]["code"], .string("INVALID_ARGUMENTS"))

        XCTAssertEqual(AyuPluginResources.icon(drawable: "msg_delete"), .asset("Chat/Context Menu/Delete"))
        XCTAssertEqual(AyuPluginResources.icon(drawable: "msg_send"), .symbol("paperplane"))
        XCTAssertNil(AyuPluginResources.icon(drawable: "_solar"))
        XCTAssertNotNil(AyuPluginIcon.symbol("paperplane").image())
        XCTAssertThrowsError(try AyuPluginResources.icon(resource: .object(["resource": .string("string"), "name": .string("AppName")])))
        XCTAssertEqual(try AyuPluginResources.icon(resource: .object(["resource": .string("raw"), "name": .string("error")])), .symbol("exclamationmark.triangle"))
    }
}
