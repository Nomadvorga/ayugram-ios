load("@build_bazel_rules_swift//swift:swift.bzl", "swift_library")

filegroup(
    name = "SGUIAssets",
    srcs = glob(["Images.xcassets/**"]),
    visibility = ["//visibility:public"],
)

swift_library(
    name = "SGSettingsUI",
    module_name = "SGSettingsUI",
    srcs = glob([
		"Sources/**/*.swift",
    ]),
    copts = [
        "-warnings-as-errors",
    ],
    deps = [
        "//AyuGram/SGMath:SGMath",
        "//AyuGram/SGItemListUI:SGItemListUI",
        "//AyuGram/SGLogging:SGLogging",
        "//AyuGram/SGSimpleSettings:SGSimpleSettings",
        "//AyuGram/SGStrings:SGStrings",
        "//AyuGram/SGSwiftUI:SGSwiftUI",
        "//submodules/AyuPluginBridge:AyuPluginBridge",
        "//AyuGram/AyuInlineResults:AyuInlineResults",
        "//AyuGram/AyuSettingsBackup:AyuSettingsBackup",
        "//submodules/SSignalKit/SwiftSignalKit:SwiftSignalKit",
        "//submodules/Display:Display",
        "//submodules/TelegramCore:TelegramCore",
        "//submodules/TelegramAudio:TelegramAudio",
        "//submodules/Media/LocalAudioTranscription:LocalAudioTranscription",
        "//submodules/Media/VoskSpeech:VoskSpeech",
        "//submodules/MtProtoKit:MtProtoKit",
        "//submodules/TelegramPresentationData:TelegramPresentationData",
        "//submodules/TelegramUIPreferences:TelegramUIPreferences",
        "//submodules/TranslateUI:TranslateUI",
        "//AyuGram/AyuAdBlock:AyuAdBlock",
        "//submodules/ItemListUI:ItemListUI",
        "//submodules/PresentationDataUtils:PresentationDataUtils",
        "//submodules/OverlayStatusController:OverlayStatusController",
        "//submodules/AccountContext:AccountContext",
        "//submodules/AsyncDisplayKit:AsyncDisplayKit",
        "//submodules/ChatListUI:ChatListUI",
        "//submodules/AppBundle:AppBundle",
        "//submodules/TelegramUI/Components/Settings/PeerNameColorScreen",
        "//submodules/UndoUI:UndoUI",
        "//submodules/SettingsUI:SettingsUI",
        "//submodules/PromptUI:PromptUI",
        "//submodules/StickerResources:StickerResources",
        "//submodules/AnimatedStickerNode:AnimatedStickerNode",
        "//submodules/TelegramAnimatedStickerNode:TelegramAnimatedStickerNode",
        "//submodules/TextFormat:TextFormat",
    ],
    visibility = [
        "//visibility:public",
    ],
)
