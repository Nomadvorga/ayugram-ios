import AccountContext
import AsyncDisplayKit
import Display
import Foundation
import ImageIO
import SwiftSignalKit
import TelegramCore
import TelegramPresentationData
import UIKit

/// Native image-bot wallpaper search. Results are handed to WallpaperGalleryController for preview and apply.
final class ExteraWallpaperSearchController: ViewController, UISearchBarDelegate, UICollectionViewDataSource, UICollectionViewDelegateFlowLayout {
    private let context: AccountContext
    private let open: (ChatContextResult) -> Void
    private var presentationData: PresentationData
    private let searchBar = UISearchBar()
    private let colors = UIScrollView()
    private let collection: UICollectionView
    private let status = UILabel()
    private let retry = UIButton(type: .system)
    private let spinner = UIActivityIndicatorView(style: .medium)
    private var colorButtons: [UIButton] = []
    private let requestDisposable = MetaDisposable()
    private var presentationDisposable: Disposable?
    private var state = WallpaperSearchState<ChatContextResult>()

    private let colorSwatches: [UIColor] = [
        .systemBlue, .systemRed, .systemOrange, .systemYellow,
        .systemGreen, .systemTeal, .systemPurple, .systemPink,
        .systemBrown, .black, .systemGray, .white
    ]

