import UIKit

/// The rule of exteraGram's `PluginFileViewer`: a plugin file is read inside the app when it is
/// text of at most 512 KiB; anything else is handed to other apps.
enum AyuPluginSourceViewer {
    static let maximumSize = 512 * 1024
    private static let sniffLength = 8192

    /// The file's text, or nil when Android would hand the file to another app instead.
    nonisolated static func text(at url: URL) -> String? {
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]), values.isRegularFile == true,
              let size = values.fileSize, size > 0, size <= self.maximumSize,
              let data = try? Data(contentsOf: url), !data.isEmpty, data.count <= self.maximumSize,
              !data.prefix(self.sniffLength).contains(0) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    /// Android's `PrismaTokenStyles`: the Prism token names that share a colour, with the
    /// 0xAARRGGBB of theme keys `code_keyword`, `code_operator`, `code_constant`, `code_string`,
    /// `code_number`, `code_comment`, `code_function`, first of the light themes (the defaults of
    /// `ThemeColors`), then of the dark ones (`darkblue.attheme`, `night.attheme`). `annotation`
    /// is not Android's: its grammar data gives a Python decorator the alias
    /// `annotation punctuation`, the app's keeps the first name only.
    private static let codeGroups: [(names: [String], light: UInt32, dark: UInt32)] = [
        (["keyword", "important", "builtin", "type", "atrule"], 0xFFE05356, 0xFFFF9380),
        (["operator", "entity", "punctuation", "annotation"], 0xFF4DBBFF, 0x7FFFFFFF),
        (["constant", "boolean", "class-name", "property", "tag", "symbol"], 0xFF7F79F3, 0xFFFF9380),
        (["string", "string-literal", "char", "template-string", "attr-value", "regex", "url", "inserted"], 0xFF37C123, 0xFF88E378),
        (["number"], 0xFF327FE5, 0xFF59DED7),
        (["comment", "block-comment", "comment-multiline", "prolog", "doctype", "cdata", "deleted"], 0x80000000, 0x7FFFFFFF),
        (["function", "function-definition", "function-variable", "function-name", "attr-name", "selector"], 0xFFF28C39, 0xFFFF9380)
    ]

    /// Android cuts the text into code blocks of at most 8192 UTF-16 units, each ending after a
    /// line break when it has one past its first unit. The blocks join into one on the page, but
    /// each takes its font size from its own length.
    static let blockLength = 8192

    static func blocks(of text: String) -> [Range<Int>] {
        let text = text as NSString
        var blocks: [Range<Int>] = []
        var start = 0
        while start < text.length {
            var end = min(text.length, start + self.blockLength)
            if end < text.length {
                let newline = text.range(of: "\n", options: .backwards, range: NSRange(location: 0, length: end)).location
                if newline != NSNotFound, newline > start { end = newline + 1 }
            }
            blocks.append(start..<end)
            start = end
        }
        return blocks
    }

    /// Android's code is 14 dp, one smaller past 80 units, two past 220, three past 500
    /// (`RichPreformattedBlock.getCodeSizeDecrement`).
    static func fontSize(codeLength: Int) -> CGFloat {
        return codeLength > 500 ? 11 : codeLength > 220 ? 12 : codeLength > 80 ? 13 : 14
    }

    /// Android's Instant View page of code blocks: the page is `windowBackgroundWhite`, its text
    /// `windowBackgroundWhiteBlackText`, and the block of code is tinted with
    /// `windowBackgroundWhiteLinkSelection` at alpha 20 of 255.
    static func androidPageColors(_ theme: AyuPluginManagerViewController.EngineTheme) -> (page: UIColor, text: UIColor, block: UIColor) {
        let rgb: [UInt32]
        switch theme {
        case .classic: rgb = [0xFFFFFF, 0x1A1D21, 0x62A9E3]
        case .day: rgb = [0xFFFFFF, 0x333333, 0x62A9E3]
        case .darkBlue: rgb = [0x1D2733, 0xFFFFFF, 0x64B5FD]
        case .night: rgb = [0x181819, 0xFFFFFF, 0x64B5FD]
        }
        let color = { (rgb: UInt32, alpha: CGFloat) in UIColor(red: CGFloat(rgb >> 16 & 0xff) / 255, green: CGFloat(rgb >> 8 & 0xff) / 255, blue: CGFloat(rgb & 0xff) / 255, alpha: alpha) }
        return (color(rgb[0], 1), color(rgb[1], 1), color(rgb[2], 20.0 / 255))
    }

    /// The colour Android gives each Prism token name in `theme`; other names have none.
    static func androidCodeColors(_ theme: AyuPluginManagerViewController.EngineTheme) -> [String: UInt32] {
        let dark = theme == .darkBlue || theme == .night
        var colors: [String: UInt32] = [:]
        for group in self.codeGroups {
            for name in group.names { colors[name] = dark ? group.dark : group.light }
        }
        return colors
    }
}

