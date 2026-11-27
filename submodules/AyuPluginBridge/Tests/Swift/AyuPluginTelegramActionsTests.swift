import Foundation
@preconcurrency import XCTest
@testable import AyuPluginBridge

/// `telegram.action.*` on the bridge side against a fake backend: what is declared, how the
/// arguments are validated, and what reaches the backend.
private final class ActionBackend: AyuPluginTelegramBackend, @unchecked Sendable {
    let listed = AyuTestBox<Set<String>>(AyuPluginTelegramAction.operations)
    let performed = AyuTestBox<[(Int64, AyuPluginTelegramAction)]>([])
    let failure = AyuTestBox<AyuPluginTelegramBackendError?>(nil)
    let answers = AyuTestBox(true)

    var operations: Set<String> { self.listed.value }
    var sendMessageParameters: Set<String> { [] }
    var sendHookMutableFields: Set<String> { [] }

    func sendRequest(account: AyuPluginTelegramAccount, function: Data, flags: Int32,
                     completion: @escaping @Sendable (AyuPluginTelegramRequestResult) -> Void) throws -> AyuPluginTelegramCancellation {
        throw AyuPluginTelegramBackendError.unsupported("telegram.request")
    }
    func connectionState(account: AyuPluginTelegramAccount,
                         completion: @escaping @Sendable (Result<AyuPluginTelegramConnectionState, AyuPluginTelegramBackendError>) -> Void) {
        completion(.failure(.unsupported("telegram.connection")))
    }
    func hookFilterDidChange(_ filter: AyuPluginTelegramHookFilter) {}
    func sendMessage(account: AyuPluginTelegramAccount, message: AyuPluginTelegramOutgoingMessage,
                     completion: @escaping @Sendable (Result<Void, AyuPluginTelegramBackendError>) -> Void) { completion(.failure(.unsupported("send"))) }
    func editMessage(account: AyuPluginTelegramAccount, edit: AyuPluginTelegramMessageEdit,
                     completion: @escaping @Sendable (Result<Void, AyuPluginTelegramBackendError>) -> Void) { completion(.failure(.unsupported("edit"))) }
    func peer(account: AyuPluginTelegramAccount, kind: AyuPluginTelegramPeerKind, id: Int64,
              completion: @escaping @Sendable (Result<Data?, AyuPluginTelegramBackendError>) -> Void) { completion(.failure(.unsupported("peer"))) }
    func messages(account: AyuPluginTelegramAccount, dialogID: Int64, ids: [Int32],
                  completion: @escaping @Sendable (Result<[Data?], AyuPluginTelegramBackendError>) -> Void) { completion(.failure(.unsupported("messages"))) }
    func navigate(account: AyuPluginTelegramAccount, target: AyuPluginTelegramNavigationTarget,
                  completion: @escaping @Sendable (Result<Void, AyuPluginTelegramBackendError>) -> Void) { completion(.failure(.unsupported("navigate"))) }
    func filePath(account: AyuPluginTelegramAccount, target: Data, cache: Bool,
                  completion: @escaping @Sendable (Result<String, AyuPluginTelegramBackendError>) -> Void) { completion(.failure(.unsupported("path"))) }
    func loadFile(account: AyuPluginTelegramAccount, target: Data, parent: Data?, priority: Int32, cacheType: Int32,
                  completion: @escaping @Sendable (Result<Void, AyuPluginTelegramBackendError>) -> Void) { completion(.failure(.unsupported("load"))) }
    func cancelFileLoad(account: AyuPluginTelegramAccount, target: Data,
                        completion: @escaping @Sendable (Result<Void, AyuPluginTelegramBackendError>) -> Void) { completion(.failure(.unsupported("cancel"))) }
    func player(action: AyuPluginTelegramPlayerAction,
                completion: @escaping @Sendable (Result<AyuPluginTelegramPlayerState, AyuPluginTelegramBackendError>) -> Void) {
        completion(.failure(.unsupported("player")))
    }
    func perform(account: AyuPluginTelegramAccount, action: AyuPluginTelegramAction,
                 completion: @escaping @Sendable (Result<Void, AyuPluginTelegramBackendError>) -> Void) {
        self.performed.update { $0.append((account.index, action)) }
        guard self.answers.value else { return }
        completion(self.failure.value.map { .failure($0) } ?? .success(()))
    }
}