    init(context: AccountContext, open: @escaping (ChatContextResult) -> Void) {
        self.context = context
        self.open = open
        self.presentationData = context.sharedContext.currentPresentationData.with { $0 }
        let layout = UICollectionViewFlowLayout()
        layout.minimumInteritemSpacing = 6.0
        layout.minimumLineSpacing = 6.0
        self.collection = UICollectionView(frame: .zero, collectionViewLayout: layout)
        super.init(navigationBarPresentationData: NavigationBarPresentationData(presentationData: self.presentationData))
        self.presentationDisposable = (context.sharedContext.presentationData |> deliverOnMainQueue).start(next: { [weak self] presentationData in
            guard let self else {
                return
            }
            self.presentationData = presentationData
            if self.isNodeLoaded {
                self.updatePresentation()
            }
        })
    }

    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        self.requestDisposable.dispose()
        self.presentationDisposable?.dispose()
    }

    override func loadDisplayNode() {
        self.displayNode = ASDisplayNode()
        self.displayNode.view.addSubview(self.searchBar)
        self.displayNode.view.addSubview(self.colors)
        self.displayNode.view.addSubview(self.collection)
        self.displayNode.view.addSubview(self.status)
        self.displayNode.view.addSubview(self.retry)
        self.displayNode.view.addSubview(self.spinner)
        self.searchBar.delegate = self
        self.searchBar.showsCancelButton = true
        self.searchBar.searchBarStyle = .minimal
        self.colors.showsHorizontalScrollIndicator = false
        self.collection.register(WallpaperSearchCell.self, forCellWithReuseIdentifier: "wallpaper")
        self.collection.dataSource = self
        self.collection.delegate = self
        self.collection.keyboardDismissMode = .onDrag
        self.collection.backgroundColor = .clear
        self.status.numberOfLines = 0
        self.status.textAlignment = .center
        self.status.font = .preferredFont(forTextStyle: .subheadline)
        self.status.adjustsFontForContentSizeCategory = true
        self.retry.addTarget(self, action: #selector(self.retryPressed), for: .touchUpInside)
        for index in WallpaperSearchQuery.colors.indices {
            let button = UIButton(type: .system)
            button.tag = index
            button.layer.cornerRadius = 12.0
            button.addTarget(self, action: #selector(self.selectColor(_:)), for: .touchUpInside)
            self.colors.addSubview(button)
            self.colorButtons.append(button)
        }
        self.updatePresentation()
        self.displayNodeDidLoad()
        self.searchBar.becomeFirstResponder()
    }

    override func containerLayoutUpdated(_ layout: ContainerViewLayout, transition: ContainedViewLayoutTransition) {
        super.containerLayoutUpdated(layout, transition: transition)
        let margins = layout.listSideMargins(base: 16.0)
        let width = max(0.0, layout.size.width - margins.left - margins.right)
        let top = self.cleanNavigationHeight
        let bottom = layout.insets(options: .input).bottom
        self.searchBar.frame = CGRect(x: margins.left, y: top, width: width, height: 56.0)
        self.colors.frame = CGRect(x: margins.left, y: top + 56.0, width: width, height: 50.0)
        self.layoutColors()
        self.collection.frame = CGRect(x: margins.left, y: top + 112.0, width: width, height: max(0.0, layout.size.height - top - 112.0 - bottom))
        self.collection.collectionViewLayout.invalidateLayout()
        self.status.frame = CGRect(x: margins.left, y: top + 170.0, width: width, height: 100.0)
        self.retry.frame = CGRect(x: margins.left, y: layout.size.height - bottom - 50.0, width: width, height: 44.0)
        self.spinner.center = CGPoint(x: margins.left + width / 2.0, y: top + 136.0)
    }

    private func layoutColors() {
        var x: CGFloat = 0.0
        for button in self.colorButtons {
            button.frame = CGRect(x: x, y: 6.0, width: 32.0, height: 32.0)
            x += 38.0
        }
        self.colors.contentSize = CGSize(width: x, height: 50.0)
    }

    private func updatePresentation() {
        let strings = self.presentationData.strings
        self.title = strings.Wallpaper_Title
        self.navigationItem.backBarButtonItem = UIBarButtonItem(title: strings.Common_Back, style: .plain, target: nil, action: nil)
        self.statusBar.statusBarStyle = self.presentationData.theme.rootController.statusBarStyle.style
        self.navigationBar?.updatePresentationData(NavigationBarPresentationData(presentationData: self.presentationData), transition: .immediate)
        self.displayNode.backgroundColor = self.presentationData.theme.list.blocksBackgroundColor
        self.searchBar.placeholder = strings.Common_Search
        self.searchBar.barStyle = self.presentationData.theme.overallDarkAppearance ? .black : .default
        self.searchBar.tintColor = self.presentationData.theme.list.itemAccentColor
        self.status.textColor = self.presentationData.theme.list.itemSecondaryTextColor
        for (index, button) in self.colorButtons.enumerated() {
            let color = WallpaperSearchQuery.colors[index]
            button.accessibilityLabel = color
            button.accessibilityTraits = self.state.query.color == color ? [.button, .selected] : [.button]
            button.backgroundColor = self.colorSwatches[index]
            button.layer.borderWidth = self.state.query.color == color ? 3.0 : 1.0
            button.layer.borderColor = (self.state.query.color == color ? self.presentationData.theme.list.itemAccentColor : self.presentationData.theme.list.itemBlocksBackgroundColor).cgColor
        }
        self.layoutColors()
        self.render()
    }

    func searchBar(_ searchBar: UISearchBar, textDidChange searchText: String) {
        self.resetSearch(immediate: false)
    }

    func searchBarSearchButtonClicked(_ searchBar: UISearchBar) {
        self.view.endEditing(true)
        self.resetSearch(immediate: true)
    }

    func searchBarCancelButtonClicked(_ searchBar: UISearchBar) {
        self.searchBar.text = ""
        self.requestDisposable.set(nil)
        self.state.reset(WallpaperSearchQuery(text: "", color: nil))
        self.view.endEditing(true)
        self.updatePresentation()
    }

    @objc private func selectColor(_ sender: UIButton) {
        let color = WallpaperSearchQuery.colors[sender.tag]
        let selected = self.state.query.color == color ? nil : color
        let text = self.searchBar.text ?? ""
        self.requestDisposable.set(nil)
        self.state.reset(WallpaperSearchQuery(text: text, color: selected))
        self.updatePresentation()
        self.loadMore(immediate: true)
    }

    private func resetSearch(immediate: Bool) {
        self.requestDisposable.set(nil)
        self.state.reset(WallpaperSearchQuery(text: self.searchBar.text ?? "", color: self.state.query.color))
        self.render()
        self.loadMore(immediate: immediate)
    }

    @objc private func retryPressed() {
        self.loadMore(immediate: true)
    }

    private func loadMore(immediate: Bool) {
        guard let request = self.state.begin() else {
            return
        }
        self.render()
        let context = self.context
        let signal: Signal<RequestChatContextResultsResult?, NoError> = (.single(()) |> delay(immediate ? 0.0 : 0.5, queue: .mainQueue()))
        |> mapToSignal { _ in
            context.engine.data.get(TelegramEngine.EngineData.Item.Configuration.SearchBots())
        }
        |> mapToSignal { configuration -> Signal<EnginePeer?, NoError> in
            guard let username = configuration.imageBotUsername, !username.isEmpty else {
                return .single(nil)
            }
            return context.engine.peers.resolvePeerByName(name: username, referrer: nil)
            |> mapToSignal { result -> Signal<EnginePeer?, NoError> in
                switch result {
                case .progress:
                    return .complete()
                case let .result(peer):
                    return .single(peer)
                }
            }
        }
        |> mapToSignal { peer -> Signal<RequestChatContextResultsResult?, NoError> in
            guard let peer else {
                return .single(nil)
            }
            return context.engine.messages.requestChatContextResults(botId: peer.id, peerId: context.account.peerId, query: request.query, offset: request.offset, incompleteResults: false, staleCachedResults: false)
            |> `catch` { _ in .single(nil) }
        }
        self.requestDisposable.set((signal |> take(1) |> deliverOnMainQueue).start(next: { [weak self] response in
            guard let self else {
                return
            }
            if let response {
                let photos = response.results.results.filter { $0.type == "photo" && WallpaperSearchCell.resource($0, thumbnail: false) != nil }
                self.state.receive(request, items: photos, nextOffset: response.results.nextOffset, id: { $0.id })
            } else {
                self.state.fail(request)
            }
            self.render()
        }))
    }

    private func render() {
        self.collection.reloadData()
        if self.state.request != nil {
            self.spinner.startAnimating()
        } else {
            self.spinner.stopAnimating()
        }
        self.retry.isHidden = !self.state.canLoadMore
        self.retry.setTitle(self.state.failed ? self.presentationData.strings.ChatImportActivity_Retry : self.presentationData.strings.Common_More, for: .normal)
        self.status.text = self.state.failed ? self.presentationData.strings.Login_UnknownError : self.presentationData.strings.ChatList_Search_NoResults
        self.status.isHidden = self.state.request != nil || !self.state.items.isEmpty || self.state.query.botQuery == nil
    }

    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        return self.state.items.count
    }

    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCell(withReuseIdentifier: "wallpaper", for: indexPath) as! WallpaperSearchCell
        cell.update(context: self.context, result: self.state.items[indexPath.item], placeholder: self.presentationData.theme.list.itemBlocksBackgroundColor)
        return cell
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        self.view.endEditing(true)
        self.open(self.state.items[indexPath.item])
    }

    func collectionView(_ collectionView: UICollectionView, layout collectionViewLayout: UICollectionViewLayout, sizeForItemAt indexPath: IndexPath) -> CGSize {
        let columns = max(1, Int((collectionView.bounds.width + 6.0) / 110.0))
        let width = floor(max(1.0, collectionView.bounds.width - CGFloat(columns - 1) * 6.0) / CGFloat(columns))
        return CGSize(width: width, height: floor(width * 1.4))
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        if (scrollView.isDragging || scrollView.isDecelerating) && !self.state.failed && scrollView.contentOffset.y + scrollView.bounds.height > scrollView.contentSize.height - 300.0 {
            self.loadMore(immediate: true)
        }
    }
}

