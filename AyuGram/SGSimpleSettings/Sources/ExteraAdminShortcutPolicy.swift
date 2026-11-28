import Foundation

/// A strings-free policy shared by the actual author menu and host tests.
/// Unknown membership is never treated as an ordinary member.
public enum ExteraAdminShortcutPolicy {
    public struct Rights: OptionSet, Equatable, Sendable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }
        public static let banMembers = Rights(rawValue: 1 << 0)
        public static let addAdmins = Rights(rawValue: 1 << 1)
        public static let deleteMessages = Rights(rawValue: 1 << 2)
    }

    public enum GroupKind: Equatable, Sendable { case unsupported, legacyGroup, supergroup }
    public enum Actor: Equatable, Sendable {
        case unknown, member, owner
        case administrator(Rights)
    }
    public enum Target: Equatable, CaseIterable, Sendable { case unknown, member, administrator, owner, removed }
    public enum Action: String, CaseIterable, Sendable {
        case promote, restrict, ban, deleteMessages, removeMember
    }

    /// Administrators are intentionally excluded as targets. Their existing profile editor retains
    /// its full hierarchy/ownership controls; shortcuts must never bypass those controls.
    public static func actions(enabled: Bool, kind: GroupKind, actor: Actor, target: Target, isSelf: Bool) -> [Action] {
        guard enabled, kind != .unsupported, !isSelf, target == .member else { return [] }
        let rights: Rights
        switch actor {
        case .owner: rights = [.banMembers, .addAdmins, .deleteMessages]
        case let .administrator(value): rights = value
        case .unknown, .member: return []
        }
        if kind == .legacyGroup {
            // Basic groups do not have per-user restrictions or deleteParticipantHistory.
            // Promotion opens the native editor, whose custom rights may migrate the group.
            var result: [Action] = []
            if actor == .owner { result.append(.promote) }
            if rights.contains(.banMembers) { result.append(.removeMember) }
            return result
        }
        var result: [Action] = []
        if rights.contains(.addAdmins) { result.append(.promote) }
        if rights.contains(.banMembers) { result.append(contentsOf: [.restrict, .ban]) }
        if rights.contains(.deleteMessages) { result.append(.deleteMessages) }
        return result
    }
}
