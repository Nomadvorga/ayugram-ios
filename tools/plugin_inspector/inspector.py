"""Bounded, non-executing AST inspection of Android Telegram Python plugins."""
from __future__ import annotations

import argparse
import ast
import hashlib
import json
import re
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Any

STATUSES = {"supported", "partial", "unsupported", "unknown"}
MAX_SOURCE_BYTES = 2 * 1024 * 1024
MAX_MANIFEST_BYTES = 1024 * 1024
MAX_NODES = 100_000
JAVA_PREFIXES = ("android.", "androidx.", "java.", "javax.", "org.telegram.", "com.exteragram.")
SENSITIVE = re.compile(r"(?i)(?:api[_-]?key|secret|password|bearer|access[_-]?token|sk-[a-z0-9])")
IDENTIFIER = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*(?:[.$][A-Za-z_][A-Za-z0-9_]*)*$")
REFLECTION = {"getClass", "getDeclaredMethod", "getDeclaredMethods", "getMethod", "getMethods", "getDeclaredField", "getDeclaredFields", "getField", "setAccessible", "invoke", "newInstance"}
HOOKS = {"hook_method", "hook_all_methods", "hook_all_constructors", "unhook_method"}
DYNAMIC = {"eval", "exec", "compile", "__import__"}
KNOWN_NATIVE = {"numpy", "scipy", "PIL", "cv2", "torch", "cryptography", "lxml", "cffi", "_ctypes"}
LIMITATIONS = [
    "Static inspection is not execution, a security audit, or proof of runtime compatibility.",
    "Imports and calls in unexecuted branches are included; branch reachability is not proven.",
    "Interprocedural flow, descriptors, monkey patches, computed names, and external modules are not evaluated.",
    "A supported finding means the supplied manifest declares that exact API implemented; the implementation is not verified here.",
]


class ManifestError(ValueError):
    """A manifest cannot be trusted for classification."""


def safe_symbol(value: Any) -> str:
    """Emit API-like names only; never arbitrary literals or source excerpts."""
    if not isinstance(value, str) or len(value) > 180 or SENSITIVE.search(value):
        return "<redacted>"
    if not IDENTIFIER.fullmatch(value):
        return "<computed-or-redacted>"
    # Long opaque identifiers may be credentials masquerading as class/method names.
    if any(len(part) > 64 for part in re.split(r"[.$]", value)):
        return "<redacted>"
    return value


def java_label(value: Any) -> str:
    if isinstance(value, str) and value.startswith(JAVA_PREFIXES):
        return safe_symbol(value)
    return "<unlisted-or-computed-class>"


def _validate_entry(entry: Any, depth: int = 0) -> None:
    if depth > 16 or not isinstance(entry, dict) or not isinstance(entry.get("status"), str) or entry.get("status") not in STATUSES:
        raise ManifestError("Invalid capability entry.")
    if "implementation" in entry and not isinstance(entry["implementation"], str):
        raise ManifestError("Invalid implementation reference.")
    if "returns" in entry and not isinstance(entry["returns"], str):
        raise ManifestError("Invalid return type declaration.")
    for key in ("symbols", "members"):
        if key in entry:
            if not isinstance(entry[key], dict):
                raise ManifestError("Invalid capability members.")
            for name, child in entry[key].items():
                if not isinstance(name, str) or len(name) > 256:
                    raise ManifestError("Invalid capability name.")
                _validate_entry(child, depth + 1)


