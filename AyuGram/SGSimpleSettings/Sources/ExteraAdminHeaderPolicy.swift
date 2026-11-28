import Foundation

/// The original Android shortcuts open administrative sections, rather than performing mutations.
/// PeerInfo exposes these sections to every channel owner/admin; native flows/server authorize changes.
public enum ExteraAdminHeaderPolicy {
    public enum Kind: Equatable, CaseIterable, Sendable {
        case unsupported, legacyGroup, supergroup, broadcast, gigagroup
    }
    public enum Role: Equatable, CaseIterable, Sendable {
        case unknown, member, administrator, owner
    }
    public enum Action: String, CaseIterable, Sendable {
        case permissions, administrators, members, recentActions
    }
    public enum Destination: Equatable, Sendable {
        case groupPermissions, removedUsers, administrators, members, recentActions
    }
    public struct Entry: Equatable, Sendable {
        public let action: Action
        public let destination: Destination
        public init(action: Action, destination: Destination) {
            self.action = action
            self.destination = destination
        }
    }

    public static func entries(enabled: Bool, kind: Kind, role: Role, isMember: Bool, isMonoforum: Bool) -> [Entry] {
        guard enabled, isMember, !isMonoforum, role == .owner || role == .administrator else { return [] }
        switch kind {
        case .unsupported, .legacyGroup: return []
        case .supergroup, .broadcast, .gigagroup: break
        }
        return [
            Entry(action: .permissions, destination: kind == .supergroup ? .groupPermissions : .removedUsers),
            Entry(action: .administrators, destination: .administrators),
            Entry(action: .members, destination: .members),
            Entry(action: .recentActions, destination: .recentActions)
        ]
    }
}
