load("@build_bazel_rules_swift//swift:swift.bzl", "swift_library")

sgdeps = [
    "//AyuGram/SGLogging:SGLogging",
    "//AyuGram/SGSimpleSettings:SGSimpleSettings",
]

swift_library(
    name = "LocalAudioTranscription",
    module_name = "LocalAudioTranscription",
    srcs = glob([
        "Sources/**/*.swift",
    ]),
    copts = [
        "-warnings-as-errors",
    ],
    deps = sgdeps +[
        "//submodules/SSignalKit/SwiftSignalKit:SwiftSignalKit",
    ],
    visibility = [
        "//visibility:public",
    ],
)
