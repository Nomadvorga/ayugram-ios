"""Elyx plugin packages (``.elyx`` / ``.eaf``): bounded inspection and loading.

A package is a ZIP archive with a ``refmap`` naming its main module, metainfo,
assets and string tables, as Android's ``elyxcore`` reads it. Inspection never
executes package code: it validates the archive, reads the manifest and runs
the static SDK inventory over every Python module. Loading uses the same
authorize / activate / generation lifecycle as a ``.plugin`` file, executes
module source taken from the inspected archive bytes, and unpacks the package
into the bridge's plugin storage so plugin code finds its files next to
``__file__`` as it does on Android.

A package's modules are ordinary entries of ``sys.modules`` under
``ElyxPlugins.<id>`` until its generation is torn down; the finder serves a
plugin only its own package, but this is scoping, not isolation.

Not supported, and reported as ``PACKAGE`` blockers: compiled ``.pyc`` modules
(another interpreter's bytecode), bundled wheels, and required plugins other
than the libraries this SDK provides itself. Encrypted archives are rejected.
"""
from __future__ import annotations

import ast
import builtins
import importlib
import importlib.abc
import importlib.util
import json
import os
import re
import stat
import sys
import types
import zipfile

import _ayu_mvel
import _ayu_operations
import _ayu_policy
import _ayu_threads
import _ayu_yaml
from _ayu_inspection import NATIVE_PREFIXES

PLUGIN_NAMESPACE = "ElyxPlugins"
PUBLIC_MODULE = "elyx"
EXTENSIONS = ("elyx", "eaf")
MAX_ARCHIVE_BYTES = 64 * 1024 * 1024
MAX_ENTRIES = 4096
MAX_TOTAL_BYTES = 256 * 1024 * 1024
# One unpacked file. The largest entry of the reference corpus is a 23 MiB Android library; the
# largest file a package can use here is a 5.5 MiB font.
MAX_ENTRY_BYTES = 32 * 1024 * 1024
# Entries are unpacked in pieces of this size, so memory does not follow the entry size.
CHUNK_BYTES = 64 * 1024
# Each file is written under this suffix and renamed into place; no entry may claim such a name.
_UNPACK_SUFFIX = ".ayu-unpack"
MAX_SOURCE_BYTES = 4 * 1024 * 1024
MAX_DATA_BYTES = 1024 * 1024
MAX_MODULES = 1024
MAX_NAME_BYTES = 512
MAX_DEPTH = 32
REFMAP_FILES = ("refmap.yaml", "refmap.yml", "refmap.json")
METAINFO_FILES = ("metainfo.yaml", "metainfo.yml", "metainfo.json")
STRINGS_FILES = ("strings.yaml", "strings.yml", "strings.json")
ALLOWED_METAINFO = ("name", "description", "version", "icon", "id", "author", "min_version", "app_version",
                    "sdk_version", "requires", "requirements", "category")
BASE_METAINFO = {"description": "Description not provided", "version": "1.0.0", "icon": "",
                 "author": "Unknown author", "min_version": "", "app_version": "", "sdk_version": "",
                 "requires": {}, "requirements": ""}
ENVIRONMENT_NAMES = ("settings", "refmap", "metainfo", "assets", "strings")
# Roots Android always resolves outside the package, even when a local module has the name.
_EXTERNAL_ROOTS = frozenset(("android", "androidx", "base_plugin", "client_utils", "com", "de", "elyx",
                             "hook_utils", "importlib", "java", "org", "ui"))
_DATA_SUFFIXES = (".json", ".yaml", ".yml", ".txt")
_ELYX_ID = re.compile(r"[a-zA-Z0-9_]{2,32}\Z")
_BRIDGE_ID = re.compile(r"[A-Za-z][A-Za-z0-9_-]{1,31}\Z")
_REQUIRED = re.compile(r"([a-zA-Z0-9_]{2,32})(?:\s*\((\d+(?:\.\d+)*)\))?\Z")
_PLACEHOLDER = re.compile(r"\{([^}]+)\}")
_SEGMENT = re.compile(r"[^\x00-\x1f\x7f/\\:*?\"<>|]+\Z")


def _bridge():
    return sys.modules["ayu_bridge"]


def _reject(message):
    return _bridge().BridgeError("LOAD_REJECTED", message)


def is_package_name(filename):
    """Android's engine claims ``name.elyx``, ``name.eaf`` and the ``.zip``-suffixed forms."""
    name = str(filename).lower()
    return any(name.endswith("." + extension) or name.endswith("." + extension + ".zip") for extension in EXTENSIONS)


def _data(raw, name):
    """Parse a manifest or string table; ``None`` for a suffix Android ignores."""
    suffix = name.rsplit("/", 1)[-1].rsplit(".", 1)[-1]
    try:
        text = raw.decode("utf-8")
        if suffix == "json":
            return json.loads(text)
        if suffix in ("yaml", "yml"):
            return _ayu_yaml.safe_load(text)
    except (UnicodeDecodeError, ValueError, RecursionError) as error:
        raise _reject(f"Package file {name} is not valid {suffix.upper()}") from error
    return None


