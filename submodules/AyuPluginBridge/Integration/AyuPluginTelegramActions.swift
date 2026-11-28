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
    /// Marks every dialog that has unread messages as read: the main list (`folderID` 0), the
    /// archive (1) or, with a negative `folderID`, both. Any other folder holds no dialog.
    case readAllDialogs(folderID: Int32)
    /// Boxed `User` and `Chat` objects to merge into the peer cache.
    case storePeers(users: [Data], chats: [Data])
    /// Refresh the cached full info of a user, or of a group or channel, from the server.
    case loadFullPeer(kind: FullPeerKind, id: Int64)
    /// Moves dialogs of the chat list into the main list (`folderID` 0) or the archive (1) and
    /// unpins them. The one action with a result: Android's 0 (no dialog moved), 1, or 2 when
    /// the move made the archive appear.
    case addDialogsToFolder(dialogIDs: [Int64], folderID: Int32)

    public static let deleteMessagesOperation = "telegram.action.delete_messages"
    public static let readDialogOperation = "telegram.action.read_dialog"
    public static let readAllDialogsOperation = "telegram.action.read_all_dialogs"
    public static let processUpdatesOperation = "telegram.action.process_updates"
    public static let storePeersOperation = "telegram.action.store_peers"
    public static let loadFullPeerOperation = "telegram.action.load_full_peer"
    public static let addDialogsToFolderOperation = "telegram.action.add_dialogs_to_folder"

    public static let operations: Set<String> = [deleteMessagesOperation, readDialogOperation, readAllDialogsOperation,
                                                 processUpdatesOperation, storePeersOperation, loadFullPeerOperation,
                                                 addDialogsToFolderOperation]

    public var operation: String {
        switch self {
        case .deleteMessages: return Self.deleteMessagesOperation
        case .readDialog: return Self.readDialogOperation
        case .readAllDialogs: return Self.readAllDialogsOperation
        case .processUpdates: return Self.processUpdatesOperation
        case .storePeers: return Self.storePeersOperation
        case .loadFullPeer: return Self.loadFullPeerOperation
        case .addDialogsToFolder: return Self.addDialogsToFolderOperation
        }
    }
}

public extension AyuPluginTelegramBackend {
    func perform(account: AyuPluginTelegramAccount, action: AyuPluginTelegramAction,
                 completion: @escaping @Sendable (Result<Int32?, AyuPluginTelegramBackendError>) -> Void) {
        completion(.failure(.unsupported(action.operation)))
    }
}

extension AyuPluginTelegramBridge {
    static let actionMessageLimit = 100
    static let actionPeerLimit = 200
    static let actionDialogLimit = 100

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
        case AyuPluginTelegramAction.readAllDialogsOperation:
            try Self.closed(arguments, required: ["account", "folder_id"])
            return .readAllDialogs(folderID: Int32(try Self.integer(arguments["folder_id"], Self.int32Range, "folder_id")))
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
        case AyuPluginTelegramAction.addDialogsToFolderOperation:
            try Self.closed(arguments, required: ["account", "dialog_ids", "folder_id"])
            guard let values = arguments["dialog_ids"]?.array, (1...Self.actionDialogLimit).contains(values.count) else {
                throw Self.invalid("dialog_ids must hold 1 to \(Self.actionDialogLimit) dialog ids")
            }
            let dialogIDs = try values.map { try Self.dialogID($0, "dialog_ids") }
            guard Set(dialogIDs).count == dialogIDs.count else { throw Self.invalid("dialog_ids must not repeat a dialog id") }
            return .addDialogsToFolder(dialogIDs: dialogIDs, folderID: Int32(try Self.integer(arguments["folder_id"], 0...1, "folder_id")))
        default:
            throw AyuBridgeFailure.unsupported(operation)
        }
    }

    /// The wire value of what the backend answered: `null`, or for the one action that has a
    /// result its integer, which must be one Android returns.
    static func actionResult(_ action: AyuPluginTelegramAction, _ result: Int32?) throws -> AyuBridgeValue {
        guard case .addDialogsToFolder = action else { return .null }
        guard let result, (0...2).contains(result) else {
            throw AyuBridgeFailure("invalid_state", "Telegram backend returned an invalid folder result")
        }
        return .integer(Int64(result))
    }
}
