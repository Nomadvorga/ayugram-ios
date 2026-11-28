"""Android version and pip-requirement policy for plugin metadata.

Pure functions over already parsed metadata literals; nothing here executes
plugin code or reaches the host. The rules follow exteraGram b4d852f:
``PythonPluginsEngine.validatePluginFromFile``, ``AppUtils.compareVersions``,
``extera_utils.metadata_parser`` and ``pip/PipController``.
"""
from __future__ import annotations

import re

# The Android releases this bridge emulates: plugins-pysdk ``_sdk_version`` and
# ``APP_VERSION_NAME`` (``BuildVars.BUILD_VERSION_STRING``) of that revision.
SDK_VERSION = "1.4.6.5"
APP_VERSION = "13.2.2"

MAX_REQUIREMENTS = 256
_MAX_ECHO = 64
# java.util.regex: ``.`` excludes every line terminator, ``\s`` is ASCII only.
_CONSTRAINT = re.compile(r"(>=|<=|==|>|<)([^\n\r\u0085\u2028\u2029]+)\Z")
_INTEGER = re.compile(r"[+-]?\d+\Z")
_REQUIREMENT_SPLIT = re.compile(r",(?![ \t\n\x0b\f\r]*[<>=!~(])")
_REQUIREMENT_EXTRA = re.compile(r"\[[^\n\r\u0085\u2028\u2029]*?\]")
_REQUIREMENT_NAME = re.compile(r"[a-zA-Z0-9_.-]+")
_NAME_SEPARATORS = re.compile(r"[-_.]+")
_SPECIFIER = re.compile(r"(===|==|>=|<=|>|<|~=|!=)[ \t\n\x0b\f\r]*([^\n\r\u0085\u2028\u2029]*)")
_VERSION_PART = re.compile(r"[0-9]+|[a-zA-Z]+")
_VERSION_WILDCARD = re.compile(r"(?:^|[.\-_])\*\Z")
_RELEASE_SEPARATOR = re.compile(r"[.\-_]")
_PRERELEASE_WEIGHT = {"post": 110, "": 100, "rc": 80, "c": 80, "beta": 70, "b": 70, "alpha": 60, "a": 60, "dev": 50}

# PipController.PREINSTALLED_PACKAGES: Android never installs or version-checks these.
ANDROID_PREINSTALLED = frozenset({"beautifulsoup4", "debugpy", "lxml", "packaging", "pillow", "requests", "pyyaml"})
# Normalized distribution name -> modules that must be importable for the
# requirement to count as bundled. Only modules shipped with this SDK or the
# embedded interpreter belong here; like Android's preinstalled set, their
# version specifiers are not evaluated.
BUNDLED_DISTRIBUTIONS = {
    "requests": ("requests",),
    # PyPI backports of modules the embedded CPython provides itself.
    "argparse": ("argparse",), "asyncio": ("asyncio",), "contextvars": ("contextvars",),
    "dataclasses": ("dataclasses",), "enum34": ("enum",), "ipaddress": ("ipaddress",),
    "pathlib": ("pathlib",), "statistics": ("statistics",), "typing": ("typing",),
}
# Normalized distribution name -> (version, modules) of the pure-Python distributions the
# app build unpacks into the embedded interpreter's library directory. This repeats
# third-party/ayu-python/packages.lock.json, which pins the artifacts. A requirement on one
# is satisfied only by this exact version, and only when the host declares its modules.
PINNED_DISTRIBUTIONS = {
    "beautifulsoup4": ("4.15.0", ("bs4",)),
    "cachetools": ("8.0.3", ("cachetools",)),
    "certifi": ("2026.11.20", ("certifi",)),
    "humanize": ("4.17.0", ("humanize",)),
    "mpmath": ("1.4.1", ("mpmath",)),
    "mutagen": ("1.48.1", ("mutagen",)),
    "packaging": ("26.4", ("packaging",)),
    "pyyaml": ("6.0.4", ("yaml",)),
    "soupsieve": ("4.1.3", ("soupsieve",)),
    "tinydb": ("4.9.0", ("tinydb",)),
    "typing-extensions": ("4.16.0", ("typing_extensions",)),
    "urllib3": ("2.8.0", ("urllib3",)),
}


def _scalar(value):
    return value is None or type(value) in (bool, int, float, str)


def android_text(value):
    """The string Android's metadata parser yields for a literal, or None.

    It keeps a constant as ``str(value)`` and a list as its constants joined
    by commas. Android drops any other shape without a diagnostic; this SDK
    reports it instead, so such values return None.
    """
    if _scalar(value):
        return str(value)
    if type(value) is list and all(_scalar(item) for item in value):
        return ",".join(str(item) for item in value)
    return None


def _parts(version):
    parts = version.split(".")
    # String.split discards trailing empty strings once a separator matched.
    if len(parts) > 1:
        while parts and parts[-1] == "":
            parts.pop()
    return parts


