import Foundation
@preconcurrency import XCTest
@testable import AyuPluginBridge

/// Bridge side of `protocol-telegram.md` against a fake backend: no Telegram
/// code, account, interpreter or network.
private final class FakeTelegramBackend: AyuPluginTelegramBackend, @unchecked Sendable {
    struct Sent {
        let account: AyuPluginTelegramAccount
        let function: Data
        let flags: Int32
        let completion: @Sendable (AyuPluginTelegramRequestResult) -> Void
    }
    struct State {
        var operations: Set<String> = AyuPluginTelegramBridge.Operation.served
        var sendMessageParameters: Set<String> = AyuPluginTelegramBridge.sendMessageParameters
        var sendHookMutableFields: Set<String> = ["message", "caption", "entities", "notify", "replyToMsg"]
        var sent: [Sent] = []
        var cancelled: [Int] = []
        var startError: AyuPluginTelegramBackendError?
        var completesAtOnce: AyuPluginTelegramRequestResult?
        /// Runs inside `sendRequest`, that is inside the plugin's dispatch.
        var duringStart: (@Sendable () -> Void)?
        var filters: [AyuPluginTelegramHookFilter] = []
        var answers = true
        var failure: AyuPluginTelegramBackendError?
        var connection = AyuPluginTelegramConnectionState(timeMilliseconds: 1_700_000_123_456, timeDifference: -2, status: .connected, datacenterID: 2)
        var peer: Data?
        var messages: [Data?] = []
        var path = "/var/mobile/cache/file"
        var player = AyuPluginTelegramPlayerState(accountIndex: 0, paused: true)
        var outgoing: [AyuPluginTelegramOutgoingMessage] = []
        var edits: [AyuPluginTelegramMessageEdit] = []
        var targets: [AyuPluginTelegramNavigationTarget] = []
        var loads: [String] = []
        var actions: [AyuPluginTelegramPlayerAction] = []
    }
    let state = AyuTestBox(State())

    var operations: Set<String> { self.state.value.operations }
    var sendMessageParameters: Set<String> { self.state.value.sendMessageParameters }
    var sendHookMutableFields: Set<String> { self.state.value.sendHookMutableFields }

    func sendRequest(account: AyuPluginTelegramAccount, function: Data, flags: Int32,
                     completion: @escaping @Sendable (AyuPluginTelegramRequestResult) -> Void) throws -> AyuPluginTelegramCancellation {
        if let error = self.state.value.startError { throw error }
        var count = 0
        self.state.update { $0.sent.append(Sent(account: account, function: function, flags: flags, completion: completion)); count = $0.sent.count }
        let index = count - 1
        if let result = self.state.value.completesAtOnce { completion(result) }
        self.state.value.duringStart?()
        return AyuPluginTelegramCancellation { [state] in state.update { $0.cancelled.append(index) } }
    }

    private func answer<Value>(_ value: Value, _ completion: @escaping @Sendable (Result<Value, AyuPluginTelegramBackendError>) -> Void) {
        let state = self.state.value
        guard state.answers else { return }
        completion(state.failure.map { .failure($0) } ?? .success(value))
    }

    func connectionState(account: AyuPluginTelegramAccount,
                         completion: @escaping @Sendable (Result<AyuPluginTelegramConnectionState, AyuPluginTelegramBackendError>) -> Void) {
        self.answer(self.state.value.connection, completion)
    }
    func hookFilterDidChange(_ filter: AyuPluginTelegramHookFilter) { self.state.update { $0.filters.append(filter) } }
    func sendMessage(account: AyuPluginTelegramAccount, message: AyuPluginTelegramOutgoingMessage,
                     completion: @escaping @Sendable (Result<Void, AyuPluginTelegramBackendError>) -> Void) {
        self.state.update { $0.outgoing.append(message) }
        self.answer((), completion)
    }
    func editMessage(account: AyuPluginTelegramAccount, edit: AyuPluginTelegramMessageEdit,
                     completion: @escaping @Sendable (Result<Void, AyuPluginTelegramBackendError>) -> Void) {
        self.state.update { $0.edits.append(edit) }
        self.answer((), completion)
    }
    func peer(account: AyuPluginTelegramAccount, kind: AyuPluginTelegramPeerKind, id: Int64,
              completion: @escaping @Sendable (Result<Data?, AyuPluginTelegramBackendError>) -> Void) {
        self.answer(self.state.value.peer, completion)
    }
    func messages(account: AyuPluginTelegramAccount, dialogID: Int64, ids: [Int32],
                  completion: @escaping @Sendable (Result<[Data?], AyuPluginTelegramBackendError>) -> Void) {
        self.answer(self.state.value.messages, completion)
    }
    func navigate(account: AyuPluginTelegramAccount, target: AyuPluginTelegramNavigationTarget,
                  completion: @escaping @Sendable (Result<Void, AyuPluginTelegramBackendError>) -> Void) {
        self.state.update { $0.targets.append(target) }
        self.answer((), completion)
    }
    func filePath(account: AyuPluginTelegramAccount, target: Data, cache: Bool,
                  completion: @escaping @Sendable (Result<String, AyuPluginTelegramBackendError>) -> Void) {
        self.answer(self.state.value.path, completion)
    }
    func loadFile(account: AyuPluginTelegramAccount, target: Data, parent: Data?, priority: Int32, cacheType: Int32,
                  completion: @escaping @Sendable (Result<Void, AyuPluginTelegramBackendError>) -> Void) {
        self.state.update { $0.loads.append("load \(priority) \(cacheType) \(parent != nil)") }
        self.answer((), completion)
    }
    func cancelFileLoad(account: AyuPluginTelegramAccount, target: Data,
                        completion: @escaping @Sendable (Result<Void, AyuPluginTelegramBackendError>) -> Void) {
        self.state.update { $0.loads.append("cancel") }
        self.answer((), completion)
    }
    func player(action: AyuPluginTelegramPlayerAction,
                completion: @escaping @Sendable (Result<AyuPluginTelegramPlayerState, AyuPluginTelegramBackendError>) -> Void) {
        self.state.update { $0.actions.append(action) }
        self.answer(self.state.value.player, completion)
    }
}

private enum CallbackEvent: Equatable {
    case sent(String, String, [AyuBridgeValue])
    case released(String, String)
}

/// A boxed TL object: a constructor id and `words` further 4-byte words.
private func tl(_ constructor: UInt32, words: Int = 0) -> Data {
    var data = Data((0..<4).map { UInt8(truncatingIfNeeded: constructor >> (8 * UInt32($0))) })
    data.append(Data(count: words * 4))
    return data
}
private func wire(_ data: Data) -> AyuBridgeValue { .object(["tl": .string(data.base64EncodedString())]) }
private func callback(_ id: String) -> AyuBridgeValue { .object(["$callback": .string(id)]) }

private let getConfig: UInt32 = 0xc4f9186b
private let sendMessageFunction: UInt32 = 0xfef48f62
private let updateNewMessage: UInt32 = 0x1f2b0afd
private let updatesContainer: UInt32 = 0x74ae4240

final class AyuPluginTelegramBridgeTests: XCTestCase {
    private let events = AyuTestBox<[CallbackEvent]>([])
    private let accounts = AyuTestBox<Set<Int64>>([0, 3])
    private let screen = AyuTestBox<AyuPluginScreenSnapshot?>(nil)
    private let legacyHooks = AyuTestBox<[AyuPluginSendHook]>([])
    private let container = FileManager.default.temporaryDirectory.appendingPathComponent("AyuTelegramBridgeTests-" + UUID().uuidString, isDirectory: true)

    private func makeBridge(_ backend: FakeTelegramBackend?, _ configure: (inout AyuPluginTelegramBridge.Limits) -> Void = { _ in }) -> AyuPluginTelegramBridge {
        var limits = AyuPluginTelegramBridge.Limits()
        limits.hookAnswerTimeout = 0.3
        limits.stateReadTimeout = 0.3
        configure(&limits)
        let bridge = AyuPluginTelegramBridge(limits: limits, containerRoots: [self.container.path])
        let accounts = self.accounts, screen = self.screen, legacyHooks = self.legacyHooks
        bridge.setEnvironment(.init(account: { index in
            accounts.value.contains(index) ? AyuPluginTelegramAccount(index: index, identity: UUID(), userID: 100 + index) : nil
        }, screen: { screen.value }, legacySendHooks: { legacyHooks.value }))
        bridge.bind(backend: backend)
        return bridge
    }

    private func context(_ owner: String) -> AyuBridgeAdapterContext {
        let events = self.events
        return AyuBridgeAdapterContext(pluginID: owner, resolveCallback: { reference in
            guard let id = reference["$callback"].string else { throw AyuBridgeFailure("invalid_arguments", "Expected a callback") }
            return AyuBridgeNativeCallback(id: id, sink: { arguments in events.update { $0.append(.sent(owner, id, arguments)) } },
                                           release: { events.update { $0.append(.released(owner, id)) } })
        }, resolve: { _ in throw AyuBridgeFailure.unsupported("snapshot") })
    }

