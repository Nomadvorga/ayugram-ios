import Foundation
import Postbox
import SwiftSignalKit
internal import TelegramApi

/// The file behind a plugin's `FileLoader` target: the media as the app models it and the
/// resource that holds its bytes.
private struct AyuPluginFileTarget {
    var media: Media
    var resource: TelegramMediaResource
    var contentType: MediaResourceUserContentType
    /// The message the target itself is, when it is one.
    var messageId: MessageId?
}

private func ayuPluginFileTarget(document: Api.Document) -> AyuPluginFileTarget? {
    guard let file = telegramMediaFileFromApiDocument(document, altDocuments: nil) else {
        return nil
    }
    return AyuPluginFileTarget(media: file, resource: file.resource, contentType: MediaResourceUserContentType(file: file), messageId: nil)
}

private func ayuPluginFileTarget(photo: Api.Photo) -> AyuPluginFileTarget? {
    guard let image = telegramMediaImageFromApiPhoto(photo), let representation = largestImageRepresentation(image.representations) else {
        return nil
    }
    return AyuPluginFileTarget(media: image, resource: representation.resource, contentType: .image, messageId: nil)
}

/// `target` is a boxed `Message`, `Document` or `Photo`. A `PhotoSize` or a `VideoSize` names a
/// size, not a file: this layer's TL gives them no location.
private func ayuPluginFileTarget(_ target: Data, operation: String) throws -> AyuPluginFileTarget {
    guard ayuPluginConstructorId(target) != nil, let object = Api.parse(Buffer(data: target)) else {
        throw AyuPluginCoreError.invalidArguments("target is not a TL object of layer \(ayuPluginApiLayer)")
    }
    if let document = object as? Api.Document {
        if let result = ayuPluginFileTarget(document: document) {
            return result
        }
        throw AyuPluginCoreError.invalidArguments("target is an empty document")
    } else if let photo = object as? Api.Photo {
        if let result = ayuPluginFileTarget(photo: photo) {
            return result
        }
        throw AyuPluginCoreError.invalidArguments("target is a photo without sizes")
    } else if let message = object as? Api.Message {
        guard case let .message(data) = message, let peerId = apiMessagePeerId(message) else {
            throw AyuPluginCoreError.invalidArguments("target message has no file")
        }
        var result: AyuPluginFileTarget?
        switch data.media {
        case let .messageMediaDocument(media):
            result = media.document.flatMap { ayuPluginFileTarget(document: $0) }
        case let .messageMediaPhoto(media):
            result = media.photo.flatMap { ayuPluginFileTarget(photo: $0) }
        default:
            break
        }
        guard var result else {
            throw AyuPluginCoreError.invalidArguments("target message has no file")
        }
        result.messageId = MessageId(peerId: peerId, namespace: Namespaces.Message.Cloud, id: data.id)
        return result
    } else if object is Api.PhotoSize || object is Api.VideoSize {
        throw AyuPluginCoreError.unsupported(operation + " for a PhotoSize or VideoSize, which names no file in this layer")
    } else {
        throw AyuPluginCoreError.invalidArguments("target must be a Message, Document or Photo")
    }
}

/// Where the file of `target` (a boxed `Message`, `Document` or `Photo`) is, or will be, in the
/// account's media store: the complete local copy when there is one, else the path at which the
/// store puts the file once its download finishes (nothing exists there before). The store names
/// files by resource id, without an extension.
public func ayuPluginFilePath(account: Account, target: Data) throws -> String {
    let file = try ayuPluginFileTarget(target, operation: "telegram.files.path")
    let mediaBox = account.postbox.mediaBox
    return mediaBox.completedResourcePath(file.resource) ?? mediaBox.resourcePath(file.resource)
}

/// Downloads in flight for plugins, by account and resource, so that a cancel finds them.
private final class AyuPluginFileLoads {
    private struct Key: Hashable {
        var account: AccountRecordId
        var resource: MediaResourceId
    }

