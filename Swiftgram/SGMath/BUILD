load("@build_bazel_rules_swift//swift:swift.bzl", "swift_library")

# One Foundation-only engine shared by the composer and settings examples.
# Source paths stay stable for the standalone XCTest/reference-data runners.
swift_library(
    name = "SGMath",
    module_name = "SGMath",
    srcs = ["//submodules/TelegramUI:ExteraMathSources"] + glob(["Sources/**/*.swift"]),
    copts = ["-warnings-as-errors"],
    deps = ["//Swiftgram/SGSimpleSettings:SGSimpleSettings"],
    visibility = ["//visibility:public"],
)