def validate_manifest(data: Any) -> dict[str, Any]:
    if not isinstance(data, dict) or type(data.get("schema_version")) is not int or data.get("schema_version") != 1:
        raise ManifestError("Unsupported manifest schema.")
    for section in ("modules", "java_classes", "features", "dependencies"):
        values = data.get(section, {})
        if not isinstance(values, dict):
            raise ManifestError("Invalid manifest section.")
        for name, entry in values.items():
            if not isinstance(name, str) or len(name) > 256:
                raise ManifestError("Invalid capability name.")
            _validate_entry(entry)
    python = data.get("python", {})
    if not isinstance(python, dict) or not isinstance(python.get("stdlib", []), list):
        raise ManifestError("Invalid Python runtime declaration.")
    if not all(isinstance(name, str) and name.isidentifier() for name in python.get("stdlib", [])):
        raise ManifestError("Invalid standard library list.")
    if any(python.get(key) is not None and not isinstance(python[key], str) for key in ("version", "implementation")):
        raise ManifestError("Invalid Python runtime provenance.")
    return data


def load_manifest(path: Path | str | None = None) -> dict[str, Any]:
    path = Path(path) if path is not None else Path(__file__).with_name("support-manifest.json")
    try:
        with path.open("rb") as stream:
            raw = stream.read(MAX_MANIFEST_BYTES + 1)
        if len(raw) > MAX_MANIFEST_BYTES:
            raise ManifestError("Manifest exceeds size limit.")
        return validate_manifest(json.loads(raw))
    except (OSError, UnicodeError, json.JSONDecodeError, RecursionError, MemoryError) as error:
        # Do not echo attacker-controlled manifest content or filesystem paths.
        raise ManifestError("Cannot read a valid support manifest.") from error


@dataclass(frozen=True)
class Ref:
    kind: str
    name: str


