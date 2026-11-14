import Foundation
import Postbox
import SGSimpleSettings

// MARK: AyuGram
// "Save Read Date": when a private chat partner reads our messages, remembers up to which
// message id and when, so the read date can be shown where Telegram does not provide one.
public final class AyuReadDates: @unchecked Sendable {
    public static let shared = AyuReadDates()

    private struct Mark: Codable {
        let maxId: Int32
        let date: Int32
    }

    private static let maxMarksPerPeer = 500

    private let queue = DispatchQueue(label: "org.ayugram.readDates")
    private let fileURL: URL?
    private var marks: [Int64: [Mark]] = [:]
    private var isLoaded = false
    private var isSaveScheduled = false

    private init() {
        if let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            self.fileURL = directory.appendingPathComponent("ayu-read-dates.json")
        } else {
            self.fileURL = nil
        }
    }

    private func loadIfNeeded() {
        if self.isLoaded {
            return
        }
        self.isLoaded = true
        guard let fileURL = self.fileURL, let data = try? Data(contentsOf: fileURL), let decoded = try? JSONDecoder().decode([String: [Mark]].self, from: data) else {
            return
        }
        for (key, value) in decoded {
            if let peerId = Int64(key) {
                self.marks[peerId] = value
            }
        }
    }

    private func scheduleSave() {
        if self.isSaveScheduled {
            return
        }
        self.isSaveScheduled = true
        self.queue.asyncAfter(deadline: .now() + 2.0) {
            self.isSaveScheduled = false
            guard let fileURL = self.fileURL else {
                return
            }
            var encoded: [String: [Mark]] = [:]
            for (peerId, value) in self.marks {
                encoded[String(peerId)] = value
            }
            if let data = try? JSONEncoder().encode(encoded) {
                try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? data.write(to: fileURL, options: .atomic)
            }
        }
    }

    func recordOutgoingRead(peerId: PeerId, maxId: Int32, date: Int32) {
        if !AyuSaveSettings.shared.saveReadDate {
            return
        }
        self.queue.async {
            self.loadIfNeeded()
            var peerMarks = self.marks[peerId.toInt64()] ?? []
            if let last = peerMarks.last, last.maxId >= maxId {
                return
            }
            peerMarks.append(Mark(maxId: maxId, date: date))
            if peerMarks.count > AyuReadDates.maxMarksPerPeer {
                peerMarks.removeFirst(peerMarks.count - AyuReadDates.maxMarksPerPeer)
            }
            self.marks[peerId.toInt64()] = peerMarks
            self.scheduleSave()
        }
    }

    // The date of the first read event that covered the message.
    public func readDate(messageId: MessageId) -> Int32? {
        return self.queue.sync {
            self.loadIfNeeded()
            guard let peerMarks = self.marks[messageId.peerId.toInt64()] else {
                return nil
            }
            return peerMarks.first(where: { $0.maxId >= messageId.id })?.date
        }
    }
}
