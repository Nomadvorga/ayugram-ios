import Foundation
import QuartzCore
import UIKit
import UIKit.UIGestureRecognizerSubclass

/// View members beyond the base registry of `AyuPluginNativeHost`: text metrics, long clicks,
/// focus listeners, weight sums, indeterminate progress and extended backgrounds. `prepare` and
/// `read` run on the host worker; everything taking a view runs on main.
enum AyuBridgeViewMembers {
    private static let textView = "android.widget.TextView"
    private static let button = AyuBridgeButtonDefaults.className
    private static let editText = "android.widget.EditText"
    private static let boldCursorEditText = "org.telegram.ui.Components.EditTextBoldCursor"
    private static let progressBar = "android.widget.ProgressBar"
    private static let linearLayout = "android.widget.LinearLayout"
    private static let gridLayout = AyuBridgeGridLayout.className
    private static let colorStateList = "android.content.res.ColorStateList"

    /// Classes that implement each member; a member missing here is one every view class has.
    private static let classes: [String: Set<String>] = [
        "setIncludeFontPadding": [textView, button, editText, boldCursorEditText], "getIncludeFontPadding": [textView, button, editText, boldCursorEditText],
        "setLineSpacing": [textView, button, editText, boldCursorEditText], "getLineSpacingExtra": [textView, button, editText, boldCursorEditText], "getLineSpacingMultiplier": [textView, button, editText, boldCursorEditText],
        "setLetterSpacing": [textView, button, editText, boldCursorEditText], "getLetterSpacing": [textView, button, editText, boldCursorEditText],
        "setMinHeight": [textView, button, editText, boldCursorEditText], "setMinWidth": [textView, button, editText, boldCursorEditText],
        "getMinHeight": [textView, button, editText, boldCursorEditText], "getMinWidth": [textView, button, editText, boldCursorEditText],
        "setTextIsSelectable": [textView, button], "isTextSelectable": [textView, button],
        "setShadowLayer": [textView, button], "getShadowRadius": [textView, button], "getShadowDx": [textView, button], "getShadowDy": [textView, button], "getShadowColor": [textView, button],
        "setSelectAllOnFocus": [editText, boldCursorEditText], "setCursorVisible": [editText, boldCursorEditText], "isCursorVisible": [editText, boldCursorEditText],
        "setOnFocusChangeListener": [editText, boldCursorEditText],
        "setCursorColor": [boldCursorEditText], "getCursorColor": [boldCursorEditText], "setCursorSize": [boldCursorEditText],
        "setCursorWidth": [boldCursorEditText], "setLineColors": [boldCursorEditText],
        "setWeightSum": [linearLayout], "getWeightSum": [linearLayout],
        "setColumnCount": [gridLayout], "getColumnCount": [gridLayout], "setRowCount": [gridLayout], "getRowCount": [gridLayout],
        "setAlignmentMode": [gridLayout], "getAlignmentMode": [gridLayout],
        "setIndeterminate": [progressBar], "isIndeterminate": [progressBar],
        "setIndeterminateTintList": [progressBar], "setProgressBackgroundTintList": [progressBar],
        "setAllCaps": [textView, button], "isAllCaps": [textView, button],
    ]

    /// Members of this file that `className` does not have.
    static func unavailable(for className: String) -> Set<String> {
        Set(self.classes.compactMap { $0.value.contains(className) ? nil : $0.key })
    }

    struct Prepared {
        var method: String
        var arguments: [AyuBridgeValue]
        /// Worker-side view state to store (nil removes the key).
        var fields: [String: AyuBridgeValue?] = [:]
    }

    private static func flag(_ args: [AyuBridgeValue], _ what: String) throws -> Bool {
        guard let value = args.first?.bool else { throw AyuBridgeFailure("invalid_arguments", "Expected a boolean for " + what) }
        return value
    }

    /// An Android colour int, as Python passes it signed or unsigned; stored signed.
    private static func argb(_ value: AyuBridgeValue, _ what: String) throws -> Int64 {
        guard let color = value.integer, Int32(exactly: color) != nil || UInt32(exactly: color) != nil else {
            throw AyuBridgeFailure("invalid_arguments", "Expected a colour for " + what)
        }
        return Int64(Int32(truncatingIfNeeded: color))
    }

