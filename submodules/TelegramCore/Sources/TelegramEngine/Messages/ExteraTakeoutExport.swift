import Foundation
import MtProtoKit
import SwiftSignalKit
internal import TelegramApi

public extension TelegramEngine.Messages {
    /// Each subscription creates an independent takeout session. Dispose to cancel;
    /// cancellation also requests finishTakeoutSession(success: false) and removes output.
    func exportAccountTakeout(options: ExteraTakeoutOptions) -> Signal<ExteraTakeoutEvent, ExteraTakeoutError> {
        return Signal { subscriber in
            let operation = ExteraTakeoutOperation(network: self.account.network, options: options, subscriber: subscriber)
            operation.start()
            return ActionDisposable { operation.cancel() }
        }
    }
}

private final class ExteraTakeoutCancellation {
    private let lock = NSLock()
    private var value = false
    var isCancelled: Bool { self.lock.lock(); defer { self.lock.unlock() }; return self.value }
    func cancel() { self.lock.lock(); self.value = true; self.lock.unlock() }
}

private final class ExteraTakeoutOperation {
    private struct Target {
        let peer: Api.InputPeer
        let record: ExteraTakeoutChatRecord
        let split: Int
    }

    private struct Media {
        let location: Api.InputFileLocation
        let datacenter: Int32
        let size: Int64
        let suffix: String
    }

    private let network: Network
    private let options: ExteraTakeoutOptions
    private let subscriber: Subscriber<ExteraTakeoutEvent, ExteraTakeoutError>
    private let queue = Queue(name: "ExteraTakeoutExport", qos: .utility)
    private let cancellation = ExteraTakeoutCancellation()
    private let request = MetaDisposable()
    private let initialization = MetaDisposable()
    private let cleanup = MetaDisposable()
    private var initializing = false
    private var terminal = false
    private var sessionId: Int64?
    private var finishing = false
    private var writer: ExteraTakeoutWriter?
    private var ranges: [(Int32, Int32)] = []
    private var targets: [Target] = []
    private var targetKeys = Set<String>()
    private var listingSplit = 0
    private var listingFolder: Int32 = 0
    private var listingOffset: (date: Int32, id: Int32, peer: Api.InputPeer, key: String)?
    private var dialogPages = 0
    private var leftOffset: Int32 = 0
    private var targetIndex = 0
    private var historyOffset: Int32 = 0
    private var page: [Api.Message] = []
    private var pageIndex = 0
    private var nextHistoryOffset: Int32 = 0
    private var pageOldestDate: Int32?
    private var messages: Int64 = 0
    private var mediaFiles = 0
    private var skippedMedia = 0
    private var mediaHandle: FileHandle?
    private var mediaPath: String?
    private var mediaOffset: Int64 = 0
    private var mediaRecord: ExteraTakeoutMessageRecord?

    init(network: Network, options: ExteraTakeoutOptions, subscriber: Subscriber<ExteraTakeoutEvent, ExteraTakeoutError>) {
        self.network = network
        self.options = options
        self.subscriber = subscriber
    }

    func start() {
        self.queue.async {
            guard !self.cancellation.isCancelled else { return }
            do { try self.options.validate(); self.writer = try ExteraTakeoutWriter(options: self.options) }
            catch { self.fail(error); return }
            self.progress(.authorizing)
            self.initializing = true
            // Keep initialization alive after disposal: a late successful reply contains
            // the session id needed to close the just-created server session.
            self.initialization.set((self.network.request(Api.functions.account.initTakeoutSession(flags: self.options.sessionFlags, fileMaxSize: self.options.media == .none ? nil : self.options.maximumFileSize), automaticFloodWait: false)
            |> timeout(60, queue: self.queue, alternate: .fail(MTRpcError(errorCode: 408, errorDescription: "REQUEST_TIMEOUT")))
            |> deliverOn(self.queue)).start(next: { result in
                self.initializing = false
                switch result { case let .takeout(data): self.sessionId = data.id }
                if self.cancellation.isCancelled || self.terminal { self.finish(success: false, completion: { _ in }); return }
                self.loadRanges()
            }, error: { error in
                self.initializing = false
                self.fail(ExteraTakeoutError.server(code: error.errorCode, text: error.errorDescription))
            }))
        }
    }