/// A backend that predates the actions: it lists them by mistake and inherits the default `perform`.
private final class LegacyBackend: AyuPluginTelegramBackend, @unchecked Sendable {
    var operations: Set<String> { AyuPluginTelegramAction.operations }
    var sendMessageParameters: Set<String> { [] }
    var sendHookMutableFields: Set<String> { [] }
    func sendRequest(account: AyuPluginTelegramAccount, function: Data, flags: Int32,
                     completion: @escaping @Sendable (AyuPluginTelegramRequestResult) -> Void) throws -> AyuPluginTelegramCancellation {
        throw AyuPluginTelegramBackendError.unsupported("telegram.request")
    }
    func connectionState(account: AyuPluginTelegramAccount,
                         completion: @escaping @Sendable (Result<AyuPluginTelegramConnectionState, AyuPluginTelegramBackendError>) -> Void) {}
    func hookFilterDidChange(_ filter: AyuPluginTelegramHookFilter) {}
    func sendMessage(account: AyuPluginTelegramAccount, message: AyuPluginTelegramOutgoingMessage,
                     completion: @escaping @Sendable (Result<Void, AyuPluginTelegramBackendError>) -> Void) {}
    func editMessage(account: AyuPluginTelegramAccount, edit: AyuPluginTelegramMessageEdit,
                     completion: @escaping @Sendable (Result<Void, AyuPluginTelegramBackendError>) -> Void) {}
    func peer(account: AyuPluginTelegramAccount, kind: AyuPluginTelegramPeerKind, id: Int64,
              completion: @escaping @Sendable (Result<Data?, AyuPluginTelegramBackendError>) -> Void) {}
    func messages(account: AyuPluginTelegramAccount, dialogID: Int64, ids: [Int32],
                  completion: @escaping @Sendable (Result<[Data?], AyuPluginTelegramBackendError>) -> Void) {}
    func navigate(account: AyuPluginTelegramAccount, target: AyuPluginTelegramNavigationTarget,
                  completion: @escaping @Sendable (Result<Void, AyuPluginTelegramBackendError>) -> Void) {}
    func filePath(account: AyuPluginTelegramAccount, target: Data, cache: Bool,
                  completion: @escaping @Sendable (Result<String, AyuPluginTelegramBackendError>) -> Void) {}
    func loadFile(account: AyuPluginTelegramAccount, target: Data, parent: Data?, priority: Int32, cacheType: Int32,
                  completion: @escaping @Sendable (Result<Void, AyuPluginTelegramBackendError>) -> Void) {}
    func cancelFileLoad(account: AyuPluginTelegramAccount, target: Data,
                        completion: @escaping @Sendable (Result<Void, AyuPluginTelegramBackendError>) -> Void) {}
    func player(action: AyuPluginTelegramPlayerAction,
                completion: @escaping @Sendable (Result<AyuPluginTelegramPlayerState, AyuPluginTelegramBackendError>) -> Void) {}
}

private func boxed(_ constructor: UInt32, words: Int = 1) -> Data {
    var data = Data()
    for shift in stride(from: 0, to: 32, by: 8) { data.append(UInt8(truncatingIfNeeded: constructor >> UInt32(shift))) }
    data.append(Data(count: words * 4))
    return data
}
private func wire(_ data: Data) -> AyuBridgeValue { .object(["tl": .string(data.base64EncodedString())]) }

final class AyuPluginTelegramActionsTests: XCTestCase {
    private func makeBridge(_ backend: AyuPluginTelegramBackend) -> AyuPluginTelegramBridge {
        var limits = AyuPluginTelegramBridge.Limits()
        limits.stateReadTimeout = 0.3
        let bridge = AyuPluginTelegramBridge(limits: limits, containerRoots: [NSTemporaryDirectory()])
        bridge.setEnvironment(.init(account: { index in
            index == 0 || index == 3 ? AyuPluginTelegramAccount(index: index, identity: UUID(), userID: 100 + index) : nil
        }, screen: { nil }, legacySendHooks: { [] }))
        bridge.bind(backend: backend)
        return bridge
    }

