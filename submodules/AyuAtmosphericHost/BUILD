load("@build_bazel_rules_swift//swift:swift.bzl", "swift_library")
load("@build_bazel_rules_apple//apple:ios.bzl", "ios_unit_test")
load("@build_bazel_rules_apple//apple/testing/default_runner:ios_test_runner.bzl", "ios_test_runner")

swift_library(
    name = "AyuAtmosphericHost",
    module_name = "AyuAtmosphericHost",
    srcs = glob(["Sources/**/*.swift"]),
    copts = ["-warnings-as-errors"],
    visibility = ["//visibility:public"],
)

swift_library(
    name = "AyuAtmosphericHostTestsLib",
    testonly = True,
    srcs = ["Tests/AtmosphericHostTests.swift"],
    deps = [":AyuAtmosphericHost"],
)

# Pin a valid simulator rather than relying on the default runner's device selection.
ios_test_runner(
    name = "AyuAtmosphericHostTestRunner",
    device_type = "iPhone 17",
    os_version = "26.5",
)

ios_unit_test(
    name = "AyuAtmosphericHostTests",
    minimum_os_version = "15.0",
    runner = ":AyuAtmosphericHostTestRunner",
    deps = [":AyuAtmosphericHostTestsLib"],
    visibility = ["//visibility:public"],
)
