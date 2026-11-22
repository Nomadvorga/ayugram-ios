load("@build_bazel_rules_swift//swift:swift.bzl", "swift_library")
load("@build_bazel_rules_apple//apple:resources.bzl", "apple_resource_bundle")
load("@rules_cc//cc:objc_library.bzl", "objc_library")
load("@build_bazel_rules_apple//apple:ios.bzl", "ios_unit_test")
load("@build_bazel_rules_apple//apple/testing/default_runner:ios_test_runner.bzl", "ios_test_runner")

objc_library(
    name = "AyuPluginPython",
    module_name = "AyuPluginPython",
    srcs = glob(["ObjC/*.m"]),
    hdrs = glob(["PublicHeaders/**/*.h"]),
    includes = ["PublicHeaders/AyuPluginPython"],
    enable_modules = True,
    sdk_frameworks = ["Foundation"],
    deps = ["@ayu_python//:Python"],
    visibility = ["//visibility:public"],
)

apple_resource_bundle(
    name = "AyuPluginSDK",
    bundle_name = "AyuPluginSDK",
    structured_resources = glob(["Python/**/*.py", "Resources/**"], exclude = ["**/__pycache__/**"]),
    visibility = ["//visibility:public"],
)

swift_library(
    name = "AyuPluginBridge",
    module_name = "AyuPluginBridge",
    srcs = glob(["Sources/**/*.swift", "Integration/**/*.swift"]),
    copts = ["-warnings-as-errors"],
    deps = [
        ":AyuPluginPython",
        ":AyuPluginSDK",
        "//submodules/AyuAtmosphericHost:AyuAtmosphericHost",
        "//submodules/AyuAtmosphericSnow:AyuAtmosphericSnow",
        "@ayu_python//:PythonResources",
    ],
    visibility = ["//visibility:public"],
)

swift_library(
    name = "AyuPluginBridgeTestsLib",
    testonly = True,
    srcs = glob(["Tests/Swift/*.swift"]),
    deps = [
        ":AyuPluginBridge",
        "//submodules/AyuAtmosphericHost:AyuAtmosphericHost",
        "//submodules/AyuAtmosphericSnow:AyuAtmosphericSnow",
    ],
)

ios_test_runner(
    name = "AyuPluginBridgeTestRunner",
    device_type = "iPhone 17",
    os_version = "26.5",
)

ios_unit_test(
    name = "AyuPluginBridgeTests",
    minimum_os_version = "15.0",
    runner = ":AyuPluginBridgeTestRunner",
    deps = [":AyuPluginBridgeTestsLib"],
)