    private static func tint(_ value: AyuBridgeValue, _ what: String, resolve: (AyuBridgeValue) throws -> AyuBridgeAdapterSnapshot) throws -> AyuBridgeValue {
        if value == .null { return .null }
        let snapshot = try resolve(value)
        guard snapshot.className == self.colorStateList, let color = snapshot.state["color"]?.integer,
              (Int64(Int32.min)...Int64(Int32.max)).contains(color) else {
            throw AyuBridgeFailure.unsupported(what + " ColorStateList")
        }
        return .integer(color)
    }

    /// Validates a member of this file and turns it into its UI command; nil for any other method.
    /// `callback` registers a listener (a callable or a proxy of the named method) and returns its id.
    static func prepare(method: String, className: String, fields: [String: AyuBridgeValue], args: [AyuBridgeValue],
                        resolve: (AyuBridgeValue) throws -> AyuBridgeAdapterSnapshot,
                        callback: (AyuBridgeValue, String) throws -> String) throws -> Prepared? {
        switch method {
        case "setIncludeFontPadding":
            // UIKit text has no font padding: it is always measured from ascent to descent, which
            // is what Android does for `false`. The flag is kept for `getIncludeFontPadding`.
            return Prepared(method: method, arguments: [], fields: ["m_font_padding": .bool(try self.flag(args, method))])
        case "setLineSpacing":
            guard let add = args[0].number, add.isFinite, abs(add) <= 100_000,
                  let multiplier = args[1].number, multiplier.isFinite, (0...100).contains(multiplier) else {
                throw AyuBridgeFailure("invalid_arguments", "Invalid line spacing")
            }
            return Prepared(method: method, arguments: [.number(add), .number(multiplier)],
                            fields: ["m_line_extra": .number(add), "m_line_multiplier": .number(multiplier)])
        case "setLetterSpacing":
            guard let spacing = args[0].number, spacing.isFinite, abs(spacing) <= 100 else {
                throw AyuBridgeFailure("invalid_arguments", "Invalid letter spacing")
            }
            return Prepared(method: method, arguments: [.number(spacing)], fields: ["m_letter_spacing": .number(spacing)])
        case "setMinHeight", "setMinWidth":
            guard let value = args[0].integer, Int32(exactly: value) != nil else {
                throw AyuBridgeFailure("invalid_arguments", "Invalid minimum text size")
            }
            return Prepared(method: method, arguments: [.integer(min(value, 100_000))],
                            fields: [method == "setMinHeight" ? "m_min_height" : "m_min_width": .integer(value)])
        case "setTextIsSelectable":
            let selectable = try self.flag(args, method)
            return Prepared(method: method, arguments: [.bool(selectable)], fields: ["m_selectable": .bool(selectable)])
        case "setShadowLayer":
            guard let radius = args[0].number, let dx = args[1].number, let dy = args[2].number, let color = args[3].integer,
                  [radius, dx, dy].allSatisfy({ $0.isFinite && abs($0) <= 100_000 }), Int32(exactly: color) != nil || UInt32(exactly: color) != nil else {
                throw AyuBridgeFailure("invalid_arguments", "Invalid shadow layer")
            }
            return Prepared(method: method, arguments: [.number(radius), .number(dx), .number(dy), .integer(color)],
                            fields: ["m_shadow_radius": .number(radius), "m_shadow_dx": .number(dx), "m_shadow_dy": .number(dy),
                                     "m_shadow_color": .integer(Int64(Int32(truncatingIfNeeded: color)))])
        case "setSelectAllOnFocus":
            return Prepared(method: method, arguments: [.bool(try self.flag(args, method))])
        case "setCursorVisible":
            let visible = try self.flag(args, method)
            return Prepared(method: method, arguments: [.bool(visible)], fields: ["m_cursor_visible": .bool(visible)])
        case "setCursorColor":
            return Prepared(method: method, arguments: [.integer(try self.argb(args[0], method))],
                            fields: ["m_cursor_color": .integer(try self.argb(args[0], method))])
        case "setCursorSize":
            guard let size = args[0].integer, (0...10_000).contains(size) else {
                throw AyuBridgeFailure("invalid_arguments", "Invalid cursor size")
            }
            return Prepared(method: method, arguments: [.integer(size)])
        case "setCursorWidth":
            guard let width = args[0].number, width.isFinite, (0...1_000).contains(width) else {
                throw AyuBridgeFailure("invalid_arguments", "Invalid cursor width")
            }
            return Prepared(method: method, arguments: [.number(width)])
        case "setLineColors":
            return Prepared(method: method, arguments: try args.map { .integer(try self.argb($0, method)) })
        case "setOnLongClickListener", "setOnFocusChangeListener":
            if args[0] == .null { return Prepared(method: method, arguments: [.null]) }
            let id = try callback(args[0], method == "setOnLongClickListener" ? "onLongClick" : "onFocusChange")
            // Android makes a view long-clickable when it gets a long-click listener.
            return Prepared(method: method, arguments: [.object(["$callback": .string(id)])],
                            fields: method == "setOnLongClickListener" ? ["m_long_clickable": .bool(true)] : [:])
        case "setLongClickable":
            let clickable = try self.flag(args, method)
            return Prepared(method: method, arguments: [.bool(clickable)], fields: ["m_long_clickable": .bool(clickable)])
        case "setWeightSum":
            guard let sum = args[0].number, sum.isFinite, abs(sum) <= 1_000_000 else {
                throw AyuBridgeFailure("invalid_arguments", "Invalid weight sum")
            }
            return Prepared(method: method, arguments: [.number(max(0, sum))], fields: ["m_weight_sum": .number(max(0, sum))])
        case "setAllCaps":
            let caps = try self.flag(args, method)
            return Prepared(method: method, arguments: [.bool(caps)], fields: ["m_all_caps": .bool(caps)])
        case "setColumnCount", "setRowCount":
            let count = try AyuBridgeGridLayout.count(args.first)
            return Prepared(method: method, arguments: [.integer(count)], fields: [method == "setRowCount" ? "m_grid_rows" : "m_grid_columns": .integer(count)])
        case "setAlignmentMode":
            guard let mode = args.first?.integer, AyuBridgeGridLayout.AlignmentMode(rawValue: Int(clamping: mode)) != nil else {
                throw AyuBridgeFailure("invalid_arguments", "Invalid GridLayout alignment mode")
            }
            return Prepared(method: method, arguments: [.integer(mode)], fields: ["m_grid_alignment": .integer(mode)])
        case "setIndeterminate":
            let indeterminate = try self.flag(args, method)
            // A ProgressBar of the default (circular) style is indeterminate only: Android ignores the call.
            guard fields["progress_mode"] == .string("horizontal") else { return Prepared(method: "setIncludeFontPadding", arguments: [], fields: [:]) }
            return Prepared(method: method, arguments: [.bool(indeterminate)], fields: ["m_indeterminate": .bool(indeterminate)])
        case "setIndeterminateTintList", "setProgressBackgroundTintList":
            return Prepared(method: method, arguments: [try self.tint(args[0], "ProgressBar." + method, resolve: resolve)])
        default:
            return nil
        }
    }

