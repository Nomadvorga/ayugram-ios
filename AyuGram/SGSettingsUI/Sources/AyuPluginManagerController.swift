import AccountContext
import AnimatedStickerNode
import AyuPluginBridge
import Display
import SGSwiftUI
import StickerResources
import SwiftSignalKit
import SwiftUI
import TelegramAnimatedStickerNode
import TelegramCore
import TextFormat
import UIKit

/// Loads the sticker pictures of one manager screen (plugin icons, the empty list's picture);
/// its requests end with it.
private final class AyuPluginIconLoader {
    private let context: AccountContext
    private let disposables = DisposableSet()

    init(context: AccountContext) {
        self.context = context
    }

    deinit {
        self.disposables.dispose()
    }

    /// Document `index` of the set `pack`, 56 pt: a plugin's `__icon__`.
    func load(pack: String, index: Int, completion: @escaping @MainActor (UIImage?) -> Void) {
        self.load(pack: pack, side: Self.iconSide, pick: { $0.indices.contains(index) ? $0[index] : nil }, animated: { [weak self] file in
            self?.animatedIcons["\(pack)/\(index)"] = file
        }, completion: completion)
    }

    /// A view that plays the icon in a loop, once `load(pack:index:)` has answered for an animated
    /// or video sticker; nil for a sticker that does not move.
    func player(pack: String, index: Int, started: @escaping @MainActor () -> Void) -> UIView? {
        guard let file = self.animatedIcons["\(pack)/\(index)"] else { return nil }
        return AyuPluginStickerPlayerView(context: self.context, file: file, side: Self.iconSide, started: started)
    }

    private static let iconSide: CGFloat = 56
    /// Read and written on main only.
    private var animatedIcons: [String: TelegramMediaFile] = [:]

    /// The first document of the set `pack` that stands for `emoji`, 100 pt: Android's `setPlaceholderImage`.
    func load(pack: String, emoji: String, completion: @escaping @MainActor (UIImage?) -> Void) {
        let plain = { (text: String) in text.replacingOccurrences(of: "\u{FE0F}", with: "") }
        let wanted = plain(emoji)
        self.load(pack: pack, side: Self.placeholderSide, pick: { items in
            items.first { $0.getStringRepresentationsOfIndexKeys().contains { plain($0) == wanted } }
        }, animated: { [weak self] file in
            self?.animatedPlaceholders[pack + "/" + emoji] = file
        }, completion: completion)
    }

    /// `player(pack:index:started:)` for the sticker of `load(pack:emoji:)`.
    func player(pack: String, emoji: String, started: @escaping @MainActor () -> Void) -> UIView? {
        guard let file = self.animatedPlaceholders[pack + "/" + emoji] else { return nil }
        return AyuPluginStickerPlayerView(context: self.context, file: file, side: Self.placeholderSide, started: started)
    }

    private static let placeholderSide: CGFloat = 100
    /// Read and written on main only.
    private var animatedPlaceholders: [String: TelegramMediaFile] = [:]

    /// Answers once on main: a still picture of the picked document of the set `pack`, or nil when
    /// the set or the document does not exist. A sticker that never downloads never answers.
    /// `animated` gets the file on main, before the answer, when the picture is a still of a sticker that moves.
    private func load(pack: String, side: CGFloat, pick: @escaping ([StickerPackItem]) -> StickerPackItem?, animated: ((TelegramMediaFile) -> Void)? = nil, completion: @escaping @MainActor (UIImage?) -> Void) {
        let account = self.context.account
        let file = self.context.engine.stickers.loadedStickerPack(reference: .name(pack), forceActualized: false)
        |> filter { pack in
            if case .fetching = pack { return false } else { return true }
        }
        |> take(1)
        |> map { pack -> TelegramMediaFile? in
            guard case let .result(_, items, _) = pack else { return nil }
            return pick(items)?.file._parse()
        }
        let image = file
        |> mapToSignal { file -> Signal<(UIImage?, TelegramMediaFile?), NoError> in
            guard let file else { return .single((nil, nil)) }
            let bounds = CGSize(width: side, height: side)
            let size = (file.dimensions?.cgSize ?? bounds).aspectFitted(bounds)
            // `onlyFullSize` holds the answer back until the picture is whole, so the first one is final.
            let picture: Signal<(TransformImageArguments) -> DrawingContext?, NoError>
            if file.isAnimatedSticker {
                // The first frame of the animation, rendered for the slot's pixels.
                let pixels = CGSize(width: size.width * UIScreenScale, height: size.height * UIScreenScale)
                picture = chatMessageAnimatedSticker(postbox: account.postbox, userLocation: .other, file: file, small: false, size: pixels, fetched: true, onlyFullSize: true)
            } else {
                // The still of a video sticker is its preview, the only picture of it that needs no player.
                if file.isVideoSticker && file.previewRepresentations.isEmpty { return .single((nil, nil)) }
                picture = chatMessageSticker(account: account, userLocation: .other, file: file, small: file.isVideoSticker, fetched: true, onlyFullSize: true)
            }
            return picture
            |> take(1)
            |> map { draw -> (UIImage?, TelegramMediaFile?) in
                let image = draw(TransformImageArguments(corners: ImageCorners(), imageSize: size, boundingSize: size, intrinsicInsets: UIEdgeInsets()))?.generateImage()
                return (image, file)
            }
        }
        self.disposables.add((image |> deliverOnMainQueue).start(next: { image, file in
            if image != nil, let file, file.isAnimatedSticker || file.isVideoSticker { animated?(file) }
            MainActor.assumeIsolated { completion(image) }
        }))
    }
}

