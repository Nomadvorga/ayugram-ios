import Foundation
import XCTest
@testable import AyuPluginBridge

/// A Telegram backend that records what the bridge asks of it and answers from what the test stored.
private final class RecordingTelegramBackend: AyuPluginTelegramBackend, @unchecked Sendable {
    struct Request {
        let account: AyuPluginTelegramAccount
        let function: Data
        let flags: Int32
        let completion: @Sendable (AyuPluginTelegramRequestResult) -> Void
    }
    struct PeerRead: Equatable { let kind: AyuPluginTelegramPeerKind; let id: Int64 }
    struct State {
        var requests: [Request] = []
        var cancelled: [Int] = []
        var filters: [AyuPluginTelegramHookFilter] = []
        var peers: [String: Data] = [:]
        var peerReads: [PeerRead] = []
        var messages: [Int32: Data] = [:]
        var messageReads: [[Int64]] = []
        var outgoing: [AyuPluginTelegramOutgoingMessage] = []
        var fileTargets: [Data] = []
        var path = "/var/mobile/Containers/Data/Application/cache/missing.ogg"
        var player = AyuPluginTelegramPlayerState(accountIndex: 0, paused: true)
        var actions: [AyuPluginTelegramPlayerAction] = []
    }
    let state = AyuTestBox(State())
    let operations: Set<String> = AyuPluginTelegramBridge.Operation.served
    let sendMessageParameters: Set<String> = AyuPluginTelegramBridge.sendMessageParameters
    let sendHookMutableFields: Set<String> = ["message", "caption", "entities", "notify"]

    func sendRequest(account: AyuPluginTelegramAccount, function: Data, flags: Int32,
                     completion: @escaping @Sendable (AyuPluginTelegramRequestResult) -> Void) throws -> AyuPluginTelegramCancellation {
        var count = 0
        self.state.update { $0.requests.append(Request(account: account, function: function, flags: flags, completion: completion)); count = $0.requests.count }
        let index = count - 1
        return AyuPluginTelegramCancellation { [state] in state.update { $0.cancelled.append(index) } }
    }
    func connectionState(account: AyuPluginTelegramAccount, completion: @escaping @Sendable (Result<AyuPluginTelegramConnectionState, AyuPluginTelegramBackendError>) -> Void) {
        completion(.success(AyuPluginTelegramConnectionState(timeMilliseconds: 1_700_000_123_456, timeDifference: -2, status: .connected, datacenterID: 4)))
    }
    func hookFilterDidChange(_ filter: AyuPluginTelegramHookFilter) { self.state.update { $0.filters.append(filter) } }
    func sendMessage(account: AyuPluginTelegramAccount, message: AyuPluginTelegramOutgoingMessage, completion: @escaping @Sendable (Result<Void, AyuPluginTelegramBackendError>) -> Void) {
        self.state.update { $0.outgoing.append(message) }
        completion(.success(()))
    }
    func editMessage(account: AyuPluginTelegramAccount, edit: AyuPluginTelegramMessageEdit, completion: @escaping @Sendable (Result<Void, AyuPluginTelegramBackendError>) -> Void) {
        completion(.failure(.unsupported("edit")))
    }
    func peer(account: AyuPluginTelegramAccount, kind: AyuPluginTelegramPeerKind, id: Int64, completion: @escaping @Sendable (Result<Data?, AyuPluginTelegramBackendError>) -> Void) {
        self.state.update { $0.peerReads.append(PeerRead(kind: kind, id: id)) }
        completion(.success(self.state.value.peers[kind.rawValue + ":" + String(id)]))
    }
    func messages(account: AyuPluginTelegramAccount, dialogID: Int64, ids: [Int32], completion: @escaping @Sendable (Result<[Data?], AyuPluginTelegramBackendError>) -> Void) {
        self.state.update { $0.messageReads.append([dialogID] + ids.map(Int64.init)) }
        let stored = self.state.value.messages
        completion(.success(ids.map { stored[$0] }))
    }
    func navigate(account: AyuPluginTelegramAccount, target: AyuPluginTelegramNavigationTarget, completion: @escaping @Sendable (Result<Void, AyuPluginTelegramBackendError>) -> Void) {
        completion(.failure(.unsupported("navigate")))
    }
    func filePath(account: AyuPluginTelegramAccount, target: Data, cache: Bool, completion: @escaping @Sendable (Result<String, AyuPluginTelegramBackendError>) -> Void) {
        self.state.update { $0.fileTargets.append(target) }
        completion(.success(self.state.value.path))
    }
    func loadFile(account: AyuPluginTelegramAccount, target: Data, parent: Data?, priority: Int32, cacheType: Int32, completion: @escaping @Sendable (Result<Void, AyuPluginTelegramBackendError>) -> Void) {
        completion(.success(()))
    }
    func cancelFileLoad(account: AyuPluginTelegramAccount, target: Data, completion: @escaping @Sendable (Result<Void, AyuPluginTelegramBackendError>) -> Void) {
        completion(.success(()))
    }
    func player(action: AyuPluginTelegramPlayerAction, completion: @escaping @Sendable (Result<AyuPluginTelegramPlayerState, AyuPluginTelegramBackendError>) -> Void) {
        self.state.update { state in
            state.actions.append(action)
            if action == .pause { state.player.paused = true }
            if action == .resume { state.player.paused = false }
        }
        completion(.success(self.state.value.player))
    }
}

