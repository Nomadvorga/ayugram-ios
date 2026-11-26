load("@rules_cc//cc:objc_library.bzl", "objc_library")

exports_files(["Vosk.BUILD", "vosk_repository.bzl"])

# The repository rule and archive BUILD are in vosk_repository.bzl / Vosk.BUILD.
objc_library(
    name = "CVosk",
    module_name = "CVosk",
    enable_modules = True,
    srcs = ["Sources/VoskInflate.c"],
    hdrs = ["include/vosk_api.h", "include/VoskInflate.h"],
    includes = ["include"],
    sdk_dylibs = ["z"],
    deps = ["@extera_vosk_ios//:VoskNative"],
    visibility = ["//visibility:public"],
)