    /// One provider call off the main thread, committed or rolled back as the host does.
    private func call(_ bridge: AyuPluginTelegramBridge, _ operation: String, _ arguments: [String: AyuBridgeValue],
                      owner: String = "alpha", commit: Bool = true) throws -> AyuBridgeValue {
        let context = self.context(owner)
        let outcome = AyuTestBox<Result<AyuBridgeValue, Error>?>(nil)
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            outcome.value = Result {
                let prepared = try bridge.prepareCall(pluginID: owner, operation: operation, arguments: arguments, context: context)
                guard case let .value(value) = prepared.result else { throw AyuBridgeFailure("invalid_state", "Unexpected result kind") }
                if commit { prepared.commit(value) } else { prepared.rollback() }
                return value
            }
            done.signal()
        }
        done.wait()
        return try XCTUnwrap(outcome.value).get()
    }

    private func code(_ body: @autoclosure () throws -> AyuBridgeValue, file: StaticString = #filePath, line: UInt = #line) -> String? {
        do { _ = try body(); XCTFail("Expected a bridge failure", file: file, line: line); return nil }
        catch { return (error as? AyuBridgeFailure)?.code }
    }

    private func request(_ bridge: AyuPluginTelegramBridge, _ id: String, owner: String = "alpha", account: Int64 = 0,
                         function: Data = tl(getConfig)) throws -> AyuBridgeValue {
        try self.call(bridge, "telegram.request", ["account": .integer(account), "request": wire(function), "flags": .integer(2),
                                                   "callback": callback(id)], owner: owner)
    }

    private func hookSet(_ bridge: AyuPluginTelegramBridge, owner: String, requests: [(UInt32, Int64)] = [], updates: [(UInt32, Int64)] = [],
                         containers: [(UInt32, Int64)] = []) throws {
        func list(_ items: [(UInt32, Int64)]) -> AyuBridgeValue { .array(items.map { .array([.integer(Int64($0.0)), .integer($0.1)]) }) }
        _ = try self.call(bridge, "telegram.hooks.set", ["requests": list(requests), "updates": list(updates), "containers": list(containers),
            "on_request": callback(owner + ":request"), "on_response": callback(owner + ":response"),
            "on_update": callback(owner + ":update"), "on_updates": callback(owner + ":updates")], owner: owner)
    }

    /// Answers hook callbacks from a script; a plugin without an entry never answers.
    private func script(_ bridge: AyuPluginTelegramBridge, _ answers: [String: AyuBridgeValue?]) -> AyuTestBox<[(String, [AyuBridgeValue])]> {
        let asked = AyuTestBox<[(String, [AyuBridgeValue])]>([])
        bridge.setAnswerInvoker { owner, callbackID, arguments, completion in
            asked.update { $0.append((callbackID, arguments)) }
            if let answer = answers[owner] { DispatchQueue.global().async { completion(answer) } }
        }
        return asked
    }

    private func await<Value: Sendable>(_ start: (@escaping @Sendable (Value) -> Void) -> Void,
                                        file: StaticString = #filePath, line: UInt = #line) throws -> Value {
        let box = AyuTestBox<Value?>(nil)
        let done = DispatchSemaphore(value: 0)
        start { box.value = $0; done.signal() }
        XCTAssertEqual(done.wait(timeout: .now() + 5), .success, "Completion was not called", file: file, line: line)
        return try XCTUnwrap(box.value, file: file, line: line)
    }

    private func strategy(_ value: Int64, _ field: String, _ object: AyuBridgeValue = .null) -> AyuBridgeValue {
        .object(["strategy": .integer(value), field: object])
    }

    // MARK: Declaration

    func testNothingIsDeclaredOrServedBeyondTheBoundBackend() throws {
        let unbound = self.makeBridge(nil)
        XCTAssertEqual(unbound.capabilities, [])
        XCTAssertEqual(self.code(try self.call(unbound, "telegram.connection", ["account": .integer(0)])), "UNSUPPORTED_API")

        let backend = FakeTelegramBackend()
        backend.state.update { $0.operations = ["telegram.connection", "telegram.request.cancel", "telegram.unknown", "menus.add"] }
        let bridge = self.makeBridge(backend)
        // Cancelling is meaningless without requests, and names outside the contract are never declared.
        XCTAssertEqual(bridge.capabilities, ["telegram.connection"])
        XCTAssertEqual(try self.call(bridge, "telegram.connection", ["account": .integer(3)]), .object([
            "time_ms": .integer(1_700_000_123_456), "time_difference": .integer(-2), "state": .integer(3), "datacenter_id": .integer(2)]))
        for operation in ["telegram.peer", "telegram.request", "telegram.request.cancel", "telegram.unknown"] {
            XCTAssertEqual(self.code(try self.call(bridge, operation, ["account": .integer(0)])), "UNSUPPORTED_API", operation)
        }
        bridge.bind(backend: nil)
        XCTAssertEqual(bridge.capabilities, [])
        XCTAssertEqual(self.code(try self.call(bridge, "telegram.connection", ["account": .integer(0)])), "UNSUPPORTED_API")

        let withoutEnvironment = AyuPluginTelegramBridge()
        withoutEnvironment.bind(backend: FakeTelegramBackend())
        XCTAssertEqual(withoutEnvironment.capabilities, [])
    }

    // MARK: Requests

    func testRequestArgumentsAreClosedBoundedAndAccountChecked() throws {
        let backend = FakeTelegramBackend()
        let bridge = self.makeBridge(backend) { $0.inboundTLBytes = 64 }
        let valid: [String: AyuBridgeValue] = ["account": .integer(0), "request": wire(tl(getConfig)), "flags": .integer(0), "callback": callback("c")]
        func with(_ key: String, _ value: AyuBridgeValue?) -> [String: AyuBridgeValue] {
            var arguments = valid; arguments[key] = value; return arguments
        }
        let malformed: [[String: AyuBridgeValue]] = [
            with("extra", .bool(true)), with("flags", nil), with("flags", .integer(-1)), with("flags", .integer(1 << 31)), with("flags", .number(1.5)),
            with("account", .integer(-1)), with("account", .string("0")), with("callback", .string("c")),
            with("request", .string(tl(getConfig).base64EncodedString())), with("request", .object(["tl": .string("@@@@")])),
            with("request", .object(["tl": .string(Data([1, 2, 3]).base64EncodedString())])),
            with("request", .object(["tl": .string(tl(getConfig).base64EncodedString()), "x": .null])),
            with("request", wire(tl(getConfig, words: 16))),
        ]
        for arguments in malformed {
            XCTAssertEqual(self.code(try self.call(bridge, "telegram.request", arguments)), "INVALID_ARGUMENTS", "\(arguments)")
        }
        XCTAssertEqual(self.code(try self.call(bridge, "telegram.request", with("account", .integer(9)))), "ACCOUNT_UNAVAILABLE")
        XCTAssertEqual(try self.call(bridge, "telegram.request", with("request", wire(tl(getConfig, words: 15)))), .integer(1))
        XCTAssertEqual(backend.state.value.sent.count, 1)
        // Every refusal handed the one-shot callback id back to the host.
        XCTAssertEqual(self.events.value.filter { $0 == .released("alpha", "c") }.count, malformed.count)

        backend.state.update { $0.startError = .invalidArguments("not a function of layer 233") }
        XCTAssertEqual(self.code(try self.request(bridge, "d")), "INVALID_ARGUMENTS")
        backend.state.update { $0.startError = .unsupported("upload.saveFilePart") }
        XCTAssertEqual(self.code(try self.request(bridge, "e")), "UNSUPPORTED_API")
        backend.state.update { $0.startError = nil }
        XCTAssertEqual(try self.request(bridge, "f"), .integer(4))
        XCTAssertEqual(backend.state.value.sent.count, 2)
        XCTAssertEqual(self.events.value.suffix(2), [.released("alpha", "d"), .released("alpha", "e")], "A refused start leaves no request behind")
    }

    func testRefusedFunctionsNeverReachTheBackend() throws {
        let backend = FakeTelegramBackend()
        let bridge = self.makeBridge(backend)
        let table = AyuPluginTelegramRefusedFunctions.table
        XCTAssertEqual(table.count, 45)
        for name in ["auth.logOut", "auth.sendCode", "account.deleteAccount", "account.resetAuthorization", "account.resetPassword",
                     "account.updatePasswordSettings", "invokeWithLayer", "invokeWithoutUpdates", "invokeAfterMsg", "initConnection"] {
            XCTAssertTrue(table.values.contains(name), name)
        }
        XCTAssertTrue(table.values.allSatisfy { $0.hasPrefix("auth.") || $0.hasPrefix("account.") || $0.hasPrefix("invoke") || $0 == "initConnection" })
        for (constructor, name) in table {
            do {
                _ = try self.request(bridge, "refused", function: tl(constructor, words: 2))
                XCTFail("\(name) was sent")
            } catch {
                let failure = try XCTUnwrap(error as? AyuBridgeFailure)
                XCTAssertEqual(failure.code, "UNSUPPORTED_API")
                XCTAssertTrue(failure.message.contains(name))
            }
        }
        XCTAssertTrue(backend.state.value.sent.isEmpty)
    }

    func testRequestQuotaIdentifiersAndExactlyOnceDelivery() throws {
        let backend = FakeTelegramBackend()
        let bridge = self.makeBridge(backend) { $0.callbackPayloadBytes = 4096 }
        var ids: [Int64] = []
        for index in 0..<64 { ids.append(try XCTUnwrap(self.request(bridge, "c\(index)").integer)) }
        XCTAssertEqual(ids, Array(1...64))
        XCTAssertEqual(self.code(try self.request(bridge, "over")), "RESOURCE_LIMIT")
        XCTAssertEqual(backend.state.value.sent.count, 64)
        XCTAssertEqual(backend.state.value.sent.first?.flags, 2)
        let other = try self.request(bridge, "beta", owner: "beta", account: 3)
        XCTAssertEqual(other, .integer(1), "The quota and the id space belong to one generation")
        self.events.value = []

        let sent = backend.state.value.sent
        let response = tl(0x330b4067, words: 3)
        sent[0].completion(.response(response))
        sent[0].completion(.rpcError(.init(code: 400, text: "LATE")))
        sent[1].completion(.rpcError(.init(code: 420, text: "FLOOD_WAIT_3")))
        sent[2].completion(.transportFailure("network"))
        sent[3].completion(.cancelledByHook)
        sent[4].completion(.response(tl(0x330b4067, words: 2048)))
        sent[5].completion(.response(Data([1, 2, 3])))
        func failure(_ code: Int32, _ text: String) -> [AyuBridgeValue] { [.null, wire(AyuPluginTelegramTL.error(code: code, text: text))] }
        XCTAssertEqual(self.events.value, [
            .sent("alpha", "c0", [wire(response), .null]), .released("alpha", "c0"),
            .sent("alpha", "c1", failure(420, "FLOOD_WAIT_3")), .released("alpha", "c1"),
            .sent("alpha", "c2", failure(-1, "network")), .released("alpha", "c2"),
            .sent("alpha", "c3", [.null, .null]), .released("alpha", "c3"),
            .sent("alpha", "c4", failure(500, "RESPONSE_TOO_LARGE")), .released("alpha", "c4"),
            .sent("alpha", "c5", failure(-1, "INVALID_RESPONSE")), .released("alpha", "c5"),
        ])
        // Six slots are free again; the lowest unused id after 64 is taken, never a live one.
        XCTAssertEqual(try self.request(bridge, "again"), .integer(65))
        XCTAssertEqual(AyuPluginTelegramTL.parseError(AyuPluginTelegramTL.error(code: -1, text: String(repeating: "é", count: 200))),
                       AyuPluginTelegramRPCError(code: -1, text: String(repeating: "é", count: 200)))
        XCTAssertNil(AyuPluginTelegramTL.parseError(AyuPluginTelegramTL.error(code: 1, text: "x") + Data(count: 4)))
    }

    func testOutboundTLLimitAndSynchronousCompletion() throws {
        let backend = FakeTelegramBackend()
        let bridge = self.makeBridge(backend) { $0.outboundTLBytes = 64; $0.callbackPayloadBytes = 1 << 20 }
        backend.state.update { $0.completesAtOnce = .response(tl(1, words: 16)) }
        XCTAssertEqual(try self.request(bridge, "big"), .integer(1))
        backend.state.update { $0.completesAtOnce = .response(tl(1, words: 15)) }
        XCTAssertEqual(try self.request(bridge, "fits"), .integer(2))
        XCTAssertEqual(self.events.value, [
            .sent("alpha", "big", [.null, wire(AyuPluginTelegramTL.error(code: 500, text: "RESPONSE_TOO_LARGE"))]), .released("alpha", "big"),
            .sent("alpha", "fits", [wire(tl(1, words: 15)), .null]), .released("alpha", "fits"),
        ])
        // The relay does not escape `/`, so a slash-heavy payload costs what any other does.
        let slashes = Data(repeating: 0xff, count: 3000)
        XCTAssertTrue(AyuPluginTelegramBridge.fits([wire(slashes), .null], payload: slashes.count, limit: 6000))
        XCTAssertTrue(AyuPluginTelegramBridge.fits([wire(slashes), .null], payload: slashes.count, limit: 4016))
        XCTAssertFalse(AyuPluginTelegramBridge.fits([wire(slashes), .null], payload: slashes.count, limit: 4015))
        XCTAssertTrue(AyuPluginTelegramBridge.fits([wire(Data(count: 3000)), .null], payload: 3000, limit: 6000))
    }

    func testCancelRollbackAndDetachSilenceCallbacks() throws {
        let backend = FakeTelegramBackend()
        let bridge = self.makeBridge(backend)
        for name in ["a", "b", "c", "d"] { _ = try self.request(bridge, name) }
        _ = try self.request(bridge, "other", owner: "beta")
        self.events.value = []
        func cancel(_ id: Int64, account: Int64 = 0, owner: String = "alpha") throws -> AyuBridgeValue {
            try self.call(bridge, "telegram.request.cancel", ["account": .integer(account), "request_id": .integer(id)], owner: owner)
        }
        XCTAssertEqual(try cancel(1), .null)
        XCTAssertEqual(try cancel(1), .null, "A finished id is not an error")
        XCTAssertEqual(try cancel(999), .null)
        XCTAssertEqual(try cancel(2, account: 3), .null, "Another account's id is unknown")
        XCTAssertEqual(try cancel(3, owner: "beta"), .null, "Another plugin's id is unknown")
        for bad: AyuBridgeValue in [.integer(0), .integer(1 << 31), .string("1")] {
            XCTAssertEqual(self.code(try self.call(bridge, "telegram.request.cancel", ["account": .integer(0), "request_id": bad])), "INVALID_ARGUMENTS")
        }
        XCTAssertEqual(self.code(try cancel(1, account: 9)), "ACCOUNT_UNAVAILABLE")
        XCTAssertEqual(backend.state.value.cancelled, [0])

        // A host-side failure after preparation cancels the started request.
        _ = try self.call(bridge, "telegram.request", ["account": .integer(0), "request": wire(tl(getConfig)), "flags": .integer(0),
                                                       "callback": callback("rolled")], commit: false)
        XCTAssertEqual(backend.state.value.cancelled, [0, 5])

        let sent = backend.state.value.sent
        sent[0].completion(.response(tl(1)))
        sent[5].completion(.response(tl(1)))
        sent[1].completion(.response(tl(1)))
        XCTAssertEqual(self.events.value, [.released("alpha", "a"), .released("alpha", "rolled"),
                                           .sent("alpha", "b", [wire(tl(1)), .null]), .released("alpha", "b")])

        self.events.value = []
        bridge.detach(pluginID: "alpha")
        XCTAssertEqual(Set(backend.state.value.cancelled), [0, 5, 2, 3])
        sent[2].completion(.response(tl(1)))
        sent[3].completion(.rpcError(.init(code: 500, text: "X")))
        XCTAssertEqual(self.events.value, [], "Nothing fires after the deactivate barrier")
        sent[4].completion(.cancelledByHook)
        XCTAssertEqual(self.events.value, [.sent("beta", "other", [.null, .null]), .released("beta", "other")])
        XCTAssertEqual(try self.request(bridge, "fresh"), .integer(1), "A new generation starts over")
    }

    // MARK: Hook sets

    func testHookSetIsValidatedReplacedAtomicallyAndPublished() throws {
        let backend = FakeTelegramBackend()
        let bridge = self.makeBridge(backend) { $0.hookConstructors = 4 }
        XCTAssertEqual(backend.state.value.filters, [AyuPluginTelegramHookFilter()])
        try self.hookSet(bridge, owner: "alpha", requests: [(getConfig, 1), (sendMessageFunction, -5)], updates: [(updateNewMessage, 0)])
        try self.hookSet(bridge, owner: "beta", containers: [(updatesContainer, Int64(Int32.max))])
        var expected = AyuPluginTelegramHookFilter()
        expected.requests = [getConfig, sendMessageFunction]; expected.updates = [updateNewMessage]
        XCTAssertEqual(backend.state.value.filters.dropFirst().first, expected)
        expected.containers = [updatesContainer]
        XCTAssertEqual(bridge.hookFilter, expected)

        func set(_ requests: AyuBridgeValue, extra: [String: AyuBridgeValue] = [:]) throws -> AyuBridgeValue {
            var arguments: [String: AyuBridgeValue] = ["requests": requests, "updates": .array([]), "containers": .array([]),
                "on_request": callback("1"), "on_response": callback("2"), "on_update": callback("3"), "on_updates": callback("4")]
            for (key, value) in extra { arguments[key] = value == .null ? nil : value }
            return try self.call(bridge, "telegram.hooks.set", arguments)
        }
        func pair(_ constructor: Int64, _ priority: Int64) -> AyuBridgeValue { .array([.integer(constructor), .integer(priority)]) }
        let invalid: [AyuBridgeValue] = [
            .array([pair(2, 0), pair(1, 0)]), .array([pair(1, 0), pair(1, 1)]), .array([pair(-1, 0)]), .array([pair(1 << 32, 0)]),
            .array([pair(1, 1 << 31)]), .array([.array([.integer(1)])]), .array([.integer(1)]), .object([:]),
        ]
        for requests in invalid { XCTAssertEqual(self.code(try set(requests)), "INVALID_ARGUMENTS", "\(requests)") }
        XCTAssertEqual(self.code(try set(.array([]), extra: ["menus": .array([])])), "INVALID_ARGUMENTS")
        XCTAssertEqual(self.code(try set(.array([]), extra: ["on_update": .null])), "INVALID_ARGUMENTS")
        XCTAssertEqual(self.code(try set(.array([]), extra: ["on_update": .string("3")])), "INVALID_ARGUMENTS")
        XCTAssertEqual(self.code(try set(.array((1...5).map { pair($0, 0) }))), "RESOURCE_LIMIT")
        XCTAssertEqual(bridge.hookFilter, expected, "A refused call leaves the previous set in place")

        XCTAssertEqual(try set(.array([pair(7, 0)])), .null)
        expected.requests = [7]; expected.updates = []
        XCTAssertEqual(bridge.hookFilter, expected)
        XCTAssertEqual(try set(.array([])), .null)
        expected.requests = []
        XCTAssertEqual(bridge.hookFilter, expected)
        bridge.detach(pluginID: "beta")
        XCTAssertEqual(backend.state.value.filters.last, AyuPluginTelegramHookFilter())
    }

    func testRequestHooksRunByPriorityThenPluginIDWithAndroidStrategies() throws {
        let backend = FakeTelegramBackend()
        let bridge = self.makeBridge(backend)
        try self.hookSet(bridge, owner: "b", requests: [(getConfig, 5)])
        try self.hookSet(bridge, owner: "a", requests: [(getConfig, 5)])
        try self.hookSet(bridge, owner: "c", requests: [(getConfig, 9), (sendMessageFunction, 0)])
        try self.hookSet(bridge, owner: "d", requests: [(sendMessageFunction, 0)])
        let original = tl(getConfig), replaced = tl(getConfig, words: 1), second = tl(getConfig, words: 2)
        func run(_ answers: [String: AyuBridgeValue?], function: Data = original) throws -> (AyuPluginTelegramHookDecision, [String], [[AyuBridgeValue]]) {
            let asked = self.script(bridge, answers)
            let decision: AyuPluginTelegramHookDecision = try self.await { bridge.interceptRequest(account: 3, function: function, completion: $0) }
            return (decision, asked.value.map { $0.0 }, asked.value.map { $0.1 })
        }

        var result = try run(["a": self.strategy(0, "request"), "b": self.strategy(2, "request", wire(second)), "c": self.strategy(2, "request", wire(replaced))])
        XCTAssertEqual(result.0, .proceed(second))
        XCTAssertEqual(result.1, ["c:request", "a:request", "b:request"])
        XCTAssertEqual(result.2, [[.integer(3), wire(original)], [.integer(3), wire(replaced)], [.integer(3), wire(replaced)]])

        result = try run(["a": self.strategy(1, "request"), "b": self.strategy(2, "request", wire(second)), "c": self.strategy(2, "request")])
        XCTAssertEqual(result.0, .cancel)
        XCTAssertEqual(result.1, ["c:request", "a:request"], "CANCEL calls no further plugin; MODIFY with null changes nothing")
        XCTAssertEqual(result.2.last, [.integer(3), wire(original)])

        result = try run(["a": self.strategy(2, "request", wire(second)), "c": self.strategy(3, "request", wire(replaced))])
        XCTAssertEqual(result.0, .proceed(replaced))
        XCTAssertEqual(result.1, ["c:request"], "MODIFY_FINAL calls no further plugin")

        // A refused function, a malformed value or an unknown shape is not applied; a failed callback is strategy 0.
        let logOut = tl(0x3e72ba19)
        result = try run(["c": self.strategy(2, "request", wire(logOut)), "a": nil, "b": .object(["strategy": .integer(2), "request": wire(second), "x": .null])])
        XCTAssertEqual(result.0, .proceed(original))
        XCTAssertEqual(result.1.count, 3)
        result = try run(["c": self.strategy(3, "request", .string("AAAA")), "a": self.strategy(1, "request")])
        XCTAssertEqual(result.0, .proceed(original), "A final result of the wrong type still ends the chain")
        result = try run(["c": self.strategy(7, "request", wire(second)), "a": .string("CANCEL"), "b": self.strategy(0, "request", wire(second))])
        XCTAssertEqual(result.0, .proceed(original))

        // Only plugins that listed the constructor are asked; an unlisted one costs nothing.
        result = try run(["c": self.strategy(0, "request"), "d": self.strategy(0, "request")], function: tl(sendMessageFunction))
        XCTAssertEqual(result.1, ["c:request", "d:request"])
        result = try run([:], function: tl(0x12345678))
        XCTAssertEqual(result.0, .proceed(tl(0x12345678)))
        XCTAssertTrue(result.1.isEmpty)
    }

    func testHookAnswerTimeoutAndDetachContinueWithStrategyZero() throws {
        let backend = FakeTelegramBackend()
        let bridge = self.makeBridge(backend)
        try self.hookSet(bridge, owner: "slow", updates: [(updateNewMessage, 9)])
        try self.hookSet(bridge, owner: "quick", updates: [(updateNewMessage, 1)])
        let update = tl(updateNewMessage, words: 3), replaced = tl(updateNewMessage, words: 4)
        var asked = self.script(bridge, ["quick": self.strategy(2, "update", wire(replaced))])
        let started = Date()
        let decision: AyuPluginTelegramHookDecision = try self.await { bridge.interceptUpdate(account: 0, update: update, completion: $0) }
        XCTAssertEqual(decision, .proceed(replaced))
        XCTAssertEqual(asked.value.map { $0.0 }, ["slow:update", "quick:update"])
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(started), 0.25)

        // A late answer is ignored, and a detached plugin stops delaying the chain at once.
        let late = AyuTestBox<[@Sendable (AyuBridgeValue?) -> Void]>([])
        asked = AyuTestBox([])
        let recorded = asked
        bridge.setAnswerInvoker { owner, callbackID, arguments, completion in
            recorded.update { $0.append((callbackID, arguments)) }
            if owner == "slow" { late.update { $0.append(completion) } } else { completion(.object(["strategy": .integer(0), "update": .null])) }
        }
        let done = DispatchSemaphore(value: 0)
        let outcome = AyuTestBox<AyuPluginTelegramHookDecision?>(nil)
        bridge.interceptUpdate(account: 0, update: update) { outcome.value = $0; done.signal() }
        while late.value.isEmpty { usleep(1000) }
        let detached = Date()
        bridge.detach(pluginID: "slow")
        XCTAssertEqual(done.wait(timeout: .now() + 5), .success)
        XCTAssertLessThan(Date().timeIntervalSince(detached), 0.2)
        XCTAssertEqual(outcome.value, .proceed(update))
        late.value[0](self.strategy(1, "update"))
        XCTAssertEqual(outcome.value, .proceed(update))
        XCTAssertEqual(bridge.hookFilter.updates, [updateNewMessage])

        let cancelled: AyuPluginTelegramHookDecision = try self.await { completion in
            _ = self.script(bridge, ["quick": self.strategy(1, "update")])
            bridge.interceptUpdate(account: 0, update: update, completion: completion)
        }
        XCTAssertEqual(cancelled, .cancel)
    }

    func testResponseAndContainerHooks() throws {
        let backend = FakeTelegramBackend()
        let bridge = self.makeBridge(backend) { $0.outboundTLBytes = 64 }
        try self.hookSet(bridge, owner: "alpha", requests: [(getConfig, 0)], containers: [(updatesContainer, 0)])
        try self.hookSet(bridge, owner: "beta", requests: [(getConfig, -1)])
        let response = tl(0x330b4067, words: 2), replaced = tl(0x330b4067, words: 3)
        let serverError = AyuPluginTelegramRPCError(code: 400, text: "BAD"), pluginError = AyuPluginTelegramRPCError(code: 403, text: "PLUGIN")
        func run(_ result: AyuPluginTelegramResponse, _ answers: [String: AyuBridgeValue?]) throws -> (AyuPluginTelegramResponse, [[AyuBridgeValue]]) {
            let asked = self.script(bridge, answers)
            let value: AyuPluginTelegramResponse = try self.await { bridge.interceptResponse(account: 0, constructor: getConfig, result: result, completion: $0) }
            return (value, asked.value.map { $0.1 })
        }
        func answer(_ strategy: Int64, response: Data? = nil, error: AyuPluginTelegramRPCError? = nil) -> AyuBridgeValue {
            .object(["strategy": .integer(strategy), "response": response.map(wire) ?? .null,
                     "error": error.map { wire(AyuPluginTelegramTL.error(code: $0.code, text: $0.text)) } ?? .null])
        }
        var result = try run(.init(response: response, error: nil), ["alpha": answer(2, response: replaced), "beta": answer(1, response: response)])
        XCTAssertEqual(result.0, .init(response: replaced, error: nil), "Strategy 1 is not a response strategy")
        XCTAssertEqual(result.1, [[.integer(0), .integer(Int64(getConfig)), wire(response), .null],
                                  [.integer(0), .integer(Int64(getConfig)), wire(replaced), .null]])
        result = try run(.init(response: nil, error: serverError), ["alpha": answer(3, error: pluginError), "beta": answer(2, response: response)])
        XCTAssertEqual(result.0, .init(response: nil, error: pluginError))
        XCTAssertEqual(result.1, [[.integer(0), .integer(Int64(getConfig)), .null, wire(AyuPluginTelegramTL.error(code: 400, text: "BAD"))]])
        result = try run(.init(response: nil, error: serverError), ["alpha": answer(2), "beta": .object(["strategy": .integer(2), "error": wire(response)])])
        XCTAssertEqual(result.0, .init(response: nil, error: serverError), "Null removes nothing and a non-error object is not an error")

        // An object above the outbound bound is not shown to plugins and passes unchanged.
        let large = tl(updatesContainer, words: 16)
        let asked = self.script(bridge, ["alpha": self.strategy(1, "updates")])
        let passed: AyuPluginTelegramHookDecision = try self.await { bridge.interceptUpdates(account: 0, container: large, completion: $0) }
        XCTAssertEqual(passed, .proceed(large))
        XCTAssertTrue(asked.value.isEmpty)
        let dropped: AyuPluginTelegramHookDecision = try self.await { bridge.interceptUpdates(account: 0, container: tl(updatesContainer, words: 5), completion: $0) }
        XCTAssertEqual(dropped, .cancel)
        XCTAssertEqual(asked.value.map { $0.0 }, ["alpha:updates"])
    }

    func testPendingHookEventsAreBounded() throws {
        let backend = FakeTelegramBackend()
        let bridge = self.makeBridge(backend) { $0.pendingHookEvents = 2; $0.hookAnswerTimeout = 0.5 }
        try self.hookSet(bridge, owner: "alpha", updates: [(updateNewMessage, 0)])
        let asked = self.script(bridge, [:])
        let finished = AyuTestBox<[AyuPluginTelegramHookDecision]>([])
        let done = DispatchSemaphore(value: 0)
        for _ in 0..<3 {
            bridge.interceptUpdate(account: 0, update: tl(updateNewMessage)) { decision in finished.update { $0.append(decision) }; done.signal() }
        }
        XCTAssertEqual(done.wait(timeout: .now() + 0.2), .success, "The event past the bound passes at once")
        XCTAssertEqual(finished.value, [.proceed(tl(updateNewMessage))])
        for _ in 0..<2 { XCTAssertEqual(done.wait(timeout: .now() + 5), .success) }
        XCTAssertEqual(asked.value.count, 2)
    }

    // MARK: Send-message hooks

    func testSendHookRegistrationQuotaOwnershipAndUnregister() throws {
        let backend = FakeTelegramBackend()
        let bridge = self.makeBridge(backend) { $0.sendHooksPerGeneration = 2 }
        func register(_ priority: AyuBridgeValue, owner: String = "alpha", commit: Bool = true) throws -> AyuBridgeValue {
            try self.call(bridge, "telegram.hooks.send_message", ["priority": priority, "callback": callback(owner + ":send")], owner: owner, commit: commit)
        }
        let token = try XCTUnwrap(register(.integer(5)).string)
        XCTAssertNotNil(UUID(uuidString: token))
        XCTAssertTrue(bridge.hasSendMessageHooks)
        XCTAssertEqual(self.code(try register(.integer(1 << 31))), "INVALID_ARGUMENTS")
        XCTAssertEqual(self.code(try self.call(bridge, "telegram.hooks.send_message", ["priority": .integer(0), "callback": callback("x"), "kind": .string("send_message")])), "INVALID_ARGUMENTS")
        _ = try register(.integer(1), commit: false)
        _ = try register(.integer(1))
        XCTAssertEqual(self.code(try register(.integer(2))), "RESOURCE_LIMIT")

        func unregister(_ token: String, owner: String) throws -> AyuBridgeValue? {
            let outcome = AyuTestBox<Result<AyuBridgeValue?, Error>?>(nil)
            let done = DispatchSemaphore(value: 0)
            DispatchQueue.global().async {
                outcome.value = Result {
                    guard let prepared = try bridge.prepareUnregister(pluginID: owner, arguments: ["token": .string(token)]) else { return nil }
                    prepared.commit(.null)
                    return .null
                }
                done.signal()
            }
            done.wait()
            return try XCTUnwrap(outcome.value).get()
        }
        XCTAssertNil(try unregister(UUID().uuidString, owner: "alpha"), "An unknown token belongs to the three-field hook's owner")
        XCTAssertThrowsError(try unregister(token, owner: "beta")) { XCTAssertEqual(($0 as? AyuBridgeFailure)?.code, "INVALID_HANDLE") }
        XCTAssertEqual(try unregister(token, owner: "alpha"), .null)
        XCTAssertNil(try unregister(token, owner: "alpha"))
        XCTAssertTrue(bridge.hasSendMessageHooks)
        bridge.detach(pluginID: "alpha")
        XCTAssertFalse(bridge.hasSendMessageHooks)
    }

    func testTypedAndThreeFieldSendHooksShareOneOrderedChain() throws {
        let backend = FakeTelegramBackend()
        let bridge = self.makeBridge(backend)
        func register(_ owner: String, _ priority: Int64) throws {
            _ = try self.call(bridge, "telegram.hooks.send_message", ["priority": .integer(priority), "callback": callback(owner + ":typed")], owner: owner)
        }
        try register("typed", 5)
        try register("both", 1)
        self.legacyHooks.value = [AyuPluginSendHook(pluginID: "legacy", callbackID: "legacy:three", priority: 7),
                                  AyuPluginSendHook(pluginID: "both", callbackID: "both:three", priority: 9),
                                  AyuPluginSendHook(pluginID: "legacy", callbackID: "legacy:second", priority: 6)]
        let entity = tl(0xbd610bc9, words: 2), reply = tl(0x9815cec8, words: 4)
        var message = AyuPluginTelegramHookedMessage(peer: -77)
        message.message = "hi"
        message.entities = [entity]
        message.replyTo = AyuPluginTelegramMessageReference(dialogID: -77, messageID: 31, message: reply)
        message.scheduleDate = 10
        message.searchLinks = false
        func run(_ answers: [String: AyuBridgeValue?]) throws -> (AyuPluginTelegramSendDecision, [(String, [AyuBridgeValue])]) {
            let asked = self.script(bridge, answers)
            let decision: AyuPluginTelegramSendDecision = try self.await { bridge.interceptSendMessage(account: 3, message: message, completion: $0) }
            return (decision, asked.value)
        }
        func typed(_ strategy: Int64, _ params: [String: AyuBridgeValue]) -> AyuBridgeValue { .object(["strategy": .integer(strategy), "params": .object(params)]) }
        let unchanged: [String: AyuBridgeValue] = ["peer": .integer(-77), "message": .string("hi"), "caption": .null, "entities": .array([wire(entity)]),
            "replyToMsg": .integer(31), "replyToTopMsg": .null, "notify": .bool(true), "scheduleDate": .integer(10), "scheduleRepeatPeriod": .integer(0),
            "searchLinks": .bool(false), "invert_media": .bool(false), "effect_id": .integer(0), "hasMediaSpoilers": .bool(false)]
        func changing(_ changes: [String: AyuBridgeValue]) -> [String: AyuBridgeValue] { unchanged.merging(changes) { $1 } }
        var expected = message
        expected.replyToMessageID = 31

        var result = try run(["legacy": typed(2, ["peer": .integer(-77), "message": .string("hi!")]),
                              "typed": typed(2, changing(["message": .string("hi!"), "notify": .bool(false)])), "both": typed(0, [:])])
        XCTAssertEqual(result.1.map { $0.0 }, ["legacy:three", "typed:typed", "both:typed"], "Priority 7, 5, 1; one call per plugin, typed when both exist")
        XCTAssertEqual(result.1[0].1, [.integer(3), .object(["peer": .integer(-77), "message": .string("hi")])])
        XCTAssertEqual(result.1[1].1, [.integer(3), .object(["peer": .integer(-77), "message": .string("hi!"), "entities": .array([wire(entity)]),
            "replyToMsg": wire(reply), "notify": .bool(true), "scheduleDate": .integer(10), "searchLinks": .bool(false)])])
        expected.message = "hi!"; expected.notify = false
        XCTAssertEqual(result.0, .send(expected, remapEntities: true), "Only the three-field hook changed the text, so its entities are stale")

        result = try run(["legacy": typed(0, [:]), "typed": typed(3, changing(["message": .string("bold"), "entities": .null, "replyToMsg": .integer(40)])),
                          "both": typed(1, [:])])
        XCTAssertEqual(result.1.count, 2, "MODIFY_FINAL ends the chain before the cancelling plugin")
        expected = message
        expected.message = "bold"; expected.entities = nil; expected.replyTo = nil; expected.replyToMessageID = 40
        XCTAssertEqual(result.0, .send(expected, remapEntities: false))

        result = try run(["legacy": typed(1, [:])])
        XCTAssertEqual(result.0, .cancel)
        XCTAssertEqual(result.1.count, 1)

        // Invalid results, and changes the backend does not apply, change nothing.
        expected = message
        expected.replyToMessageID = 31
        let refused: [[String: AyuBridgeValue]] = [
            changing(["peer": .integer(5)]), changing(["scheduleDate": .integer(99)]), changing(["replyToTopMsg": .integer(2)]),
            changing(["message": .null]), changing(["message": .string("")]), changing(["caption": .string("moved")]),
            changing(["entities": .array([.string("x")])]), changing(["path": .string("/a")]), changing(["notify": .integer(0)]),
            changing(["message": .string(String(repeating: "a", count: 65_537))]),
        ]
        for params in refused {
            result = try run(["legacy": typed(0, [:]), "typed": typed(2, params), "both": typed(0, [:])])
            XCTAssertEqual(result.0, .send(expected, remapEntities: false), "\(params.keys.sorted())")
            XCTAssertEqual(result.1.count, 3)
        }
        backend.state.update { $0.sendHookMutableFields = [] }
        result = try run(["legacy": typed(3, ["message": .string("changed")]), "typed": typed(1, [:])])
        XCTAssertEqual(result.0, .send(expected, remapEntities: false), "A final three-field result ends the chain even when it cannot be applied")
        XCTAssertEqual(result.1.count, 1)

        bridge.detach(pluginID: "typed"); bridge.detach(pluginID: "both")
        self.legacyHooks.value = []
        let asked = self.script(bridge, [:])
        let direct: AyuPluginTelegramSendDecision = try self.await { bridge.interceptSendMessage(account: 3, message: message, completion: $0) }
        XCTAssertEqual(direct, .send(expected, remapEntities: false))
        XCTAssertTrue(asked.value.isEmpty)
    }

    // MARK: Sending, editing and state

    func testSendMessageParametersAreClosedTypedAndNeverDropped() throws {
        try FileManager.default.createDirectory(at: self.container, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: self.container) }
        let backend = FakeTelegramBackend()
        let bridge = self.makeBridge(backend)
        let inside = self.container.appendingPathComponent("photo.jpg").path
        func send(_ params: [String: AyuBridgeValue], account: Int64 = 0) throws -> AyuBridgeValue {
            try self.call(bridge, "telegram.send_message", ["account": .integer(account), "params": .object(params)])
        }
        let reference: AyuBridgeValue = .object(["dialog_id": .integer(-5), "id": .integer(31), "message": wire(tl(0x9815cec8, words: 2))])
        XCTAssertEqual(try send(["peer": .integer(-5), "caption": .string("c"), "entities": .array([wire(tl(0xbd610bc9, words: 2))]), "replyToMsg": reference,
            "notify": .bool(false), "effect_id": .integer(Int64.max), "scheduleDate": .integer(17), "params": .object(["k": .string("v")]),
            "path": .string(inside), "attach": .object(["kind": .string("photo")]), "replyMarkup": wire(tl(0xa03e5b85, words: 1))]), .null)
        var expected = AyuPluginTelegramOutgoingMessage(peer: -5)
        expected.keys = ["attach", "caption", "effect_id", "entities", "notify", "params", "path", "peer", "replyMarkup", "replyToMsg", "scheduleDate"]
        expected.caption = "c"; expected.entities = [tl(0xbd610bc9, words: 2)]
        expected.replyTo = AyuPluginTelegramMessageReference(dialogID: -5, messageID: 31, message: tl(0x9815cec8, words: 2))
        expected.booleans = ["notify": false]; expected.integers = ["effect_id": Int64.max, "scheduleDate": 17]
        expected.parameters = ["k": "v"]; expected.path = AyuPluginTelegramBridge.canonicalPath(inside); expected.attachment = .photo
        expected.objects = ["replyMarkup": tl(0xa03e5b85, words: 1)]
        XCTAssertEqual(backend.state.value.outgoing, [expected])

        let text: [String: AyuBridgeValue] = ["peer": .integer(42), "message": .string("hi")]
        func with(_ key: String, _ value: AyuBridgeValue) -> [String: AyuBridgeValue] { text.merging([key: value]) { $1 } }
        let invalid: [[String: AyuBridgeValue]] = [
            ["message": .string("no peer")], with("peer", .integer(0)), with("peer", .string("42")), with("pollIndex", .integer(1)), with("replyQuote", .null),
            with("message", .integer(1)), with("message", .string(String(repeating: "a", count: 65_537))), with("notify", .integer(0)),
            with("scheduleDate", .integer(1 << 31)), with("ttl", .integer(-1)), with("payStars", .string("1")), with("entities", wire(tl(1))),
            with("replyToMsg", .integer(31)), with("replyToMsg", .object(["dialog_id": .integer(1), "id": .integer(1)])),
            with("params", .object(["k": .integer(1)])), with("document", .string("x")), with("attach", .object(["kind": .string("photo")])),
            with("path", .string(inside)), with("path", .string("relative.jpg")).merging(["attach": .object(["kind": .string("photo")])]) { $1 },
            with("path", .string("/etc/passwd")).merging(["attach": .object(["kind": .string("document")])]) { $1 },
            with("path", .string(self.container.path + "/../escape")).merging(["attach": .object(["kind": .string("document")])]) { $1 },
            with("path", .string(inside)).merging(["attach": .object(["kind": .string("sticker")])]) { $1 },
            with("path", .string(inside)).merging(["attach": .object(["kind": .string("photo"), "x": .null])]) { $1 },
        ]
        for params in invalid { XCTAssertEqual(self.code(try send(params)), "INVALID_ARGUMENTS", "\(params.keys.sorted())") }
        XCTAssertEqual(self.code(try self.call(bridge, "telegram.send_message", ["account": .integer(0), "params": .object(text), "parse_mode": .null])), "INVALID_ARGUMENTS")
        XCTAssertEqual(self.code(try send(text, account: 9)), "ACCOUNT_UNAVAILABLE")
        XCTAssertEqual(try send(with("path", .string(inside)).merging(["document": wire(tl(0x8fd4c4d8, words: 4))]) { $1 }), .null,
                       "Android sends a described document with its path and no attach")
        XCTAssertEqual(backend.state.value.outgoing.count, 2)

        // A listed key the backend cannot honour is refused by name, before the backend sees the message.
        backend.state.update { $0.sendMessageParameters = ["peer", "message"] }
        do { _ = try send(with("scheduleDate", .integer(5))); XCTFail("scheduleDate was dropped") } catch {
            let failure = try XCTUnwrap(error as? AyuBridgeFailure)
            XCTAssertEqual(failure.code, "UNSUPPORTED_API")
            XCTAssertTrue(failure.message.contains("scheduleDate"))
        }
        XCTAssertEqual(backend.state.value.outgoing.count, 2)
        XCTAssertEqual(try send(text), .null)
        backend.state.update { $0.failure = .unsupported("peer kind") }
        XCTAssertEqual(self.code(try send(text)), "UNSUPPORTED_API")
        backend.state.update { $0.failure = nil; $0.answers = false }
        XCTAssertEqual(self.code(try send(text)), "TIMEOUT", "An unanswered backend is a failure, not a null result")
    }

    func testEditMessageValidation() throws {
        try FileManager.default.createDirectory(at: self.container, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: self.container) }
        let backend = FakeTelegramBackend()
        let bridge = self.makeBridge(backend)
        let base: [String: AyuBridgeValue] = ["account": .integer(0), "dialog_id": .integer(-9), "message_id": .integer(4)]
        func edit(_ extra: [String: AyuBridgeValue]) throws -> AyuBridgeValue { try self.call(bridge, "telegram.edit_message", base.merging(extra) { $1 }) }
        let path = self.container.appendingPathComponent("a.mp4").path
        XCTAssertEqual(try edit(["text": .string(""), "entities": .array([]), "params": .object([:]),
                                 "attach": .object(["kind": .string("video"), "path": .string(path), "spoiler": .bool(true)])]), .null)
        var expected = AyuPluginTelegramMessageEdit(dialogID: -9, messageID: 4)
        expected.text = ""; expected.entities = []; expected.parameters = [:]
        expected.attachment = .init(kind: .video, path: AyuPluginTelegramBridge.canonicalPath(path), spoiler: true)
        XCTAssertEqual(backend.state.value.edits, [expected])
        let invalid: [[String: AyuBridgeValue]] = [
            [:], ["entities": .array([])], ["text": .integer(1)], ["text": .string("x"), "file_path": .string(path)], ["text": .string("x"), "message_id": .integer(1 << 31)],
            ["attach": .object(["kind": .string("video"), "path": .string(path)])], ["attach": .object(["kind": .string("gif"), "path": .string(path), "spoiler": .bool(false)])],
            ["attach": .object(["kind": .string("video"), "path": .string("/tmp/../etc/hosts"), "spoiler": .bool(false)])], ["text": .string("x"), "dialog_id": .integer(0)],
        ]
        for extra in invalid { XCTAssertEqual(self.code(try edit(extra)), "INVALID_ARGUMENTS", "\(extra.keys.sorted())") }
        backend.state.update { $0.failure = .invalidArguments("The message is not editable") }
        XCTAssertEqual(self.code(try edit(["text": .string("x")])), "INVALID_ARGUMENTS")
    }

    func testPeerMessagesFilesAndPlayer() throws {
        let backend = FakeTelegramBackend()
        let bridge = self.makeBridge(backend) { $0.outboundTLBytes = 64 }
        func peer(_ kind: String, _ id: AyuBridgeValue = .integer(42)) throws -> AyuBridgeValue {
            try self.call(bridge, "telegram.peer", ["account": .integer(0), "kind": .string(kind), "id": id])
        }
        XCTAssertEqual(try peer("user"), .null, "A peer that is not cached is null, not an empty object")
        backend.state.update { $0.peer = tl(0x31774388, words: 3) }
        for kind in ["user", "chat", "user_full", "chat_full"] { XCTAssertEqual(try peer(kind), wire(tl(0x31774388, words: 3))) }
        XCTAssertEqual(self.code(try peer("channel")), "INVALID_ARGUMENTS")
        XCTAssertEqual(self.code(try peer("user", .integer(0))), "INVALID_ARGUMENTS")
        XCTAssertEqual(self.code(try peer("user", .integer(-42))), "INVALID_ARGUMENTS")
        backend.state.update { $0.peer = tl(1, words: 16) }
        XCTAssertEqual(self.code(try peer("user")), "RESOURCE_LIMIT")
        backend.state.update { $0.peer = Data([1, 2]) }
        XCTAssertEqual(self.code(try peer("user")), "INVALID_STATE")

        func messages(_ ids: [AyuBridgeValue]) throws -> AyuBridgeValue {
            try self.call(bridge, "telegram.messages", ["account": .integer(3), "dialog_id": .integer(-7), "ids": .array(ids)])
        }
        backend.state.update { $0.messages = [tl(0x9815cec8, words: 1), nil] }
        XCTAssertEqual(try messages([.integer(5), .integer(6)]), .array([wire(tl(0x9815cec8, words: 1)), .null]))
        XCTAssertEqual(self.code(try messages([.integer(5)])), "INVALID_STATE", "A list of the wrong length is not passed on")
        XCTAssertEqual(self.code(try messages([])), "INVALID_ARGUMENTS")
        XCTAssertEqual(self.code(try messages(Array(repeating: .integer(1), count: 101))), "INVALID_ARGUMENTS")
        XCTAssertEqual(self.code(try messages([.integer(1 << 31)])), "INVALID_ARGUMENTS")

        let target = wire(tl(0x8fd4c4d8, words: 4))
        func files(_ operation: String, _ extra: [String: AyuBridgeValue]) throws -> AyuBridgeValue {
            try self.call(bridge, operation, ["account": AyuBridgeValue.integer(0), "target": target].merging(extra) { $1 })
        }
        XCTAssertEqual(try files("telegram.files.path", ["cache": .bool(false)]), .string("/var/mobile/cache/file"))
        XCTAssertEqual(self.code(try files("telegram.files.path", [:])), "INVALID_ARGUMENTS")
        XCTAssertEqual(self.code(try files("telegram.files.path", ["cache": .integer(0)])), "INVALID_ARGUMENTS")
        backend.state.update { $0.path = "relative" }
        XCTAssertEqual(self.code(try files("telegram.files.path", ["cache": .bool(true)])), "INVALID_STATE")
        XCTAssertEqual(try files("telegram.files.load", ["priority": .integer(3), "cache_type": .integer(1), "parent": target]), .null)
        XCTAssertEqual(try files("telegram.files.load", ["priority": .integer(0), "cache_type": .integer(0)]), .null)
        XCTAssertEqual(try files("telegram.files.load", ["cancel": .bool(true)]), .null)
        XCTAssertEqual(backend.state.value.loads, ["load 3 1 true", "load 0 0 false", "cancel"])
        for extra: [String: AyuBridgeValue] in [["priority": .integer(4), "cache_type": .integer(0)], ["priority": .integer(1)], ["cancel": .bool(false)],
                                                 ["cancel": .bool(true), "priority": .integer(1)], ["priority": .integer(1), "cache_type": .integer(0), "parent": .null]] {
            XCTAssertEqual(self.code(try files("telegram.files.load", extra)), "INVALID_ARGUMENTS", "\(extra.keys.sorted())")
        }

        func player(_ arguments: [String: AyuBridgeValue]) throws -> AyuBridgeValue { try self.call(bridge, "telegram.player", arguments) }
        XCTAssertEqual(try player(["action": .string("state")]), .object(["account": .integer(0), "paused": .bool(true)]))
        backend.state.update { $0.player = .init(accountIndex: 3, paused: false, message: tl(0x9815cec8, words: 2), progress: 0.5, positionMilliseconds: 1500, durationMilliseconds: 3000) }
        XCTAssertEqual(try player(["action": .string("seek"), "progress": .integer(1)]), .object(["account": .integer(3), "paused": .bool(false),
            "message": wire(tl(0x9815cec8, words: 2)), "progress": .number(0.5), "position_ms": .integer(1500), "duration_ms": .integer(3000)]))
        for name in ["pause", "resume", "next", "previous", "stop"] { _ = try player(["action": .string(name)]) }
        XCTAssertEqual(backend.state.value.actions, [.state, .seek(1), .pause, .resume, .next, .previous, .stop])
        for arguments: [String: AyuBridgeValue] in [[:], ["action": .string("rewind")], ["action": .string("seek")], ["action": .string("seek"), "progress": .number(1.5)],
                                                     ["action": .string("pause"), "progress": .number(0.1)], ["action": .integer(1)]] {
            XCTAssertEqual(self.code(try player(arguments)), "INVALID_ARGUMENTS", "\(arguments)")
        }
        backend.state.update { $0.player.progress = 2 }
        XCTAssertEqual(self.code(try player(["action": .string("state")])), "INVALID_STATE")
    }

    func testScreenComesFromTheSharedSnapshotAndNavigationIsValidated() throws {
        let backend = FakeTelegramBackend()
        let bridge = self.makeBridge(backend)
        func screen(_ arguments: [String: AyuBridgeValue] = [:]) throws -> AyuBridgeValue { try self.call(bridge, "telegram.screen", arguments) }
        XCTAssertEqual(try screen(), .null)
        XCTAssertEqual(self.code(try screen(["account": .integer(0)])), "INVALID_ARGUMENTS")
        self.screen.value = AyuPluginScreenSnapshot(identity: UUID(), accountIndex: 3, dialogID: -91, isGroup: true)
        XCTAssertEqual(self.code(try screen()), "UNSUPPORTED_API", "A snapshot without a screen kind is not guessed")
        self.screen.value = AyuPluginScreenSnapshot(identity: UUID(), accountIndex: 3, dialogID: -91, isGroup: true,
                                                    telegram: .init(kind: .chat, dialogID: -91, topicID: 12, chatMode: 1))
        XCTAssertEqual(try screen(), .object(["kind": .string("chat"), "account": .integer(3), "dialog_id": .integer(-91), "topic_id": .integer(12), "chat_mode": .integer(1)]))
        self.screen.value = AyuPluginScreenSnapshot(identity: UUID(), accountIndex: 3, dialogID: -91, telegram: .init(kind: .chat, dialogID: 5))
        XCTAssertEqual(self.code(try screen()), "INVALID_STATE", "The fragment adapter and the description must name one dialog")
        self.screen.value = AyuPluginScreenSnapshot(identity: UUID(), accountIndex: 0, telegram: .init(kind: .profile, dialogID: 42, topicID: 9))
        XCTAssertEqual(try screen(), .object(["kind": .string("profile"), "account": .integer(0), "dialog_id": .integer(42)]))
        self.screen.value = AyuPluginScreenSnapshot(identity: UUID(), accountIndex: 0, telegram: .init(kind: .dialogs))
        XCTAssertEqual(try screen(), .object(["kind": .string("dialogs"), "account": .integer(0)]))
        self.screen.value = AyuPluginScreenSnapshot(identity: UUID(), accountIndex: 8, telegram: .init(kind: .other))
        XCTAssertEqual(self.code(try screen()), "ACCOUNT_UNAVAILABLE")

        func open(_ arguments: [String: AyuBridgeValue]) throws -> AyuBridgeValue {
            try self.call(bridge, "telegram.navigation.open", ["account": AyuBridgeValue.integer(0)].merging(arguments) { $1 })
        }
        XCTAssertEqual(try open(["dialog_id": .integer(-5), "screen": .string("chat"), "message_id": .integer(7)]), .null)
        XCTAssertEqual(try open(["dialog_id": .integer(42), "screen": .string("profile")]), .null)
        XCTAssertEqual(try open(["username": .string("durov"), "type": .integer(0)]), .null)
        XCTAssertEqual(backend.state.value.targets, [.dialog(id: -5, screen: .chat, messageID: 7), .dialog(id: 42, screen: .profile, messageID: nil), .username("durov", type: 0)])
        for arguments: [String: AyuBridgeValue] in [
            ["dialog_id": .integer(42), "screen": .string("profile"), "message_id": .integer(7)], ["dialog_id": .integer(42), "screen": .string("settings")],
            ["dialog_id": .integer(0), "screen": .string("chat")], ["dialog_id": .integer(42)], ["username": .string(""), "type": .integer(0)],
            ["username": .string("a b"), "type": .integer(0)], ["username": .string("durov")], ["username": .string("durov"), "type": .integer(0), "dialog_id": .integer(1)],
        ] {
            XCTAssertEqual(self.code(try open(arguments)), "INVALID_ARGUMENTS", "\(arguments.keys.sorted())")
        }
        backend.state.update { $0.failure = .invalidArguments("Unknown peer") }
        XCTAssertEqual(self.code(try open(["dialog_id": .integer(42), "screen": .string("chat")])), "INVALID_ARGUMENTS")
        backend.state.update { $0.failure = .screenUnavailable }
        XCTAssertEqual(self.code(try open(["dialog_id": .integer(42), "screen": .string("chat")])), "SCREEN_UNAVAILABLE")
    }
}