    func cancel() {
        self.cancellation.cancel()
        self.queue.async {
            guard !self.terminal else { return }
            self.terminal = true
            self.request.set(nil)
            self.closeMedia()
            self.writer?.closeAndRemove()
            self.writer = nil
            if !self.initializing && !self.finishing { self.finish(success: false, completion: { _ in }) }
        }
    }

    /// Generic TL wrappers have the same result decoder as the inner request.
    /// The constructor ids and field order match swift_scheme.tl and Android TakeoutRequests.
    /// Preserve the inner description for method telemetry; no takeout id enters logs.
    private func wrapped<T>(_ function: (FunctionDescription, Buffer, DeserializeFunctionResponse<T>), sessionId: Int64, range: (Int32, Int32)? = nil) -> (FunctionDescription, Buffer, DeserializeFunctionResponse<T>) {
        let prefix = Buffer()
        prefix.appendInt32(Int32(bitPattern: 0xaca9fd2e))
        prefix.appendInt64(sessionId)
        if let range {
            prefix.appendInt32(Int32(bitPattern: 0x365275f2))
            prefix.appendInt32(Int32(bitPattern: 0x0ae30253))
            prefix.appendInt32(range.0)
            prefix.appendInt32(range.1)
        }
        var payload = prefix.makeData()
        payload.append(function.1.makeData())
        return (function.0, Buffer(data: payload), function.2)
    }

    private func send<T>(_ function: (FunctionDescription, Buffer, DeserializeFunctionResponse<T>), split: Int? = nil, next: @escaping (T) -> Void) {
        guard !self.terminal, !self.cancellation.isCancelled, let sessionId = self.sessionId else { return }
        let range = split.map { self.ranges[$0] }
        self.request.set((self.network.request(self.wrapped(function, sessionId: sessionId, range: range), automaticFloodWait: false)
        |> timeout(60, queue: self.queue, alternate: .fail(MTRpcError(errorCode: 408, errorDescription: "REQUEST_TIMEOUT")))
        |> deliverOn(self.queue)).start(next: { [weak self] result in
            guard let self, !self.terminal, !self.cancellation.isCancelled else { return }
            next(result)
        }, error: { [weak self] error in
            self?.fail(ExteraTakeoutError.server(code: error.errorCode, text: error.errorDescription))
        }))
    }

    private func loadRanges() {
        self.progress(.listingChats)
        self.send(Api.functions.messages.getSplitRanges()) { ranges in
            guard ranges.count <= 1000 else { self.fail(ExteraTakeoutError.outputLimit); return }
            self.ranges = ranges.compactMap { range in
                switch range { case let .messageRange(data): return data.minId <= data.maxId ? (data.minId, data.maxId) : nil }
            }
            guard self.ranges.count == ranges.count else { self.fail(ExteraTakeoutError.invalidResponse); return }
            if self.ranges.isEmpty { self.ranges = [(1, Int32.max)] }
            self.loadDialogs()
        }
    }

