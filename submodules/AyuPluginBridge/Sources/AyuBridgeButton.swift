import UIKit

/// `android.widget.Button` as the Material light theme of the app styles it
/// (`Widget.Material.Light.Button`): a TextView with other defaults. Sizes are dp.
enum AyuBridgeButtonDefaults {
    static let className = "android.widget.Button"
    static let minimumWidth: CGFloat = 88
    static let minimumHeight: CGFloat = 48
    /// The padding of `btn_default_material`: its inset plus the padding of its shape. It stays
    /// when a plugin replaces the background with a drawable that has no padding of its own.
    static let padding = UIEdgeInsets(top: 10, left: 12, bottom: 10, right: 12)
    static let backgroundInset = UIEdgeInsets(top: 6, left: 4, bottom: 6, right: 4)
    static let cornerRadius: CGFloat = 2
    /// `button_material_light`, and the light theme's primary text color.
    static let backgroundColor = UIColor(red: 0xD6 / 255, green: 0xD7 / 255, blue: 0xD7 / 255, alpha: 1)
    static let textColor = UIColor(white: 0, alpha: 0xDE / 255)
    /// `colorControlHighlight` of the light theme, laid over the button while it is pressed.
    static let pressedOverlay = UIColor(white: 0, alpha: 0x1F / 255)
    static let textSize: CGFloat = 14
    static let typeface = AyuBridgeTypefaceValue(design: .sans, baseWeight: 500, weight: 500, style: 0)
    static let gravity: Int64 = 17

    /// Worker-side view state the getters of a new Button answer from.
    static var fields: [String: AyuBridgeValue] {
        ["m_all_caps": .bool(true), "m_min_height": .integer(Int64(minimumHeight)), "m_min_width": .integer(Int64(minimumWidth)),
         "typeface": .object(typeface.state)]
    }
}

/// The default background of a Button: a grey rounded rectangle inside the drawable's inset,
/// lifted by a small shadow and darkened while pressed. Any background a plugin sets replaces it.
@MainActor final class AyuBridgeButtonBackground {
    let layer = CALayer()
    private let highlight = CALayer()

    init() {
        self.layer.backgroundColor = AyuBridgeButtonDefaults.backgroundColor.cgColor
        self.layer.cornerRadius = AyuBridgeButtonDefaults.cornerRadius
        self.layer.shadowColor = UIColor.black.cgColor
        self.layer.shadowOpacity = 0.24
        self.layer.shadowRadius = 1
        self.layer.shadowOffset = CGSize(width: 0, height: 1)
        self.highlight.backgroundColor = AyuBridgeButtonDefaults.pressedOverlay.cgColor
        self.highlight.cornerRadius = AyuBridgeButtonDefaults.cornerRadius
        self.highlight.isHidden = true
        self.layer.addSublayer(self.highlight)
    }

    func layout(bounds: CGRect) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        self.layer.frame = bounds.inset(by: AyuBridgeButtonDefaults.backgroundInset)
        self.highlight.frame = self.layer.bounds
        CATransaction.commit()
    }

    func setPressed(_ pressed: Bool) { self.highlight.isHidden = !pressed }
}