class Inspector(ast.NodeVisitor):
    def __init__(self, manifest: dict[str, Any]):
        self.manifest = manifest
        self.scopes: list[dict[str, Ref | None]] = [{}]
        self.constants: list[dict[str, str | None]] = [{}]
        self.phase = "import"
        self.class_base: Ref | None = None
        self.findings: list[dict[str, Any]] = []
        self.seen: set[tuple[Any, ...]] = set()
        self.metadata: dict[str, Any] = {}

    def binding(self, name: str) -> Ref | None:
        for scope in reversed(self.scopes):
            if name in scope:
                return scope[name]
        return None

    def literal(self, node: ast.AST | None) -> str | None:
        if isinstance(node, ast.Constant) and isinstance(node.value, str):
            return node.value
        if isinstance(node, ast.Name):
            for scope in reversed(self.constants):
                if node.id in scope:
                    return scope[node.id]
        return None

    def entry(self, ref: Ref) -> dict[str, Any] | None:
        if ref.kind in {"java_class", "java_instance"}:
            return self.manifest.get("java_classes", {}).get(ref.name)
        if ref.kind == "java_member":
            owner, _, name = ref.name.rpartition("::")
            return self.manifest.get("java_classes", {}).get(owner, {}).get("members", {}).get(name)
        if ref.kind in {"module", "symbol"}:
            modules = self.manifest.get("modules", {})
            if ref.name in modules:
                return modules[ref.name]
            parts = ref.name.split(".")
            for count in range(len(parts) - 1, 0, -1):
                base = ".".join(parts[:count])
                if base not in modules:
                    continue
                entry = modules[base]
                for index, part in enumerate(parts[count:]):
                    entry = entry.get("symbols" if index == 0 else "members", {}).get(part)
                    if entry is None:
                        return None
                return entry
        return None

    def status(self, entry: dict[str, Any] | None) -> str:
        if entry is None:
            return "unknown"
        status = entry["status"]
        # A wish list or a stub without provenance cannot assert implementation.
        if status in {"supported", "partial"} and not entry.get("implementation", "").strip():
            return "unknown"
        return status

    def add(self, node: ast.AST, category: str, target: str, status: str, reason: str) -> None:
        target = safe_symbol(target) if not target.startswith("<") else target
        key = (getattr(node, "lineno", 0), getattr(node, "col_offset", 0), category, target)
        if key in self.seen:
            return
        self.seen.add(key)
        self.findings.append({
            "category": category, "target": target, "status": status,
            "line": getattr(node, "lineno", 0), "column": getattr(node, "col_offset", 0) + 1,
            "phase": self.phase, "reason": reason,
        })

    def feature(self, node: ast.AST, feature: str, reason: str, force_unknown: bool = False) -> None:
        status = "unknown" if force_unknown else self.status(self.manifest.get("features", {}).get(feature))
        self.add(node, "feature", feature, status, reason)

    def require(self, node: ast.AST, ref: Ref, category: str) -> None:
        target = ref.name.replace("::", ".")
        self.add(node, category, target, self.status(self.entry(ref)), "Exact API declaration in the supplied manifest is required.")

    def resolve(self, node: ast.AST | None) -> Ref | None:
        if isinstance(node, ast.Name):
            return self.binding(node.id)
        if isinstance(node, ast.Attribute):
            parent = self.resolve(node.value)
            if parent is None:
                return None
            if parent.kind in {"java_class", "java_instance"}:
                return Ref("java_member", parent.name + "::" + node.attr)
            if parent.kind == "unresolved_java":
                return parent
            if parent.kind == "java_member":
                return Ref("unresolved_java", parent.name.split("::")[0])
            name = parent.name + "." + node.attr
            if name.startswith(JAVA_PREFIXES) and name in self.manifest.get("java_classes", {}):
                return Ref("java_class", name)
            return Ref("symbol", name)
        if isinstance(node, ast.Call):
            function = self.resolve(node.func)
            if function is None:
                return None
            if function.name in {"java.jclass", "hook_utils.find_class"}:
                name = self.literal(node.args[0]) if node.args else None
                return Ref("java_class", name) if name and safe_symbol(name) == name and name.startswith(JAVA_PREFIXES) else None
            if function.kind == "java_class":
                return Ref("java_instance", function.name)
            if function.kind == "java_member":
                owner, _, member = function.name.rpartition("::")
                if member == "getClass":
                    return Ref("java_class", owner)
                result = (self.entry(function) or {}).get("returns")
                if result == "self":
                    return Ref("java_instance", owner)
                if result in self.manifest.get("java_classes", {}):
                    return Ref("java_instance", result)
                return Ref("unresolved_java", owner)
            if function.name == "base_plugin.BasePlugin":
                return function
        return None

    def visit_Import(self, node: ast.Import) -> None:
        for alias in node.names:
            self.check_import(node, alias.name)
            name = alias.asname or alias.name.split(".")[0]
            self.scopes[-1][name] = Ref("module", alias.name if alias.asname else name)
            self.constants[-1][name] = None

    def visit_ImportFrom(self, node: ast.ImportFrom) -> None:
        module = node.module or ""
        if node.level:
            self.feature(node, "relative_import", "Local plugin module contents were not inspected.", True)
        if not module.startswith(JAVA_PREFIXES):
            self.check_import(node, module)
        for alias in node.names:
            if alias.name == "*":
                self.feature(node, "wildcard_import", "Wildcard names cannot be resolved statically.", True)
                continue
            full = module + "." + alias.name if module else alias.name
            kind = "java_class" if module.startswith(JAVA_PREFIXES) else "symbol"
            ref = Ref(kind, full)
            self.scopes[-1][alias.asname or alias.name] = ref
            self.constants[-1][alias.asname or alias.name] = None
            if kind == "java_class":
                self.require(node, ref, "java_class_import")
                if any(part in full for part in ("WindowManager", "DexClassLoader", "PathClassLoader", "Runtime")):
                    self.feature(node, "restricted_android_api", "Android system overlay, VM, or code-loading API needs an explicit policy and platform mapping.")
            elif module in self.manifest.get("modules", {}) or module in {"java", "base_plugin", "client_utils", "hook_utils", "android_utils"} or module.startswith("ui."):
                self.require(node, ref, "imported_symbol")

    def check_import(self, node: ast.AST, module: str) -> None:
        root = module.split(".")[0]
        if root in {"subprocess", "multiprocessing"}:
            self.add(node, "platform_restriction", root, "unsupported", "Spawning external processes is unavailable in the intended iOS bridge.")
        elif root in KNOWN_NATIVE:
            entry = self.manifest.get("dependencies", {}).get(root)
            self.add(node, "native_dependency", root, self.status(entry), "Native extensions require an explicit iOS build and packaging declaration.")
        elif module in self.manifest.get("modules", {}):
            self.require(node, Ref("module", module), "module_import")
        elif module.startswith(JAVA_PREFIXES):
            self.add(node, "java_namespace", module, "unknown", "Java namespace imports require a concrete class or member mapping.")
        elif root in self.manifest.get("python", {}).get("stdlib", []):
            runtime = self.manifest.get("python", {})
            status = "supported" if runtime.get("version") and runtime.get("implementation") else "unknown"
            self.add(node, "stdlib_import", module, status, "Availability depends on the declared embedded Python distribution.")
        else:
            entry = self.manifest.get("dependencies", {}).get(root)
            self.add(node, "dependency_import", module, self.status(entry), "Dependency must be explicitly shipped or provided by the bridge.")
        if root in {"ctypes", "cffi"}:
            self.feature(node, "native_ffi", "FFI can bypass the bridge; native code cannot be inferred from Python AST.")

    def visit_Assign(self, node: ast.Assign) -> None:
        self.visit(node.value)
        ref = self.resolve(node.value)
        literal = self.literal(node.value)
        for target in node.targets:
            self.bind_target(target, ref, literal)
            if len(self.scopes) == 1 and isinstance(target, ast.Name):
                self.capture_metadata(target.id, node.value)
            if not isinstance(target, ast.Name):
                self.visit(target)

    def visit_AnnAssign(self, node: ast.AnnAssign) -> None:
        if node.value is not None:
            self.visit(node.value)
        self.bind_target(node.target, self.resolve(node.value), self.literal(node.value))
        self.visit(node.annotation)

    def visit_AugAssign(self, node: ast.AugAssign) -> None:
        self.bind_target(node.target, None, None)
        self.generic_visit(node)

    def visit_NamedExpr(self, node: ast.NamedExpr) -> None:
        self.visit(node.value)
        self.bind_target(node.target, self.resolve(node.value), self.literal(node.value))

    def visit_Delete(self, node: ast.Delete) -> None:
        for target in node.targets:
            self.bind_target(target, None, None)

    def visit_Global(self, node: ast.Global) -> None:
        self.feature(node, "scope_mutation", "Global binding mutation is not resolved across functions.", True)

    visit_Nonlocal = visit_Global

    def bind_target(self, target: ast.AST, ref: Ref | None, literal: str | None) -> None:
        if isinstance(target, ast.Name):
            self.scopes[-1][target.id] = ref
            self.constants[-1][target.id] = literal
        elif isinstance(target, (ast.Tuple, ast.List)):
            for item in target.elts:
                self.bind_target(item, None, None)

    def capture_metadata(self, name: str, value: ast.AST) -> None:
        if name in {"__id__", "__name__", "__version__", "__sdk_version__", "__app_version__", "__min_version__"}:
            text = value.value if isinstance(value, ast.Constant) and isinstance(value.value, str) else None
            key = name.strip("_")
            if text is None or len(text) > 96 or SENSITIVE.search(text) or any(ord(ch) < 32 for ch in text):
                self.metadata[key] = "<computed-or-redacted>"
            elif name == "__name__" and all(ch.isalnum() or ch in " _.-+()" for ch in text):
                self.metadata[key] = text
            elif name != "__name__" and re.fullmatch(r"[A-Za-z0-9_.+<>=!*, -]{1,96}", text):
                self.metadata[key] = text
            else:
                self.metadata[key] = "<computed-or-redacted>"
        elif name == "__requirements__":
            if isinstance(value, (ast.List, ast.Tuple)):
                for item in value.elts:
                    text = item.value if isinstance(item, ast.Constant) else None
                    match = re.fullmatch(r"([A-Za-z][A-Za-z0-9_.-]*)(?:\[[A-Za-z0-9_, -]+\])?(?:[<>=!~][A-Za-z0-9_.+<>=!~*, -]*)?", text or "") if isinstance(text, str) else None
                    if match:
                        package = match.group(1)
                        entry = self.manifest.get("dependencies", {}).get(package)
                        self.add(item, "declared_dependency", package, self.status(entry), "Declared package must be provided by the iOS runtime.")
                        if package.replace("-", "_") in KNOWN_NATIVE or (entry or {}).get("native") is True:
                            self.add(item, "native_dependency", package, self.status(entry), "Declared native package needs an explicit iOS build and packaging declaration.")
                    else:
                        self.feature(item, "dynamic_dependency", "Non-package requirement or computed dependency is not evaluated.", True)
            else:
                self.feature(value, "dynamic_dependency", "Computed dependency metadata is not evaluated.", True)

    def visit_FunctionDef(self, node: ast.FunctionDef | ast.AsyncFunctionDef) -> None:
        # Decorators, defaults, and annotations execute while defining the function.
        for expr in node.decorator_list + node.args.defaults + [v for v in node.args.kw_defaults if v is not None]:
            self.visit(expr)
        for arg in node.args.posonlyargs + node.args.args + node.args.kwonlyargs:
            if arg.annotation:
                self.visit(arg.annotation)
        if node.returns:
            self.visit(node.returns)
        self.scopes[-1][node.name] = None
        self.constants[-1][node.name] = None
        arguments = node.args.posonlyargs + node.args.args + node.args.kwonlyargs
        scope = {arg.arg: None for arg in arguments}
        if node.args.vararg:
            scope[node.args.vararg.arg] = None
        if node.args.kwarg:
            scope[node.args.kwarg.arg] = None
        if arguments and arguments[0].arg == "self" and self.class_base:
            scope["self"] = self.class_base
        self.scopes.append(scope)
        self.constants.append({name: None for name in scope})
        old_phase = self.phase
        self.phase = "runtime"
        for statement in node.body:
            self.visit(statement)
        self.phase = old_phase
        self.constants.pop()
        self.scopes.pop()

    visit_AsyncFunctionDef = visit_FunctionDef

    def visit_Lambda(self, node: ast.Lambda) -> None:
        for default in node.args.defaults + [v for v in node.args.kw_defaults if v is not None]:
            self.visit(default)
        args = node.args.posonlyargs + node.args.args + node.args.kwonlyargs
        scope = {arg.arg: None for arg in args}
        self.scopes.append(scope)
        self.constants.append({key: None for key in scope})
        old_phase, self.phase = self.phase, "runtime"
        self.visit(node.body)
        self.phase = old_phase
        self.constants.pop()
        self.scopes.pop()

    def visit_ClassDef(self, node: ast.ClassDef) -> None:
        previous_base = self.class_base
        self.class_base = None
        for base in node.bases:
            self.visit(base)
            ref = self.resolve(base)
            if ref and ref.name == "base_plugin.BasePlugin":
                self.class_base = ref
            if ref and ref.name in {"base_plugin.MethodHook", "base_plugin.MethodReplacement"}:
                self.feature(base, "method_hooks", "MethodHook subclasses require explicit host lifecycle or method interception points.")
        for item in node.decorator_list + [kw.value for kw in node.keywords]:
            self.visit(item)
        self.scopes[-1][node.name] = None
        self.constants[-1][node.name] = None
        self.scopes.append({})
        self.constants.append({})
        for statement in node.body:
            self.visit(statement)
        self.constants.pop()
        self.scopes.pop()
        self.class_base = previous_base

    def merge_branches(self, node: ast.AST, branches: list[list[ast.stmt]]) -> None:
        initial_scopes = [scope.copy() for scope in self.scopes]
        initial_constants = [scope.copy() for scope in self.constants]
        outcomes = []
        for branch in branches:
            self.scopes = [scope.copy() for scope in initial_scopes]
            self.constants = [scope.copy() for scope in initial_constants]
            for statement in branch:
                self.visit(statement)
            outcomes.append((self.scopes, self.constants))
        uncertain = False
        merged = []
        for which in (0, 1):
            scopes = []
            for level in range(len(initial_scopes)):
                keys = set().union(*(outcome[which][level] for outcome in outcomes))
                scope = {}
                for key in keys:
                    values = [outcome[which][level].get(key) for outcome in outcomes]
                    scope[key] = values[0] if all(value == values[0] for value in values) else None
                    if which == 0 and scope[key] is None and any(value is not None for value in values):
                        uncertain = True
                scopes.append(scope)
            merged.append(scopes)
        self.scopes, self.constants = merged
        if uncertain:
            self.feature(node, "conditional_binding", "Branches bind different API aliases; the selected target requires runtime validation.", True)

    def visit_If(self, node: ast.If) -> None:
        self.visit(node.test)
        self.merge_branches(node, [node.body, node.orelse])

    def visit_Try(self, node: ast.Try) -> None:
        branches = [node.body + node.orelse] + [handler.body for handler in node.handlers]
        if not node.handlers:
            branches.append([])
        for handler in node.handlers:
            if handler.type:
                self.visit(handler.type)
        self.merge_branches(node, branches)
        for statement in node.finalbody:
            self.visit(statement)

    def visit_For(self, node: ast.For | ast.AsyncFor) -> None:
        self.visit(node.iter)
        self.bind_target(node.target, None, None)
        self.merge_branches(node, [[], node.body])
        for statement in node.orelse:
            self.visit(statement)

    visit_AsyncFor = visit_For

    def visit_While(self, node: ast.While) -> None:
        self.visit(node.test)
        self.merge_branches(node, [[], node.body])
        for statement in node.orelse:
            self.visit(statement)

    def visit_comprehension_expression(self, node: ast.AST) -> None:
        generators = node.generators
        self.visit(generators[0].iter)
        self.scopes.append({})
        self.constants.append({})
        for index, generator in enumerate(generators):
            if index:
                self.visit(generator.iter)
            self.bind_target(generator.target, None, None)
            for condition in generator.ifs:
                self.visit(condition)
        if isinstance(node, ast.DictComp):
            self.visit(node.key)
            self.visit(node.value)
        else:
            self.visit(node.elt)
        self.constants.pop()
        self.scopes.pop()

    visit_ListComp = visit_comprehension_expression
    visit_SetComp = visit_comprehension_expression
    visit_DictComp = visit_comprehension_expression
    visit_GeneratorExp = visit_comprehension_expression

    def visit_Attribute(self, node: ast.Attribute) -> None:
        ref = self.resolve(node)
        if ref and ref.kind == "java_member":
            self.require(node, ref, "java_member")
        elif ref and ref.kind == "unresolved_java":
            self.feature(node, "dynamic_java_members", "Java return-object type or nested member is not declared; member coverage is unknown.", True)
        self.generic_visit(node)

    def visit_Call(self, node: ast.Call) -> None:
        ref = self.resolve(node.func)
        raw_name = ref.name if ref else (node.func.id if isinstance(node.func, ast.Name) else "")
        attr = node.func.attr if isinstance(node.func, ast.Attribute) else ""
        if raw_name in {"java.jclass", "hook_utils.find_class"}:
            name = self.literal(node.args[0]) if node.args else None
            if name and safe_symbol(name) == name and name.startswith(JAVA_PREFIXES):
                self.require(node, Ref("java_class", name), "java_class_lookup")
            else:
                self.add(node, "java_class_lookup", java_label(name), "unknown", "Computed or unlisted class names are not evaluated or printed.")
            if name and any(part in name for part in ("WindowManager", "DexClassLoader", "PathClassLoader", "dalvik.", "Runtime")):
                self.feature(node, "restricted_android_api", "Android system overlay, VM, or code-loading API needs an explicit policy and platform mapping.")
        elif raw_name == "java.dynamic_proxy":
            self.feature(node, "dynamic_proxy", "Java interface proxies require a callback mapping with lifetime management.")
        elif raw_name in DYNAMIC or raw_name in {"builtins.eval", "builtins.exec", "builtins.compile", "builtins.__import__", "importlib.import_module"}:
            self.feature(node, "dynamic_code", "Computed code or imports cannot be inspected from this AST.", True)
        elif raw_name in {"getattr", "setattr", "delattr", "builtins.getattr", "builtins.setattr", "builtins.delattr"}:
            self.feature(node, "dynamic_attributes", "Attribute lookup or mutation needs runtime coverage; values are not evaluated.", True)
        elif raw_name in {"os.system", "os.popen", "os.fork", "os.execv", "os.execve", "os.posix_spawn", "subprocess.run", "subprocess.Popen"}:
            self.add(node, "platform_restriction", raw_name, "unsupported", "External process execution is unavailable in the intended iOS bridge.")
        if attr in REFLECTION or raw_name in {"hook_utils.get_private_field", "hook_utils.set_private_field", "hook_utils.find_method"}:
            self.feature(node, "reflection", "Java reflection requires a virtual class/member registry; arbitrary Swift reflection is not implied.")
            if attr in {"getDeclaredMethod", "getMethod", "getDeclaredField", "getField"}:
                target = self.literal(node.args[0]) if node.args else None
                owner = self.resolve(node.func.value) if isinstance(node.func, ast.Attribute) else None
                if target is not None and owner and owner.kind in {"java_class", "java_instance"} and safe_symbol(target) == target:
                    self.require(node, Ref("java_member", owner.name + "::" + target), "reflection_target")
                else:
                    self.feature(node, "computed_reflection", "Computed or unresolved reflection target cannot be proven by static analysis.", True)
            elif attr in {"getDeclaredMethods", "getMethods", "getDeclaredFields"}:
                self.feature(node, "enumerated_reflection", "Member enumeration and overload selection require runtime tracing.", True)
        if attr in HOOKS:
            self.feature(node, "method_hooks", "Hook calls require explicit host interception and unload semantics.")
            if attr == "hook_all_methods":
                target = self.literal(node.args[1]) if len(node.args) > 1 else None
                owner = self.resolve(node.args[0]) if node.args else None
                if target is not None and owner and owner.kind in {"java_class", "java_instance"} and safe_symbol(target) == target:
                    self.require(node, Ref("java_member", owner.name + "::" + target), "hook_target")
                else:
                    self.feature(node, "computed_hook", "Computed or unresolved method selection requires runtime tracing.", True)
            elif attr in {"hook_method", "hook_all_constructors"}:
                self.feature(node, "unresolved_hook_target", "Method objects or constructor overloads need runtime target validation.", True)
        if ref and ref.kind in {"java_class", "java_member"}:
            self.require(node, ref, "java_call")
        elif ref and (ref.name.startswith(("base_plugin.", "client_utils.", "android_utils.", "hook_utils.", "ui.", "java."))):
            self.require(node, ref, "bridge_call")
        self.generic_visit(node)


