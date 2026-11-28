load("@build_bazel_rules_swift//swift:swift.bzl", "swift_library")

swift_library(
    name = "VoskSpeech",
    module_name = "VoskSpeech",
    srcs = glob(["Sources/**/*.swift"]),
    copts = ["-warnings-as-errors"],
    deps = [
        "//AyuGram/SGSimpleSettings:SGSimpleSettings",
        "//submodules/SSignalKit/SwiftSignalKit:SwiftSignalKit",
        "//submodules/VoskNative:CVosk",
    ],
    visibility = ["//visibility:public"],
)