/// A hand-rolled reader of boxed TL, so the bytes the backend receives are checked without the SDK.
private struct TLReader {
    private let bytes: [UInt8]
    private(set) var offset = 0
    init(_ data: Data) { self.bytes = Array(data) }
    var isAtEnd: Bool { self.offset == self.bytes.count }
    mutating func uint32() -> UInt32 {
        guard self.offset + 4 <= self.bytes.count else { self.offset = self.bytes.count + 1; return 0 }
        defer { self.offset += 4 }
        return (0..<4).reduce(UInt32(0)) { $0 | UInt32(self.bytes[self.offset + $1]) << (8 * UInt32($1)) }
    }
    mutating func int32() -> Int32 { Int32(bitPattern: self.uint32()) }
    mutating func int64() -> Int64 {
        let low = UInt64(self.uint32()), high = UInt64(self.uint32())
        return Int64(bitPattern: low | high << 32)
    }
    mutating func string() -> String {
        guard self.offset < self.bytes.count else { self.offset = self.bytes.count + 1; return "" }
        var length = Int(self.bytes[self.offset]), header = 1
        if length == 254 {
            guard self.offset + 4 <= self.bytes.count else { self.offset = self.bytes.count + 1; return "" }
            length = Int(self.bytes[self.offset + 1]) | Int(self.bytes[self.offset + 2]) << 8 | Int(self.bytes[self.offset + 3]) << 16
            header = 4
        }
        let start = self.offset + header
        guard start + length <= self.bytes.count else { self.offset = self.bytes.count + 1; return "" }
        self.offset = start + length
        while (self.offset - (start - header)) % 4 != 0 { self.offset += 1 }
        return String(decoding: self.bytes[start..<(start + length)], as: UTF8.self)
    }
}

private func tlBytes(_ words: [UInt32]) -> Data {
    Data(words.flatMap { word in (0..<4).map { UInt8(truncatingIfNeeded: word >> (8 * UInt32($0))) } })
}

/// The Telegram plane end to end: the real SDK in the real interpreter, `AyuPluginTelegramBridge`
/// and a recording backend. TL bytes are checked by hand or produced by the SDK in a plugin.
@MainActor
final class AyuPluginEndToEndTelegramTests: XCTestCase {
    private static let helpers = """
    import base64
    from org.telegram.tgnet import SerializedData, TLRPC

    def wire(value):
        stream = SerializedData()
        value.serializeToStream(stream)
        return base64.b64encode(bytes(stream.toByteArray())).decode("ascii")
    """

    private func bind(_ stack: AyuEndToEnd, dialogID: Int64 = 77) -> (RecordingTelegramBackend, AyuPluginScreenSnapshot) {
        let screen = stack.bindApplication(dialogID: dialogID, telegram: AyuPluginTelegramScreen(kind: .chat, dialogID: dialogID))
        let backend = RecordingTelegramBackend()
        AyuPluginTelegramBridge.shared.bind(backend: backend)
        return (backend, screen)
    }

    private func unbind(_ stack: AyuEndToEnd) {
        AyuPluginTelegramBridge.shared.bind(backend: nil)
        stack.unbindApplication()
    }