/// The same plane through the real host and the composite provider: routing,
/// declaration in `runtime.capabilities`, callback delivery and the deactivate barrier.
@MainActor final class AyuPluginTelegramHostTests: XCTestCase {
    private func call(_ host: AyuPluginNativeHost, _ operation: String, _ arguments: [String: AyuBridgeValue] = [:], owner: String = "alpha") async throws -> AyuBridgeValue {
        let body: AyuBridgeValue = .object(["version": .integer(1), "id": .string("7"), "plugin_id": .string(operation == "runtime.capabilities" ? "$runtime" : owner),
                                            "operation": .string(operation), "arguments": .object(arguments)])
        let text = String(decoding: try JSONEncoder().encode(body), as: UTF8.self)
        let result = await Task.detached { host.dispatch(text, owner: owner) }.value
        return try JSONDecoder().decode(AyuBridgeValue.self, from: Data(result.utf8))
    }

    private func eventually(_ condition: @escaping @Sendable () -> Bool) async throws {
        for _ in 0..<400 where !condition() { try await Task.sleep(nanoseconds: 5_000_000) }
        XCTAssertTrue(condition())
    }

    func testCompositeProviderDeclaresRoutesDeliversAndCleansUp() async throws {
        let application = AyuPluginApplicationBridge(clipboardWriter: { _ in })
        application.updateAccounts([AyuPluginAccountSnapshot(index: 0, identity: UUID(), userID: 777, firstName: "Ann")], selected: 0)
        let identity = UUID()
        application.bindScreen(screen: { AyuPluginScreenSnapshot(identity: identity, accountIndex: 0, dialogID: 42, telegram: .init(kind: .chat, dialogID: 42)) },
                               presenter: { nil })
        let bridge = AyuPluginTelegramBridge()
        let provider = AyuPluginMenuHostProvider(application: application, menus: AyuPluginMenuBridge(), telegram: bridge)
        let delivered = AyuTestBox<[(String, [AyuBridgeValue])]>([])
        var limits = AyuPluginBridgeLimits()
        limits.callbacksPerPlugin = 8
        let host = AyuPluginNativeHost(defaults: UserDefaults(suiteName: "AyuPluginTelegramHostTests." + UUID().uuidString)!, provider: provider,
                                       limits: limits, trustedOwner: { "alpha" }, callback: { _, id, arguments in delivered.update { $0.append((id, arguments)) } })
        func operations() async throws -> [String] {
            try await self.call(host, "runtime.capabilities")["result"]["operations"].array?.compactMap(\.string).filter { $0.hasPrefix("telegram.") } ?? []
        }
        let authorized = try await self.call(host, "plugin.authorize")
        XCTAssertEqual(authorized["result"], .bool(true))
        let active = try await self.call(host, "plugin.activate", ["generation": .string("g")])
        XCTAssertEqual(active["result"], .null)

        var declared = try await operations()
        XCTAssertEqual(declared, [], "Without a backend the host declares no Telegram operation")
        let refused = try await self.call(host, "telegram.connection", ["account": .integer(0)])
        XCTAssertEqual(refused["error"]["code"], .string("UNSUPPORTED_API"))

        let backend = FakeTelegramBackend()
        bridge.bind(backend: backend)
        declared = try await operations()
        XCTAssertEqual(Set(declared), AyuPluginTelegramBridge.Operation.served)
        let connection = try await self.call(host, "telegram.connection", ["account": .integer(0)])
        XCTAssertEqual(connection["result"]["state"], .integer(3))
        let unknownAccount = try await self.call(host, "telegram.connection", ["account": .integer(4)])
        XCTAssertEqual(unknownAccount["error"]["code"], .string("ACCOUNT_UNAVAILABLE"))
        let screen = try await self.call(host, "telegram.screen")
        XCTAssertEqual(screen["result"], .object(["kind": .string("chat"), "account": .integer(0), "dialog_id": .integer(42)]))
        let undeclared = try await self.call(host, "telegram.stickers")
        XCTAssertEqual(undeclared["error"]["code"], .string("UNSUPPORTED_API"))

        // More one-shot callbacks than the host's registry holds: each id is released after its delivery or refusal.
        for index in 0..<20 {
            let function = index % 2 == 0 ? tl(getConfig) : tl(0x3e72ba19)
            let response = try await self.call(host, "telegram.request", ["account": .integer(0), "request": wire(function), "flags": .integer(0),
                                                                          "callback": callback("g:\(index)")])
            if index % 2 == 0 {
                let sent = backend.state.value.sent
                XCTAssertEqual(response["result"], .integer(Int64(sent.count)), "\(response)")
                sent[sent.count - 1].completion(.response(tl(0x330b4067, words: index == 0 ? 0 : 1)))
                try await self.eventually { delivered.value.count == sent.count }
            } else {
                XCTAssertEqual(response["error"]["code"], .string("UNSUPPORTED_API"))
            }
        }
        XCTAssertEqual(delivered.value.map { $0.0 }, stride(from: 0, to: 20, by: 2).map { "g:\($0)" })
        XCTAssertEqual(delivered.value.first?.1, [wire(tl(0x330b4067)), .null])

        // Both send-hook kinds register side by side and `hooks.unregister` removes either.
        let typed = try await self.call(host, "telegram.hooks.send_message", ["priority": .integer(1), "callback": callback("g:typed")])
        let legacy = try await self.call(host, "hooks.register", ["kind": .string("send_message"), "priority": .integer(2), "callback": callback("g:legacy")])
        let typedToken = try XCTUnwrap(typed["result"].string), legacyToken = try XCTUnwrap(legacy["result"].string)
        let asked = AyuTestBox<[String]>([])
        bridge.setAnswerInvoker { _, callbackID, _, completion in
            asked.update { $0.append(callbackID) }
            completion(.object(["strategy": .integer(0), "params": .null]))
        }
        var message = AyuPluginTelegramHookedMessage(peer: 42)
        message.message = "hi"
        let first: AyuPluginTelegramSendDecision = await withCheckedContinuation { continuation in
            bridge.interceptSendMessage(account: 0, message: message) { continuation.resume(returning: $0) }
        }
        XCTAssertEqual(first, .send(message, remapEntities: false))
        XCTAssertEqual(asked.value, ["g:typed"], "One call per plugin: the typed hook stands for both registrations")
        let removedTyped = try await self.call(host, "hooks.unregister", ["token": .string(typedToken)])
        XCTAssertEqual(removedTyped["result"], .null)
        _ = await withCheckedContinuation { (continuation: CheckedContinuation<AyuPluginTelegramSendDecision, Never>) in
            bridge.interceptSendMessage(account: 0, message: message) { continuation.resume(returning: $0) }
        }
        XCTAssertEqual(asked.value, ["g:typed", "g:legacy"])
        let removedLegacy = try await self.call(host, "hooks.unregister", ["token": .string(legacyToken)])
        XCTAssertEqual(removedLegacy["result"], .null)
        XCTAssertFalse(bridge.hasSendMessageHooks)

        // A request answered while it is being started is still delivered after the dispatch that registered it.
        let seenDuringDispatch = AyuTestBox<Int?>(nil)
        backend.state.update {
            $0.completesAtOnce = .rpcError(.init(code: 400, text: "AT_ONCE"))
            $0.duringStart = { usleep(50_000); seenDuringDispatch.value = delivered.value.count }
        }
        let immediate = try await self.call(host, "telegram.request", ["account": .integer(0), "request": wire(tl(getConfig)), "flags": .integer(0),
                                                                       "callback": callback("g:immediate")])
        XCTAssertEqual(immediate["result"], .integer(11))
        XCTAssertEqual(seenDuringDispatch.value, 10)
        try await self.eventually { delivered.value.count == 11 }
        XCTAssertEqual(delivered.value.last?.1, [.null, wire(AyuPluginTelegramTL.error(code: 400, text: "AT_ONCE"))])
        backend.state.update { $0.completesAtOnce = nil; $0.duringStart = nil }

        // Deactivate: in-flight requests are cancelled and their callbacks never fire.
        let pending = try await self.call(host, "telegram.request", ["account": .integer(0), "request": wire(tl(getConfig)), "flags": .integer(0),
                                                                     "callback": callback("g:pending")])
        XCTAssertEqual(pending["result"], .integer(12))
        let set = try await self.call(host, "telegram.hooks.set", ["requests": .array([.array([.integer(Int64(getConfig)), .integer(0)])]),
            "updates": .array([]), "containers": .array([]), "on_request": callback("g:a"), "on_response": callback("g:b"),
            "on_update": callback("g:c"), "on_updates": callback("g:d")])
        XCTAssertEqual(set["result"], .null)
        XCTAssertEqual(bridge.hookFilter.requests, [getConfig])
        let deactivated = try await self.call(host, "plugin.deactivate", ["generation": .string("g")])
        XCTAssertEqual(deactivated["result"], .null)
        XCTAssertEqual(backend.state.value.cancelled, [10, 11], "The answered request's handle was cancelled harmlessly; the pending one by the barrier")
        XCTAssertTrue(bridge.hookFilter.isEmpty)
        backend.state.value.sent[11].completion(.response(tl(1)))
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(delivered.value.count, 11)
    }
}
