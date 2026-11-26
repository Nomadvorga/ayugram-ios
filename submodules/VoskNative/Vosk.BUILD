load("@build_bazel_rules_apple//apple:apple.bzl", "apple_static_xcframework_import")

apple_static_xcframework_import(
    name = "VoskNative",
    xcframework_imports = glob(["libvosk.xcframework/**"]),
    sdk_dylibs = ["c++"],
    sdk_frameworks = ["Accelerate"],
    visibility = ["//visibility:public"],
)