    /// Getters answered from the worker-side view state; nil for any other method.
    static func read(method: String, fields: [String: AyuBridgeValue], args: [AyuBridgeValue]) throws -> AyuBridgeValue? {
        let value: AyuBridgeValue
        switch method {
        case "getIncludeFontPadding": value = fields["m_font_padding"] ?? .bool(true)
        case "getLineSpacingExtra": value = fields["m_line_extra"] ?? .number(0)
        case "getLineSpacingMultiplier": value = fields["m_line_multiplier"] ?? .number(1)
        case "getLetterSpacing": value = fields["m_letter_spacing"] ?? .number(0)
        // `getMinHeight`/`getMinWidth` are -1 until a pixel minimum is set.
        case "getMinHeight": value = fields["m_min_height"] ?? .integer(-1)
        case "getMinWidth": value = fields["m_min_width"] ?? .integer(-1)
        case "isTextSelectable": value = fields["m_selectable"] ?? .bool(false)
        case "getShadowRadius": value = fields["m_shadow_radius"] ?? .number(0)
        case "getShadowDx": value = fields["m_shadow_dx"] ?? .number(0)
        case "getShadowDy": value = fields["m_shadow_dy"] ?? .number(0)
        case "getShadowColor": value = fields["m_shadow_color"] ?? .integer(0)
        case "isCursorVisible": value = fields["m_cursor_visible"] ?? .bool(true)
        // The colour of the cursor drawable EditTextBoldCursor creates for itself.
        case "getCursorColor": value = fields["m_cursor_color"] ?? .integer(Int64(Int32(bitPattern: 0xff54_a1db)))
        case "isLongClickable": value = fields["m_long_clickable"] ?? .bool(false)
        case "getWeightSum": value = fields["m_weight_sum"] ?? .number(0)
        case "isAllCaps": value = fields["m_all_caps"] ?? .bool(false)
        case "getColumnCount": value = fields["m_grid_columns"] ?? .integer(AyuBridgeGridLayout.undefined)
        case "getRowCount": value = fields["m_grid_rows"] ?? .integer(AyuBridgeGridLayout.undefined)
        case "getAlignmentMode": value = fields["m_grid_alignment"] ?? .integer(Int64(AyuBridgeGridLayout.AlignmentMode.margins.rawValue))
        case "isIndeterminate": value = fields["progress_mode"] == .string("horizontal") ? fields["m_indeterminate"] ?? .bool(false) : .bool(true)
        default: return nil
        }
        guard args.isEmpty else { throw AyuBridgeFailure("invalid_arguments", method + " takes no arguments") }
        return value
    }