    private func loadDialogs() {
        guard self.listingSplit < self.ranges.count else {
            if self.options.includeLeftChannels && !self.options.chatTypes.intersection([.privateGroups, .publicGroups, .privateChannels, .publicChannels]).isEmpty { self.loadLeftChannels() }
            else { self.beginNextChat() }
            return
        }
        self.dialogPages += 1
        guard self.dialogPages <= 100000 else { self.fail(ExteraTakeoutError.outputLimit); return }
        let offset = self.listingOffset
        let flags: Int32 = (1 << 1) | (offset == nil ? 0 : 1 << 0)
        self.send(Api.functions.messages.getDialogs(flags: flags, folderId: self.listingFolder, offsetDate: offset?.date ?? 0, offsetId: offset?.id ?? 0, offsetPeer: offset?.peer ?? .inputPeerEmpty, limit: 100, hash: 0), split: self.listingSplit) { result in
            let dialogs: [Api.Dialog]
            let messages: [Api.Message]
            let chats: [Api.Chat]
            let users: [Api.User]
            let complete: Bool
            switch result {
            case let .dialogs(data): (dialogs, messages, chats, users, complete) = (data.dialogs, data.messages, data.chats, data.users, true)
            case let .dialogsSlice(data): (dialogs, messages, chats, users, complete) = (data.dialogs, data.messages, data.chats, data.users, false)
            case .dialogsNotModified: self.fail(ExteraTakeoutError.invalidResponse); return
            }
            guard dialogs.count <= 100, messages.count <= 1000, chats.count <= 1000, users.count <= 1000 else { self.fail(ExteraTakeoutError.invalidResponse); return }
            var last: (Int32, Int32, Api.InputPeer, String)?
            for dialog in dialogs {
                guard case let .dialog(data) = dialog else { continue }
                guard let target = self.target(peer: data.peer, users: users, chats: chats, split: self.listingSplit, left: false) else {
                    self.fail(ExteraTakeoutError.invalidResponse); return
                }
                if self.includes(target) { self.addTarget(target) }
                if self.terminal { return }
                if data.flags & (1 << 2) == 0, data.topMessage > 0 {
                    let date = messages.compactMap { message -> Int32? in
                        switch message {
                        case let .message(message): return message.id == data.topMessage && self.peerKey(message.peerId) == target.record.id ? message.date : nil
                        case let .messageService(message): return message.id == data.topMessage && self.peerKey(message.peerId) == target.record.id ? message.date : nil
                        case .messageEmpty: return nil
                        }
                    }.first
                    guard let date else { self.fail(ExteraTakeoutError.invalidResponse); return }
                    last = (date, data.topMessage, target.peer, target.record.id)
                }
            }
            self.progress(.listingChats)
            if complete || dialogs.isEmpty { self.advanceDialogList(); return }
            guard let last else { self.fail(ExteraTakeoutError.cursorDidNotAdvance); return }
            if let offset, offset.date == last.0, offset.id == last.1, offset.key == last.3 { self.fail(ExteraTakeoutError.cursorDidNotAdvance); return }
            self.listingOffset = (last.0, last.1, last.2, last.3)
            self.queue.justDispatch { self.loadDialogs() }
        }
    }

    private func advanceDialogList() {
        self.listingOffset = nil
        if self.listingFolder == 0 { self.listingFolder = 1 }
        else { self.listingFolder = 0; self.listingSplit += 1 }
        self.queue.justDispatch { self.loadDialogs() }
    }

    private func loadLeftChannels() {
        let previous = self.leftOffset
        self.send(Api.functions.channels.getLeftChannels(offset: previous)) { result in
            let chats: [Api.Chat]
            let complete: Bool
            switch result {
            case let .chats(data): chats = data.chats; complete = true
            case let .chatsSlice(data): chats = data.chats; complete = false
            }
            guard chats.count <= 1000 else { self.fail(ExteraTakeoutError.invalidResponse); return }
            for chat in chats {
                let peer: Api.Peer
                switch chat {
                case let .channel(data): peer = .peerChannel(.init(channelId: data.id))
                case let .channelForbidden(data): peer = .peerChannel(.init(channelId: data.id))
                default: continue
                }
                if let target = self.target(peer: peer, users: [], chats: [chat], split: self.ranges.count - 1, left: true), self.includes(target) { self.addTarget(target) }
                if self.terminal { return }
            }
            if complete || chats.isEmpty { self.beginNextChat(); return }
            guard Int64(previous) + Int64(chats.count) < Int64(Int32.max) else { self.fail(ExteraTakeoutError.outputLimit); return }
            self.leftOffset += Int32(chats.count)
            self.queue.justDispatch { self.loadLeftChannels() }
        }
    }

    private func peerKey(_ peer: Api.Peer) -> String {
        switch peer {
        case let .peerUser(data): return "user\(data.userId)"
        case let .peerChat(data): return "group\(data.chatId)"
        case let .peerChannel(data): return "channel\(data.channelId)"
        }
    }