def _parse_int(text):
    if not _INTEGER.match(text):
        raise ValueError("Version component is not an integer")
    value = int(text)
    if not -(2**31) <= value < 2**31:
        raise ValueError("Version component exceeds 32 bits")
    return value


def compare_version_values(left, right):
    """``AppUtils.compareVersionValues``: -1, 0 or 1; ValueError where Java throws.

    Components are compared as integers from the left, a missing one is 0, and
    parsing stops at the first difference, so later text is never validated.
    """
    first, second = _parts(left), _parts(right)
    for index in range(max(len(first), len(second))):
        a = _parse_int(first[index]) if index < len(first) else 0
        b = _parse_int(second[index]) if index < len(second) else 0
        if a != b:
            return -1 if a < b else 1
    return 0


def compare_versions(operator, current, target):
    """``AppUtils.compareVersions(operator, current, target)``."""
    order = compare_version_values(current, target)
    try:
        return {"==": order == 0, ">": order > 0, "<": order < 0, ">=": order >= 0, "<=": order <= 0}[operator]
    except KeyError:
        raise ValueError("Unsupported operator") from None


def _echo(text):
    return text if len(text) <= _MAX_ECHO and text.isprintable() else "<constraint>"


def _check(label, constraint, current, product):
    match = _CONSTRAINT.match(constraint)
    if match is None:
        return f"{label} is not a valid version constraint"
    try:
        satisfied = compare_versions(match.group(1), current, match.group(2).strip())
    except ValueError:
        return f"{label} is not a valid version constraint"
    return None if satisfied else f"{label}{_echo(constraint)} is not met by the emulated {product} {current}"


def version_findings(metadata, app_version=APP_VERSION, sdk_version=SDK_VERSION):
    """Why the metadata's Android version constraints do not hold; empty when they do.

    ``__min_version__`` means ``app_version >= value`` and is ignored when
    ``__app_version__`` is present; ``__app_version__`` and ``__sdk_version__``
    must be ``<operator><version>`` with one of ``>= <= == > <``.
    """
    findings, texts = [], {}
    for key in ("__min_version__", "__app_version__", "__sdk_version__"):
        if key in metadata:
            texts[key] = android_text(metadata[key])
            if texts[key] is None:
                findings.append(f"{key[2:-2]} must be a constant")
    app = texts.get("__app_version__") if "__app_version__" in texts else (
        ">=" + texts["__min_version__"] if texts.get("__min_version__") is not None else None)
    if app is not None:
        finding = _check("app_version", app, app_version, "exteraGram")
        if finding:
            findings.append(finding)
    if texts.get("__sdk_version__") is not None:
        finding = _check("sdk_version", texts["__sdk_version__"], sdk_version, "plugin SDK")
        if finding:
            findings.append(finding)
    return findings


def requirement_list(value):
    """``__requirements__`` split as Android does, or None for an unsupported shape.

    Android accepts one comma-separated string or a list of constants. A comma
    that continues a version specifier (``pkg>=1,<2``) does not separate.
    """
    text = android_text(value)
    if text is None:
        return None
    return [item for item in (part.strip() for part in _REQUIREMENT_SPLIT.split(text)) if item]


def distribution_name(requirement):
    """Normalized distribution of one requirement (``PipController.parseRequirement``)."""
    clean = requirement.split(";")[0].strip()
    clean = _REQUIREMENT_EXTRA.sub("", clean).strip()
    clean = clean.replace("(", "").replace(")", "").strip()
    match = _REQUIREMENT_NAME.match(clean)
    return _NAME_SEPARATORS.sub("-", (match.group(0) if match else clean).lower())


def requirement_specifiers(requirement):
    """``(operator, version)`` pairs of one requirement (``PipController.parseSpecs``).

    As on Android, markers and extras are dropped and a comma-separated part
    that does not start with an operator is ignored.
    """
    clean = requirement.split(";")[0].strip()
    clean = _REQUIREMENT_EXTRA.sub("", clean).strip()
    clean = clean.replace("(", "").replace(")", "").strip()
    match = _REQUIREMENT_NAME.match(clean)
    if match is None:
        return []
    # ``(.*)`` in REGEX_REQ_PARSE stops at the first line terminator.
    rest = re.split(r"[\n\r\u0085\u2028\u2029]", clean[match.end():], maxsplit=1)[0]
    specifiers = []
    for part in rest.split(","):
        found = _SPECIFIER.match(part.strip())
        if found:
            specifiers.append((found.group(1), found.group(2).strip()))
    return specifiers


def _pip_int(text):
    # String.toIntOrNull: a signed decimal that fits 32 bits, else None.
    if not _INTEGER.match(text):
        return None
    value = int(text)
    return value if -(2**31) <= value < 2**31 else None


