import Foundation

/// Native sticker controls shared by history rendering and the recent-sticker store.
public final class ExteraStickerSettings: @unchecked Sendable {
    /// Raw ids match exteraGram's StickerTimeMode preference ids.
    public enum TimeMode: Int, CaseIterable {
        case `default` = 0
        case side = 1
        case hidden = 2
    }

    /// exteraGram: 0 = no clipping, 1 = 6pt corners, 2 = current bubble radius.
    public enum Shape: Int, CaseIterable {
        case original = 0
        case rounded = 1
        case bubble = 2
    }

    public static let shared = ExteraStickerSettings()
    private let store = AyuSettingsStore.shared

    private init() {
        self.store.register(defaults: ["extera.stickers.unlimitedRecent": false, "extera.stickers.size": 0, "extera.stickers.timeMode": -1, "extera.stickers.shape": Shape.rounded.rawValue])
    }

    /// The unset sentinel inherits Swiftgram's old timestamp toggle. Once explicitly chosen, this
    /// enum owns visibility; writing it also updates the old toggle for older app versions.
    public var timeMode: TimeMode {
        get {
            let value = self.store.int("extera.stickers.timeMode")
            return TimeMode(rawValue: value) ?? (SGSimpleSettings.shared.stickerTimestamp ? .default : .hidden)
        }
        set {
            self.store.performBatchUpdates {
                self.store.setInt(newValue.rawValue, "extera.stickers.timeMode")
                SGSimpleSettings.shared.stickerTimestamp = newValue != .hidden
            }
        }
    }

    public var shape: Shape {
        get { return Shape(rawValue: self.store.int("extera.stickers.shape")) ?? .rounded }
        set { self.store.setInt(newValue.rawValue, "extera.stickers.shape") }
    }

    public var unlimitedRecentStickers: Bool {
        get { return self.store.bool("extera.stickers.unlimitedRecent") }
        set { self.store.setBool(newValue, "extera.stickers.unlimitedRecent") }
    }

    /// exteraGram's 4…20 size range, with 12 preserving the native size. A zero
    /// sentinel inherits the previous Swiftgram percentage until explicitly chosen.
    public var size: Int {
        get {
            let value = self.store.int("extera.stickers.size")
            if value == 0 {
                return max(4, min(20, Int((Double(SGSimpleSettings.shared.stickerSize) * 0.12).rounded())))
            }
            return max(4, min(20, value))
        }
        set { self.store.setInt(max(4, min(20, newValue)), "extera.stickers.size") }
    }

    public var sizeCoefficient: Float {
        return Float(self.size) / 12.0
    }

    /// nil deliberately retains the full local history; the server still limits its list.
    public var recentStickersLimit: Int? {
        return self.unlimitedRecentStickers ? nil : 20
    }
}

/// Pure layout shared by static, animated and video stickers. Side timestamps stay at the native
/// vertical anchor, move toward the conversation centre, and reserve room for the real share button.
/// If either view would leave the safe column or meet a header, retain BOTH native frames.
public enum ExteraStickerGeometry {
    public struct StatusLayout {
        public let statusFrame: CGRect
        public let shareFrame: CGRect?
        public let usesSide: Bool
    }

    public static func statusLayout(mode: ExteraStickerSettings.TimeMode, incoming: Bool, stickerFrame: CGRect, defaultStatusFrame: CGRect, shareFrame: CGRect?, availableMinX: CGFloat, availableMaxX: CGFloat, obstacles: [CGRect] = []) -> StatusLayout {
        let fallback = StatusLayout(statusFrame: defaultStatusFrame, shareFrame: shareFrame, usesSide: false)
        guard mode == .side, stickerFrame.width > 0, defaultStatusFrame.width > 0,
              stickerFrame.minX.isFinite, stickerFrame.maxX.isFinite,
              defaultStatusFrame.width.isFinite, defaultStatusFrame.height.isFinite,
              defaultStatusFrame.height > 0, defaultStatusFrame.minY.isFinite,
              availableMinX.isFinite, availableMaxX.isFinite else { return fallback }
        let gap: CGFloat = 8.0
        var status = defaultStatusFrame
        status.origin.x = incoming ? stickerFrame.maxX + gap : stickerFrame.minX - gap - status.width
        var share = shareFrame
        if var frame = share {
            frame.origin.x = incoming ? max(frame.minX, status.maxX + gap) : min(frame.minX, status.minX - gap - frame.width)
            share = frame
        }
        for frame in [Optional(status), share].compactMap({ $0 }) {
            guard frame.minX >= availableMinX, frame.maxX <= availableMaxX,
                  !obstacles.contains(where: { $0.insetBy(dx: -gap, dy: -2.0).intersects(frame) }) else { return fallback }
        }
        return StatusLayout(statusFrame: status, shareFrame: share, usesSide: true)
    }

    public static func cornerRadius(shape: ExteraStickerSettings.Shape, bubbleRadius: CGFloat, size: CGSize) -> CGFloat {
        let radius: CGFloat
        switch shape {
        case .original: radius = 0
        case .rounded: radius = 6
        case .bubble: radius = bubbleRadius.isFinite ? max(0, bubbleRadius) : 0
        }
        return max(0, min(radius, min(size.width, size.height) * 0.5))
    }
}