def inspect_source(source: str | bytes, manifest: dict[str, Any] | None = None) -> dict[str, Any]:
    """Parse a bounded source value; never import, compile, or evaluate plugin code."""
    raw = source.encode("utf-8") if isinstance(source, str) else source
    report: dict[str, Any] = {
        "schema_version": 1, "source_sha256": hashlib.sha256(raw).hexdigest(),
        "status": "unknown", "execution_verified": False, "runtime_validation_required": True,
        "metadata": {}, "findings": [], "limitations": LIMITATIONS[:],
    }
    if len(raw) > MAX_SOURCE_BYTES:
        report["error"] = {"code": "source_too_large", "line": 0, "column": 0}
        return report
    try:
        tree = ast.parse(raw, filename="<plugin>")
        if sum(1 for _ in ast.walk(tree)) > MAX_NODES:
            report["error"] = {"code": "ast_too_large", "line": 0, "column": 0}
            return report
    except (SyntaxError, UnicodeError, ValueError, RecursionError, MemoryError) as error:
        report["error"] = {"code": "invalid_or_excessive_python", "line": getattr(error, "lineno", 0) or 0, "column": getattr(error, "offset", 0) or 0}
        return report
    visitor = Inspector(validate_manifest(manifest) if manifest is not None else load_manifest())
    try:
        visitor.visit(tree)
    except (RecursionError, MemoryError):
        report["error"] = {"code": "analysis_resource_limit", "line": 0, "column": 0}
        return report
    report["metadata"] = visitor.metadata
    report["findings"] = sorted(visitor.findings, key=lambda item: (item["line"], item["column"], item["category"], item["target"]))
    statuses = {finding["status"] for finding in visitor.findings}
    report["status"] = next((status for status in ("unsupported", "unknown", "partial") if status in statuses), "supported" if statuses else "unknown")
    report["counts"] = {status: sum(item["status"] == status for item in visitor.findings) for status in sorted(STATUSES)}
    return report