    private func target(peer: Api.Peer, users: [Api.User], chats: [Api.Chat], split: Int, left: Bool) -> Target? {
        let id = self.peerKey(peer)
        switch peer {
        case let .peerUser(peer):
            for user in users {
                if case let .user(user) = user, user.id == peer.userId {
                    let name = [user.firstName, user.lastName].compactMap { $0 }.joined(separator: " ")
                    let input: Api.InputPeer = user.flags & (1 << 10) != 0 ? .inputPeerSelf : .inputPeerUser(.init(userId: user.id, accessHash: user.accessHash ?? 0))
                    return Target(peer: input, record: .init(id: id, title: name.isEmpty ? id : name, type: user.flags & (1 << 14) != 0 ? "bot" : "personal", split: split, left: left), split: split)
                }
                if case let .userEmpty(user) = user, user.id == peer.userId {
                    return Target(peer: .inputPeerUser(.init(userId: user.id, accessHash: 0)), record: .init(id: id, title: id, type: "personal", split: split, left: left), split: split)
                }
            }
        case let .peerChat(peer):
            for chat in chats {
                if case let .chat(chat) = chat, chat.id == peer.chatId {
                    return Target(peer: .inputPeerChat(.init(chatId: chat.id)), record: .init(id: id, title: chat.title, type: "private_group", split: split, left: left), split: split)
                }
                if case let .chatForbidden(chat) = chat, chat.id == peer.chatId {
                    return Target(peer: .inputPeerChat(.init(chatId: chat.id)), record: .init(id: id, title: chat.title, type: "private_group", split: split, left: left), split: split)
                }
            }
        case let .peerChannel(peer):
            for chat in chats {
                if case let .channel(chat) = chat, chat.id == peer.channelId {
                    let isPublic = !(chat.username ?? "").isEmpty || (chat.usernames ?? []).contains { username in
                        switch username { case let .username(data): return data.flags & (1 << 1) != 0 }
                    }
                    let group = chat.flags & (1 << 8) != 0
                    let type = (isPublic ? "public_" : "private_") + (group ? "group" : "channel")
                    return Target(peer: .inputPeerChannel(.init(channelId: chat.id, accessHash: chat.accessHash ?? 0)), record: .init(id: id, title: chat.title, type: type, split: split, left: left), split: split)
                }
                if case let .channelForbidden(chat) = chat, chat.id == peer.channelId {
                    return Target(peer: .inputPeerChannel(.init(channelId: chat.id, accessHash: chat.accessHash)), record: .init(id: id, title: chat.title, type: chat.flags & (1 << 8) != 0 ? "private_group" : "private_channel", split: split, left: left), split: split)
                }
            }
        }
        return nil
    }

    private func includes(_ target: Target) -> Bool {
        if target.record.id.hasPrefix("channel"), target.split != self.ranges.count - 1 { return false }
        let type: ExteraTakeoutOptions.ChatTypes
        switch target.record.type {
        case "personal": type = .personal
        case "bot": type = .bots
        case "private_group": type = .privateGroups
        case "public_group": type = .publicGroups
        case "private_channel": type = .privateChannels
        default: type = .publicChannels
        }
        return self.options.chatTypes.contains(type)
    }

    private func addTarget(_ target: Target) {
        let key = "\(target.split):\(target.record.id)"
        guard !self.targetKeys.contains(key) else { return }
        guard self.targets.count < 50000 else { self.fail(ExteraTakeoutError.outputLimit); return }
        self.targetKeys.insert(key)
        self.targets.append(target)
    }

    private func beginNextChat() {
        guard !self.terminal, !self.cancellation.isCancelled else { return }
        guard self.targetIndex < self.targets.count else { self.complete(); return }
        do { try self.writer?.beginChat(self.targets[self.targetIndex].record) }
        catch { self.fail(error); return }
        self.historyOffset = 0
        self.progress(.exportingHistory)
        self.loadHistory()
    }

    private func loadHistory() {
        let target = self.targets[self.targetIndex]
        self.send(Api.functions.messages.getHistory(peer: target.peer, offsetId: self.historyOffset, offsetDate: self.historyOffset == 0 ? self.options.untilTimestamp ?? 0 : 0, addOffset: 0, limit: 100, maxId: 0, minId: 0, hash: 0), split: target.split) { result in
            let messages: [Api.Message]
            switch result {
            case let .messages(data): messages = data.messages
            case let .messagesSlice(data): messages = data.messages
            case let .channelMessages(data): messages = data.messages
            case .messagesNotModified: self.fail(ExteraTakeoutError.invalidResponse); return
            }
            guard messages.count <= 100 else { self.fail(ExteraTakeoutError.invalidResponse); return }
            if messages.isEmpty { self.endCurrentChat(); return }
            let ids = messages.map(self.messageId)
            guard let minimum = ids.filter({ $0 > 0 }).min(), self.historyOffset == 0 || minimum < self.historyOffset else { self.fail(ExteraTakeoutError.cursorDidNotAdvance); return }
            // Server pages may overlap; the previous offset is an exclusive boundary.
            var pageIds = Set<Int32>()
            self.page = messages.filter { message in
                let id = self.messageId(message)
                return id > 0 && (self.historyOffset == 0 || id < self.historyOffset) && pageIds.insert(id).inserted
            }.sorted { self.messageId($0) > self.messageId($1) }
            self.pageIndex = 0
            self.nextHistoryOffset = minimum
            self.pageOldestDate = self.page.compactMap(self.messageDate).min()
            self.consumePage()
        }
    }