    private func wait(_ condition: @escaping () -> Bool, timeout: TimeInterval = 10) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() >= deadline { return false }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return true
    }

    func testEveryTelegramOperationIsDeclaredOnlyWhileABackendIsBound() async throws {
        let stack = try AyuEndToEnd.shared()
        let before = try await AyuEndToEnd.capabilities(of: stack.service.host)["operations"].array ?? []
        XCTAssertFalse(before.contains { $0.string?.hasPrefix("telegram.") == true }, "\(before)")
        XCTAssertFalse(before.contains(.string("menus.add")))
        let (_, _) = self.bind(stack)
        defer { self.unbind(stack) }
        let bound = Set((try await AyuEndToEnd.capabilities(of: stack.service.host)["operations"].array ?? []).compactMap(\.string))
        XCTAssertTrue(bound.isSuperset(of: AyuPluginTelegramBridge.Operation.served), "\(AyuPluginTelegramBridge.Operation.served.subtracting(bound))")
        XCTAssertTrue(bound.contains("menus.add"))
    }

    func testRequestsReachTheBackendAsTLAndAnswersAreDecodedByTheSDK() async throws {
        let stack = try AyuEndToEnd.shared()
        let (backend, _) = self.bind(stack)
        defer { self.unbind(stack) }
        let id = try await stack.start(AyuEndToEnd.source(id: "e2e_tg_requests", """
        from base_plugin import BasePlugin
        from client_utils import RequestCallback, get_connections_manager, send_request
        from org.telegram.tgnet import TLRPC, Vector
        \(AyuEndToEnd.recorder)


        class RequestPlugin(Recorder, BasePlugin):
            def answer(self, name):
                def callback(response, error):
                    fields = []
                    if isinstance(response, TLRPC.TL_messages_affectedMessages):
                        fields = [response.pts, response.pts_count]
                    elif isinstance(response, TLRPC.TL_nearestDc):
                        fields = [response.country, response.this_dc, response.nearest_dc]
                    elif isinstance(response, Vector):
                        fields = [type(item).__name__ + ":" + str(item.id) for item in response.objects]
                    self.set_setting("answer_" + name, [None if response is None else type(response).__name__, fields,
                                                        None if error is None else [type(error).__name__, error.code, error.text]])
                return callback

            def on_plugin_load(self):
                read = TLRPC.TL_messages_readHistory()
                read.peer = TLRPC.TL_inputPeerSelf()
                read.max_id = 77
                self.record("read", lambda: send_request(read, self.answer("read")))
                resolve = TLRPC.TL_contacts_resolveUsername()
                resolve.username = "durov"
                self.record("resolve", lambda: send_request(resolve, self.answer("resolve")))
                self.record("nearest", lambda: get_connections_manager().sendRequest(TLRPC.TL_help_getNearestDc(), RequestCallback(self.answer("nearest"))))
                users = TLRPC.TL_users_getUsers()
                users.id.add(TLRPC.TL_inputUserSelf())
                self.record("users", lambda: send_request(users, self.answer("users")))
                self.record("transport", lambda: send_request(TLRPC.TL_help_getConfig(), self.answer("transport")))
                self.record("hooked", lambda: send_request(TLRPC.TL_help_getConfig(), self.answer("hooked")))
                self.record("held", lambda: send_request(TLRPC.TL_help_getConfig(), self.answer("held")))
                self.record("cancel", lambda: get_connections_manager().cancelRequest(self.get_setting("held"), True))
                self.record("refused", lambda: send_request(TLRPC.TL_auth_logOut(), self.answer("refused")))
                self.record("not_a_function", lambda: send_request(TLRPC.TL_inputPeerSelf(), self.answer("not_a_function")))
                self.record("time", lambda: [get_connections_manager().getCurrentTime(), get_connections_manager().getConnectionState()])
        """))
        let stored = { (key: String) in stack.stored(id, key) }
        let ids = ["read", "resolve", "nearest", "users", "transport", "hooked", "held"].map { stored($0).integer }
        XCTAssertEqual(ids.compactMap { $0 }.count, 7, "Every request returns its id: \(ids)")
        XCTAssertEqual(Set(ids.compactMap { $0 }).count, 7, "Request ids are unique")
        XCTAssertEqual(stored("cancel"), .null)
        XCTAssertEqual(stored("refused"), .string("!BridgeError: UNSUPPORTED_API: Unsupported API: telegram.request does not send auth.logOut"))
        XCTAssertTrue(stored("not_a_function").string?.hasPrefix("!TypeError") == true, "\(stored("not_a_function"))")
        XCTAssertEqual(stored("time"), .array([.integer(1_700_000_123), .integer(3)]))

        let requests = backend.state.value.requests
        XCTAssertEqual(requests.count, 7, "The refused function and the non-function never reach the backend")
        XCTAssertEqual(requests.map(\.account.index), Array(repeating: 0, count: 7))
        XCTAssertEqual(requests.map(\.flags), Array(repeating: 0, count: 7))
        // messages.readHistory#0e306d3a peer:InputPeer max_id:int, with inputPeerSelf#7da07ec9.
        var read = TLReader(requests[0].function)
        XCTAssertEqual([read.uint32(), read.uint32()], [0x0e30_6d3a, 0x7da0_7ec9])
        XCTAssertEqual(read.int32(), 77)
        XCTAssertTrue(read.isAtEnd)
        // contacts.resolveUsername#725afbbc flags:# username:string referer:flags.0?string.
        var resolve = TLReader(requests[1].function)
        XCTAssertEqual([resolve.uint32(), resolve.uint32()], [0x725a_fbbc, 0])
        XCTAssertEqual(resolve.string(), "durov")
        XCTAssertTrue(resolve.isAtEnd)
        XCTAssertEqual(requests[2].function, tlBytes([0x1fb3_3026]), "help.getNearestDc")
        // users.getUsers#0d91a548 id:Vector<InputUser>, with inputUserSelf#f7c1b13f.
        XCTAssertEqual(requests[3].function, tlBytes([0x0d91_a548, 0x1cb5_c415, 1, 0xf7c1_b13f]))
        XCTAssertEqual(requests[4].function, tlBytes([0xc4f9_186b]), "help.getConfig")
        XCTAssertEqual(backend.state.value.cancelled, [6], "cancelRequest reaches the backend's cancellation")

        // messages.affectedMessages#84d19185 pts:int pts_count:int.
        requests[0].completion(.response(tlBytes([0x84d1_9185, 5, 2])))
        requests[1].completion(.rpcError(AyuPluginTelegramRPCError(code: 400, text: "USERNAME_INVALID")))
        // nearestDc#8e1a1775 country:string this_dc:int nearest_dc:int.
        requests[2].completion(.response(Data([0x75, 0x17, 0x1a, 0x8e, 2, 0x55, 0x53, 0]) + tlBytes([2, 4])))
        // Vector<User> with userEmpty#d3bc4b7a id:long.
        requests[3].completion(.response(tlBytes([0x1cb5_c415, 1, 0xd3bc_4b7a, 77, 0])))
        requests[4].completion(.transportFailure("NETWORK_LOST"))
        requests[5].completion(.cancelledByHook)
        requests[6].completion(.response(tlBytes([0x84d1_9185, 1, 1])))

        let readAnswer = await stack.waitForStored(id, "answer_read")
        XCTAssertEqual(readAnswer, .array([.string("TL_messages_affectedMessages"), .array([.integer(5), .integer(2)]), .null]))
        let resolveAnswer = await stack.waitForStored(id, "answer_resolve")
        XCTAssertEqual(resolveAnswer, .array([.null, .array([]), .array([.string("TL_error"), .integer(400), .string("USERNAME_INVALID")])]))
        let nearestAnswer = await stack.waitForStored(id, "answer_nearest")
        XCTAssertEqual(nearestAnswer, .array([.string("TL_nearestDc"), .array([.string("US"), .integer(2), .integer(4)]), .null]))
        let usersAnswer = await stack.waitForStored(id, "answer_users")
        XCTAssertEqual(usersAnswer, .array([.string("Vector"), .array([.string("TL_userEmpty:77")]), .null]))
        let transportAnswer = await stack.waitForStored(id, "answer_transport")
        XCTAssertEqual(transportAnswer, .array([.null, .array([]), .array([.string("TL_error"), .integer(-1), .string("NETWORK_LOST")])]))
        let hookedAnswer = await stack.waitForStored(id, "answer_hooked")
        XCTAssertEqual(hookedAnswer, .array([.null, .array([]), .null]), "A request cancelled by a hook completes with neither")
        XCTAssertEqual(stack.stored(id, "answer_held"), .null, "A cancelled request's callback never fires")
        XCTAssertEqual(stack.record(id)?.error, nil)
        await stack.remove(id)
    }

    func testPeersMessagesFilesAndThePlayerDecodeWhatTheBackendStores() async throws {
        let stack = try AyuEndToEnd.shared()
        let (backend, _) = self.bind(stack)
        defer { self.unbind(stack) }
        let factory = try await stack.start(AyuEndToEnd.source(id: "e2e_tg_factory", """
        from base_plugin import BasePlugin
        \(Self.helpers)
        \(AyuEndToEnd.recorder)


        class FactoryPlugin(Recorder, BasePlugin):
            def on_plugin_load(self):
                def user():
                    value = TLRPC.TL_user()
                    value.id, value.first_name, value.last_name, value.username = 77, "Ann", "Lee", "annlee"
                    value.access_hash, value.bot = 0x1122334455667788, True
                    value.flags = 1 | 2 | 4 | 8
                    return wire(value)
                def channel():
                    value = TLRPC.TL_channel()
                    value.id, value.title, value.megagroup, value.access_hash, value.date = 5, "News", True, -42, 1700000000
                    value.photo = TLRPC.TL_chatPhotoEmpty()
                    value.flags = 0x2000
                    return wire(value)
                def message():
                    value = TLRPC.TL_message()
                    value.id, value.date, value.message = 12, 1700000000, "hello"
                    value.peer_id = TLRPC.TL_peerUser()
                    value.peer_id.user_id = 77
                    return wire(value)
                self.record("user", user)
                self.record("channel", channel)
                self.record("message", message)
        """))
        func made(_ key: String) throws -> Data {
            let text = try XCTUnwrap(stack.stored(factory, key).string, "\(stack.stored(factory, key))")
            XCTAssertFalse(text.hasPrefix("!"), text)
            return try XCTUnwrap(Data(base64Encoded: text), text)
        }
        let user = try made("user"), channel = try made("channel"), message = try made("message")
        await stack.remove(factory)
        // user#31774388 for layer 233 starts with its constructor and the flags the SDK derived (bot is bit 14).
        var userReader = TLReader(user)
        _ = userReader.uint32()
        XCTAssertEqual(userReader.uint32() & 0x400f, 0x400f)
        backend.state.update {
            $0.peers = ["user:77": user, "chat:5": channel]
            $0.messages = [12: message]
            $0.player = AyuPluginTelegramPlayerState(accountIndex: 0, paused: false, message: message, progress: 0.5, positionMilliseconds: 61_500, durationMilliseconds: 123_000)
        }

        let id = try await stack.start(AyuEndToEnd.source(id: "e2e_tg_state", """
        from base_plugin import BasePlugin
        from client_utils import get_file_loader, get_media_controller, get_messages_controller, get_messages_storage
        from org.telegram.messenger import ChatObject, FileLoader, MediaController, MessageObject, MessagesController, MessagesStorage, UserObject
        from org.telegram.tgnet import TLRPC
        \(AyuEndToEnd.recorder)


        class StatePlugin(Recorder, BasePlugin):
            def on_plugin_load(self):
                controller = get_messages_controller()
                def user():
                    value = controller.getUser(77)
                    return [type(value).__name__, value.id, value.first_name, value.last_name, value.username, value.access_hash, value.bot,
                            getattr(value, "self"), UserObject.isUserSelf(value), isinstance(value, TLRPC.User)]
                self.record("user", user)
                def chat():
                    value = MessagesController.getInstance(0).getChat(5)
                    return [type(value).__name__, value.id, value.title, value.megagroup, value.access_hash, ChatObject.isChannel(value),
                            ChatObject.isChannelAndNotMegaGroup(value)]
                self.record("chat", chat)
                self.record("unknown", lambda: [controller.getUser(404), controller.getChat(404)])
                def stored():
                    value = MessagesStorage.getInstance(0).getMessage(77, 12)
                    missing = get_messages_storage().getMessage(77, 13)
                    return [type(value).__name__, value.id, value.message, value.date, type(value.peer_id).__name__, value.peer_id.user_id, missing]
                self.record("message", stored)
                def path():
                    value = MessagesStorage.getInstance(0).getMessage(77, 12)
                    file = FileLoader.getInstance(0).getPathToMessage(value)
                    return [file.getAbsolutePath(), file.exists(), get_file_loader().getPathToMessage(None).getPath()]
                self.record("path", path)
                def player():
                    media = MediaController.getInstance()
                    playing = media.getPlayingMessageObject()
                    return [type(playing).__name__, playing.getId(), playing.getDialogId(), playing.audioProgress, type(playing.audioProgress).__name__,
                            playing.audioProgressSec, media.isMessagePaused(), media.isPlayingMessage(playing), media.getDuration(),
                            media.pauseMessage(playing), media.isMessagePaused(), media.playMessage(playing), get_media_controller().isMessagePaused(),
                            media.seekToProgress(playing, 1), media.getProgressMs(playing)]
                self.record("player", player)
        """))
        let stored = { (key: String) in stack.stored(id, key) }
        XCTAssertEqual(stored("user"), .array([.string("TL_user"), .integer(77), .string("Ann"), .string("Lee"), .string("annlee"),
                                               .integer(0x1122_3344_5566_7788), .bool(true), .bool(false), .bool(false), .bool(true)]))
        XCTAssertEqual(stored("chat"), .array([.string("TL_channel"), .integer(5), .string("News"), .bool(true), .integer(-42), .bool(true), .bool(false)]))
        XCTAssertEqual(stored("unknown"), .array([.null, .null]))
        XCTAssertEqual(stored("message"), .array([.string("TL_message"), .integer(12), .string("hello"), .integer(1_700_000_000), .string("TL_peerUser"), .integer(77), .null]))
        XCTAssertEqual(stored("path"), .array([.string(backend.state.value.path), .bool(false), .string("")]))
        XCTAssertEqual(stored("player"), .array([.string("MessageObject"), .integer(12), .integer(77), .number(0.5), .string("float"), .integer(61),
                                                 .bool(false), .bool(true), .integer(123_000), .bool(true), .bool(true), .bool(true), .bool(false),
                                                 .bool(true), .integer(61_500)]))
        let state = backend.state.value
        XCTAssertEqual(Array(state.peerReads.prefix(4)), [.init(kind: .user, id: 77), .init(kind: .chat, id: 5), .init(kind: .user, id: 404), .init(kind: .chat, id: 404)])
        XCTAssertEqual(Array(state.messageReads.prefix(2)), [[77, 12], [77, 13]])
        XCTAssertEqual(state.fileTargets, [message], "The file target is the message the SDK was given, byte for byte")
        XCTAssertTrue(state.actions.contains(.pause) && state.actions.contains(.resume) && state.actions.contains(.seek(1)), "\(state.actions)")
        await stack.remove(id)
    }

    func testSendMessageParametersArriveAsTheBackendTypes() async throws {
        let stack = try AyuEndToEnd.shared()
        let (backend, _) = self.bind(stack)
        defer { self.unbind(stack) }
        let attachment = FileManager.default.temporaryDirectory.appendingPathComponent("ayu-e2e-" + UUID().uuidString + ".txt")
        try Data("attachment".utf8).write(to: attachment)
        defer { try? FileManager.default.removeItem(at: attachment) }
        // message#… as the SDK serializes it, produced by the plugin itself before it replies to it.
        let id = try await stack.start(AyuEndToEnd.source(id: "e2e_tg_send", """
        from base_plugin import BasePlugin
        from client_utils import send_document, send_message, send_photo, send_text
        from org.telegram.messenger import MessageObject
        \(Self.helpers)
        \(AyuEndToEnd.recorder)

        PATH = "\(attachment.path)"


        class SendPlugin(Recorder, BasePlugin):
            def on_plugin_load(self):
                self.record("plain", lambda: send_text(77, "plain"))
                def rich():
                    bold = TLRPC.TL_messageEntityBold()
                    bold.offset, bold.length = 0, 4
                    replied = TLRPC.TL_message()
                    replied.id, replied.date, replied.message = 12, 1700000000, "hello"
                    replied.peer_id = TLRPC.TL_peerUser()
                    replied.peer_id.user_id = 77
                    self.set_setting("replied", wire(replied))
                    return send_message({"peer": -1001234567890, "message": "rich text", "entities": [bold], "replyToMsg": MessageObject(0, replied),
                                         "notify": False, "scheduleDate": 1700000100, "searchLinks": False, "params": {"k": 1}})
                self.record("rich", rich)
                self.record("markdown", lambda: send_text(77, "*bold* tail", parse_mode="markdown"))
                self.record("html", lambda: send_text(77, "<i>it</i> tail", parse_mode="HTML"))
                self.record("document", lambda: send_document(77, PATH, "caption"))
                self.record("photo", lambda: send_photo(77, PATH, "", True))
                self.record("unknown_key", lambda: send_message({"peer": 77, "message": "x", "no_such_field": 1}))
                self.record("no_peer", lambda: send_message({"message": "x"}))
                self.record("outside", lambda: send_document(77, "/etc/hosts", "caption"))
        """))
        let stored = { (key: String) in stack.stored(id, key) }
        for key in ["plain", "rich", "markdown", "html", "document", "photo", "unknown_key"] { XCTAssertEqual(stored(key), .null, key) }
        XCTAssertTrue(stored("no_peer").string?.hasPrefix("!") == true, "\(stored("no_peer"))")
        XCTAssertTrue(stored("outside").string?.hasPrefix("!BridgeError: INVALID_ARGUMENTS") == true, "A file outside the app container is refused: \(stored("outside"))")
        let outgoing = backend.state.value.outgoing
        XCTAssertEqual(outgoing.count, 7, "\(outgoing.map(\.keys))")
        guard outgoing.count == 7 else { await stack.remove(id); return }

        XCTAssertEqual(outgoing[0].keys, ["message", "peer"])
        XCTAssertEqual(outgoing[0].peer, 77)
        XCTAssertEqual(outgoing[0].message, "plain")
        XCTAssertNil(outgoing[0].entities)

        let rich = outgoing[1]
        XCTAssertEqual(rich.keys, ["entities", "message", "notify", "params", "peer", "replyToMsg", "scheduleDate", "searchLinks"])
        XCTAssertEqual(rich.peer, -1_001_234_567_890)
        XCTAssertEqual(rich.message, "rich text")
        // messageEntityBold#bd610bc9 offset:int length:int.
        XCTAssertEqual(rich.entities, [tlBytes([0xbd61_0bc9, 0, 4])])
        XCTAssertEqual(rich.replyTo?.dialogID, 77)
        XCTAssertEqual(rich.replyTo?.messageID, 12)
        XCTAssertEqual(rich.replyTo?.message, Data(base64Encoded: stored("replied").string ?? ""))
        XCTAssertEqual(rich.booleans, ["notify": false, "searchLinks": false])
        XCTAssertEqual(rich.integers, ["scheduleDate": 1_700_000_100])
        XCTAssertEqual(rich.parameters, ["k": "1"])

        XCTAssertEqual(outgoing[2].message, "bold tail", "parse_mode strips the markup")
        XCTAssertEqual(outgoing[2].entities, [tlBytes([0xbd61_0bc9, 0, 4])])

        XCTAssertEqual(outgoing[3].message, "it tail")
        // messageEntityItalic#826f8b60 offset:int length:int.
        XCTAssertEqual(outgoing[3].entities, [tlBytes([0x826f_8b60, 0, 2])])

        XCTAssertEqual(outgoing[4].path, attachment.path)
        XCTAssertEqual(outgoing[4].attachment, .document)
        XCTAssertEqual(outgoing[4].caption, "caption")
        XCTAssertNil(outgoing[4].message)
        XCTAssertEqual(outgoing[5].attachment, .photo)
        XCTAssertEqual(outgoing[5].booleans, ["sendingHighQuality": true])
        XCTAssertEqual(outgoing[5].caption, "", "Android's send_photo sets the empty caption it was given; the backend sees it")
        XCTAssertEqual(outgoing[6].keys, ["message", "peer"], "A field SendMessageParams does not have is logged and left out")
        await stack.remove(id)
    }

    func testTheTypedSendMessageHookSeesAndRewritesTheOutgoingMessage() async throws {
        let stack = try AyuEndToEnd.shared()
        let (_, _) = self.bind(stack)
        defer { self.unbind(stack) }
        let id = try await stack.start(AyuEndToEnd.source(id: "e2e_tg_send_hook", """
        from base_plugin import BasePlugin, HookResult, HookStrategy
        from org.telegram.tgnet import TLRPC
        \(AyuEndToEnd.recorder)


        class SendHookPlugin(Recorder, BasePlugin):
            def on_plugin_load(self):
                self.record("hook", lambda: type(self.add_on_send_message_hook(7)).__name__)

            def on_send_message_hook(self, account, params):
                reply = params.replyToMsg
                self.set_setting("seen", _plain([account, type(params).__name__, params.peer, params.message, params.caption, params.notify,
                                                 params.scheduleDate, None if params.entities is None else [type(entity).__name__ + ":" + str(entity.offset) + "+" + str(entity.length) for entity in params.entities],
                                                 None if reply is None else [type(reply).__name__, reply.getId(), reply.messageOwner.message], params.path]))
                if params.message == "drop":
                    return HookResult(strategy=HookStrategy.CANCEL)
                if params.message == "keep":
                    return HookResult()
                if params.message == "move":
                    params.peer = 99
                    return HookResult(strategy=HookStrategy.MODIFY, params=params)
                italic = TLRPC.TL_messageEntityItalic()
                italic.offset, italic.length = 0, 2
                params.message = params.message.upper()
                params.entities = [italic]
                params.notify = False
                return HookResult(strategy=HookStrategy.MODIFY_FINAL, params=params)
        """))
        XCTAssertEqual(stack.stored(id, "hook"), .string("Registration"))
        let bridge = AyuPluginTelegramBridge.shared
        XCTAssertTrue(bridge.hasSendMessageHooks)
        func send(_ message: AyuPluginTelegramHookedMessage) async -> AyuPluginTelegramSendDecision {
            await withCheckedContinuation { continuation in bridge.interceptSendMessage(account: 0, message: message) { continuation.resume(returning: $0) } }
        }
        // message#… with id 12 and text "hello" is rebuilt here by hand: messageEmpty#90a6ca84 has no text, so the reply is a service-free minimum.
        var original = AyuPluginTelegramHookedMessage(peer: -1_001_234_567_890)
        original.message = "edit me"
        original.entities = [tlBytes([0xbd61_0bc9, 0, 4])]
        original.scheduleDate = 1_700_000_100
        let edited = await send(original)
        XCTAssertEqual(stack.stored(id, "seen"), .array([.integer(0), .string("SendMessageParams"), .integer(-1_001_234_567_890), .string("edit me"), .null,
                                                         .bool(true), .integer(1_700_000_100), .array([.string("TL_messageEntityBold:0+4")]), .null, .null]))
        guard case let .send(message, remapEntities) = edited else { return XCTFail("\(edited)") }
        XCTAssertEqual(message.message, "EDIT ME")
        // messageEntityItalic#826f8b60 offset:int length:int.
        XCTAssertEqual(message.entities, [tlBytes([0x826f_8b60, 0, 2])])
        XCTAssertFalse(message.notify)
        XCTAssertFalse(remapEntities, "Entities the plugin supplied are applied as given")
        XCTAssertEqual(message.peer, -1_001_234_567_890)
        XCTAssertEqual(message.scheduleDate, 1_700_000_100)

        var kept = AyuPluginTelegramHookedMessage(peer: 77)
        kept.message = "keep"
        let unchanged = await send(kept)
        guard case let .send(same, _) = unchanged else { return XCTFail("\(unchanged)") }
        XCTAssertEqual(same.message, "keep")
        XCTAssertTrue(same.notify)

        var moved = AyuPluginTelegramHookedMessage(peer: 77)
        moved.message = "move"
        let refused = await send(moved)
        guard case let .send(stays, _) = refused else { return XCTFail("\(refused)") }
        XCTAssertEqual(stays.peer, 77, "A changed peer discards the modification")

        var dropped = AyuPluginTelegramHookedMessage(peer: 77)
        dropped.message = "drop"
        let cancelled = await send(dropped)
        XCTAssertEqual(cancelled, .cancel)

        await stack.remove(id)
        XCTAssertFalse(bridge.hasSendMessageHooks)
    }

    func testRequestAndUpdateHooksRunByPriorityWithTheirStrategies() async throws {
        let stack = try AyuEndToEnd.shared()
        let (backend, _) = self.bind(stack)
        defer { self.unbind(stack) }
        func plugin(_ id: String, priority: Int, body: String) -> String {
            AyuEndToEnd.source(id: id, """
            from base_plugin import BasePlugin, HookResult, HookStrategy
            from org.telegram.tgnet import TLRPC
            \(AyuEndToEnd.recorder)


            class HookPlugin(Recorder, BasePlugin):
                def on_plugin_load(self):
                    self.log_lines = []
                    for name in ("TL_messages_readHistory", "TL_updateDeleteMessages", "TL_updateShort", "TL_help_getConfig"):
                        self.record("add_" + name, lambda: type(self.add_hook(name, priority=\(priority))).__name__)
                    self.record("unknown", lambda: self.add_hook("TL_noSuchConstructor"))

                def note(self, *values):
                    self.log_lines.append(list(values))
                    self.set_setting("log", self.log_lines)

            \(body.split(separator: "\n", omittingEmptySubsequences: false).map { $0.hasPrefix("    ") ? String($0.dropFirst(4)) : String($0) }.joined(separator: "\n"))
            """)
        }
        let first = try await stack.start(plugin("e2e_tg_hooks_a", priority: 10, body: """
                def pre_request_hook(self, request_name, account, request):
                    self.note("pre", request_name, account, type(request).__name__, getattr(request, "max_id", None))
                    if request_name == "TL_help_getConfig":
                        return HookResult(strategy=HookStrategy.CANCEL)
                    request.max_id += 1
                    return HookResult(strategy=HookStrategy.MODIFY, request=request)

                def post_request_hook(self, request_name, account, response, error):
                    self.note("post", request_name, account, None if response is None else [type(response).__name__, response.pts], None if error is None else [error.code, error.text])
                    if response is not None:
                        response.pts += 100
                        return HookResult(strategy=HookStrategy.MODIFY, response=response)
                    replaced = TLRPC.TL_error()
                    replaced.code, replaced.text = 420, "FLOOD_WAIT_3"
                    return HookResult(strategy=HookStrategy.MODIFY, error=replaced)

                def on_update_hook(self, update_name, account, update):
                    self.note("update", update_name, account, list(update.messages), update.pts)
                    if update.pts == 1:
                        return HookResult(strategy=HookStrategy.CANCEL)
                    update.pts += 10
                    return HookResult(strategy=HookStrategy.MODIFY_FINAL, update=update)

                def on_updates_hook(self, container_name, account, updates):
                    self.note("updates", container_name, account, type(updates.update).__name__, updates.date)
                    updates.date += 1
                    return HookResult(strategy=HookStrategy.MODIFY, updates=updates)
        """))
        let second = try await stack.start(plugin("e2e_tg_hooks_b", priority: 1, body: """
                def pre_request_hook(self, request_name, account, request):
                    self.note("pre", request_name, account, type(request).__name__, getattr(request, "max_id", None))
                    return HookResult()

                def post_request_hook(self, request_name, account, response, error):
                    self.note("post", request_name, account, None if response is None else [type(response).__name__, response.pts], None if error is None else [error.code, error.text])
                    return HookResult()

                def on_update_hook(self, update_name, account, update):
                    self.note("update", update_name, account, list(update.messages), update.pts)
                    return HookResult()

                def on_updates_hook(self, container_name, account, updates):
                    self.note("updates", container_name, account, type(updates.update).__name__, updates.date)
                    return HookResult(strategy=HookStrategy.CANCEL)
        """))
        for id in [first, second] {
            XCTAssertEqual(stack.stored(id, "add_TL_messages_readHistory"), .string("EventHook"), "\(stack.stored(id, "add_TL_messages_readHistory"))")
            XCTAssertEqual(stack.stored(id, "unknown"), .string("<EventHook>"), "A name no constructor has is a filter that never matches, as on Android")
        }
        // messages.readHistory, help.getConfig; updateDeleteMessages#a20db0e5; updateShort#78d4dec1.
        let filter = try XCTUnwrap(backend.state.value.filters.last)
        XCTAssertEqual(filter.requests, [0x0e30_6d3a, 0xc4f9_186b])
        XCTAssertEqual(filter.updates, [0xa20d_b0e5])
        XCTAssertEqual(filter.containers, [0x78d4_dec1])
        let bridge = AyuPluginTelegramBridge.shared
        XCTAssertEqual(bridge.hookFilter, filter)

        let readHistory = tlBytes([0x0e30_6d3a, 0x7da0_7ec9, 77])
        let request = await withCheckedContinuation { continuation in bridge.interceptRequest(account: 0, function: readHistory) { continuation.resume(returning: $0) } }
        XCTAssertEqual(request, .proceed(tlBytes([0x0e30_6d3a, 0x7da0_7ec9, 78])), "The higher priority's change reaches the backend")
        let config = await withCheckedContinuation { continuation in bridge.interceptRequest(account: 0, function: tlBytes([0xc4f9_186b])) { continuation.resume(returning: $0) } }
        XCTAssertEqual(config, .cancel)
        let unlisted = await withCheckedContinuation { continuation in bridge.interceptRequest(account: 0, function: tlBytes([0x1fb3_3026])) { continuation.resume(returning: $0) } }
        XCTAssertEqual(unlisted, .proceed(tlBytes([0x1fb3_3026])), "A constructor nobody listed is not shown to plugins")

        let answered = await withCheckedContinuation { continuation in
            bridge.interceptResponse(account: 0, constructor: 0x0e30_6d3a, result: AyuPluginTelegramResponse(response: tlBytes([0x84d1_9185, 5, 2]), error: nil)) { continuation.resume(returning: $0) }
        }
        XCTAssertEqual(answered, AyuPluginTelegramResponse(response: tlBytes([0x84d1_9185, 105, 2]), error: nil))
        let failed = await withCheckedContinuation { continuation in
            bridge.interceptResponse(account: 0, constructor: 0x0e30_6d3a, result: AyuPluginTelegramResponse(response: nil, error: AyuPluginTelegramRPCError(code: 400, text: "PEER_ID_INVALID"))) { continuation.resume(returning: $0) }
        }
        XCTAssertEqual(failed, AyuPluginTelegramResponse(response: nil, error: AyuPluginTelegramRPCError(code: 420, text: "FLOOD_WAIT_3")))

        // updateDeleteMessages#a20db0e5 messages:Vector<int> pts:int pts_count:int.
        func deletion(pts: UInt32) -> Data { tlBytes([0xa20d_b0e5, 0x1cb5_c415, 1, 7, pts, 1]) }
        let update = await withCheckedContinuation { continuation in bridge.interceptUpdate(account: 0, update: deletion(pts: 3)) { continuation.resume(returning: $0) } }
        XCTAssertEqual(update, .proceed(deletion(pts: 13)), "MODIFY_FINAL ends the chain with the change")
        let droppedUpdate = await withCheckedContinuation { continuation in bridge.interceptUpdate(account: 0, update: deletion(pts: 1)) { continuation.resume(returning: $0) } }
        XCTAssertEqual(droppedUpdate, .cancel)
        // updateShort#78d4dec1 update:Update date:int.
        let container = await withCheckedContinuation { continuation in
            bridge.interceptUpdates(account: 0, container: tlBytes([0x78d4_dec1]) + deletion(pts: 3) + tlBytes([9])) { continuation.resume(returning: $0) }
        }
        XCTAssertEqual(container, .cancel, "The lower priority cancels after the higher one modified")

        XCTAssertEqual(stack.stored(first, "log"), .array([
            .array([.string("pre"), .string("TL_messages_readHistory"), .integer(0), .string("TL_messages_readHistory"), .integer(77)]),
            .array([.string("pre"), .string("TL_help_getConfig"), .integer(0), .string("TL_help_getConfig"), .null]),
            .array([.string("post"), .string("TL_messages_readHistory"), .integer(0), .array([.string("TL_messages_affectedMessages"), .integer(5)]), .null]),
            .array([.string("post"), .string("TL_messages_readHistory"), .integer(0), .null, .array([.integer(400), .string("PEER_ID_INVALID")])]),
            .array([.string("update"), .string("TL_updateDeleteMessages"), .integer(0), .array([.integer(7)]), .integer(3)]),
            .array([.string("update"), .string("TL_updateDeleteMessages"), .integer(0), .array([.integer(7)]), .integer(1)]),
            .array([.string("updates"), .string("TL_updateShort"), .integer(0), .string("TL_updateDeleteMessages"), .integer(9)]),
        ]))
        XCTAssertEqual(stack.stored(second, "log"), .array([
            .array([.string("pre"), .string("TL_messages_readHistory"), .integer(0), .string("TL_messages_readHistory"), .integer(78)]),
            .array([.string("post"), .string("TL_messages_readHistory"), .integer(0), .array([.string("TL_messages_affectedMessages"), .integer(105)]), .null]),
            .array([.string("post"), .string("TL_messages_readHistory"), .integer(0), .null, .array([.integer(420), .string("FLOOD_WAIT_3")])]),
            .array([.string("updates"), .string("TL_updateShort"), .integer(0), .string("TL_updateDeleteMessages"), .integer(10)]),
        ]), "The lower priority sees what the higher one made, and nothing after CANCEL or MODIFY_FINAL")

        await stack.remove(first)
        XCTAssertEqual(backend.state.value.filters.last, filter, "The remaining plugin keeps the constructors listed")
        await stack.remove(second)
        XCTAssertEqual(backend.state.value.filters.last?.isEmpty, true)
    }

    func testAChatActionMenuItemReceivesTheBackendsTLContext() async throws {
        let stack = try AyuEndToEnd.shared()
        let (backend, screen) = self.bind(stack)
        let menus = AyuPluginMenuBridge.shared
        let account = try XCTUnwrap(AyuPluginTelegramBridge.shared.currentEnvironment()?.account(0)).identity
        menus.bindLocations(resolve: { request in
            AyuPluginMenuLocation(kind: request.kind, screen: screen, accountIdentity: account,
                                  dialogID: request.kind.needsDialog ? 77 : nil, messageID: request.messageID)
        }, isCurrent: { location, _ in location.isCurrent(screen: screen, accountIdentity: account) })
        defer {
            menus.unbindLocations()
            self.unbind(stack)
        }
        // userEmpty#d3bc4b7a id:long; messageEmpty#90a6ca84 flags:# id:int.
        backend.state.update {
            $0.peers = ["user:77": tlBytes([0xd3bc_4b7a, 77, 0])]
            $0.messages = [12: tlBytes([0x90a6_ca84, 0, 12])]
        }
        let id = try await stack.start(AyuEndToEnd.source(id: "e2e_tg_menu", """
        from base_plugin import BasePlugin, MenuItemData, MenuItemType
        \(AyuEndToEnd.recorder)


        class MenuPlugin(Recorder, BasePlugin):
            def on_plugin_load(self):
                self.record("chat", lambda: self.add_menu_item(MenuItemData(menu_type=MenuItemType.CHAT_ACTION_MENU, text="Chat row", item_id="chat",
                                                                            on_click=self.clicked, condition=lambda context: context["user"].id == 77)))
                self.record("message", lambda: self.add_menu_item(MenuItemData(menu_type=MenuItemType.MESSAGE_CONTEXT_MENU, text="Message row", item_id="message",
                                                                               on_click=self.message_clicked)))

            def clicked(self, context):
                self.set_setting("clicked", [context["account"], context["dialog_id"], type(context["user"]).__name__, context["user"].id, sorted(key for key in context if key not in ("fragment", "context"))])

            def message_clicked(self, context):
                self.set_setting("message_clicked", [context["dialog_id"], type(context["message"]).__name__, context["message"].getId(), type(context["user"]).__name__])
        """))
        XCTAssertEqual(stack.stored(id, "chat"), .string("chat"))
        let chat = await menus.open(AyuPluginMenuRequest(kind: .chatActionMenu, accountKey: nil), isPresented: { true })
        XCTAssertEqual(chat.entries.map(\.identifier), ["e2e_tg_menu:chat"])
        if let row = chat.entries.first { chat.activate(row) }
        let clicked = await stack.waitForStored(id, "clicked")
        XCTAssertEqual(Array(clicked.array?.prefix(4) ?? []), [.integer(0), .integer(77), .string("TL_userEmpty"), .integer(77)], "\(clicked)")
        let message = await menus.open(AyuPluginMenuRequest(kind: .messageContextMenu, accountKey: nil, messageID: 12), isPresented: { true })
        XCTAssertEqual(message.entries.map(\.identifier), ["e2e_tg_menu:message"])
        if let row = message.entries.first { message.activate(row) }
        let messageClicked = await stack.waitForStored(id, "message_clicked")
        XCTAssertEqual(messageClicked, .array([.integer(77), .string("MessageObject"), .integer(12), .string("TL_userEmpty")]))
        XCTAssertTrue(backend.state.value.peerReads.contains(.init(kind: .user, id: 77)))
        XCTAssertTrue(backend.state.value.messageReads.contains([77, 12]))
        await stack.remove(id)
    }
}