    // MARK: Main thread

    private static let textCommands: Set<String> = ["setText", "setTextSize", "setTextSizeSP", "setTextSizePixels", "setTypefaceStyle", "setTextColor",
                                                    "setGravity", "setTextAlignment", "setEllipsize", "setMaxLines", "setSingleLine"]

    private static func color(_ raw: Int64) -> UIColor {
        let bits = UInt32(truncatingIfNeeded: raw)
        return UIColor(red: CGFloat((bits >> 16) & 255) / 255, green: CGFloat((bits >> 8) & 255) / 255,
                       blue: CGFloat(bits & 255) / 255, alpha: CGFloat((bits >> 24) & 255) / 255)
    }

    /// Runs before the base command switch; true when the command is one of this file's.
    @MainActor static func apply(_ command: AyuBridgeUI.Command, to view: AyuBridgeView) -> Bool {
        let args = command.arguments, members = view.members
        switch command.method {
        case "setIncludeFontPadding":
            break
        case "setLineSpacing":
            members.lineSpacingExtra = CGFloat(args[0].number ?? 0)
            members.lineSpacingMultiplier = CGFloat(args[1].number ?? 1)
            members.restyleText(view); view.invalidateBridgeLayout()
        case "setLetterSpacing":
            members.letterSpacing = CGFloat(args[0].number ?? 0)
            members.restyleText(view); view.invalidateBridgeLayout()
        case "setMinHeight":
            // A pixel minimum replaces a minimum in lines, and the reverse (see `setMinLines` below).
            members.textMinimumHeight = CGFloat(max(0, args[0].integer ?? 0)); view.invalidateBridgeLayout()
        case "setMinWidth":
            members.textMinimumWidth = CGFloat(max(0, args[0].integer ?? 0)); view.invalidateBridgeLayout()
        case "setMinLines":
            members.textMinimumHeight = nil
            return false
        case "setTextIsSelectable":
            members.setTextSelectable(args[0].bool ?? false, view: view)
        case "setShadowLayer":
            guard let layer = view.label?.layer else { break }
            let radius = args[0].number ?? 0
            // Android draws no shadow for a zero radius. Its blur sigma is `0.57735 * radius + 0.5`
            // (Skia), and a layer's `shadowRadius` is a sigma.
            layer.shadowOpacity = radius > 0 ? 1 : 0
            layer.shadowRadius = radius > 0 ? CGFloat(0.57735 * radius + 0.5) : 0
            layer.shadowOffset = CGSize(width: args[1].number ?? 0, height: args[2].number ?? 0)
            layer.shadowColor = self.color(args[3].integer ?? 0).cgColor
            members.layoutSelectableText(view)
        case "setSelectAllOnFocus":
            members.selectAllOnFocus = args[0].bool ?? false; members.observeEditing(view)
        case "setCursorVisible":
            if let field = view.textField as? AyuBridgeBoldCursorField {
                field.cursorVisible = args[0].bool != false
            } else {
                // The caret takes the tint color; nil restores the inherited one.
                view.textField?.tintColor = args[0].bool == false ? .clear : nil
            }
        case "setCursorColor":
            (view.textField as? AyuBridgeBoldCursorField)?.cursorColor = self.color(args[0].integer ?? 0)
        case "setCursorSize":
            (view.textField as? AyuBridgeBoldCursorField)?.cursorSize = CGFloat(args[0].integer ?? 0)
        case "setCursorWidth":
            (view.textField as? AyuBridgeBoldCursorField)?.cursorWidth = CGFloat(args[0].number ?? 0)
        case "setLineColors":
            let line = args[0].integer ?? 0
            (view.textField as? AyuBridgeBoldCursorField)?.setLineColors(line == 0 ? nil : self.color(line), active: self.color(args[1].integer ?? 0))
            view.setNeedsLayout()
        case "setOnFocusChangeListener":
            members.focusCallback = args[0]["$callback"].string; members.observeEditing(view)
        case "setOnLongClickListener":
            members.longClickCallback = args[0]["$callback"].string
            if members.longClickCallback != nil { members.longClickable = true }
            members.updateLongPress(view)
        case "setLongClickable":
            members.longClickable = args[0].bool ?? false; members.updateLongPress(view)
        case "setWeightSum":
            members.weightSum = CGFloat(args[0].number ?? 0); view.invalidateBridgeLayout()
        case "setAllCaps":
            view.setBridgeAllCaps(args[0].bool ?? false); members.restyleText(view)
        case "setColumnCount":
            members.gridColumnCount = AyuBridgeGridLayout.defined(args[0]); view.invalidateBridgeLayout()
        case "setRowCount":
            members.gridRowCount = AyuBridgeGridLayout.defined(args[0]); view.invalidateBridgeLayout()
        case "setAlignmentMode":
            members.gridAlignment = AyuBridgeGridLayout.AlignmentMode(rawValue: Int(args[0].integer ?? 1)) ?? .margins; view.invalidateBridgeLayout()
        case "setIndeterminate":
            members.setIndeterminate(args[0].bool ?? false, view: view)
        case "setIndeterminateTintList":
            members.indeterminateTint = args[0].integer.map(self.color)
            if let indicator = view.indeterminateProgressBar {
                if members.defaultIndicatorColor == nil { members.defaultIndicatorColor = indicator.color }
                indicator.color = members.indeterminateTint ?? members.defaultIndicatorColor
            }
            members.layoutIndeterminate(view)
        case "setProgressBackgroundTintList":
            view.progressBar?.trackTintColor = args[0].integer.map(self.color)
        case "setBackgroundStyle":
            members.pendingBackground = AyuBridgeDrawableStyle(style: args[0].object ?? [:])
            return false
        case "setBackgroundColor", "clearBackground":
            members.pendingBackground = nil
            return false
        default:
            return false
        }
        return true
    }