def inspect_file(path: Path | str, manifest: dict[str, Any] | None = None) -> dict[str, Any]:
    with Path(path).open("rb") as stream:
        return inspect_source(stream.read(MAX_SOURCE_BYTES + 1), manifest)


def render_markdown(report: dict[str, Any]) -> str:
    def cell(value: Any) -> str:
        return str(value).replace("|", "\\|").replace("\n", " ").replace("`", "'").replace("<", "&lt;").replace(">", "&gt;")
    lines = ["# Plugin static compatibility inspection", "", "Status: **" + report["status"] + "**", "", "Runtime compatibility has not been verified.", ""]
    for key, value in report.get("metadata", {}).items():
        lines.append("- " + cell(key) + ": " + cell(value))
    if "error" in report:
        lines.extend(["", "Inspection error: " + cell(report["error"]["code"])])
    lines.extend(["", "| Line | Phase | Kind | API | Status | Evidence |", "| --- | --- | --- | --- | --- | --- |"])
    for item in report.get("findings", []):
        lines.append("| " + " | ".join(cell(item[key]) for key in ("line", "phase", "category", "target", "status", "reason")) + " |")
    lines.extend(["", "## Limits", ""] + ["- " + item for item in report["limitations"]])
    return "\n".join(lines) + "\n"


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Inspect plugin AST without executing or importing it.")
    parser.add_argument("plugin", type=Path)
    parser.add_argument("--manifest", type=Path, help="Explicit bridge support manifest (schema v1).")
    parser.add_argument("--format", choices=("json", "markdown"), default="json")
    parser.add_argument("--output", type=Path, help="Write report to this file instead of stdout.")
    args = parser.parse_args(argv)
    try:
        manifest_path = args.manifest or Path(__file__).with_name("support-manifest.json")
        if args.output:
            for protected in (args.plugin, manifest_path):
                if args.output.resolve() == protected.resolve() or (args.output.exists() and protected.exists() and args.output.samefile(protected)):
                    raise OSError("Output must not overwrite inspection inputs.")
        report = inspect_file(args.plugin, load_manifest(manifest_path))
        text = json.dumps(report, ensure_ascii=False, indent=2) + "\n" if args.format == "json" else render_markdown(report)
        if args.output:
            args.output.write_text(text, encoding="utf-8")
        else:
            sys.stdout.write(text)
        return 2 if "error" in report else 0
    except (OSError, ManifestError):
        sys.stderr.write("Inspection failed: input, output, or support manifest unavailable or invalid.\n")
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
