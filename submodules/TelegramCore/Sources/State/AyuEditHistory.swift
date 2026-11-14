import Foundation
import Postbox
import SGSimpleSettings

// MARK: AyuGram
private let ayuMaxEditHistoryEntries = 50

// Appends the version being replaced to the message's edit history when its text changes.
func ayuMessageWithEditHistory(previous: Message, updated: StoreMessage) -> StoreMessage {
    if !AyuSaveSettings.shared.saveMessagesHistory {
        return updated
    }
    let previousEntities = previous.textEntitiesAttribute?.entities ?? []
    let updatedEntities = (updated.attributes.first(where: { $0 is TextEntitiesMessageAttribute }) as? TextEntitiesMessageAttribute)?.entities ?? []
    if previous.text == updated.text && previousEntities == updatedEntities {
        return updated
    }
    let previousEditDate = (previous.attributes.first(where: { $0 is EditedMessageAttribute }) as? EditedMessageAttribute)?.date
    var entries = previous.ayuEditHistory
    entries.append(AyuEditHistoryMessageAttribute.Entry(date: previousEditDate ?? previous.timestamp, text: previous.text, entities: previousEntities))
    if entries.count > ayuMaxEditHistoryEntries {
        entries.removeFirst(entries.count - ayuMaxEditHistoryEntries)
    }
    var attributes = updated.attributes.filter { !($0 is AyuEditHistoryMessageAttribute) }
    attributes.append(AyuEditHistoryMessageAttribute(entries: entries))
    return updated.withUpdatedAttributes(attributes)
}