    /// Runs after a base command was applied.
    @MainActor static func didApply(_ command: AyuBridgeUI.Command, to view: AyuBridgeView) {
        let members = view.members
        switch command.method {
        case "setBackgroundStyle", "setBackgroundColor", "clearBackground":
            members.setBackground(members.pendingBackground, view: view)
        case "setOnClickListener":
            members.updateLongPress(view)
        case "setProgress", "setMax":
            if members.indeterminate { view.progressBar?.setProgress(0, animated: false) }
        default:
            if self.textCommands.contains(command.method) { members.restyleText(view) }
        }
    }

    /// Runs at the end of the view's layout pass.
    @MainActor static func didLayout(_ view: AyuBridgeView) {
        let members = view.members
        if let renderer = members.drawable {
            renderer.layout(bounds: view.bounds)
            if view.bridgeClipToOutline, view.bridgeOutlineProviderIsBackground, let mask = view.layer.mask as? CAShapeLayer {
                mask.path = renderer.style.outline(in: CGRect(origin: .zero, size: view.bounds.size))
            }
        }
        members.layoutSelectableText(view)
        members.layoutIndeterminate(view)
    }
}

/// Per-view state of `AyuBridgeViewMembers`. Main-only.
@MainActor final class AyuBridgeViewMemberState {
    var lineSpacingExtra: CGFloat = 0
    var lineSpacingMultiplier: CGFloat = 1
    var letterSpacing: CGFloat = 0
    private var textIsStyled = false
    /// `TextView.setMinHeight`: replaces the minimum in lines while set.
    var textMinimumHeight: CGFloat?
    var textMinimumWidth: CGFloat = 0
    /// `LinearLayout.setWeightSum`; 0 means the sum of the children's weights.
    var weightSum: CGFloat = 0
    var gridRowCount: Int?
    var gridColumnCount: Int?
    var gridAlignment = AyuBridgeGridLayout.AlignmentMode.margins
    var longClickCallback: String?
    var longClickable = false
    private var longPress: UILongPressGestureRecognizer?
    var focusCallback: String?
    var selectAllOnFocus = false
    private var observesEditing = false
    private var selectableText: UITextView?
    var pendingBackground: AyuBridgeDrawableStyle?
    private(set) var drawable: AyuBridgeDrawableRenderer?
    private var press: AyuBridgePressRecognizer?
    private(set) var indeterminate = false
    var indeterminateTint: UIColor?
    var defaultIndicatorColor: UIColor?
    private var indeterminateBar: CALayer?