def _resolve(files, directories, dotted):
    """Android's module lookup below the plugin root: ``(archive name, kind, is_package)`` or None."""
    base = "/".join(dotted.split(".")) if dotted else ""
    if base and any(part in ("", ".", "..") for part in base.split("/")):
        return None
    if base + ".py" in files:
        return base + ".py", "source", False
    if base + ".pyc" in files:
        return base + ".pyc", "bytecode", False
    if base + "/__init__.py" in files:
        return base + "/__init__.py", "source", True
    if base + "/__init__.pyc" in files:
        return base + "/__init__.pyc", "bytecode", True
    if base in directories or base == "":
        return base, "namespace", True
    for suffix in _DATA_SUFFIXES:
        if base + suffix in files:
            return base + suffix, "data", False
    return None


class Package:
    """A validated plugin archive: its manifest, string tables and module sources."""

    def __init__(self, path):
        if not isinstance(path, str) or not path:
            raise _reject("Package path is required")
        try:
            status = os.lstat(path)
        except OSError as error:
            raise _reject("Package file is unavailable") from error
        if not stat.S_ISREG(status.st_mode) or status.st_size > MAX_ARCHIVE_BYTES:
            raise _reject("Package must be a regular file within the archive size limit")
        self.archive_bytes = status.st_size
        try:
            self._zip = zipfile.ZipFile(path)
        except (OSError, zipfile.BadZipFile, ValueError) as error:
            raise _reject("Package is not a ZIP archive") from error
        try:
            self._index()
            self._manifest()
        except BaseException:
            self.close()
            raise

    def close(self):
        if self._zip is not None:
            self._zip.close()
            self._zip = None

    # ---- archive ----

    def _index(self):
        entries = self._zip.infolist()
        if not entries or len(entries) > MAX_ENTRIES:
            raise _reject("Package is empty or exceeds its entry limit")
        self.files, self.directories, total = {}, set(), 0
        seen = set()
        for info in entries:
            name = info.filename
            is_directory = name.endswith("/")
            parts = name[:-1].split("/") if is_directory else name.split("/")
            if (len(name.encode("utf-8", "surrogatepass")) > MAX_NAME_BYTES or len(parts) > MAX_DEPTH
                    or any(part in ("", ".", "..") or not _SEGMENT.match(part) or part.endswith(_UNPACK_SUFFIX)
                           for part in parts)):
                raise _reject("Package holds an unsafe entry path")
            if info.flag_bits & 0x1:
                raise _reject("Encrypted packages are not supported")
            if stat.S_ISLNK(info.external_attr >> 16):
                raise _reject("Package holds a symbolic link")
            if info.compress_type not in (zipfile.ZIP_STORED, zipfile.ZIP_DEFLATED):
                raise _reject("Package uses an unsupported compression method")
            folded = "/".join(parts).casefold()
            if folded in seen:
                raise _reject("Package holds duplicate entry paths")
            seen.add(folded)
            for depth in range(1, len(parts) if not is_directory else len(parts) + 1):
                self.directories.add("/".join(parts[:depth]))
            if is_directory:
                continue
            if info.file_size > MAX_ENTRY_BYTES:
                raise _reject("Package holds a file over the entry size limit")
            total += info.file_size
            if total > MAX_TOTAL_BYTES:
                raise _reject("Package exceeds its unpacked size limit")
            self.files[name] = info
        if any(name in self.directories for name in self.files):
            raise _reject("Package holds a path that is both a file and a directory")
        self.total_bytes = total

    def read(self, name, limit):
        """The bytes of one entry, never more than ``limit`` whatever its header claims."""
        info = self.files.get(name)
        if info is None:
            raise _reject(f"Package has no file {name}")
        if info.file_size > limit:
            raise _reject(f"Package file {name} exceeds its size limit")
        try:
            with self._zip.open(info) as stream:
                data = stream.read(limit + 1)
        except (OSError, zipfile.BadZipFile, RuntimeError, NotImplementedError, EOFError, ValueError) as error:
            raise _reject(f"Package file {name} cannot be read") from error
        if len(data) > limit:
            raise _reject(f"Package file {name} exceeds its size limit")
        return data

    def chunks(self, name):
        """The bytes of one entry in pieces of at most ``CHUNK_BYTES``, exactly as many as it declares."""
        info = self.files.get(name)
        if info is None:
            raise _reject(f"Package has no file {name}")
        remaining = info.file_size
        try:
            stream = self._zip.open(info)
        except (OSError, zipfile.BadZipFile, RuntimeError, NotImplementedError, ValueError) as error:
            raise _reject(f"Package file {name} cannot be read") from error
        with stream:
            while remaining >= 0:
                try:
                    data = stream.read(CHUNK_BYTES)
                except (OSError, zipfile.BadZipFile, RuntimeError, NotImplementedError, EOFError, ValueError) as error:
                    raise _reject(f"Package file {name} cannot be read") from error
                if not data:
                    break
                remaining -= len(data)
                if remaining >= 0:
                    yield data
        if remaining:
            raise _reject(f"Package file {name} does not have its declared size")

    def _mapping(self, name):
        value = _data(self.read(name, MAX_DATA_BYTES), name)
        if not isinstance(value, dict):
            raise _reject(f"Package file {name} must hold a mapping")
        return value

    @staticmethod
    def _relative(value, what):
        """A refmap path as a normalized archive-relative name."""
        if not isinstance(value, str) or not value:
            raise _reject(f"Package refmap {what} must be a path")
        parts = value.strip("/").split("/")
        if any(part in ("", ".", "..") or not _SEGMENT.match(part) for part in parts):
            raise _reject(f"Package refmap {what} is not a safe relative path")
        return "/".join(parts)

    # ---- manifest ----

    def _manifest(self):
        refmap_name = next((name for name in self.files if name in REFMAP_FILES), None)
        self.refmap = self._mapping(refmap_name) if refmap_name else {}
        self._metainfo()
        self._strings()
        if "main" in self.refmap:
            self.main = self._relative(self.refmap["main"], "main")
        else:
            self.main = "main.py" if "main.py" in self.files else None
        if not self.main:
            raise _reject("Main file not found!")
        if self.main not in self.files:
            raise _reject("Main file named by the refmap is not in the package")
        self.assets = None
        if "assets" in self.refmap:
            self.assets = self._relative(self.refmap["assets"], "assets")
            if self.assets not in self.directories:
                raise _reject("Assets directory not found!")
        elif "assets" in self.directories:
            self.assets = "assets"
        self.wheels = None
        if "wheels" in self.refmap:
            self.wheels = self._relative(self.refmap["wheels"], "wheels")
            if self.wheels not in self.directories:
                raise _reject("Wheels directory not found!")
        self._metadata()

    def _metainfo(self):
        result = None
        if self.refmap.get("metainfo"):
            name = self._relative(self.refmap["metainfo"], "metainfo")
            if name not in self.files:
                raise _reject("Metainfo not found or must be empty!")
            if name.endswith((".json", ".yaml", ".yml")):
                result = {str(key).replace("__", ""): value for key, value in self._mapping(name).items()
                          if str(key).replace("__", "") in ALLOWED_METAINFO}
        if result is None:
            name = next((name for name in self.files if name in METAINFO_FILES), None)
            if name is not None:
                result = self._mapping(name)
        if not result:
            raise _reject("Metainfo not found or must be empty!")
        self.metainfo = {**BASE_METAINFO, **result}
        requirements = _ayu_policy.requirement_list(self.metainfo.get("requirements") or [])
        if requirements is None or len(requirements) > _ayu_policy.MAX_REQUIREMENTS:
            raise _reject("Package requirements must be a bounded string or list of constants")
        if requirements:
            self.metainfo["requirements"] = requirements
        else:
            self.metainfo.pop("requirements", None)

    def _locale_tables(self, directory):
        tables = {}
        prefix = directory + "/"
        for name in self.files:
            if not name.startswith(prefix) or "/" in name[len(prefix):]:
                continue
            basename = name[len(prefix):]
            parts = basename.split(".")[0].split("_")
            table = tables.setdefault(parts[-1] if len(parts) > 1 else "en", {})
            if basename.endswith((".json", ".yaml", ".yml")):
                table.update(self._mapping(name))
        return tables

    def _strings(self):
        self.strings = {}
        if self.refmap.get("strings"):
            name = self._relative(self.refmap["strings"], "strings")
            if name in self.files:
                if name.endswith((".json", ".yaml", ".yml")):
                    self.strings = {"en": {str(key).replace("__", ""): value
                                           for key, value in self._mapping(name).items()}}
            elif name in self.directories:
                self.strings = self._locale_tables(name)
            if not self.strings:
                raise _reject("Strings named by the refmap were not found")
            return
        name = next((name for name in self.files if name in STRINGS_FILES), None)
        if name is not None:
            self.strings = {"en": self._mapping(name)}
        elif "strings" in self.directories:
            self.strings = self._locale_tables("strings")

    def description(self, language=None):
        """The description with its ``{key}`` placeholders taken from the string tables."""
        text = str(self.metainfo.get("description", ""))
        if not self.strings or "{" not in text:
            return text
        table = self.strings.get(language) or self.strings.get("en") or self.strings
        english = self.strings.get("en")
        if not isinstance(table, dict):
            return text

        def replace(match):
            value = table.get(match.group(1))
            if value is None and isinstance(english, dict):
                value = english.get(match.group(1))
            return match.group(1) if value is None else str(value)

        return _PLACEHOLDER.sub(replace, text)

    def _metadata(self):
        info = self.metainfo
        plugin_id, name = info.get("id"), info.get("name")
        if not plugin_id or not name:
            raise _reject("Plugin metadata must contain non-empty '__id__' and '__name__'.")
        plugin_id, name = str(plugin_id), str(name)
        if not _ELYX_ID.match(plugin_id) or not _BRIDGE_ID.match(plugin_id) or not name.strip():
            raise _reject("Package id must be 2-32 letters, digits and underscores and start with a letter")
        metadata = {"__id__": plugin_id, "__name__": name, "__description__": self.description()}
        for key in ("author", "version", "icon", "min_version", "app_version", "sdk_version", "category"):
            value = info.get(key)
            if isinstance(value, (list, tuple)):
                value = ",".join(map(str, value))
            if value and not isinstance(value, dict):
                metadata[f"__{key}__"] = str(value)
        if info.get("requirements"):
            metadata["__requirements__"] = list(info["requirements"])
        self.metadata = metadata
        requires = info.get("requires") or {}
        if not isinstance(requires, dict):
            raise _reject("Package 'requires' must map plugin ids to links")
        self.requires = []
        for required in requires:
            match = _REQUIRED.match(str(required))
            if match is None:
                raise _reject("Package 'requires' entries must look like \"plugin_id (min_version)\"")
            self.requires.append((match.group(1), match.group(2)))

    # ---- modules ----

    def _excluded(self, name):
        if any(part.startswith(".") for part in name.split("/")):
            return True
        return any(root and (name == root or name.startswith(root + "/")) for root in (self.assets, self.wheels))

    def python_sources(self):
        """Archive names of the Python modules that belong to the plugin's code."""
        return [name for name in self.files if name.endswith(".py") and not self._excluded(name)]

    def bytecode_files(self):
        return [name for name in self.files if name.endswith(".pyc") and not self._excluded(name)]

    def resolve(self, dotted):
        return _resolve(self.files, self.directories, dotted)

    def is_local(self, module, importer=""):
        """Whether an absolute import inside the package resolves to one of its own modules.

        Android resolves it below the plugin root. A module beside the importing
        file (or beside one of its parent packages) also counts: packages put
        their own directory on ``sys.path`` and the files are unpacked there.
        """
        if not module or module.split(".", 1)[0] in _EXTERNAL_ROOTS:
            return False
        own = f"{PLUGIN_NAMESPACE}.{self.metadata['__id__']}"
        if module == PLUGIN_NAMESPACE or module == own:
            return True
        if module.startswith(own + "."):
            return self.resolve(module[len(own) + 1:]) is not None
        parents = importer.split("/")[:-1]
        return any(self.resolve(".".join(parents[:depth] + [module])) is not None
                   for depth in range(len(parents) + 1))

    def module_name(self, archive_name):
        parts = archive_name[:-3].split("/")
        if parts[-1] == "__init__":
            parts.pop()
        return ".".join([PLUGIN_NAMESPACE, self.metadata["__id__"]] + parts)


