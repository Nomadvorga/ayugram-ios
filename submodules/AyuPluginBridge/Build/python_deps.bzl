"""Thin alias for the generated, checksum-pinned Python packaging targets."""

load(
    "@ayu_python//:python_deps.bzl",
    _python_runtime_deps = "ayu_python_runtime_deps",
    _python_resource_deps = "ayu_python_resource_deps",
)


def ayu_python_packaging():
    """Returns the separate compilation and resource dependencies for Python."""
    return struct(
        deps = _python_runtime_deps(),
        data = _python_resource_deps(),
    )