    // MARK: Text

    /// Line and letter spacing need attributed text; any plain assignment by the base view drops
    /// it, so this runs again after every text command.
    func restyleText(_ view: AyuBridgeView) {
        if let field = view.textField {
            let size = field.font?.pointSize ?? UIFont.systemFontSize
            if self.letterSpacing != 0 { field.defaultTextAttributes[.kern] = self.letterSpacing * size }
            else { field.defaultTextAttributes[.kern] = nil }
        }
        guard let label = view.label else { return }
        let font: UIFont = label.font ?? .systemFont(ofSize: UIFont.labelFontSize)
        // Android adds `lineHeight * (multiplier - 1) + extra` after every line but the last.
        let extra = font.lineHeight * (self.lineSpacingMultiplier - 1) + self.lineSpacingExtra
        guard self.letterSpacing != 0 || extra != 0 else {
            if self.textIsStyled {
                self.textIsStyled = false
                let text = label.text
                label.attributedText = nil
                label.text = text
            }
            self.layoutSelectableText(view)
            return
        }
        let paragraph = NSMutableParagraphStyle()
        if extra >= 0 {
            paragraph.lineSpacing = extra
        } else {
            // UIKit has no negative spacing between lines: every line is made shorter instead,
            // which also shortens the last one.
            let height = max(0, font.lineHeight + extra)
            paragraph.minimumLineHeight = height
            paragraph.maximumLineHeight = height
        }
        let alignment = label.textAlignment, lineBreakMode = label.lineBreakMode
        var attributes: [NSAttributedString.Key: Any] = [.font: font, .paragraphStyle: paragraph]
        if let color = label.textColor { attributes[.foregroundColor] = color }
        // Android's letter spacing is in ems of the text size.
        if self.letterSpacing != 0 { attributes[.kern] = self.letterSpacing * font.pointSize }
        label.attributedText = NSAttributedString(string: label.text ?? "", attributes: attributes)
        label.textAlignment = alignment
        label.lineBreakMode = lineBreakMode
        self.textIsStyled = true
        self.layoutSelectableText(view)
    }

    /// A selectable TextView shows its text in a non-editable text view laid over the label,
    /// which keeps measuring; UILabel itself cannot select a range.
    func setTextSelectable(_ selectable: Bool, view: AyuBridgeView) {
        guard let label = view.label else { return }
        if !selectable {
            self.selectableText?.removeFromSuperview()
            self.selectableText = nil
            label.isHidden = false
            return
        }
        if self.selectableText == nil {
            let text = UITextView()
            text.isEditable = false
            text.isSelectable = true
            text.isScrollEnabled = false
            text.backgroundColor = .clear
            text.textContainer.lineFragmentPadding = 0
            text.textContainerInset = .zero
            view.insertSubview(text, aboveSubview: label)
            self.selectableText = text
        }
        label.isHidden = true
        self.layoutSelectableText(view)
    }