    private let lock = NSLock()
    private var disposables: [Key: MetaDisposable] = [:]
    private let limit = 64

    /// False when the per-process bound is reached; a download of the same file is replaced.
    /// `start` receives the closure to call when the download ends by itself, which may be
    /// before `start` returns.
    func begin(account: AccountRecordId, resource: MediaResourceId, start: (@escaping () -> Void) -> Disposable) -> Bool {
        let key = Key(account: account, resource: resource)
        let holder = MetaDisposable()
        self.lock.lock()
        if self.disposables[key] == nil && self.disposables.count >= self.limit {
            self.lock.unlock()
            return false
        }
        let previous = self.disposables.updateValue(holder, forKey: key)
        self.lock.unlock()
        previous?.dispose()
        holder.set(start({
            self.lock.lock()
            if self.disposables[key] === holder {
                self.disposables.removeValue(forKey: key)
            }
            self.lock.unlock()
        }))
        return true
    }

    func cancel(account: AccountRecordId, resource: MediaResourceId) {
        self.lock.lock()
        let disposable = self.disposables.removeValue(forKey: Key(account: account, resource: resource))
        self.lock.unlock()
        disposable?.dispose()
    }
}

private let ayuPluginFileLoads = AyuPluginFileLoads()

/// Starts downloading the file of `target` into the media store, as opening it in a chat would.
/// `parent` (a boxed `Message`) or a `Message` target supplies the stored message whose file
/// reference the download may refresh; without one that is stored, an expired reference fails
/// the download. Completes once the download is started; its progress is observed through
/// `ayuPluginFilePath`.
public func ayuPluginLoadFile(account: Account, target: Data, parent: Data?) -> Signal<Never, AyuPluginCoreError> {
    let file: AyuPluginFileTarget
    var parentId: MessageId?
    do {
        file = try ayuPluginFileTarget(target, operation: "telegram.files.load")
        parentId = file.messageId
        if let parent {
            guard ayuPluginConstructorId(parent) != nil, let message = Api.parse(Buffer(data: parent)) as? Api.Message, let peerId = apiMessagePeerId(message), case let .message(data) = message else {
                throw AyuPluginCoreError.invalidArguments("parent must be a Message")
            }
            parentId = MessageId(peerId: peerId, namespace: Namespaces.Message.Cloud, id: data.id)
        }
    } catch let error as AyuPluginCoreError {
        return .fail(error)
    } catch {
        return .fail(.invalidArguments("target could not be read"))
    }
    let postbox = account.postbox
    let accountId = account.id
    return postbox.transaction { transaction -> Message? in
        return parentId.flatMap { transaction.getMessage($0) }
    }
    |> castError(AyuPluginCoreError.self)
    |> mapToSignal { stored -> Signal<Never, AyuPluginCoreError> in
        let reference: MediaResourceReference
        var location: MediaResourceUserLocation = .other
        if let stored {
            reference = AnyMediaReference.message(message: MessageReference(stored), media: file.media).resourceReference(file.resource)
            location = .peer(stored.id.peerId)
        } else {
            reference = .standalone(resource: file.resource)
        }
        let resourceId = file.resource.id
        let started = ayuPluginFileLoads.begin(account: accountId, resource: resourceId, start: { finished in
            return fetchedMediaResource(mediaBox: postbox.mediaBox, userLocation: location, userContentType: file.contentType, reference: reference).start(error: { _ in
                finished()
            }, completed: {
                finished()
            })
        })
        return started ? .complete() : .fail(.unsupported("more than 64 plugin downloads at once"))
    }
}

/// Stops a download `ayuPluginLoadFile` started for the same target. A download the app itself
/// started for the file (the user opened it) is not touched.
public func ayuPluginCancelFileLoad(account: Account, target: Data) throws {
    let file = try ayuPluginFileTarget(target, operation: "telegram.files.load")
    ayuPluginFileLoads.cancel(account: account.id, resource: file.resource.id)
}
