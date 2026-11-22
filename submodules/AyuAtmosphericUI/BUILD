load("@build_bazel_rules_swift//swift:swift.bzl", "swift_library")

swift_library(
    name = "AyuAtmosphericUI",
    module_name = "AyuAtmosphericUI",
    srcs = glob(["Sources/**/*.swift"]),
    copts = ["-warnings-as-errors"],
    deps = ["//submodules/AyuAtmosphericHost"],
    visibility = ["//visibility:public"],
)