    private func messageId(_ message: Api.Message) -> Int32 {
        switch message { case let .message(data): return data.id; case let .messageService(data): return data.id; case let .messageEmpty(data): return data.id }
    }

    private func messageDate(_ message: Api.Message) -> Int32? {
        switch message { case let .message(data): return data.date; case let .messageService(data): return data.date; case .messageEmpty: return nil }
    }

    private func consumePage() {
        guard !self.terminal, !self.cancellation.isCancelled else { return }
        while self.pageIndex < self.page.count {
            guard !self.cancellation.isCancelled else { return }
            let message = self.page[self.pageIndex]
            self.pageIndex += 1
            guard let date = self.messageDate(message), self.options.includes(date: date) else { continue }
            let record: ExteraTakeoutMessageRecord
            let media: Media?
            switch message {
            case let .message(data):
                var reply: Int32?
                if case let .messageReplyHeader(header)? = data.replyTo { reply = header.replyToMsgId }
                let extracted = self.extractMedia(data.media)
                record = ExteraTakeoutMessageRecord(id: data.id, date: data.date, sender: data.fromId.map(self.peerKey), outgoing: data.flags & (1 << 1) != 0, text: data.message, serviceAction: nil, replyToMessageId: reply, groupedId: data.groupedId.map { String($0) }, media: extracted.0)
                media = extracted.1
            case let .messageService(data):
                record = ExteraTakeoutMessageRecord(id: data.id, date: data.date, sender: data.fromId.map(self.peerKey), outgoing: data.flags & (1 << 1) != 0, text: "", serviceAction: String(describing: data.action), replyToMessageId: nil, groupedId: nil, media: nil)
                media = nil
            case .messageEmpty: continue
            }
            if let media { self.beginMedia(media, record: record); return }
            if record.media != nil { self.skippedMedia += 1 }
            do { try self.writer?.append(record); self.messages += 1 }
            catch { self.fail(error); return }
        }
        self.page.removeAll(keepingCapacity: true)
        self.progress(.exportingHistory)
        if let start = self.options.fromTimestamp, let oldest = self.pageOldestDate, oldest < start { self.endCurrentChat(); return }
        self.historyOffset = self.nextHistoryOffset
        self.queue.justDispatch { self.loadHistory() }
    }

    private func endCurrentChat() {
        do { try self.writer?.endChat() } catch { self.fail(error); return }
        self.targetIndex += 1
        self.queue.justDispatch { self.beginNextChat() }
    }

