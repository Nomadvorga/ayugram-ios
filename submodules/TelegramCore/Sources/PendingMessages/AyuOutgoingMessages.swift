import Foundation
import Postbox
import SGSimpleSettings

// MARK: AyuGram
private let ayuScheduledTextDelay: Int32 = 12
private let ayuScheduledMediaDelay: Int32 = 30

// Applies "Send without Sound" and "Schedule Messages" to outgoing messages.
func ayuTransformOutgoingMessages(accountPeerId: PeerId, peerId: PeerId, messages: [EnqueueMessage]) -> [EnqueueMessage] {
    let settings = AyuGhostSettings.shared
    let sendSilently: Bool
    switch settings.sendWithoutSound {
    case .never:
        sendSilently = false
    case .inGhostMode:
        sendSilently = settings.isGhostModeActive
    case .always:
        sendSilently = true
    }
    // Secret chats cannot schedule, and Saved Messages never reveal the online status.
    let schedule = settings.useScheduledMessages && peerId != accountPeerId && peerId.namespace != Namespaces.Peer.SecretChat
    if !sendSilently && !schedule {
        return messages
    }
    let timestamp = Int32(CFAbsoluteTimeGetCurrent() + NSTimeIntervalSince1970)
    return messages.map { message in
        var hasMedia = false
        if case let .message(_, _, _, mediaReference, _, _, _, _, _, _) = message, mediaReference != nil {
            hasMedia = true
        }
        return message.withUpdatedAttributes { attributes in
            var attributes = attributes
            if sendSilently && !attributes.contains(where: { $0 is NotificationInfoMessageAttribute }) {
                attributes.append(NotificationInfoMessageAttribute(flags: .muted))
            }
            if schedule && !attributes.contains(where: { $0 is OutgoingScheduleInfoMessageAttribute || $0 is OutgoingQuickReplyMessageAttribute }) {
                let delay = hasMedia ? ayuScheduledMediaDelay : ayuScheduledTextDelay
                attributes.append(OutgoingScheduleInfoMessageAttribute(scheduleTime: timestamp + delay, repeatPeriod: nil))
            }
            return attributes
        }
    }
}
