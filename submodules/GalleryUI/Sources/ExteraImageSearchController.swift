import AccountContext
import Foundation
import SafariServices
import SGStrings
import SwiftSignalKit
import TelegramCore
import UIKit

func exteraImageSearchText(_ key: String, _ language: String, _ fallback: String) -> String {
    return i18n(key, language, fallback)
}

/// Native gallery utility. Merely opening it observes existing cache entries; only
/// confirming a provider sends the sanitized JPEG to Android's Yandex upload endpoint.
final class ExteraImageSearchController: UIViewController {
    private let context: AccountContext
    private let resources: [EngineMediaResource.Id]
    private let language: String
    private let cacheDisposable = MetaDisposable()
    private var upload: ExteraImageSearchUpload?
    private var generation = 0
    private var photo: ExteraImageSearchPhoto?
    private var backgroundObserver: NSObjectProtocol?
    private let scrollView = UIScrollView()
    private let stack = UIStackView()
    private let preview = UIImageView()
    private let status = UILabel()
    private var providerButtons: [UIButton] = []

    init(context: AccountContext, resources: [EngineMediaResource.Id]) {
        self.context = context
        self.resources = resources
        self.language = context.sharedContext.currentPresentationData.with { $0 }.strings.baseLanguageCode
        super.init(nibName: nil, bundle: nil)
        self.title = self.text("Extera.ImageTools", "Photo Tools")
        self.backgroundObserver = NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main, using: { [weak self] _ in
            self?.cancelUpload()
        })
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit {
        self.cacheDisposable.dispose()
        self.upload?.cancel()
        if let observer = self.backgroundObserver { NotificationCenter.default.removeObserver(observer) }
    }

    private func text(_ key: String, _ fallback: String) -> String { return exteraImageSearchText(key, self.language, fallback) }

