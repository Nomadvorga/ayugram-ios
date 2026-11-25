import AccountContext
import Display
import Foundation
import SGStrings
import SwiftSignalKit
import TelegramCore
import TelegramPresentationData
import UIKit

/// Native setup, progress and share flow. The controller owns cancellation; no
/// export begins until Start is tapped. Push from the parent settings controller.
public func exteraTakeoutController(context: AccountContext) -> ViewController {
    return ExteraTakeoutController(context: context)
}

private final class ExteraTakeoutController: ViewController {
    private let context: AccountContext
    private let content = UIScrollView()
    private let stack = UIStackView()
    private let format = UISegmentedControl(items: ["JSON", "HTML", "JSON + HTML"])
    private let media = UISegmentedControl(items: [])
    private let size = UISegmentedControl(items: ["8 MB", "32 MB", "128 MB", "512 MB"])
    private let dateEnabled = UISwitch()
    private let fromDate = UIDatePicker()
    private let untilDate = UIDatePicker()
    private let leftChannels = UISwitch()
    private var chatSwitches: [(ExteraTakeoutOptions.ChatTypes, UISwitch)] = []
    private let setup = UIStackView()
    private let status = UILabel()
    private let activity = UIActivityIndicatorView(style: .medium)
    private let startButton = UIButton(type: .system)
    private let cancelButton = UIButton(type: .system)
    private let shareButton = UIButton(type: .system)
    private let operation = MetaDisposable()
    private var presentationDisposable: Disposable?
    private var result: ExteraTakeoutResult?
    private var running = false
    private var shared = false
    private var backgroundObserver: NSObjectProtocol?