    private func call(_ bridge: AyuPluginTelegramBridge, _ operation: String, _ arguments: [String: AyuBridgeValue]) throws -> AyuBridgeValue {
        let context = AyuBridgeAdapterContext(pluginID: "alpha", resolveCallback: { _ in throw AyuBridgeFailure.unsupported("callback") },
                                              resolve: { _ in throw AyuBridgeFailure.unsupported("snapshot") })
        let outcome = AyuTestBox<Result<AyuBridgeValue, Error>?>(nil)
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            outcome.value = Result {
                let prepared = try bridge.prepareCall(pluginID: "alpha", operation: operation, arguments: arguments, context: context)
                guard case let .value(value) = prepared.result else { throw AyuBridgeFailure("invalid_state", "Unexpected result kind") }
                prepared.commit(value)
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

    private func ids(_ values: [Int64]) -> AyuBridgeValue { .array(values.map { .integer($0) }) }

    func testOnlyListedActionsAreDeclaredAndServed() throws {
        let backend = ActionBackend()
        backend.listed.value = [AyuPluginTelegramAction.deleteMessagesOperation, "telegram.action.unknown"]
        let bridge = self.makeBridge(backend)
        XCTAssertEqual(bridge.capabilities, ["telegram.action.delete_messages"], "An action the bridge does not know is never declared")
        let read: [String: AyuBridgeValue] = ["account": .integer(0), "dialog_id": .integer(5), "max_id": .integer(9)]
        XCTAssertEqual(self.code(try self.call(bridge, "telegram.action.read_dialog", read)), "UNSUPPORTED_API")
        XCTAssertEqual(self.code(try self.call(bridge, "telegram.action.unknown", ["account": .integer(0)])), "UNSUPPORTED_API")
        XCTAssertTrue(backend.performed.value.isEmpty)
        backend.listed.value = AyuPluginTelegramAction.operations
        XCTAssertEqual(bridge.capabilities, AyuPluginTelegramAction.operations.sorted())
        XCTAssertEqual(try self.call(bridge, "telegram.action.read_dialog", read), .null)
        XCTAssertEqual(backend.performed.value.map(\.1), [.readDialog(dialogID: 5, maxID: 9)])
    }

    func testABackendWithoutPerformRefuses() throws {
        let bridge = self.makeBridge(LegacyBackend())
        XCTAssertEqual(self.code(try self.call(bridge, "telegram.action.load_full_peer",
                                               ["account": .integer(0), "kind": .string("user"), "id": .integer(7)])), "UNSUPPORTED_API")
    }

    func testDeleteMessagesArguments() throws {
        let backend = ActionBackend()
        let bridge = self.makeBridge(backend)
        let operation = "telegram.action.delete_messages"
        func arguments(_ change: (inout [String: AyuBridgeValue]) -> Void = { _ in }) -> [String: AyuBridgeValue] {
            var result: [String: AyuBridgeValue] = ["account": .integer(3), "dialog_id": .integer(-1_000_000_000_123), "ids": self.ids([7, 9]), "revoke": .bool(true)]
            change(&result)
            return result
        }
        XCTAssertEqual(try self.call(bridge, operation, arguments()), .null)
        XCTAssertEqual(backend.performed.value.map(\.0), [3])
        XCTAssertEqual(backend.performed.value.map(\.1), [.deleteMessages(dialogID: -1_000_000_000_123, ids: [7, 9], revoke: true)])
        backend.performed.value = []
        let invalid: [(inout [String: AyuBridgeValue]) -> Void] = [
            { $0["revoke"] = nil }, { $0["revoke"] = .integer(1) }, { $0["topic"] = .integer(1) }, { $0["dialog_id"] = .integer(0) },
            { $0["ids"] = self.ids([]) }, { $0["ids"] = self.ids(Array(1...101)) }, { $0["ids"] = self.ids([0]) }, { $0["ids"] = self.ids([-4]) },
            { $0["ids"] = self.ids([4, 4]) }, { $0["ids"] = .array([.string("4")]) }, { $0["ids"] = self.ids([Int64(Int32.max) + 1]) },
        ]
        for change in invalid { XCTAssertEqual(self.code(try self.call(bridge, operation, arguments(change))), "INVALID_ARGUMENTS") }
        XCTAssertEqual(self.code(try self.call(bridge, operation, arguments { $0["account"] = .integer(1) })), "ACCOUNT_UNAVAILABLE")
        XCTAssertTrue(backend.performed.value.isEmpty, "A refused call never reaches the backend")
        XCTAssertEqual(try self.call(bridge, operation, arguments { $0["ids"] = self.ids(Array(1...100)); $0["revoke"] = .bool(false) }), .null)
        XCTAssertEqual(backend.performed.value.map(\.1), [.deleteMessages(dialogID: -1_000_000_000_123, ids: Array(1...100), revoke: false)])
    }

    func testReadProcessStoreAndLoadArguments() throws {
        let backend = ActionBackend()
        let bridge = self.makeBridge(backend)
        let updates = boxed(0x74ae4240, words: 4), user = boxed(0x31774388, words: 3), chat = boxed(0x41cbf256, words: 5)
        XCTAssertEqual(try self.call(bridge, "telegram.action.process_updates", ["account": .integer(0), "updates": wire(updates)]), .null)
        XCTAssertEqual(try self.call(bridge, "telegram.action.store_peers", ["account": .integer(0), "users": .array([wire(user)]), "chats": .array([wire(chat)])]), .null)
        XCTAssertEqual(try self.call(bridge, "telegram.action.store_peers", ["account": .integer(0), "users": .array([]), "chats": .array([wire(chat)])]), .null)
        XCTAssertEqual(try self.call(bridge, "telegram.action.load_full_peer", ["account": .integer(0), "kind": .string("chat"), "id": .integer(44)]), .null)
        XCTAssertEqual(backend.performed.value.map(\.1), [.processUpdates(updates), .storePeers(users: [user], chats: [chat]),
                                                          .storePeers(users: [], chats: [chat]), .loadFullPeer(kind: .chat, id: 44)])
        backend.performed.value = []
        let refused: [(String, [String: AyuBridgeValue])] = [
            ("telegram.action.read_dialog", ["account": .integer(0), "dialog_id": .integer(5), "max_id": .integer(0)]),
            ("telegram.action.read_dialog", ["account": .integer(0), "dialog_id": .integer(5)]),
            ("telegram.action.process_updates", ["account": .integer(0), "updates": .string("AAAA")]),
            ("telegram.action.process_updates", ["account": .integer(0), "updates": .object(["tl": .string("AAA=")])]),
            ("telegram.action.process_updates", ["account": .integer(0), "updates": wire(updates), "from_queue": .bool(false)]),
            ("telegram.action.store_peers", ["account": .integer(0), "users": .array([]), "chats": .array([])]),
            ("telegram.action.store_peers", ["account": .integer(0), "users": .array([wire(user)])]),
            ("telegram.action.store_peers", ["account": .integer(0), "users": .array(Array(repeating: wire(user), count: 201)), "chats": .array([])]),
            ("telegram.action.store_peers", ["account": .integer(0), "users": .array([.integer(1)]), "chats": .array([])]),
            ("telegram.action.load_full_peer", ["account": .integer(0), "kind": .string("channel"), "id": .integer(44)]),
            ("telegram.action.load_full_peer", ["account": .integer(0), "kind": .string("user"), "id": .integer(-44)]),
        ]
        for (operation, arguments) in refused { XCTAssertEqual(self.code(try self.call(bridge, operation, arguments)), "INVALID_ARGUMENTS", operation) }
        XCTAssertTrue(backend.performed.value.isEmpty)
    }

    func testBackendFailuresAndSilenceAreReported() throws {
        let backend = ActionBackend()
        let bridge = self.makeBridge(backend)
        let arguments: [String: AyuBridgeValue] = ["account": .integer(0), "dialog_id": .integer(5), "max_id": .integer(9)]
        backend.failure.value = .invalidArguments("max_id is not a stored message of the dialog")
        XCTAssertEqual(self.code(try self.call(bridge, "telegram.action.read_dialog", arguments)), "INVALID_ARGUMENTS")
        backend.failure.value = .unsupported("telegram.action.read_dialog")
        XCTAssertEqual(self.code(try self.call(bridge, "telegram.action.read_dialog", arguments)), "UNSUPPORTED_API")
        backend.failure.value = nil
        backend.answers.value = false
        XCTAssertEqual(self.code(try self.call(bridge, "telegram.action.read_dialog", arguments)), "TIMEOUT")
    }
}
