import Foundation

// Compile the real AyuSettingsStore.swift and ExteraStickerSettings.swift with this file. Only the
// app group id and legacy Swiftgram settings facade are replaced; tests never read the app's suite.
let APP_GROUP_IDENTIFIER = "ExteraStickerHostTests.\(UUID().uuidString)"

final class SGSimpleSettings {
    static let shared = SGSimpleSettings()
    var stickerSize = 100
    var stickerTimestamp = true
}

@main
private enum ExteraStickerHostTests {
    private static var count = 0

    private static func expect(_ value: @autoclosure () -> Bool, _ message: String) {
        precondition(value(), message)
        self.count += 1
    }

    static func main() {
        defer { AyuSettingsStore.shared.userDefaults.removePersistentDomain(forName: APP_GROUP_IDENTIFIER) }
        self.persistence()
        self.geometry()
        print("PASS: \(self.count) production sticker persistence/migration/geometry assertions")
    }

    private static func persistence() {
        let settings = ExteraStickerSettings.shared
        let store = AyuSettingsStore.shared
        self.expect(settings.timeMode == .default, "Initial time inherits legacy true")
        SGSimpleSettings.shared.stickerTimestamp = false
        self.expect(settings.timeMode == .hidden, "Unset time inherits legacy false")
        SGSimpleSettings.shared.stickerTimestamp = true
        settings.timeMode = .side
        self.expect(settings.timeMode == .side, "Side roundtrip")
        self.expect(store.userDefaults.integer(forKey: "extera.stickers.timeMode") == 1, "Side persists Android-compatible id")
        self.expect(SGSimpleSettings.shared.stickerTimestamp, "Side keeps old toggle enabled")
        SGSimpleSettings.shared.stickerTimestamp = false
        self.expect(settings.timeMode == .side, "Explicit mode is authoritative over old toggle")
        settings.timeMode = .hidden
        self.expect(settings.timeMode == .hidden && !SGSimpleSettings.shared.stickerTimestamp, "Hidden persists and updates legacy toggle")
        settings.timeMode = .default
        self.expect(settings.timeMode == .default && SGSimpleSettings.shared.stickerTimestamp, "Default restores visibility")
        store.setInt(-1, "extera.stickers.timeMode")
        SGSimpleSettings.shared.stickerTimestamp = false
        self.expect(settings.timeMode == .hidden, "Reset sentinel inherits old hidden value")
        store.setInt(999, "extera.stickers.timeMode")
        self.expect(settings.timeMode == .hidden, "Unknown mode falls back safely")
        self.expect(settings.shape == .rounded, "Android default shape")
        for shape in ExteraStickerSettings.Shape.allCases {
            settings.shape = shape
            self.expect(settings.shape == shape, "Shape roundtrip")
            self.expect(store.userDefaults.integer(forKey: "extera.stickers.shape") == shape.rawValue, "Shape persisted id")
        }
        store.setInt(999, "extera.stickers.shape")
        self.expect(settings.shape == .rounded, "Unknown shape uses rounded fallback")
        self.expect(settings.size == 12 && settings.sizeCoefficient == 1, "Native size inherited")
        SGSimpleSettings.shared.stickerSize = 150
        self.expect(settings.size == 18, "Legacy percentage maps to 4...20 scale")
        settings.size = -100
        self.expect(settings.size == 4, "Size lower clamp")
        settings.size = 100
        self.expect(settings.size == 20, "Size upper clamp")
        settings.size = 12
        self.expect(settings.sizeCoefficient == 1, "Explicit native coefficient")
        self.expect(settings.recentStickersLimit == 20, "Default recent limit preserved")
        settings.unlimitedRecentStickers = true
        self.expect(settings.recentStickersLimit == nil, "Unlimited retains local history")
        self.expect(store.userDefaults.bool(forKey: "extera.stickers.unlimitedRecent"), "Unlimited flag persists")
    }

