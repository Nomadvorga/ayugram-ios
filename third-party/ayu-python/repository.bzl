"""Pinned repository rule for BeeWare's prebuilt iOS CPython support package."""

_URL = "https://github.com/beeware/Python-Apple-support/releases/download/3.15-b3/Python-3.15-iOS-support.b3.tar.gz"
_SHA256 = "429080dcfab3778b75bbc6548cbfd754dc943cfc6092a92b72022541ff3212a0"

# Pure-Python distributions bundled with the interpreter. The lock pins one
# artifact (URL and SHA-256) per distribution; prepare.py validates and unpacks them.
_PACKAGES_LOCK = "//third-party/ayu-python:packages.lock.json"
_PACKAGES_DIR = "_packages"


def _ayu_python_repository_impl(ctx):
    host = ctx.os.name.lower()
    if "mac" not in host and "darwin" not in host:
        fail("ayu_python_repository requires a macOS host (xcrun lipo packages the simulator extension slice)")

    ctx.download_and_extract(
        url = _URL,
        sha256 = _SHA256,
        type = "tar.gz",
    )
    packages_lock = ctx.path(Label(_PACKAGES_LOCK))
    for package in json.decode(ctx.read(packages_lock))["packages"]:
        # Archives stay packed: prepare.py reads the pinned members itself.
        ctx.download(
            url = package["url"],
            sha256 = package["sha256"],
            output = _PACKAGES_DIR + "/" + package["filename"],
        )

    prepare = ctx.path(Label("//third-party/ayu-python:prepare.py"))
    repo_root = ctx.path(".")
    result = ctx.execute(
        ["python3", str(prepare), str(repo_root), str(repo_root), str(ctx.path(_PACKAGES_DIR)), str(packages_lock)],
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
    doc = "Downloads the checksum-pinned BeeWare Python 3.15-b3 iOS XCFramework and pinned pure-Python packages, and prepares Bazel imports/resources.",
)
