load("@build_bazel_rules_swift//swift:swift.bzl", "swift_library")

swift_library(
    name = "VoskSpeechAudio",
    module_name = "VoskSpeechAudio",
    srcs = glob(["Sources/**/*.swift"]),
    copts = ["-warnings-as-errors"],
    deps = [
        "//submodules/Media/VoskSpeech:VoskSpeech",
        "//submodules/MediaPlayer:UniversalMediaPlayer",
        "//submodules/SSignalKit/SwiftSignalKit:SwiftSignalKit",
    ],
    visibility = ["//visibility:public"],
)
