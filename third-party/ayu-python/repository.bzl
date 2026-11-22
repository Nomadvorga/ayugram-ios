"""Pinned repository rule for BeeWare's prebuilt iOS CPython support package."""

_URL = "https://github.com/beeware/Python-Apple-support/releases/download/3.15-b3/Python-3.15-iOS-support.b3.tar.gz"
_SHA256 = "429080dcfab3778b75bbc6548cbfd754dc943cfc6092a92b72022541ff3212a0"
_CERTIFI_URL = "https://files.pythonhosted.org/packages/51/33/4cd27639502f010084bcef7a2036391dd637439901341ce1a530f36f6e51/certifi-2026.11.20.tar.gz"
_CERTIFI_SHA256 = "af1cb240a8133f105aa52684a3a3258339d7f2fd0bd4e2812698ff5cf5588c4e"
_CERTIFI_PREFIX = "certifi-2026.11.20"


def _ayu_python_repository_impl(ctx):
    host = ctx.os.name.lower()
    if "mac" not in host and "darwin" not in host:
        fail("ayu_python_repository requires a macOS host (xcrun lipo packages the simulator extension slice)")

    ctx.download_and_extract(
        url = _URL,
        sha256 = _SHA256,
        type = "tar.gz",
    )
    certifi_root = ctx.path("_certifi")
    ctx.download_and_extract(
        url = _CERTIFI_URL,
        sha256 = _CERTIFI_SHA256,
        type = "tar.gz",
        output = "_certifi",
        stripPrefix = _CERTIFI_PREFIX,
    )

    prepare = ctx.path(Label("//third-party/ayu-python:prepare.py"))
    repo_root = ctx.path(".")
    result = ctx.execute(
        ["python3", str(prepare), str(repo_root), str(repo_root), str(certifi_root)],
        quiet = False,
    )
    if result.return_code != 0:
        fail("preparing BeeWare Python {} failed (exit {}):\n{}\n{}".format(
            "3.15-b3",
            result.return_code,
            result.stdout,
            result.stderr,
        ))

ayu_python_repository = repository_rule(
    implementation = _ayu_python_repository_impl,
    doc = "Downloads the checksum-pinned BeeWare Python 3.15-b3 iOS XCFramework and prepares Bazel imports/resources.",
)