def _pip_version(version):
    """``PipController.parseVersion``: (epoch, public version, numeric and alphabetic parts)."""
    public = version.strip().lower()
    if public.startswith("v"):
        public = public[1:]
    public = public.split("+", 1)[0]
    epoch = 0
    if "!" in public:
        head, public = public.split("!", 1)
        epoch = _pip_int(head) or 0
    return epoch, public, _VERSION_PART.findall(public)


def compare_pip_versions(left, right):
    """``PipController.VersionComparator.compare``: negative, zero or positive."""
    (first_epoch, _, first), (second_epoch, _, second) = _pip_version(left), _pip_version(right)
    if first_epoch != second_epoch:
        return -1 if first_epoch < second_epoch else 1
    for index in range(max(len(first), len(second))):
        a = first[index] if index < len(first) else None
        b = second[index] if index < len(second) else None
        if a is None and b is not None and _pip_int(b) is not None:
            a = "0"
        if b is None and a is not None and _pip_int(a) is not None:
            b = "0"
        a, b = a or "", b or ""
        if a == b:
            continue
        x, y = _pip_int(a), _pip_int(b)
        if x is not None and y is not None:
            if x != y:
                return -1 if x < y else 1
        elif x is not None:
            return 1
        elif y is not None:
            return -1
        else:
            weights = _PRERELEASE_WEIGHT.get(a, 0), _PRERELEASE_WEIGHT.get(b, 0)
            if weights[0] != weights[1]:
                return -1 if weights[0] < weights[1] else 1
            return -1 if a < b else 1
    return 0


def _release_parts(version):
    parts = (_pip_int(part) for part in _RELEASE_SEPARATOR.split(_pip_version(version)[1]))
    return [part for part in parts if part is not None]


def _matches_wildcard(version, specifier):
    prefix = specifier.strip().split("+", 1)[0]
    for suffix in (".*", "-*", "_*"):
        if prefix.endswith(suffix):
            prefix = prefix[:-len(suffix)]
    prefix = prefix.rstrip(".-_")
    if "!" in prefix and _pip_version(prefix)[0] != _pip_version(version)[0]:
        return False
    wanted, actual = _release_parts(prefix), _release_parts(version)
    return len(actual) >= len(wanted) and actual[:len(wanted)] == wanted


def version_satisfies(version, specifiers):
    """``PipController.checkVersionSatisfies``: every specifier holds for the version."""
    for operator, target in specifiers:
        order = compare_pip_versions(version, target)
        wildcard = bool(_VERSION_WILDCARD.search(target.strip()))
        if operator == "===":
            satisfied = version == target
        elif operator == "==":
            satisfied = _matches_wildcard(version, target) if wildcard else order == 0
        elif operator == "!=":
            satisfied = not _matches_wildcard(version, target) if wildcard else order != 0
        elif operator == "~=":
            satisfied = order >= 0
            parts = target.split(".")
            bump = _pip_int(parts[-2]) if len(parts) >= 2 else None
            if satisfied and bump is not None:
                # Compatible release: below the next value of the second-to-last component.
                ceiling = ".".join(parts[:-2] + [str(bump + 1 if bump < 2**31 - 1 else -(2**31))])
                satisfied = compare_pip_versions(version, ceiling) < 0
        else:
            satisfied = {">=": order >= 0, "<=": order <= 0, ">": order > 0, "<": order < 0}[operator]
        if not satisfied:
            return False
    return True


def requirement_findings(requirements, modules):
    """One finding per requirement that the bundled modules cannot satisfy.

    ``modules`` is every importable module name: SDK, host-declared and stdlib.
    Nothing is ever installed, so an unbundled distribution always blocks, and a
    pinned distribution satisfies only the specifiers its one bundled version
    meets. Android never version-checks its preinstalled distributions, so their
    specifiers are not evaluated here either.
    """
    findings = []
    for requirement in requirements:
        name = distribution_name(requirement)
        pinned = PINNED_DISTRIBUTIONS.get(name)
        needed = pinned[1] if pinned is not None else BUNDLED_DISTRIBUTIONS.get(name)
        declared = needed is not None and all(module in modules for module in needed)
        if declared and (pinned is None or name in ANDROID_PREINSTALLED
                         or version_satisfies(pinned[0], requirement_specifiers(requirement))):
            continue
        if declared:
            wanted = ",".join(operator + target for operator, target in requirement_specifiers(requirement))
            finding = f"{name} ({_echo(wanted)} is not met by the bundled {pinned[0]})"
        elif needed is not None:
            finding = f"{name} (host does not declare its bundled module)"
        elif name in ANDROID_PREINSTALLED:
            finding = f"{name} (bundled by Android exteraGram, not by this bridge)"
        else:
            finding = name
        if finding not in findings:
            findings.append(finding)
    return findings