# ---- static inspection ------------------------------------------------------

def _version_tuple(text):
    return tuple(int(part) for part in str(text).split("."))


def _provided_plugin(plugin_id, version):
    """Whether a required library plugin is one this SDK provides itself, in a sufficient version."""
    if plugin_id != "zwylib":
        return False
    if version is None:
        return True
    import zwylib
    return _version_tuple(zwylib.__version__) >= _version_tuple(version)


def _elyx_names():
    import elyxcore
    return set(elyxcore.__all__)


def _module_imports(tree):
    """Absolute imports of one module as ``(modules, {module: names}, elyx names, wildcard native)``."""
    modules, symbols, elyx, wildcard = set(), {}, set(), False
    aliases = set()
    for node in ast.walk(tree):
        if isinstance(node, ast.Import):
            for alias in node.names:
                modules.add(alias.name)
                if alias.name == PUBLIC_MODULE:
                    aliases.add(alias.asname or PUBLIC_MODULE)
        elif isinstance(node, ast.ImportFrom) and not node.level and node.module:
            modules.add(node.module)
            names = symbols.setdefault(node.module, set())
            for alias in node.names:
                names.add(alias.name)
                if node.module == PUBLIC_MODULE and alias.name != "*":
                    elyx.add(alias.name)
            if node.module.startswith(NATIVE_PREFIXES) and any(alias.name == "*" for alias in node.names):
                wildcard = True
    if aliases:
        for node in ast.walk(tree):
            if isinstance(node, ast.Attribute) and isinstance(node.value, ast.Name) and node.value.id in aliases:
                elyx.add(node.attr)
    return modules, symbols, elyx, wildcard