/// Plays an animated or video sticker in a loop, as Android's `BackupImageView` does. A node's
/// own view does not keep its node alive, so this view owns it.
private final class AyuPluginStickerPlayerView: UIView {
    private let node = DefaultAnimatedStickerNodeImpl()
    private let dimensions: CGSize
    private var fetch: Disposable?

    init(context: AccountContext, file: TelegramMediaFile, side: CGFloat, started: @escaping @MainActor () -> Void) {
        let bounds = CGSize(width: side, height: side)
        self.dimensions = file.dimensions?.cgSize ?? bounds
        super.init(frame: CGRect(origin: CGPoint(), size: bounds))
        let pixels = self.dimensions.aspectFitted(CGSize(width: side * UIScreenScale, height: side * UIScreenScale))
        let cache = context.engine.resources.shortLivedResourceCachePathPrefix(id: EngineMediaResource.Id(file.resource.id))
        self.node.setup(source: AnimatedStickerResourceSource(account: context.account, resource: file.resource, isVideo: file.isVideoSticker), width: Int(pixels.width), height: Int(pixels.height), playbackMode: .loop, mode: .direct(cachePathPrefix: cache))
        if file.isVideoSticker {
            // The still of a video sticker is its preview, so nothing has fetched the video yet;
            // the node starts once the file is whole.
            self.fetch = freeMediaFileResourceInteractiveFetched(account: context.account, userLocation: .other, fileReference: stickerPackFileReference(file), resource: file.resource).start()
        }
        self.node.started = {
            Queue.mainQueue().async { MainActor.assumeIsolated { started() } }
        }
        self.addSubview(self.node.view)
        self.node.visibility = true
    }

    required init?(coder: NSCoder) {
        return nil
    }

    deinit {
        self.fetch?.dispose()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let size = self.dimensions.aspectFitted(self.bounds.size)
        self.node.frame = CGRect(origin: CGPoint(x: (self.bounds.width - size.width) / 2, y: (self.bounds.height - size.height) / 2), size: size)
        self.node.updateLayout(size: size)
    }
}

private struct AyuPluginManagerScreen: UIViewControllerRepresentable {
    @Environment(\.colorScheme) private var colorScheme
    /// Read so that the screen is updated when the app's theme changes, also from one dark theme to the other.
    @Environment(\.sgTheme) private var theme
    let context: AccountContext

    /// Android's counterpart of the app's theme: Day Classic is its default, Tinted Night its "Dark Blue".
    private var engineTheme: AyuPluginManagerViewController.EngineTheme {
        switch self.context.sharedContext.currentPresentationData.with({ $0 }).theme.referenceTheme.baseTheme {
        case .classic: return .classic
        case .day: return .day
        case .tinted: return .darkBlue
        case .night: return .night
        }
    }

    private func applyTheme(to controller: AyuPluginManagerViewController) {
        let _ = self.theme
        controller.overrideUserInterfaceStyle = self.colorScheme == .dark ? .dark : .light
        controller.engineTheme = self.engineTheme
    }

    func makeUIViewController(context: Context) -> AyuPluginManagerViewController {
        let controller = AyuPluginManagerViewController(service: .shared)
        let loader = AyuPluginIconLoader(context: self.context)
        controller.iconProvider = { pack, index, completion in
            loader.load(pack: pack, index: index, completion: completion)
        }
        controller.iconPlayerProvider = { pack, index, started in
            loader.player(pack: pack, index: index, started: started)
        }
        controller.placeholderProvider = { pack, emoji, completion in
            loader.load(pack: pack, emoji: emoji, completion: completion)
        }
        controller.placeholderPlayerProvider = { pack, emoji, started in
            loader.player(pack: pack, emoji: emoji, started: started)
        }
        // The Prism engine of code blocks in chats, with the colours the page asks for.
        controller.codeHighlighter = { code, language, palette, completion in
            let colors = palette.mapValues { UIColor(argb: $0) }
            let _ = (asyncStandaloneSyntaxHighlight(text: code, language: language, palette: colors) |> deliverOnMainQueue).start(next: { runs in
                let colors = runs.map { (range: $0.range, argb: $0.color.argb) }
                MainActor.assumeIsolated { completion(colors) }
            })
        }
        self.applyTheme(to: controller)
        return controller
    }

    func updateUIViewController(_ controller: AyuPluginManagerViewController, context: Context) {
        self.applyTheme(to: controller)
    }
}

@MainActor
public func ayuPluginManagerController(context: AccountContext) -> ViewController {
    return SGSwiftUIController(
        title: "Плагины",
        presentationData: context.sharedContext.currentPresentationData.with { $0 },
        presentationDataSignal: context.sharedContext.presentationData
    ) {
        AyuPluginManagerScreen(context: context)
    }
}
