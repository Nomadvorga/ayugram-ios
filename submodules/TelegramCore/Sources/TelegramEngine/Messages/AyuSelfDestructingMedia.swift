import Foundation
import Postbox

// MARK: AyuGram
// Incoming self-destructing media in cloud chats can be viewed any number of times:
// opening it neither starts its timer nor reports it as viewed, and a view reported by
// another session does not replace it with the expired placeholder.
// Secret chats keep the regular behavior.
func ayuKeepsSelfDestructingMedia(_ message: Message) -> Bool {
    if !message.flags.contains(.Incoming) || message.id.peerId.namespace == Namespaces.Peer.SecretChat {
        return false
    }
    if !message.containsSecretMedia {
        return false
    }
    return message.attributes.contains(where: { $0 is AutoclearTimeoutMessageAttribute })
}