def analyze(package):
    """Static inventory of every Python module in the package; nothing is executed."""
    bridge = _bridge()
    sources = package.python_sources()
    if len(sources) > MAX_MODULES:
        raise _reject("Package exceeds its module limit")
    if package.main.endswith(".py") and package.main not in sources:
        raise _reject("Main file lies inside a data directory of the package")
    imports, classes, findings, dynamic = set(), set(), [], False
    imported_symbols, unsupported, texts = {}, {}, {}
    # What the package uses of the SDK's host-backed entry points. A package is one plugin, so a
    # method name counts as its own when any of its modules defines a function of that name.
    references, called, defined, fields = set(), set(), set(), set()
    conditions, dynamic_conditions = set(), False
    environment = {"settings", "refmap", "metainfo", "import_module"}
    if package.assets:
        environment.add("assets")
    if package.strings:
        environment.add("strings")
    elyx_names = _elyx_names() | environment
    for name in sources:
        try:
            text = package.read(name, MAX_SOURCE_BYTES).decode("utf-8")
            tree = ast.parse(text, filename=name)
        except (UnicodeDecodeError, SyntaxError, ValueError, RecursionError):
            if name == package.main:
                raise _reject("Package main module is not valid UTF-8 Python source")
            findings.append("module is not valid Python source: " + name)
            continue
        texts[name] = text
        inventory = bridge._inventory(tree)
        modules, symbols, elyx, wildcard = _module_imports(tree)
        if wildcard:
            raise _reject("Wildcard native imports are unsupported")
        local = {module for module in modules if package.is_local(module, name)}
        for module in modules - local:
            if module.split(".", 1)[0] == PUBLIC_MODULE:
                if module != PUBLIC_MODULE:
                    unsupported.setdefault(PUBLIC_MODULE, set()).add(module.split(".", 1)[1])
                continue
            imports.add(module)
        for missing in sorted(elyx - elyx_names):
            unsupported.setdefault(PUBLIC_MODULE, set()).add(missing)
        for module, names in inventory["unsupported_sdk_symbols"].items():
            if module not in local and module.split(".", 1)[0] != PUBLIC_MODULE:
                unsupported.setdefault(module, set()).update(names)
        for module, names in inventory["imported_symbols"].items():
            if module not in local and module.split(".", 1)[0] != PUBLIC_MODULE:
                imported_symbols.setdefault(module, set()).update(names)
        classes.update(inventory["classes"])
        dynamic = dynamic or bool(inventory["dynamic_class_lookup_lines"])
        references.update(reference for reference in inventory["sdk_references"]
                          if reference.split(".", 1)[0] not in local)
        called.update(inventory["method_calls"])
        fields.update(inventory.get("field_reads", ()))
        found, computed = _ayu_mvel.static_conditions(tree)
        conditions.update(found)
        dynamic_conditions = dynamic_conditions or bool(computed)
        defined.update(node.name for node in ast.walk(tree)
                       if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef)))
    if package.main.endswith(".pyc") or package.bytecode_files():
        findings.append("compiled Python bytecode")
    if package.wheels:
        findings.append("bundled wheels")
    for plugin_id, version in package.requires:
        if not _provided_plugin(plugin_id, version):
            findings.append("required plugin " + plugin_id)
    warnings = []
    if dynamic:
        warnings.append("DYNAMIC_CLASSES: computed native classes are checked only at runtime")
    if dynamic_conditions:
        warnings.append("DYNAMIC_MENU_CONDITIONS: computed menu conditions are checked only at runtime")
    if any(name.rsplit(".", 1)[-1] in ("dex", "dexan", "so", "jar", "apk") or name.endswith(".dex.gz")
           for name in package.files):
        warnings.append("NATIVE_PAYLOAD: Android binaries in the package cannot be loaded")
    unsupported_imports = {name: bridge.UNSUPPORTED_IMPORTS[name.split(".")[0]] for name in sorted(imports)
                           if name.split(".")[0] in bridge.UNSUPPORTED_IMPORTS}
    report = {
        "package": True, "metadata": package.metadata, "main": package.main,
        "refmap": {key: value for key, value in package.refmap.items() if isinstance(value, str)},
        "modules": sorted(sources), "entries": len(package.files), "unpacked_bytes": package.total_bytes,
        "imports": sorted(imports), "classes": sorted(classes),
        "requirements": list(package.metadata.get("__requirements__", [])), "warnings": warnings,
        "unsupported_imports": unsupported_imports,
        "imported_symbols": {module: sorted(names) for module, names in sorted(imported_symbols.items())},
        "unsupported_sdk_symbols": {module: sorted(names) for module, names in sorted(unsupported.items())},
        "sdk_requirements": _ayu_operations.requirements(sorted(references), sorted(called - defined),
                                                         field_reads=sorted(fields)),
        "package_findings": findings, "menu_conditions": sorted(conditions),
    }
    try:
        json.dumps(report, allow_nan=False)
    except (TypeError, ValueError) as error:
        raise _reject("Package metadata must contain finite JSON-compatible values") from error
    return report, texts


