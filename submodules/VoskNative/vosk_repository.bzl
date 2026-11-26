"""Immutable native SDK identity; no acoustic models are build dependencies."""

load("@bazel_tools//tools/build_defs/repo:http.bzl", "http_archive")

def extera_vosk_repository():
    http_archive(
        name = "extera_vosk_ios",
        urls = ["https://github.com/ishantve/VoskSpeechKit/releases/download/0.1.2/libvosk.xcframework.zip"],
        sha256 = "1891ad61293278363f75f2b4e5313c606183d0acd14f4b1ff1a71f5629c676f9",
        build_file = "//submodules/VoskNative:Vosk.BUILD",
    )