    private static func geometry() {
        let sticker = CGRect(x: 20, y: 10, width: 180, height: 180)
        let status = CGRect(x: 140, y: 170, width: 60, height: 18)
        let share = CGRect(x: 206, y: 140, width: 30, height: 50)
        let incoming = ExteraStickerGeometry.statusLayout(mode: .side, incoming: true, stickerFrame: sticker, defaultStatusFrame: status, shareFrame: share, availableMinX: 10, availableMaxX: 390)
        self.expect(incoming.usesSide && incoming.statusFrame.minX == 208, "Incoming time moves right with 8pt gap")
        self.expect(incoming.statusFrame.minY == status.minY, "Side preserves vertical anchor")
        self.expect(incoming.shareFrame?.minX == 276, "Incoming share moves beyond time")
        self.expect(incoming.shareFrame?.minY == share.minY, "Share vertical anchor preserved")
        let outgoingSticker = CGRect(x: 200, y: 10, width: 180, height: 180)
        let outgoingShare = CGRect(x: 164, y: 140, width: 30, height: 50)
        let outgoing = ExteraStickerGeometry.statusLayout(mode: .side, incoming: false, stickerFrame: outgoingSticker, defaultStatusFrame: status, shareFrame: outgoingShare, availableMinX: 10, availableMaxX: 390)
        self.expect(outgoing.usesSide && outgoing.statusFrame.minX == 132, "Outgoing time moves left")
        self.expect(outgoing.shareFrame?.minX == 94, "Outgoing share moves beyond time")
        for mode in [ExteraStickerSettings.TimeMode.default, .hidden] {
            let native = ExteraStickerGeometry.statusLayout(mode: mode, incoming: true, stickerFrame: sticker, defaultStatusFrame: status, shareFrame: share, availableMinX: 10, availableMaxX: 390)
            self.expect(!native.usesSide && native.statusFrame == status && native.shareFrame == share, "Default and hidden preserve geometry")
        }
        let narrow = ExteraStickerGeometry.statusLayout(mode: .side, incoming: true, stickerFrame: sticker, defaultStatusFrame: status, shareFrame: share, availableMinX: 10, availableMaxX: 300)
        self.expect(!narrow.usesSide && narrow.statusFrame == status && narrow.shareFrame == share, "Share button prevents side overflow; both frames revert")
        let noShare = ExteraStickerGeometry.statusLayout(mode: .side, incoming: true, stickerFrame: sticker, defaultStatusFrame: status, shareFrame: nil, availableMinX: 10, availableMaxX: 268)
        self.expect(noShare.usesSide && noShare.shareFrame == nil, "Exact right bound fits without share")
        let onePointShort = ExteraStickerGeometry.statusLayout(mode: .side, incoming: true, stickerFrame: sticker, defaultStatusFrame: status, shareFrame: nil, availableMinX: 10, availableMaxX: 267)
        self.expect(!onePointShort.usesSide, "One point overflow falls back")
        let noLeftRoom = ExteraStickerGeometry.statusLayout(mode: .side, incoming: false, stickerFrame: sticker, defaultStatusFrame: status, shareFrame: nil, availableMinX: 10, availableMaxX: 390)
        self.expect(!noLeftRoom.usesSide, "Outgoing left bound respected")
        let obstructed = ExteraStickerGeometry.statusLayout(mode: .side, incoming: true, stickerFrame: sticker, defaultStatusFrame: status, shareFrame: nil, availableMinX: 10, availableMaxX: 390, obstacles: [CGRect(x: 215, y: 170, width: 50, height: 20)])
        self.expect(!obstructed.usesSide, "Overlapping header rejects side")
        let clear = ExteraStickerGeometry.statusLayout(mode: .side, incoming: true, stickerFrame: sticker, defaultStatusFrame: status, shareFrame: nil, availableMinX: 10, availableMaxX: 390, obstacles: [CGRect(x: 215, y: 10, width: 50, height: 20)])
        self.expect(clear.usesSide, "Nonoverlapping header leaves side available")
        let empty = ExteraStickerGeometry.statusLayout(mode: .side, incoming: true, stickerFrame: .zero, defaultStatusFrame: status, shareFrame: nil, availableMinX: 10, availableMaxX: 390)
        self.expect(!empty.usesSide, "Zero-size sticker uses fallback")
        let size = CGSize(width: 100, height: 60)
        self.expect(ExteraStickerGeometry.cornerRadius(shape: .original, bubbleRadius: 20, size: size) == 0, "Original removes clipping")
        self.expect(ExteraStickerGeometry.cornerRadius(shape: .rounded, bubbleRadius: 20, size: size) == 6, "Rounded matches Android 6pt")
        self.expect(ExteraStickerGeometry.cornerRadius(shape: .bubble, bubbleRadius: 20, size: size) == 20, "Bubble radius follows theme")
        self.expect(ExteraStickerGeometry.cornerRadius(shape: .bubble, bubbleRadius: 100, size: size) == 30, "Radius bounded by shortest dimension")
        self.expect(ExteraStickerGeometry.cornerRadius(shape: .bubble, bubbleRadius: -1, size: size) == 0, "Negative radius clamped")
        self.expect(ExteraStickerGeometry.cornerRadius(shape: .bubble, bubbleRadius: .infinity, size: size) == 0, "Nonfinite radius rejected")
        self.expect(ExteraStickerGeometry.cornerRadius(shape: .rounded, bubbleRadius: 20, size: CGSize(width: 8, height: 20)) == 4, "Tiny sticker has valid corners")
    }
}