def _blockers(runtime, report, capabilities):
    """The blockers of an analyzed package, in the order ``preflight_plugin_json`` reports them."""
    blockers = []

    def block(code, detail):
        blockers.append({"code": code, "detail": detail})

    for module, symbols in report["unsupported_sdk_symbols"].items():
        for symbol in symbols:
            block("SDK_MEMBER", module + "." + symbol)
    for name in report["unsupported_imports"]:
        block("IMPORT", name)
    for name in _ayu_threads.unavailable_imports(report["imports"], capabilities["operations"]):
        block("IMPORT", name)
    declared = runtime._declared_classes(capabilities)
    for name in report["classes"]:
        if name not in declared:
            block("CLASS", name)
    for name in runtime._undeclared_imports(report["imports"], report["imported_symbols"], declared,
                                            capabilities["modules"]):
        block("DEPENDENCY", name)
    for finding in runtime._unbundled_requirements(report["requirements"], capabilities):
        block("REQUIREMENT", finding)
    for finding in _ayu_policy.version_findings(report["metadata"]):
        block("VERSION_POLICY", finding)
    # SDK entry points the package references whose host operations are not declared.
    for finding in _ayu_operations.missing(report["sdk_requirements"], capabilities["operations"]):
        block("OPERATION", finding)
    for code, detail in _ayu_mvel.preflight(report["menu_conditions"], capabilities):
        if {"code": code, "detail": detail} not in blockers:
            block(code, detail)
    for finding in report["package_findings"]:
        block("PACKAGE", finding)
    return blockers