private final class WallpaperSearchCell: UICollectionViewCell {
    private let imageView = UIImageView()
    private var imageDisposable: Disposable?
    private var fetchDisposable: Disposable?
    private var resultId: String?

    override init(frame: CGRect) {
        super.init(frame: frame)
        self.imageView.contentMode = .scaleAspectFill
        self.imageView.clipsToBounds = true
        self.contentView.addSubview(self.imageView)
        self.isAccessibilityElement = true
        self.accessibilityTraits = .button
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        self.imageDisposable?.dispose()
        self.fetchDisposable?.dispose()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        self.imageView.frame = self.contentView.bounds
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        self.imageDisposable?.dispose()
        self.fetchDisposable?.dispose()
        self.imageDisposable = nil
        self.fetchDisposable = nil
        self.resultId = nil
        self.imageView.image = nil
    }

    static func resource(_ result: ChatContextResult, thumbnail: Bool) -> EngineMediaResource? {
        switch result {
        case let .externalReference(value):
            guard let content = value.content else {
                return nil
            }
            let resource = thumbnail ? (value.thumbnail?.resource ?? content.resource) : content.resource
            return EngineMediaResource(resource)
        case let .internalReference(value):
            guard let image = value.image else {
                return nil
            }
            let representation = thumbnail ? smallestImageRepresentation(image.representations) : imageRepresentationLargerThan(image.representations, size: PixelDimensions(width: 1000, height: 800))
            return representation.map { EngineMediaResource($0.resource) }
        }
    }

    func update(context: AccountContext, result: ChatContextResult, placeholder: UIColor) {
        self.prepareForReuse()
        self.resultId = result.id
        self.imageView.backgroundColor = placeholder
        self.accessibilityLabel = result.title ?? result.id
        guard let resource = Self.resource(result, thumbnail: true) else {
            return
        }
        self.fetchDisposable = context.engine.resources.fetchedResource(resource: resource).start()
        self.imageDisposable = (context.engine.resources.data(resource: resource)
        |> filter { $0.isComplete }
        |> take(1)
        |> deliverOn(Queue.concurrentDefaultQueue())
        |> map { data -> UIImage? in
            guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: data.path) as CFURL, nil),
                  let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 600, kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary) else {
                return nil
            }
            return UIImage(cgImage: image)
        }
        |> deliverOnMainQueue).start(next: { [weak self] image in
            guard let self, self.resultId == result.id else {
                return
            }
            self.imageView.image = image
        })
    }
}
