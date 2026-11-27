import Foundation

/// The state changes of `Python/protocol-telegram.md` ("State changes"): a closed set, one
/// operation each, so a backend lists exactly the ones it carries out. There is no generic
/// "call a controller method".
public enum AyuPluginTelegramAction: Sendable, Equatable {
    public enum FullPeerKind: String, Sendable, CaseIterable { case user, chat }

    /// `revoke` is Android's `forAll`.
    case deleteMessages(dialogID: Int64, ids: [Int32], revoke: Bool)
    /// Marks the dialog's incoming messages up to the stored message `maxID` as read.
    case readDialog(dialogID: Int64, maxID: Int32)
    /// A boxed `Updates` to process as if the server had sent it.
    case processUpdates(Data)
    /// Boxed `User` and `Chat` objects to merge into the peer cache.
    case storePeers(users: [Data], chats: [Data])
    /// Refresh the cached full info of a user, or of a group or channel, from the server.
    case loadFullPeer(kind: FullPeerKind, id: Int64)

    public static let deleteMessagesOperation = "telegram.action.delete_messages"
    public static let readDialogOperation = "telegram.action.read_dialog"
    public static let processUpdatesOperation = "telegram.action.process_updates"
    public static let storePeersOperation = "telegram.action.store_peers"
    public static let loadFullPeerOperation = "telegram.action.load_full_peer"

    public static let operations: Set<String> = [deleteMessagesOperation, readDialogOperation, processUpdatesOperation,
                                                 storePeersOperation, loadFullPeerOperation]

    public var operation: String {
        switch self {
        case .deleteMessages: return Self.deleteMessagesOperation
        case .readDialog: return Self.readDialogOperation
        case .processUpdates: return Self.processUpdatesOperation
        case .storePeers: return Self.storePeersOperation
        case .loadFullPeer: return Self.loadFullPeerOperation
        }
    }
}

public extension AyuPluginTelegramBackend {
    func perform(account: AyuPluginTelegramAccount, action: AyuPluginTelegramAction,
                 completion: @escaping @Sendable (Result<Void, AyuPluginTelegramBackendError>) -> Void) {
        completion(.failure(.unsupported(action.operation)))
    }
}

extension AyuPluginTelegramBridge {
    static let actionMessageLimit = 100
    static let actionPeerLimit = 200

    /// The arguments of one `telegram.action.*` call; closed and typed like every other operation.
    func action(_ operation: String, _ arguments: [String: AyuBridgeValue]) throws -> AyuPluginTelegramAction {
        switch operation {
        case AyuPluginTelegramAction.deleteMessagesOperation:
            try Self.closed(arguments, required: ["account", "dialog_id", "ids", "revoke"])
            let dialogID = try Self.dialogID(arguments["dialog_id"], "dialog_id")
            guard let values = arguments["ids"]?.array, (1...Self.actionMessageLimit).contains(values.count) else {
                throw Self.invalid("ids must hold 1 to \(Self.actionMessageLimit) message ids")
            }
            let ids = try values.map { Int32(try Self.integer($0, 1...Int64(Int32.max), "ids")) }
            guard Set(ids).count == ids.count else { throw Self.invalid("ids must not repeat a message id") }
            return .deleteMessages(dialogID: dialogID, ids: ids, revoke: try Self.bool(arguments["revoke"], "revoke"))
        case AyuPluginTelegramAction.readDialogOperation:
            try Self.closed(arguments, required: ["account", "dialog_id", "max_id"])
            return .readDialog(dialogID: try Self.dialogID(arguments["dialog_id"], "dialog_id"),
                               maxID: Int32(try Self.integer(arguments["max_id"], 1...Int64(Int32.max), "max_id")))
        case AyuPluginTelegramAction.processUpdatesOperation:
            try Self.closed(arguments, required: ["account", "updates"])
            return .processUpdates(try self.inbound(arguments["updates"], "updates"))
        case AyuPluginTelegramAction.storePeersOperation:
            try Self.closed(arguments, required: ["account", "users", "chats"])
            func objects(_ key: String) throws -> [Data] {
                guard let values = arguments[key]?.array, values.count <= Self.actionPeerLimit else {
                    throw Self.invalid(key + " must be a list of at most \(Self.actionPeerLimit) TL values")
                }
                return try values.map { try self.inbound($0, key) }
            }
            let users = try objects("users"), chats = try objects("chats")
            guard !(users.isEmpty && chats.isEmpty) else { throw Self.invalid("users and chats are both empty") }
            return .storePeers(users: users, chats: chats)
        case AyuPluginTelegramAction.loadFullPeerOperation:
            try Self.closed(arguments, required: ["account", "kind", "id"])
            guard let kind = arguments["kind"]?.string.flatMap(AyuPluginTelegramAction.FullPeerKind.init(rawValue:)) else {
                throw Self.invalid("kind must be user or chat")
            }
            return .loadFullPeer(kind: kind, id: try Self.integer(arguments["id"], 1...Int64.max, "id"))
        default:
            throw AyuBridgeFailure.unsupported(operation)
        }
    }
}