def inspect_package_json(runtime, path, filename="plugin.elyx"):
    runtime.check_queue()
    package = Package(path)
    try:
        report, _ = analyze(package)
    finally:
        package.close()
    return json.dumps(report, allow_nan=False)


def preflight_package_json(runtime, path, filename="plugin.elyx"):
    report = json.loads(inspect_package_json(runtime, path, filename))
    report["blockers"] = _blockers(runtime, report, runtime._capabilities())
    return json.dumps(report, allow_nan=False)


# ---- runtime ----------------------------------------------------------------

class _Loaded:
    """The package of one loaded plugin generation: sources in memory, files on disk."""

    def __init__(self, package, texts, root):
        self.plugin_id = package.metadata["__id__"]
        self.root = root
        self.refmap, self.metainfo, self.strings = package.refmap, package.metainfo, package.strings
        self.assets = package.assets
        self.sources = texts
        self.data = {name: package.read(name, MAX_DATA_BYTES) for name in package.files
                     if name.endswith(_DATA_SUFFIXES) and not package._excluded(name)
                     and package.files[name].file_size <= MAX_DATA_BYTES}
        self.files = frozenset(package.files)
        self.directories = frozenset(package.directories)
        self._builtins = None
        self._strings = None

    def resolve(self, dotted):
        return _resolve(self.files, self.directories, dotted)

    def environment(self):
        from elyxcore.assets import Assets
        from elyxcore.localization import Strings
        from elyxcore.settings import SettingsController
        values = {"settings": SettingsController(self.plugin_id), "refmap": self.refmap, "metainfo": self.metainfo}
        if self.assets:
            values["assets"] = Assets(os.path.join(self.root, *self.assets.split("/")))
        if self.strings:
            if self._strings is None:
                self._strings = Strings(self.strings)
            values["strings"] = self._strings
        return values

    def builtins(self):
        """Module builtins whose ``__import__`` finds the package's own modules first, as on Android."""
        if self._builtins is None:
            real_import = builtins.__import__
            prefix = f"{PLUGIN_NAMESPACE}.{self.plugin_id}."

            def scoped_import(name, globals=None, locals=None, fromlist=(), level=0):
                if level != 0 or not name:
                    return real_import(name, globals, locals, fromlist, level)
                if name.split(".", 1)[0] not in _EXTERNAL_ROOTS and self.resolve(name) is not None:
                    module = importlib.import_module(prefix + name)
                    return module if fromlist else sys.modules[prefix + name.split(".", 1)[0]]
                return real_import(name, globals, locals, fromlist, level)

            values = dict(vars(builtins))
            values["__import__"] = scoped_import
            self._builtins = values
        return self._builtins


def _loaded(required=True):
    """The package of the calling plugin generation."""
    scope = _bridge().runtime.require()
    loaded = scope.__dict__.get("_ayu_package")
    if loaded is None and required:
        raise RuntimeError("Elyx environment is only available from plugin code")
    return loaded


def environment():
    return _loaded().environment()


def import_module(name, package=None):
    if name.startswith("."):
        if not package:
            raise TypeError("package is required for a relative import")
        return importlib.import_module(name, package)
    loaded = _loaded(required=False)
    if loaded is not None and loaded.resolve(name) is not None:
        return importlib.import_module(f"{PLUGIN_NAMESPACE}.{loaded.plugin_id}.{name}")
    return importlib.import_module(name, package)


class _DataModule(types.ModuleType):
    def __getitem__(self, key):
        return self._data[key]

    def get(self, key, default=None):
        return self._data.get(key, default)

    def __contains__(self, key):
        return key in self._data

    def __str__(self):
        return str(self._data)


def environment_value(name):
    """A package-bound attribute of the ``elyx`` module for the calling plugin."""
    if name in ENVIRONMENT_NAMES:
        try:
            loaded = _loaded(required=False)
        except _bridge().BridgeError:
            loaded = None
        if loaded is not None:
            values = loaded.environment()
            if name in values:
                return values[name]
    raise AttributeError(f"module 'elyx' has no attribute {name!r}")