    init(context: AccountContext) {
        self.context = context
        let data = context.sharedContext.currentPresentationData.with { $0 }
        super.init(navigationBarPresentationData: NavigationBarPresentationData(theme: NavigationBarTheme(rootControllerTheme: data.theme), strings: NavigationBarStrings(presentationStrings: data.strings)))
        self.title = self.text("Title", "Export Cloud Chats")
        self.backgroundObserver = NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self, self.running else { return }
            self.cancelExport()
        }
        self.presentationDisposable = (context.sharedContext.presentationData |> deliverOnMainQueue).start(next: { [weak self] data in
            guard let self else { return }
            self.setNavigationBarPresentationData(NavigationBarPresentationData(theme: NavigationBarTheme(rootControllerTheme: data.theme), strings: NavigationBarStrings(presentationStrings: data.strings)), animated: false)
            if self.isViewLoaded { self.applyTheme(data) }
        })
    }

    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit {
        self.operation.dispose()
        self.presentationDisposable?.dispose()
        // An active share sheet retains its result through its completion closure.
        if !self.shared { self.result?.remove() }
        if let observer = self.backgroundObserver { NotificationCenter.default.removeObserver(observer) }
    }

    private func text(_ key: String, _ fallback: String) -> String {
        return i18n("Extera.Takeout." + key, self.context.sharedContext.currentPresentationData.with { $0 }.strings.baseLanguageCode, fallback)
    }

    override func loadDisplayNode() {
        self.displayNode = ViewControllerTracingNode()
        self.displayNodeDidLoad()
        self.displayNode.view.addSubview(self.content)
        self.content.addSubview(self.stack)
        self.stack.translatesAutoresizingMaskIntoConstraints = false
        self.stack.axis = .vertical
        self.stack.spacing = 14
        NSLayoutConstraint.activate([
            self.stack.leadingAnchor.constraint(equalTo: self.content.contentLayoutGuide.leadingAnchor, constant: 16),
            self.stack.trailingAnchor.constraint(equalTo: self.content.contentLayoutGuide.trailingAnchor, constant: -16),
            self.stack.topAnchor.constraint(equalTo: self.content.contentLayoutGuide.topAnchor, constant: 16),
            self.stack.bottomAnchor.constraint(equalTo: self.content.contentLayoutGuide.bottomAnchor, constant: -24),
            self.stack.widthAnchor.constraint(equalTo: self.content.frameLayoutGuide.widthAnchor, constant: -32)
        ])
        self.setup.axis = .vertical
        self.setup.spacing = 12
        self.stack.addArrangedSubview(self.setup)
        self.setup.addArrangedSubview(self.label(self.text("Scope", "Export cloud chat histories directly from Telegram, including messages absent from this device. Secret chats, profile data, contacts, sessions and stories are excluded. Some message details and media types are unsupported; the archive lists omissions. Telegram may require an authorization delay. Keep this screen open and the app active.")))
        let choices: [(ExteraTakeoutOptions.ChatTypes, String, String)] = [
            (.personal, "Personal", "Personal chats"), (.bots, "Bots", "Bot chats"),
            (.privateGroups, "PrivateGroups", "Private groups"), (.publicGroups, "PublicGroups", "Public groups"),
            (.privateChannels, "PrivateChannels", "Private channels"), (.publicChannels, "PublicChannels", "Public channels")
        ]
        for (type, key, fallback) in choices {
            let toggle = UISwitch()
            toggle.isOn = type == .personal || type == .privateGroups
            self.chatSwitches.append((type, toggle))
            self.setup.addArrangedSubview(self.row(self.text(key, fallback), control: toggle))
        }
        self.setup.addArrangedSubview(self.row(self.text("LeftChannels", "Include left groups and channels"), control: self.leftChannels))
        self.setup.addArrangedSubview(self.label(self.text("Format", "Output format")))
        self.format.selectedSegmentIndex = 0
        self.setup.addArrangedSubview(self.format)
        for (index, value) in [self.text("NoMedia", "No media"), self.text("Photos", "Photos"), self.text("Files", "Photos + files")].enumerated() { self.media.insertSegment(withTitle: value, at: index, animated: false) }
        self.media.selectedSegmentIndex = 0
        self.setup.addArrangedSubview(self.label(self.text("Media", "Download media")))
        self.setup.addArrangedSubview(self.media)
        self.setup.addArrangedSubview(self.label(self.text("FileSize", "Maximum size per file")))
        self.size.selectedSegmentIndex = 0
        self.setup.addArrangedSubview(self.size)
        self.setup.addArrangedSubview(self.label(self.text("Storage", "Export content is limited to 2 GB. Packaging needs additional free space of roughly the same size. Larger exports stop explicitly; shorten the date range or select fewer chat types.")))
        self.setup.addArrangedSubview(self.row(self.text("DateRange", "Limit dates"), control: self.dateEnabled))
        self.dateEnabled.addTarget(self, action: #selector(self.updateDates), for: .valueChanged)
        for picker in [self.fromDate, self.untilDate] {
            picker.datePickerMode = .date
            picker.maximumDate = Date()
            if #available(iOS 13.4, *) { picker.preferredDatePickerStyle = .compact }
            picker.isEnabled = false
        }
        self.fromDate.date = Calendar.current.date(byAdding: .month, value: -1, to: Date()) ?? Date()
        self.setup.addArrangedSubview(self.row(self.text("From", "From (inclusive)"), control: self.fromDate))
        self.setup.addArrangedSubview(self.row(self.text("Until", "Until (exclusive)"), control: self.untilDate))
        self.status.numberOfLines = 0
        self.status.font = UIFont.preferredFont(forTextStyle: .body)
        self.status.adjustsFontForContentSizeCategory = true
        self.status.accessibilityTraits = .updatesFrequently
        self.stack.addArrangedSubview(self.status)
        self.stack.addArrangedSubview(self.activity)
        self.button(self.startButton, title: self.text("Start", "Start Export"), selector: #selector(self.startExport))
        self.button(self.cancelButton, title: self.text("Cancel", "Cancel Export"), selector: #selector(self.cancelExport))
        self.button(self.shareButton, title: self.text("Share", "Save or Share Archive"), selector: #selector(self.shareArchive))
        self.cancelButton.isHidden = true
        self.shareButton.isHidden = true
        self.applyTheme(self.context.sharedContext.currentPresentationData.with { $0 })
    }

    private func label(_ text: String) -> UILabel {
        let label = UILabel()
        label.text = text
        label.numberOfLines = 0
        label.font = UIFont.preferredFont(forTextStyle: .body)
        label.adjustsFontForContentSizeCategory = true
        return label
    }

    private func row(_ title: String, control: UIView) -> UIView {
        let label = self.label(title)
        control.accessibilityLabel = title
        control.setContentHuggingPriority(.required, for: .horizontal)
        let row = UIStackView(arrangedSubviews: [label, control])
        row.axis = .horizontal
        row.alignment = .center
        row.spacing = 8
        row.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
        return row
    }

    private func button(_ button: UIButton, title: String, selector: Selector) {
        button.setTitle(title, for: .normal)
        button.titleLabel?.font = UIFont.preferredFont(forTextStyle: .headline)
        button.titleLabel?.adjustsFontForContentSizeCategory = true
        button.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
        button.addTarget(self, action: selector, for: .touchUpInside)
        self.stack.addArrangedSubview(button)
    }

    private func applyTheme(_ data: PresentationData) {
        self.displayNode.backgroundColor = data.theme.list.blocksBackgroundColor
        self.content.tintColor = data.theme.list.itemAccentColor
        func apply(_ view: UIView) {
            if let label = view as? UILabel { label.textColor = data.theme.list.itemPrimaryTextColor }
            for child in view.subviews { apply(child) }
        }
        apply(self.stack)
    }

    override func containerLayoutUpdated(_ layout: ContainerViewLayout, transition: ContainedViewLayoutTransition) {
        super.containerLayoutUpdated(layout, transition: transition)
        let top = self.navigationLayout(layout: layout).navigationFrame.maxY
        let bottom = layout.insets(options: [.input]).bottom
        let side = layout.sideInsets(forBandFrom: top, to: layout.size.height - bottom)
        transition.updateFrame(view: self.content, frame: CGRect(x: side.left, y: top, width: max(0, layout.size.width - side.left - side.right), height: max(0, layout.size.height - top - bottom)))
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if self.running, self.viewIfLoaded?.window == nil { self.cancelExport() }
    }

    @objc private func updateDates() { self.fromDate.isEnabled = self.dateEnabled.isOn; self.untilDate.isEnabled = self.dateEnabled.isOn }

    private func setRunning(_ value: Bool) {
        self.running = value
        self.setup.isUserInteractionEnabled = !value
        self.setup.alpha = value ? 0.5 : 1
        self.startButton.isHidden = value
        self.cancelButton.isHidden = !value
        if value { self.activity.startAnimating() } else { self.activity.stopAnimating() }
    }

    @objc private func startExport() {
        guard !self.running else { return }
        var options = ExteraTakeoutOptions()
        options.chatTypes = []
        for (type, toggle) in self.chatSwitches where toggle.isOn { options.chatTypes.insert(type) }
        options.format = ExteraTakeoutOptions.Format(rawValue: self.format.selectedSegmentIndex) ?? .json
        options.media = ExteraTakeoutOptions.Media(rawValue: self.media.selectedSegmentIndex) ?? .none
        options.includeLeftChannels = self.leftChannels.isOn
        options.maximumFileSize = Int64([8, 32, 128, 512][max(0, self.size.selectedSegmentIndex)]) * 1024 * 1024
        if self.dateEnabled.isOn {
            let start = Calendar.current.startOfDay(for: self.fromDate.date).timeIntervalSince1970
            let end = Calendar.current.startOfDay(for: self.untilDate.date).timeIntervalSince1970
            guard start >= 0, end > start, end < Double(Int32.max) else { self.showError(ExteraTakeoutError.invalidOptions); return }
            options.fromTimestamp = Int32(start)
            options.untilTimestamp = Int32(end)
        }
        guard !options.chatTypes.isEmpty else { self.showError(ExteraTakeoutError.invalidOptions); return }
        self.result?.remove(); self.result = nil
        self.shareButton.isHidden = true
        self.setRunning(true)
        self.operation.set((self.context.engine.messages.exportAccountTakeout(options: options) |> deliverOnMainQueue).start(next: { [weak self] event in
            guard let self else { return }
            switch event {
            case let .progress(progress): self.showProgress(progress)
            case let .completed(result):
                self.setRunning(false)
                self.result = result
                self.shareButton.isHidden = false
                self.status.text = self.text("Completed", "Export ready") + "\n\(result.messages) " + self.text("Messages", "messages") + " · \(result.skippedMedia) " + self.text("Skipped", "media items omitted (see archive)")
                self.shareArchive()
            }
        }, error: { [weak self] error in
            guard let self else { return }
            self.setRunning(false)
            self.status.text = self.text("Failed", "Export failed. No completed archive was produced.")
            self.showError(error)
        }))
    }

    private func showProgress(_ progress: ExteraTakeoutProgress) {
        let phase: String
        switch progress.phase {
        case .authorizing: phase = self.text("Authorizing", "Authorizing takeout session…")
        case .listingChats: phase = self.text("Listing", "Finding chats on Telegram…")
        case .exportingHistory: phase = self.text("History", "Exporting server history…")
        case .downloadingMedia: phase = self.text("Downloading", "Downloading media…")
        case .finishing: phase = self.text("Finishing", "Closing takeout session…")
        case .packaging: phase = self.text("Packaging", "Packaging archive…")
        }
        let bytes = ByteCountFormatter.string(fromByteCount: progress.bytesWritten, countStyle: .file)
        self.status.text = "\(phase)\n\(progress.chatTitle)\n\(progress.completedChats)/\(progress.totalChats) " + self.text("Chats", "chat segments") + " · \(progress.messages) " + self.text("Messages", "messages") + "\n\(bytes) · \(progress.mediaFiles) " + self.text("Downloaded", "media files") + " · \(progress.skippedMedia) " + self.text("Skipped", "media items omitted (see archive)")
    }

    @objc private func cancelExport() {
        self.operation.set(nil)
        self.setRunning(false)
        self.status.text = self.text("Cancelled", "Export cancelled. Temporary files were removed and session cleanup was requested.")
    }

    @objc private func shareArchive() {
        guard !self.shared, let result = self.result, self.viewIfLoaded?.window != nil else { return }
        self.shared = true
        let share = UIActivityViewController(activityItems: [result.archiveURL], applicationActivities: nil)
        if let popover = share.popoverPresentationController {
            popover.sourceView = self.shareButton
            popover.sourceRect = self.shareButton.bounds
        }
        share.completionWithItemsHandler = { [weak self, result] _, _, _, _ in
            result.remove()
            DispatchQueue.main.async { self?.result = nil; self?.shared = false; self?.shareButton.isHidden = true }
        }
        self.present(share, animated: true)
    }

    private func showError(_ error: Error) {
        let alert = UIAlertController(title: self.text("Error", "Export Error"), message: error.localizedDescription, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: self.text("OK", "OK"), style: .default))
        self.present(alert, animated: true)
    }
}
