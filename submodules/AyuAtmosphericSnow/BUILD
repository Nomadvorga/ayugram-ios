load("@build_bazel_rules_swift//swift:swift.bzl", "swift_library")
load("@build_bazel_rules_apple//apple:ios.bzl", "ios_unit_test")
load("@build_bazel_rules_apple//apple/testing/default_runner:ios_test_runner.bzl", "ios_test_runner")

swift_library(
    name = "AyuAtmosphericSnow",
    module_name = "AyuAtmosphericSnow",
    srcs = glob(["Sources/*.swift"]),
    copts = ["-warnings-as-errors"],
    visibility = ["//visibility:public"],
)

swift_library(
    name = "AyuAtmosphericSnowTestsLib",
    testonly = True,
    srcs = glob(["Tests/*.swift"]),
    deps = [":AyuAtmosphericSnow"],
)

ios_test_runner(
    name = "AyuAtmosphericSnowTestRunner",
    device_type = "iPhone 17",
    os_version = "26.5",
)

ios_unit_test(
    name = "AyuAtmosphericSnowTests",
    minimum_os_version = "15.0",
    runner = ":AyuAtmosphericSnowTestRunner",
    deps = [":AyuAtmosphericSnowTestsLib"],
)