class _Importer(importlib.abc.MetaPathFinder, importlib.abc.Loader):
    def find_spec(self, fullname, path=None, target=None):
        if fullname != PLUGIN_NAMESPACE and not fullname.startswith(PLUGIN_NAMESPACE + "."):
            return None
        if fullname == PLUGIN_NAMESPACE:
            spec = importlib.util.spec_from_loader(fullname, self, is_package=True)
            spec.loader_state = {"kind": "namespace"}
            spec.submodule_search_locations = []
            return spec
        parts = fullname.split(".")
        try:
            loaded = _loaded(required=False)
        except _bridge().BridgeError:
            return None
        # A plugin imports its own package only.
        if loaded is None or loaded.plugin_id != parts[1]:
            return None
        resolved = loaded.resolve(".".join(parts[2:]))
        if resolved is None:
            return None
        name, kind, is_package = resolved
        origin = os.path.join(loaded.root, *name.split("/")) if name else loaded.root
        spec = importlib.util.spec_from_loader(fullname, self, origin=origin, is_package=is_package)
        spec.loader_state = {"kind": kind, "name": name, "generation": id(loaded)}
        if is_package:
            spec.submodule_search_locations = [origin if kind == "namespace" else os.path.dirname(origin)]
        return spec

    def create_module(self, spec):
        if (spec.loader_state or {}).get("kind") == "data":
            return _DataModule(spec.name)
        return None

    def exec_module(self, module):
        state = module.__spec__.loader_state or {}
        kind = state.get("kind")
        if kind == "namespace":
            return
        loaded = _loaded()
        if state.get("generation") != id(loaded):
            raise ImportError(f"Elyx module {module.__name__} belongs to another plugin generation")
        name = state["name"]
        module.__dict__["__builtins__"] = loaded.builtins()
        try:
            if kind == "source":
                source = loaded.sources.get(name)
                if source is None:
                    raise ImportError(f"Elyx module {module.__name__} was not part of the inspected package")
                module.__file__ = module.__spec__.origin
                exec(compile(source, module.__spec__.origin, "exec", dont_inherit=True), module.__dict__)
            elif kind == "bytecode":
                raise ImportError(f"Incompatible bytecode file: {name}")
            elif kind == "data":
                raw = loaded.data.get(name)
                if raw is None:
                    raise ImportError(f"Elyx data module {module.__name__} exceeds its size limit")
                if name.endswith(".txt"):
                    module.content = raw.decode("utf-8")
                else:
                    from elyxcore.utils import LazyDict
                    data = _data(raw, name)
                    module._data = data
                    for key, value in data.items():
                        setattr(module, key, LazyDict(value) if isinstance(value, dict) else value)
        except ImportError:
            sys.modules.pop(module.__name__, None)
            raise
        except _bridge().BridgeError:
            sys.modules.pop(module.__name__, None)
            raise
        except Exception as error:
            sys.modules.pop(module.__name__, None)
            raise ImportError(f"Failed to load Elyx module {module.__name__}") from error


_importer = _Importer()


def _install_importer():
    if _importer not in sys.meta_path:
        sys.meta_path.insert(0, _importer)


def _forget_modules(plugin_id, root=None):
    """Drop every module of a plugin generation, including ones it imported from its unpacked files."""
    prefix = f"{PLUGIN_NAMESPACE}.{plugin_id}"
    for name, module in tuple(sys.modules.items()):
        origin = getattr(module, "__file__", None)
        if name == prefix or name.startswith(prefix + ".") or (
                root and isinstance(origin, str) and origin.startswith(root)):
            sys.modules.pop(name, None)
    if root:
        directory = root.rstrip(os.sep)
        sys.path[:] = [entry for entry in sys.path
                       if not (isinstance(entry, str) and (entry == directory or entry.startswith(root)))]
        for entry in [entry for entry in sys.path_importer_cache
                      if isinstance(entry, str) and (entry == directory or entry.startswith(root))]:
            sys.path_importer_cache.pop(entry, None)


def _directory(root, parts):
    """Create ``root/parts`` one level at a time, refusing to pass through a link."""
    path = root
    for part in parts:
        path = os.path.join(path, part)
        # An earlier run of the plugin may have left a link that leads outside its directory.
        if os.path.islink(path) or os.path.exists(path) and not os.path.isdir(path):
            raise _reject("Package storage holds a link or file where a package directory belongs")
        if not os.path.isdir(path):
            os.mkdir(path)
    return path


def _new_file(path):
    """Create ``path`` as a new regular file; a link or anything else already there is never written through."""
    try:
        status = os.lstat(path)
    except FileNotFoundError:
        status = None
    except OSError as error:
        raise _reject("Package storage cannot be examined") from error
    if status is not None:
        if not stat.S_ISREG(status.st_mode):
            raise _reject("Package storage holds a link or directory where a package file belongs")
        # What an interrupted unpack left behind. It is removed, not opened.
        os.unlink(path)
    try:
        return os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o644)
    except OSError as error:
        raise _reject("Package storage holds a link or directory where a package file belongs") from error