    private func extractMedia(_ media: Api.MessageMedia?) -> (ExteraTakeoutMediaRecord?, Media?) {
        guard let media else { return (nil, nil) }
        switch media {
        case .messageMediaEmpty: return (nil, nil)
        case let .messageMediaDocument(data):
            guard case let .document(document)? = data.document else { return (.init(type: "document", name: nil, size: nil, path: nil, skippedReason: "unavailable"), nil) }
            var name: String?
            for attribute in document.attributes { if case let .documentAttributeFilename(data) = attribute { name = data.fileName } }
            let reason = data.ttlSeconds != nil ? "ephemeral_media" : self.options.media != .photosAndFiles ? "media_type_not_selected" : document.size > self.options.maximumFileSize ? "size_limit" : document.size < 0 || document.dcId <= 0 ? "unknown_size_or_location" : nil
            let record = ExteraTakeoutMediaRecord(type: document.mimeType, name: name, size: document.size, path: nil, skippedReason: reason)
            guard reason == nil else { return (record, nil) }
            let location = Api.InputFileLocation.inputDocumentFileLocation(.init(id: document.id, accessHash: document.accessHash, fileReference: document.fileReference, thumbSize: ""))
            return (record, Media(location: location, datacenter: document.dcId, size: document.size, suffix: (name.map { ($0 as NSString).pathExtension.lowercased() }).flatMap { $0.isEmpty ? nil : $0 } ?? "bin"))
        case let .messageMediaPhoto(data):
            guard case let .photo(photo)? = data.photo else { return (.init(type: "photo", name: nil, size: nil, path: nil, skippedReason: "unavailable"), nil) }
            let sizes: [(String, Int64)] = photo.sizes.compactMap { size in
                switch size {
                case let .photoSize(size): return (size.type, Int64(size.size))
                case let .photoSizeProgressive(size): return size.sizes.max().map { (size.type, Int64($0)) }
                default: return nil
                }
            }
            guard let largest = sizes.max(by: { $0.1 < $1.1 }), largest.1 >= 0 else { return (.init(type: "photo", name: nil, size: nil, path: nil, skippedReason: "unknown_size"), nil) }
            let reason = data.ttlSeconds != nil ? "ephemeral_media" : self.options.media == .none ? "media_type_not_selected" : largest.1 > self.options.maximumFileSize ? "size_limit" : photo.dcId <= 0 ? "unavailable_location" : nil
            let record = ExteraTakeoutMediaRecord(type: "photo", name: "photo.jpg", size: largest.1, path: nil, skippedReason: reason)
            guard reason == nil else { return (record, nil) }
            let location = Api.InputFileLocation.inputPhotoFileLocation(.init(id: photo.id, accessHash: photo.accessHash, fileReference: photo.fileReference, thumbSize: largest.0))
            return (record, Media(location: location, datacenter: photo.dcId, size: largest.1, suffix: "jpg"))
        default: return (.init(type: String(describing: media), name: nil, size: nil, path: nil, skippedReason: "unsupported_media"), nil)
        }
    }

    private func beginMedia(_ media: Media, record: ExteraTakeoutMessageRecord) {
        do {
            guard let writer = self.writer else { throw ExteraTakeoutError.io }
            let file = try writer.createMedia(extension: media.suffix)
            self.mediaPath = file.0
            self.mediaHandle = file.1
            self.mediaOffset = 0
            self.mediaRecord = record
            self.progress(.downloadingMedia)
            self.loadMediaPart(media)
        } catch { self.fail(error) }
    }

    private func loadMediaPart(_ media: Media) {
        guard !self.terminal, !self.cancellation.isCancelled, let sessionId = self.sessionId else { return }
        if self.mediaOffset == media.size { self.completeMedia(reason: nil); return }
        let request = self.wrapped(Api.functions.upload.getFile(flags: 0, location: media.location, offset: self.mediaOffset, limit: 512 * 1024), sessionId: sessionId)
        let signal = self.network.download(datacenterId: Int(media.datacenter), isMedia: true, tag: nil)
        |> castError(MTRpcError.self)
        |> mapToSignal { worker in worker.request(request, automaticFloodWait: false) }
        |> timeout(60, queue: self.queue, alternate: .fail(MTRpcError(errorCode: 408, errorDescription: "REQUEST_TIMEOUT")))
        self.request.set((signal |> deliverOn(self.queue)).start(next: { [weak self] result in
            guard let self, !self.terminal, !self.cancellation.isCancelled else { return }
            switch result {
            case .fileCdnRedirect: self.completeMedia(reason: "cdn_redirect_unsupported")
            case let .file(data):
                let bytes = data.bytes.makeData()
                guard !bytes.isEmpty, bytes.count <= 512 * 1024, Int64(bytes.count) <= media.size - self.mediaOffset else { self.completeMedia(reason: "incomplete_media"); return }
                do {
                    guard let handle = self.mediaHandle else { throw ExteraTakeoutError.io }
                    try self.writer?.appendMedia(bytes, to: handle)
                    self.mediaOffset += Int64(bytes.count)
                    self.progress(.downloadingMedia)
                    self.queue.justDispatch { self.loadMediaPart(media) }
                } catch { self.fail(error) }
            }
        }, error: { [weak self] error in
            guard let self else { return }
            let text = error.errorDescription ?? "REQUEST_FAILED"
            if text.hasPrefix("FILE_REFERENCE_") || ["LOCATION_INVALID", "LOCATION_NOT_AVAILABLE", "VERSION_INVALID", "TAKEOUT_FILE_TOO_BIG"].contains(text) { self.completeMedia(reason: text.lowercased()) }
            else { self.fail(ExteraTakeoutError.server(code: error.errorCode, text: text)) }
        }))
    }

