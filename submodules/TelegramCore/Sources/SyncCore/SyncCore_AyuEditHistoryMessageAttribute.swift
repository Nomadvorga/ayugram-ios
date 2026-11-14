import Foundation
import Postbox

// MARK: AyuGram
public final class AyuEditHistoryMessageAttribute: MessageAttribute {
    public struct Entry: Equatable {
        // When this version was shown: the send date for the first one, the previous edit date otherwise.
        public let date: Int32
        public let text: String
        public let entities: [MessageTextEntity]

        public init(date: Int32, text: String, entities: [MessageTextEntity]) {
            self.date = date
            self.text = text
            self.entities = entities
        }
    }

    // Oldest first; the current text is not included.
    public let entries: [Entry]

    public init(entries: [Entry]) {
        self.entries = entries
    }

    required public init(decoder: PostboxDecoder) {
        let dates = decoder.decodeInt32ArrayForKey("d")
        let texts = decoder.decodeStringArrayForKey("t")
        let entityCounts = decoder.decodeInt32ArrayForKey("c")
        let allEntities: [MessageTextEntity] = decoder.decodeObjectArrayWithDecoderForKey("e")
        var entries: [Entry] = []
        var entityOffset = 0
        for i in 0 ..< min(dates.count, texts.count) {
            let count = i < entityCounts.count ? max(0, Int(entityCounts[i])) : 0
            let end = min(entityOffset + count, allEntities.count)
            entries.append(Entry(date: dates[i], text: texts[i], entities: Array(allEntities[entityOffset ..< end])))
            entityOffset = end
        }
        self.entries = entries
    }

    public func encode(_ encoder: PostboxEncoder) {
        encoder.encodeInt32Array(self.entries.map(\.date), forKey: "d")
        encoder.encodeStringArray(self.entries.map(\.text), forKey: "t")
        encoder.encodeInt32Array(self.entries.map { Int32($0.entities.count) }, forKey: "c")
        encoder.encodeObjectArray(self.entries.flatMap(\.entities), forKey: "e")
    }
}

public extension Message {
    var ayuEditHistory: [AyuEditHistoryMessageAttribute.Entry] {
        for attribute in self.attributes {
            if let attribute = attribute as? AyuEditHistoryMessageAttribute {
                return attribute.entries
            }
        }
        return []
    }
}