def _write_file(package, name, target, budget):
    """Stream one entry to ``target`` through a new temporary file; returns the bytes written."""
    try:
        status = os.lstat(target)
    except FileNotFoundError:
        status = None
    except OSError as error:
        raise _reject("Package storage cannot be examined") from error
    if status is not None and not stat.S_ISREG(status.st_mode):
        raise _reject("Package storage holds a link or directory where a package file belongs")
    temporary = target + _UNPACK_SUFFIX
    descriptor = _new_file(temporary)
    written = 0
    try:
        try:
            for data in package.chunks(name):
                written += len(data)
                if written > min(budget, MAX_ENTRY_BYTES):
                    raise _reject("Package exceeds its unpacked size limit")
                view = memoryview(data)
                while view:
                    view = view[os.write(descriptor, view):]
        finally:
            os.close(descriptor)
        os.replace(temporary, target)
    except BaseException:
        try:
            os.unlink(temporary)
        except OSError:
            pass
        raise
    return written


def _unpack(package, root):
    """Write the package's files below ``root`` without ever leaving it or following a link."""
    os.makedirs(root, exist_ok=True)
    if os.path.islink(root):
        raise _reject("Package storage is a link")
    for name in sorted(package.directories):
        _directory(root, name.split("/"))
    total = 0
    for name in package.files:
        parts = name.split("/")
        target = os.path.join(_directory(root, parts[:-1]), parts[-1])
        try:
            total += _write_file(package, name, target, MAX_TOTAL_BYTES - total)
        except OSError as error:
            raise _reject(f"Package file {name} cannot be unpacked") from error


def load_package(runtime, path, filename="plugin.elyx", expected_id=None):
    """Load a package with the lifecycle ``Runtime.load_plugin`` gives a ``.plugin`` file."""
    bridge = _bridge()
    runtime.check_queue()
    package = Package(path)
    try:
        report, texts = analyze(package)
        metadata = report["metadata"]
        plugin_id = metadata["__id__"]
        if expected_id is not None and expected_id != plugin_id:
            raise _reject("Plugin ID does not match trusted expected ID")
        if plugin_id in runtime.scopes:
            raise bridge.BridgeError("ALREADY_LOADED", "Unload the current plugin generation first")
        if len(runtime.scopes) >= 32:
            raise bridge.BridgeError("RESOURCE_LIMIT", "Loaded plugin limit reached")
        capabilities = runtime._capabilities()
        if runtime.scopes and runtime.capabilities != capabilities:
            raise bridge.ProtocolError("Host capabilities changed while plugins are active")
        runtime.capabilities = capabilities
        for blocker in _blockers(runtime, report, capabilities):
            raise _reject(f"Package is blocked: {blocker['code']} {blocker['detail']}")
        host_classes = [name for name in report["classes"] if name in capabilities["classes"]
                        and name not in capabilities["local_classes"]]
        approval = runtime._dispatch(plugin_id, "plugin.authorize", {
            "metadata": metadata, "imports": report["imports"], "classes": host_classes, "requirements": [],
            "version_policy": {"app_version": _ayu_policy.APP_VERSION, "sdk_version": _ayu_policy.SDK_VERSION}})
        if approval is not True:
            raise _reject("Host did not explicitly authorize execution")
        scope = bridge.Scope(plugin_id, metadata=metadata)
        runtime.scopes[plugin_id] = scope
        try:
            with runtime.context(scope):
                from file_utils import get_plugins_dir
                root = os.path.join(get_plugins_dir(), PLUGIN_NAMESPACE, plugin_id)
                scope.source_filename = os.path.join(root, *package.main.split("/"))
                scope.source_root = root + os.sep
                with runtime.budget(scope, "load"):
                    runtime.call("plugin.activate", {"metadata": metadata, "generation": scope.generation})
                    bridge.install_native_importer()
                    _install_importer()
                    _forget_modules(plugin_id, scope.source_root)
                    _ayu_threads.add_closer(lambda: _forget_modules(plugin_id, root + os.sep))
                    _unpack(package, root)
                    scope.__dict__["_ayu_package"] = _Loaded(package, texts, root)
                    module = importlib.import_module(package.module_name(package.main))
                    scope.module, scope.module_key = module, module.__name__
                    from base_plugin import BasePlugin
                    candidates = [value for value in module.__dict__.values()
                                  if isinstance(value, type) and issubclass(value, BasePlugin) and value is not BasePlugin]
                    if not candidates:
                        raise _reject("Could not find a class inheriting from BasePlugin in the package main module")
                    scope.instance = candidates[0]()
                    if package.strings:
                        scope.instance.strings = package.strings
                    scope.instance.on_plugin_load()
                    scope.state = "active"
            return {"plugin_id": plugin_id, "metadata": metadata, "generation": scope.generation}
        except BaseException:
            with runtime.context(scope):
                runtime._cleanup(scope)
            raise
    finally:
        package.close()