    override func viewDidLoad() {
        super.viewDidLoad()
        self.view.backgroundColor = .systemBackground
        self.navigationItem.rightBarButtonItem = UIBarButtonItem(barButtonSystemItem: .done, target: self, action: #selector(self.close))
        self.scrollView.translatesAutoresizingMaskIntoConstraints = false
        self.stack.translatesAutoresizingMaskIntoConstraints = false
        self.stack.axis = .vertical
        self.stack.spacing = 16.0
        self.view.addSubview(self.scrollView)
        self.scrollView.addSubview(self.stack)
        NSLayoutConstraint.activate([
            self.scrollView.leadingAnchor.constraint(equalTo: self.view.safeAreaLayoutGuide.leadingAnchor),
            self.scrollView.trailingAnchor.constraint(equalTo: self.view.safeAreaLayoutGuide.trailingAnchor),
            self.scrollView.topAnchor.constraint(equalTo: self.view.safeAreaLayoutGuide.topAnchor),
            self.scrollView.bottomAnchor.constraint(equalTo: self.view.bottomAnchor),
            self.stack.leadingAnchor.constraint(equalTo: self.scrollView.contentLayoutGuide.leadingAnchor, constant: 20),
            self.stack.trailingAnchor.constraint(equalTo: self.scrollView.contentLayoutGuide.trailingAnchor, constant: -20),
            self.stack.topAnchor.constraint(equalTo: self.scrollView.contentLayoutGuide.topAnchor, constant: 16),
            self.stack.bottomAnchor.constraint(equalTo: self.scrollView.contentLayoutGuide.bottomAnchor, constant: -24),
            self.stack.widthAnchor.constraint(equalTo: self.scrollView.frameLayoutGuide.widthAnchor, constant: -40),
        ])
        self.preview.contentMode = .scaleAspectFit
        self.preview.heightAnchor.constraint(equalToConstant: 220).isActive = true
        self.preview.isAccessibilityElement = true
        self.preview.accessibilityLabel = self.text("Extera.ImageSearchPreview", "Image to upload")
        self.stack.addArrangedSubview(self.preview)
        self.status.font = .preferredFont(forTextStyle: .body)
        self.status.adjustsFontForContentSizeCategory = true
        self.status.numberOfLines = 0
        self.status.text = self.text("Extera.ImageReadingCache", "Reading the cached image…")
        self.stack.addArrangedSubview(self.status)
        self.readCache()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if self.isBeingDismissed || self.navigationController?.isBeingDismissed == true {
            self.generation += 1
            self.cancelUpload()
            self.cacheDisposable.set(nil)
        }
    }

    private func readCache() {
        guard !self.resources.isEmpty else { self.showCacheError(); return }
        let signal = combineLatest(self.resources.map { self.context.engine.resources.data(id: $0) |> take(1) })
        self.cacheDisposable.set((signal |> deliverOnMainQueue).start(next: { [weak self] values in
            guard let self else { return }
            // Candidate IDs are ordered largest first; incomplete data is never downloaded here.
            let paths = values.filter { $0.isComplete }.map(\.path)
            let generation = self.generation
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                let photo = paths.lazy.compactMap { try? ExteraImageSearchPhoto.load(path: $0) }.first
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.generation == generation else { return }
                    guard let photo else { self.showCacheError(); return }
                    self.show(photo)
                }
            }
        }))
    }

    private func showCacheError() {
        self.status.text = self.text("Extera.ImageCacheUnavailable", "A complete cached image up to 32 MB is required. Let this photo finish loading in the gallery, then reopen Photo Tools.")
    }

    private func show(_ photo: ExteraImageSearchPhoto) {
        self.photo = photo
        self.preview.image = photo.preview
        self.status.text = self.text("Extera.ImageSearchDisclosure", "Search uploads a JPEG copy, resized to at most 1280 pixels, to Yandex. Google Lens, Bing, and TinEye then receive Yandex’s image URL. The upload can make a private photo accessible to those services. Original EXIF and GPS metadata are removed from the uploaded copy. Nothing is uploaded until you confirm a provider.")
        for provider in ExteraImageSearchProvider.allCases {
            let button = self.button(provider.title, action: #selector(self.providerPressed(_:)))
            button.tag = ExteraImageSearchProvider.allCases.firstIndex(of: provider)!
            self.providerButtons.append(button)
            self.stack.addArrangedSubview(button)
        }
        self.stack.addArrangedSubview(self.button(self.text("Extera.ImageCopy", "Copy Image"), action: #selector(self.copyImage)))
        self.stack.addArrangedSubview(self.button(self.text("Extera.ImageCopyFingerprint", "Copy SHA-256"), action: #selector(self.copyFingerprint)))
        let info = UILabel()
        info.numberOfLines = 0
        info.font = .preferredFont(forTextStyle: .footnote)
        info.adjustsFontForContentSizeCategory = true
        info.textColor = .secondaryLabel
        let metadata = photo.metadata.map { $0.0 + ": " + $0.1 }.joined(separator: "\n")
        info.text = "\(photo.width) × \(photo.height) · \(ByteCountFormatter.string(fromByteCount: Int64(photo.byteCount), countStyle: .file))\n\(photo.format)\nSHA-256 (cached file):\n\(photo.sha256)\n\n" + (metadata.isEmpty ? self.text("Extera.ImageNoExif", "No camera EXIF metadata is present in this cached image.") : metadata)
        self.stack.addArrangedSubview(info)
    }

    private func button(_ title: String, action: Selector) -> UIButton {
        let button = UIButton(type: .system)
        button.setTitle(title, for: .normal)
        button.titleLabel?.font = .preferredFont(forTextStyle: .headline)
        button.titleLabel?.adjustsFontForContentSizeCategory = true
        button.titleLabel?.numberOfLines = 0
        button.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
        button.addTarget(self, action: action, for: .touchUpInside)
        return button
    }

    @objc private func providerPressed(_ sender: UIButton) {
        guard self.upload == nil, let photo = self.photo,
              ExteraImageSearchProvider.allCases.indices.contains(sender.tag) else { return }
        let provider = ExteraImageSearchProvider.allCases[sender.tag]
        let alert = UIAlertController(title: provider.title, message: self.text("Extera.ImageSearchConfirm", "Upload the previewed JPEG to Yandex and open the selected search service? Yandex receives the image for every provider; the selected provider receives its Yandex-hosted URL."), preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: self.context.sharedContext.currentPresentationData.with { $0 }.strings.Common_Cancel, style: .cancel))
        alert.addAction(UIAlertAction(title: self.text("Extera.ImageUploadAndSearch", "Upload and Search"), style: .default, handler: { [weak self] _ in
            self?.startUpload(photo: photo, provider: provider)
        }))
        self.present(alert, animated: true)
    }

    private func startUpload(photo: ExteraImageSearchPhoto, provider: ExteraImageSearchProvider) {
        guard self.upload == nil, self.viewIfLoaded?.window != nil, UIApplication.shared.applicationState == .active else { return }
        self.generation += 1
        let generation = self.generation
        self.status.text = self.text("Extera.ImageUploading", "Uploading the confirmed JPEG to Yandex…")
        self.providerButtons.forEach { $0.isEnabled = false }
        self.navigationItem.leftBarButtonItem = UIBarButtonItem(title: self.context.sharedContext.currentPresentationData.with { $0 }.strings.Common_Cancel, style: .plain, target: self, action: #selector(self.cancelUpload))
        self.upload = ExteraImageSearchUpload(jpeg: photo.jpeg, provider: provider, completion: { [weak self] result in
            guard let self, self.generation == generation else { return }
            self.upload = nil
            self.providerButtons.forEach { $0.isEnabled = true }
            self.navigationItem.leftBarButtonItem = nil
            guard self.viewIfLoaded?.window != nil, UIApplication.shared.applicationState == .active else { return }
            switch result {
            case let .success(url):
                self.status.text = self.text("Extera.ImageSearchUploaded", "Image uploaded to Yandex. Search results open in the browser.")
                self.present(SFSafariViewController(url: url), animated: true)
            case .failure:
                self.status.text = self.text("Extera.ImageSearchFailed", "Image search did not return a usable result. The service may require browser verification or may have changed its upload endpoint. You can select a provider to explicitly retry.")
            }
        })
    }

    @objc private func cancelUpload() {
        guard self.upload != nil else { return }
        self.generation += 1
        self.upload?.cancel()
        self.upload = nil
        self.providerButtons.forEach { $0.isEnabled = true }
        self.navigationItem.leftBarButtonItem = nil
        self.status.text = self.text("Extera.ImageSearchCanceled", "Upload canceled. Any bytes already sent may have reached Yandex.")
    }

    @objc private func copyImage() {
        guard let photo = self.photo else { return }
        UIPasteboard.general.setItems([["public.jpeg": photo.jpeg]], options: [.localOnly: true, .expirationDate: Date().addingTimeInterval(120)])
        self.status.text = self.text("Extera.ImageCopied", "Image copied locally for two minutes. The copied JPEG excludes original EXIF and GPS metadata.")
    }

    @objc private func copyFingerprint() {
        guard let photo = self.photo else { return }
        UIPasteboard.general.setItems([["public.utf8-plain-text": photo.sha256]], options: [.localOnly: true, .expirationDate: Date().addingTimeInterval(120)])
        self.status.text = self.text("Extera.ImageFingerprintCopied", "Cached file SHA-256 copied locally for two minutes.")
    }

    @objc private func close() {
        self.generation += 1
        self.cancelUpload()
        self.cacheDisposable.set(nil)
        self.dismiss(animated: true)
    }
}