/// The plugin's code as read-only monospaced text under its file name, in the colours of
/// Android's page for it: an Instant View page whose Python code blocks join into one. Like
/// there, the text is plain until its colours arrive.
@MainActor final class AyuPluginSourceViewController: UIViewController {
    static let textIdentifier = "AyuPluginSource.text"
    static let blockIdentifier = "AyuPluginSource.block"
    /// Android leaves 8 dp of the page above and below the block of code, and the code stands
    /// 16 dp from the block's sides and 12 dp from its top and bottom.
    static let blockGap: CGFloat = 8
    static let codeInsets = UIEdgeInsets(top: 12, left: 16, bottom: 12, right: 16)
    /// Android's `PluginFileViewer` reads every plugin file as Python.
    static let language = "python"
    private let text: String
    private let theme: AyuPluginManagerViewController.EngineTheme?
    private let highlighter: AyuPluginManagerViewController.CodeHighlighter?
    private let block = UIView()

    /// Without `theme` the page takes Android's default light or dark theme, as the banner does.
    init(fileName: String, text: String, theme: AyuPluginManagerViewController.EngineTheme? = nil, highlighter: AyuPluginManagerViewController.CodeHighlighter? = nil) {
        self.text = text
        self.theme = theme
        self.highlighter = highlighter
        super.init(nibName: nil, bundle: nil)
        self.title = fileName
    }

    required init?(coder: NSCoder) { return nil }

    override func loadView() {
        let view = UITextView()
        view.isEditable = false
        let colors = self.pageColors
        view.textColor = colors.text
        view.backgroundColor = colors.page
        let insets = Self.codeInsets
        view.textContainerInset = UIEdgeInsets(top: Self.blockGap + insets.top, left: insets.left, bottom: Self.blockGap + insets.bottom, right: insets.right)
        view.textContainer.lineFragmentPadding = 0
        view.alwaysBounceVertical = true
        view.accessibilityIdentifier = Self.textIdentifier
        view.text = self.text
        view.font = .monospacedSystemFont(ofSize: AyuPluginSourceViewer.fontSize(codeLength: 0), weight: .regular)
        for block in AyuPluginSourceViewer.blocks(of: self.text) {
            let size = AyuPluginSourceViewer.fontSize(codeLength: block.count)
            view.textStorage.addAttribute(.font, value: UIFont.monospacedSystemFont(ofSize: size, weight: .regular), range: NSRange(location: block.lowerBound, length: block.count))
        }
        self.block.backgroundColor = colors.block
        self.block.isUserInteractionEnabled = false
        self.block.accessibilityIdentifier = Self.blockIdentifier
        view.insertSubview(self.block, at: 0)
        self.view = view
    }

    private var pageColors: (page: UIColor, text: UIColor, block: UIColor) {
        if let theme = self.theme { return AyuPluginSourceViewer.androidPageColors(theme) }
        let light = AyuPluginSourceViewer.androidPageColors(.classic), dark = AyuPluginSourceViewer.androidPageColors(.darkBlue)
        let color = { (light: UIColor, dark: UIColor) in UIColor { $0.userInterfaceStyle == .dark ? dark : light } }
        return (color(light.page, dark.page), color(light.text, dark.text), color(light.block, dark.block))
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        guard let page = self.view as? UITextView else { return }
        // The block scrolls with the code, so the page shows above and below it as on Android.
        let frame = CGRect(x: 0, y: Self.blockGap, width: page.bounds.width, height: max(page.contentSize.height - 2 * Self.blockGap, 0))
        if self.block.frame != frame { self.block.frame = frame }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        let theme = self.theme ?? (self.traitCollection.userInterfaceStyle == .dark ? .darkBlue : .classic)
        self.highlighter?(self.text, Self.language, AyuPluginSourceViewer.androidCodeColors(theme)) { [weak self] colors in self?.color(colors) }
    }

    /// Colours the runs in place, so the page keeps its scroll position and selection.
    private func color(_ colors: [(range: Range<Int>, argb: UInt32)]) {
        guard let storage = (self.view as? UITextView)?.textStorage else { return }
        storage.beginEditing()
        for run in colors where run.range.lowerBound >= 0 && run.range.lowerBound < run.range.upperBound && run.range.upperBound <= storage.length {
            let color = UIColor(red: CGFloat(run.argb >> 16 & 0xff) / 255, green: CGFloat(run.argb >> 8 & 0xff) / 255, blue: CGFloat(run.argb & 0xff) / 255, alpha: CGFloat(run.argb >> 24) / 255)
            storage.addAttribute(.foregroundColor, value: color, range: NSRange(location: run.range.lowerBound, length: run.range.count))
        }
        storage.endEditing()
    }
}
