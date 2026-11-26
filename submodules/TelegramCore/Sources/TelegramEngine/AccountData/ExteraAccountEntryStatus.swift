import Foundation
import MtProtoKit
import SGSimpleSettings
import SwiftSignalKit
internal import TelegramApi

func exteraAccountEntryStatus(_ status: Api.UserStatus?) -> ExteraPillEntryStatus {
    switch status {
    case let .userStatusOnline(value)?: return .online(until: value.expires)
    case let .userStatusOffline(value)?: return .offline(at: value.wasOnline)
    default: return .longAgo
    }
}

/// Exact APK source: LastSeenPill -> AyuRequestUtils.requestUser(self) -> User.status.
/// Read the raw response: the general peer-presence cache deliberately skips the account itself.
/// This read does not announce online/offline or manufacture a timestamp on failure.
public func exteraRequestAccountEntryStatus(account: Account) -> Signal<ExteraPillEntryStatus?, NoError> {
    return exteraPresenceBarrier(network: account.network)
    |> castError(MTRpcError.self)
    |> mapToSignal { _ in account.network.request(Api.functions.users.getUsers(id: [.inputUserSelf]), automaticFloodWait: false) }
    |> map { users -> ExteraPillEntryStatus? in
        for user in users {
            guard case let .user(data) = user, data.id == account.peerId.id._internalGetInt64Value() else { continue }
            let status = exteraAccountEntryStatus(data.status)
            exteraRecordEntryStatus(status, network: account.network)
            return status
        }
        return nil
    }
    |> `catch` { _ -> Signal<ExteraPillEntryStatus?, NoError> in .single(nil) }
    |> timeout(15.0, queue: .mainQueue(), alternate: .single(nil))
}