    func layoutSelectableText(_ view: AyuBridgeView) {
        guard let text = self.selectableText, let label = view.label else { return }
        text.frame = label.frame
        text.attributedText = label.attributedText
        text.textAlignment = label.textAlignment
        text.textContainer.maximumNumberOfLines = label.numberOfLines
        text.textContainer.lineBreakMode = label.lineBreakMode
        text.layer.shadowOpacity = label.layer.shadowOpacity
        text.layer.shadowRadius = label.layer.shadowRadius
        text.layer.shadowOffset = label.layer.shadowOffset
        text.layer.shadowColor = label.layer.shadowColor
        // The label places its text by gravity; the copy starts where the label would draw.
        let drawn = label.textRect(forBounds: label.bounds, limitedToNumberOfLines: label.numberOfLines)
        text.textContainerInset = UIEdgeInsets(top: max(0, drawn.minY - label.bounds.minY), left: 0, bottom: 0, right: 0)
    }

    // MARK: Long click

    func updateLongPress(_ view: AyuBridgeView) {
        if self.longClickCallback != nil, self.longClickable {
            if self.longPress == nil {
                let recognizer = UILongPressGestureRecognizer(target: view, action: #selector(AyuBridgeView.membersLongPressed(_:)))
                // `ViewConfiguration.getLongPressTimeout()` of this bridge.
                recognizer.minimumPressDuration = 0.5
                recognizer.cancelsTouchesInView = false
                view.addGestureRecognizer(recognizer)
                view.isUserInteractionEnabled = true
                self.longPress = recognizer
            }
            // A handled long click is not followed by a click.
            if let recognizer = self.longPress {
                for tap in view.gestureRecognizers ?? [] where tap is UITapGestureRecognizer { tap.require(toFail: recognizer) }
            }
        } else if let recognizer = self.longPress {
            view.removeGestureRecognizer(recognizer)
            self.longPress = nil
        }
    }

    // MARK: Focus

    func observeEditing(_ view: AyuBridgeView) {
        guard !self.observesEditing, let field = view.textField else { return }
        self.observesEditing = true
        field.addTarget(view, action: #selector(AyuBridgeView.membersEditingBegan), for: .editingDidBegin)
        field.addTarget(view, action: #selector(AyuBridgeView.membersEditingEnded), for: .editingDidEnd)
    }

    // MARK: Background

    func setBackground(_ style: AyuBridgeDrawableStyle?, view: AyuBridgeView) {
        guard let style else {
            self.drawable?.container.removeFromSuperlayer()
            self.drawable = nil
            if let press = self.press { view.removeGestureRecognizer(press); self.press = nil }
            return
        }
        // The extended layers draw the whole drawable; the base path keeps only the outline flag.
        view.bridgeBackgroundColor = .clear
        view.backgroundShape = 0
        view.backgroundCornerRadius = 0
        view.backgroundStrokeWidth = 0
        view.backgroundStrokeColor = nil
        view.updateBackgroundStyle()
        if let renderer = self.drawable {
            renderer.update(style: style, bounds: view.bounds)
        } else {
            let renderer = AyuBridgeDrawableRenderer(style: style)
            view.layer.insertSublayer(renderer.container, at: 0)
            renderer.layout(bounds: view.bounds)
            self.drawable = renderer
        }
        if style.ripple != nil, self.press == nil {
            let press = AyuBridgePressRecognizer()
            press.onChange = { [weak view] pressed in
                guard let view else { return }
                // Android shows the pressed state of clickable or long-clickable enabled views only.
                let accepts = view.bridgeEnabled && (view.bridgeClickable || view.members.longClickable)
                view.members.drawable?.setPressed(pressed && accepts)
            }
            view.addGestureRecognizer(press)
            self.press = press
        } else if style.ripple == nil, let press = self.press {
            view.removeGestureRecognizer(press)
            self.press = nil
        }
        if view.bridgeClipToOutline { view.setNeedsLayout() }
    }

    // MARK: Progress

    /// A horizontal ProgressBar in indeterminate mode: a segment of the progress tint travelling
    /// along the track, animated by Core Animation.
    func setIndeterminate(_ indeterminate: Bool, view: AyuBridgeView) {
        guard let progress = view.progressBar, indeterminate != self.indeterminate else { return }
        self.indeterminate = indeterminate
        if indeterminate {
            progress.setProgress(0, animated: false)
            let bar = CALayer()
            progress.layer.addSublayer(bar)
            progress.layer.masksToBounds = true
            self.indeterminateBar = bar
            self.layoutIndeterminate(view)
        } else {
            self.indeterminateBar?.removeFromSuperlayer()
            self.indeterminateBar = nil
            let fraction = view.progressMaximum > 0 ? Float(min(max(0, view.progressValue), view.progressMaximum)) / Float(view.progressMaximum) : 0
            progress.setProgress(fraction, animated: false)
        }
    }

    func layoutIndeterminate(_ view: AyuBridgeView) {
        guard let bar = self.indeterminateBar, let progress = view.progressBar else { return }
        let bounds = progress.bounds
        let width = bounds.width * 0.4
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        bar.backgroundColor = (self.indeterminateTint ?? progress.progressTintColor ?? progress.tintColor ?? .systemBlue).cgColor
        bar.bounds = CGRect(x: 0, y: 0, width: width, height: bounds.height)
        bar.position = CGPoint(x: -width / 2, y: bounds.midY)
        CATransaction.commit()
        let travel = bar.animation(forKey: "travel") as? CABasicAnimation
        guard bounds.width > 0, travel == nil || (travel?.toValue as? CGFloat) != bounds.width + width / 2 else { return }
        let animation = CABasicAnimation(keyPath: "position.x")
        animation.fromValue = -width / 2
        animation.toValue = bounds.width + width / 2
        animation.duration = 1.4
        animation.repeatCount = .infinity
        animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        // Keeps the loop when the app returns from the background.
        animation.isRemovedOnCompletion = false
        bar.add(animation, forKey: "travel")
    }
}

extension AyuBridgeView {
    @objc func membersLongPressed(_ recognizer: UILongPressGestureRecognizer) {
        if recognizer.state == .began { self.membersPerformLongClick() }
    }

    /// `View.performLongClick()` of an enabled, long-clickable view with a listener.
    func membersPerformLongClick() {
        guard self.bridgeEnabled, self.members.longClickable, let id = self.members.longClickCallback else { return }
        // Android gives LONG_PRESS feedback for a handled long click.
        self.performBridgeHapticFeedback(0)
        self.callback?(id, [])
    }

    @objc func membersEditingBegan() {
        if self.members.selectAllOnFocus, let field = self.textField {
            // The selection set while becoming first responder is replaced by UIKit; set it afterwards.
            DispatchQueue.main.async { [weak field] in
                guard let field, field.isFirstResponder else { return }
                field.selectedTextRange = field.textRange(from: field.beginningOfDocument, to: field.endOfDocument)
            }
        }
        if let id = self.members.focusCallback { self.callback?(id, [.bool(true)]) }
    }

    @objc func membersEditingEnded() {
        if let id = self.members.focusCallback { self.callback?(id, [.bool(false)]) }
    }
}

/// Reports touch down and up on a view without ever taking or delaying its touches.
final class AyuBridgePressRecognizer: UIGestureRecognizer {
    var onChange: ((Bool) -> Void)?

    init() {
        super.init(target: nil, action: nil)
        self.cancelsTouchesInView = false
        self.delaysTouchesBegan = false
        self.delaysTouchesEnded = false
    }

    override func canPrevent(_ preventedGestureRecognizer: UIGestureRecognizer) -> Bool { false }
    override func canBePrevented(by preventingGestureRecognizer: UIGestureRecognizer) -> Bool { false }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        self.state = .began
        self.onChange?(true)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let view = self.view, let touch = touches.first else { return }
        // A finger that leaves the view (with the touch slop of this bridge) no longer presses it.
        self.onChange?(view.bounds.insetBy(dx: -8, dy: -8).contains(touch.location(in: view)))
        self.state = .changed
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        self.state = .ended
        self.onChange?(false)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        self.state = .cancelled
        self.onChange?(false)
    }
}