    private func completeMedia(reason: String?) {
        guard var record = self.mediaRecord, let path = self.mediaPath else { self.fail(ExteraTakeoutError.invalidResponse); return }
        do { try self.mediaHandle?.close() } catch { self.fail(error); return }
        self.mediaHandle = nil
        if let reason {
            self.writer?.removeMedia(path)
            record.media?.skippedReason = reason
            self.skippedMedia += 1
        } else {
            record.media?.path = path
            self.mediaFiles += 1
        }
        self.mediaRecord = nil
        self.mediaPath = nil
        do { try self.writer?.append(record); self.messages += 1 }
        catch { self.fail(error); return }
        self.queue.justDispatch { self.consumePage() }
    }

    private func closeMedia() { try? self.mediaHandle?.close(); self.mediaHandle = nil; self.mediaRecord = nil; self.mediaPath = nil }

    private func progress(_ phase: ExteraTakeoutProgress.Phase) {
        guard !self.terminal, !self.cancellation.isCancelled else { return }
        self.subscriber.putNext(.progress(ExteraTakeoutProgress(phase: phase, chatTitle: self.targetIndex < self.targets.count ? self.targets[self.targetIndex].record.title : "", completedChats: self.targetIndex, totalChats: self.targets.count, messages: self.messages, mediaFiles: self.mediaFiles, skippedMedia: self.skippedMedia, bytesWritten: self.writer?.bytesWritten ?? 0)))
    }

    private func complete() {
        guard !self.terminal, !self.cancellation.isCancelled, let writer = self.writer else { return }
        do {
            try writer.finalize(messages: self.messages, skippedMedia: self.skippedMedia)
            self.progress(.packaging)
            try ExteraTakeoutArchive.create(directory: writer.contentsURL, destination: writer.archiveURL, cancelled: { self.cancellation.isCancelled })
        } catch { self.fail(error); return }
        self.progress(.finishing)
        self.finish(success: true) { finished in
            guard !self.terminal, !self.cancellation.isCancelled else { return }
            guard finished else { self.fail(ExteraTakeoutError.finishFailed); return }
            self.terminal = true
            self.writer = nil
            self.subscriber.putNext(.completed(ExteraTakeoutResult(archiveURL: writer.archiveURL, directory: writer.directory, messages: self.messages, skippedMedia: self.skippedMedia)))
            self.subscriber.putCompletion()
        }
    }

    private func finish(success: Bool, completion: @escaping (Bool) -> Void) {
        guard !self.finishing else { completion(false); return }
        guard let sessionId = self.sessionId else { completion(true); return }
        self.finishing = true
        let function = self.wrapped(Api.functions.account.finishTakeoutSession(flags: success ? 1 : 0), sessionId: sessionId)
        // Retain this operation until the cleanup attempt resolves, even after the UI
        // disposes its subscription. A lost network cannot guarantee server cleanup.
        self.cleanup.set((self.network.request(function, automaticFloodWait: false)
        |> timeout(15, queue: self.queue, alternate: .fail(MTRpcError(errorCode: 408, errorDescription: "REQUEST_TIMEOUT")))
        |> deliverOn(self.queue)).start(next: { result in
            withExtendedLifetime(self) {
                self.finishing = false
                switch result {
                case .boolTrue: self.sessionId = nil; completion(true)
                case .boolFalse:
                    if !success { self.sessionId = nil }
                    if success && (self.terminal || self.cancellation.isCancelled) { self.finish(success: false, completion: { _ in }) }
                    completion(false)
                }
            }
        }, error: { _ in
            withExtendedLifetime(self) {
                self.finishing = false
                if !success { self.sessionId = nil }
                if success && (self.terminal || self.cancellation.isCancelled) { self.finish(success: false, completion: { _ in }) }
                completion(false)
            }
        }))
    }

    private func fail(_ error: Error) {
        guard !self.terminal else { return }
        self.terminal = true
        self.request.set(nil)
        self.closeMedia()
        self.writer?.closeAndRemove()
        self.writer = nil
        self.finish(success: false, completion: { _ in })
        if !self.cancellation.isCancelled { self.subscriber.putError(error as? ExteraTakeoutError ?? .io) }
    }
}
