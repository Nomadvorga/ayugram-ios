import Foundation
import TelegramCore
import SwiftSignalKit

// MARK: AyuGram
// Keeps the phone, username and note that Telegram has already shown for a user, so that they stay
// in the profile after the user hides them. Empty values from the server never erase a known one.
struct AyuCachedProfileFields {
    let phone: String?
    let username: String?
    let note: String?
}

private struct AyuCachedProfileFieldsCodable: Codable, Equatable {
    var phone: String?
    var username: String?
    var note: String?
}

enum AyuProfileFieldCache {
    private static let defaultsKey = "ayu.profileFieldCache"

    private static func load() -> [String: AyuCachedProfileFieldsCodable] {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey), let value = try? JSONDecoder().decode([String: AyuCachedProfileFieldsCodable].self, from: data) else {
            return [:]
        }
        return value
    }

    private static let state = Atomic<[String: AyuCachedProfileFieldsCodable]>(value: load())

    static func remember(peerId: EnginePeer.Id, phone: String?, username: String?, note: String?) {
        let key = String(peerId.toInt64())
        var valueToPersist: [String: AyuCachedProfileFieldsCodable]?
        let _ = state.modify { current in
            var current = current
            var entry = current[key] ?? AyuCachedProfileFieldsCodable()
            let previousEntry = entry
            if let phone, !phone.isEmpty {
                entry.phone = phone
            }
            if let username, !username.isEmpty {
                entry.username = username
            }
            if let note, !note.isEmpty {
                entry.note = note
            }
            if entry != previousEntry {
                current[key] = entry
                valueToPersist = current
            }
            return current
        }
        if let valueToPersist, let data = try? JSONEncoder().encode(valueToPersist) {
            UserDefaults.standard.set(data, forKey: defaultsKey)
        }
    }

    static func value(peerId: EnginePeer.Id) -> AyuCachedProfileFields {
        return state.with { current in
            let entry = current[String(peerId.toInt64())]
            return AyuCachedProfileFields(phone: entry?.phone, username: entry?.username, note: entry?.note)
        }
    }
}
