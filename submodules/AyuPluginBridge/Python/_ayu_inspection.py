"""Bounded static import inventory; neither SDK nor plugin source is executed.

This inventories possible imports, not Python control flow or runtime support.
In particular an ImportError handler is evidence of an optional import, never
evidence that an unsupported API is implemented.
"""
from __future__ import annotations

import ast
from functools import lru_cache
from pathlib import Path


_SDK_ROOT = Path(__file__).resolve().parent
_MAX_SOURCE_BYTES = 4 * 1024 * 1024
_MAX_NODES = 100_000
_MAX_DEPTH = 64
_NATIVE_PREFIXES = ("android.", "androidx.", "org.telegram.", "java.", "javax.", "com.")


def _bounded_nodes(tree):
    pending = [(tree, 0)]
    count = 0
    while pending:
        node, depth = pending.pop()
        count += 1
        if count > _MAX_NODES or depth > _MAX_DEPTH:
            raise ValueError("Static SDK inventory exceeds AST limits")
        yield node
        pending.extend((child, depth + 1) for child in reversed(list(ast.iter_child_nodes(node))))


def _module_path(module):
    if not module or not all(part.isidentifier() for part in module.split(".")):
        raise ValueError("Invalid SDK module name")
    root = _SDK_ROOT.resolve()
    relative = Path(*module.split("."))
    for path in (root / relative.with_suffix(".py"), root / relative / "__init__.py"):
        if not path.resolve().is_relative_to(root):
            raise ValueError("SDK module must stay inside bundled SDK")
        if path.is_file():
            return path
    return None


def _target_names(target):
    if isinstance(target, ast.Name):
        return {target.id}
    if isinstance(target, (ast.Tuple, ast.List)):
        return set().union(*(_target_names(item) for item in target.elts))
    return set()


def _export_literal(node):
    if isinstance(node, ast.BinOp) and isinstance(node.op, ast.Add):
        return _export_literal(node.left) + _export_literal(node.right)
    if not isinstance(node, (ast.List, ast.Tuple)) or not all(
            isinstance(item, ast.Constant) and isinstance(item.value, str) for item in node.elts):
        raise ValueError("Invalid bundled SDK export declaration")
    names = [item.value for item in node.elts]
    if not all(name.isidentifier() for name in names):
        raise ValueError("Invalid bundled SDK export declaration")
    return names


@lru_cache(maxsize=128)
def _sdk_surface(module, ancestors=()):
    if module in ancestors or len(ancestors) >= _MAX_DEPTH:
        raise ValueError("Cyclic or excessive bundled SDK exports")
    path = _module_path(module)
    if path is None:
        raise ValueError("SDK module is not bundled: " + module)
    with path.open("rb") as stream:
        source = stream.read(_MAX_SOURCE_BYTES + 1)
    if len(source) > _MAX_SOURCE_BYTES:
        raise ValueError("Bundled SDK source exceeds size limit")
    tree = ast.parse(source.decode("utf-8"))
    list(_bounded_nodes(tree))
    names, exports = set(), None
    for statement in tree.body:
        if isinstance(statement, (ast.FunctionDef, ast.AsyncFunctionDef, ast.ClassDef)):
            names.add(statement.name)
        elif isinstance(statement, (ast.Import, ast.ImportFrom)):
            if isinstance(statement, ast.ImportFrom) and statement.module == "__future__":
                continue
            for alias in statement.names:
                if alias.name != "*":
                    names.add(alias.asname or (alias.name.split(".")[0]
                                              if isinstance(statement, ast.Import) else alias.name))
                    continue
                target = statement.module or ""
                if statement.level:
                    package = module.split(".") if path.name == "__init__.py" else module.split(".")[:-1]
                    if statement.level > len(package):
                        raise ValueError("Bundled SDK relative import escapes package")
                    target = ".".join(package[:len(package) - statement.level + 1] + ([target] if target else []))
                names.update(_sdk_surface(target, ancestors + (module,))[1])
        elif isinstance(statement, (ast.Assign, ast.AnnAssign)):
            targets = statement.targets if isinstance(statement, ast.Assign) else [statement.target]
            assigned = set().union(*(_target_names(target) for target in targets))
            # An annotation without a value does not create a module attribute.
            if statement.value is not None:
                names.update(assigned)
                if "__all__" in assigned:
                    exports = _export_literal(statement.value)
        elif isinstance(statement, ast.AugAssign) and isinstance(statement.target, ast.Name) and statement.target.id == "__all__":
            if exports is None or not isinstance(statement.op, ast.Add):
                raise ValueError("Invalid bundled SDK export declaration")
            exports += _export_literal(statement.value)
    children = set()
    if path.name == "__init__.py":
        for child in path.parent.iterdir():
            if child.name == "__init__.py" or child.name.startswith("_"):
                continue
            name = child.stem if child.suffix == ".py" else child.name
            if name.isidentifier() and _module_path(module + "." + name) is not None:
                children.add(name)
    # __all__ controls star imports only. Explicit imports can name other public
    # bindings and importable package children.
    public = {name for name in names if not name.startswith("_")} | children
    if exports is not None and not set(exports) <= names | children:
        raise ValueError("Bundled SDK exports an undefined name")
    if exports is not None:
        public.update(exports)
    star_names = exports if exports is not None else {name for name in names if not name.startswith("_")}
    return frozenset(public), frozenset(star_names)


@lru_cache(maxsize=128)
def sdk_symbols(module):
    """Public explicit-import bindings, including bundled package children."""
    return _sdk_surface(module)[0]


class _Scope:
    def __init__(self, parent=None, is_class=False):
        self.parent = parent
        self.is_class = is_class
        self.imports = {}
        self.locals = set()
        self.aliases = {}

    def bind(self, name, qualified):
        self.locals.add(name)
        self.imports.setdefault(name, set()).add(qualified)

    def lookup(self, name, qualified, seen):
        if name in self.locals:
            result = set(self.imports.get(name, ()))
            for expression in self.aliases.get(name, ()):
                result.update(qualified(expression, seen))
            return result
        return self.parent.lookup(name, qualified, seen) if self.parent else set()


def _import_error_handler(handler):
    def matches(node):
        return (isinstance(node, ast.Name) and node.id in {"ImportError", "ModuleNotFoundError"}
                or isinstance(node, ast.Attribute) and isinstance(node.value, ast.Name)
                and node.value.id == "builtins" and node.attr in {"ImportError", "ModuleNotFoundError"})
    kind = handler.type
    return matches(kind) or isinstance(kind, ast.Tuple) and bool(kind.elts) and all(matches(item) for item in kind.elts)


def import_inventory(tree, sdk_modules):
    nodes = list(_bounded_nodes(tree))
    imports, classes, unsupported = {}, set(), {}
    scopes, optional = {}, []
    sdk_roots = {name.split(".")[0] for name in sdk_modules}
    resolution_steps = 0

    @lru_cache(maxsize=256)
    def module_path(module):
        return _module_path(module)

    def owned(module):
        return module.split(".")[0] in sdk_roots

    def missing(module, symbol):
        unsupported.setdefault(module, set()).add(symbol)

    def check_module(module):
        if not owned(module):
            return
        parts = module.split(".")
        for index in range(1, len(parts) + 1):
            name = ".".join(parts[:index])
            if module_path(name) is None:
                missing(".".join(parts[:index - 1]) or name, parts[index - 1])
                return

    def visit(node, scope, handlers=()):
        scopes[id(node)] = scope
        if isinstance(node, ast.Import):
            for alias in node.names:
                check_module(alias.name)
                scope.bind(alias.asname or alias.name.split(".")[0],
                           alias.name if alias.asname else alias.name.split(".")[0])
                if handlers:
                    optional.append({"module": alias.name, "line": node.lineno, "handler_line": handlers[-1]})
        elif isinstance(node, ast.ImportFrom) and node.module and not node.level:
            check_module(node.module)
            symbols = imports.setdefault(node.module, set())
            for alias in node.names:
                symbols.add(alias.name)
                if alias.name == "*":
                    if owned(node.module) and module_path(node.module) is not None:
                        for symbol in _sdk_surface(node.module)[1]:
                            scope.bind(symbol, node.module + "." + symbol)
                else:
                    scope.bind(alias.asname or alias.name, node.module + "." + alias.name)
                    if node.module.startswith(_NATIVE_PREFIXES):
                        classes.add(node.module + "." + alias.name)
            if handlers:
                optional.append({"module": node.module, "line": node.lineno, "handler_line": handlers[-1]})
        elif isinstance(node, (ast.Assign, ast.AnnAssign, ast.NamedExpr)):
            targets = node.targets if isinstance(node, ast.Assign) else [node.target]
            for target in targets:
                scope.locals.update(_target_names(target))
                if isinstance(target, ast.Name) and isinstance(node.value, (ast.Name, ast.Attribute)):
                    scope.aliases.setdefault(target.id, []).append(node.value)
        elif isinstance(node, (ast.For, ast.AsyncFor, ast.comprehension)):
            scope.locals.update(_target_names(node.target))

        if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef, ast.ClassDef, ast.Lambda)):
            if not isinstance(node, ast.Lambda):
                scope.locals.add(node.name)
            parent = scope
            # A method's lexical lookup skips class-body bindings.
            if not isinstance(node, ast.ClassDef):
                while parent is not None and parent.is_class:
                    parent = parent.parent
            inner = _Scope(parent, is_class=isinstance(node, ast.ClassDef))
            if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef, ast.Lambda)):
                args = node.args
                inner.locals.update(arg.arg for arg in args.posonlyargs + args.args + args.kwonlyargs)
                inner.locals.update(arg.arg for arg in (args.vararg, args.kwarg) if arg is not None)
            body = node.body if not isinstance(node, ast.Lambda) else [node.body]
            body_ids = {id(child) for child in body}
            for child in ast.iter_child_nodes(node):
                # Decorators, defaults and bases execute in the enclosing scope.
                visit(child, inner if id(child) in body_ids else scope)
            return
        if isinstance(node, ast.Try):
            handler = next((handler for handler in node.handlers if _import_error_handler(handler)
                            and not any(isinstance(item, ast.Raise) for statement in handler.body
                                        for item in ast.walk(statement))), None)
            body_ids = {id(child) for child in node.body}
            for child in ast.iter_child_nodes(node):
                visit(child, scope, handlers + (handler.lineno,) if handler and id(child) in body_ids else handlers)
            return
        for child in ast.iter_child_nodes(node):
            visit(child, scope, handlers)

    visit(tree, _Scope())

    def qualified(node, seen=frozenset()):
        nonlocal resolution_steps
        resolution_steps += 1
        if resolution_steps > _MAX_NODES * 4:
            raise ValueError("Static SDK inventory exceeds alias resolution budget")
        if id(node) in seen:
            return set()
        if len(seen) >= _MAX_DEPTH:
            raise ValueError("Static SDK inventory exceeds alias limits")
        seen = seen | {id(node)}
        if isinstance(node, ast.Name):
            result = scopes[id(node)].lookup(node.id, qualified, seen)
            if len(result) > 256:
                raise ValueError("Static SDK inventory exceeds alias limits")
            return result
        if isinstance(node, ast.Attribute):
            return {name + "." + node.attr for name in qualified(node.value, seen)}
        return set()

    dynamic = set()
    for module, symbols in imports.items():
        if owned(module) and module_path(module) is not None:
            for symbol in symbols - sdk_symbols(module) - {"*"}:
                missing(module, symbol)
    for node in nodes:
        if isinstance(node, ast.Attribute):
            for module in qualified(node.value):
                if owned(module) and module_path(module) is not None and node.attr not in sdk_symbols(module):
                    missing(module, node.attr)
        elif isinstance(node, ast.Call) and qualified(node.func) & {"java.jclass", "hook_utils.find_class"}:
            argument = node.args[0] if node.args else next((item.value for item in node.keywords if item.arg == "name"), None)
            if isinstance(argument, ast.Constant) and isinstance(argument.value, str):
                classes.add(argument.value)
            else:
                dynamic.add(node.lineno)
    return {"imported_symbols": {module: sorted(symbols) for module, symbols in sorted(imports.items())},
            "unsupported_sdk_symbols": {module: sorted(symbols) for module, symbols in sorted(unsupported.items())},
            "classes": sorted(classes), "dynamic_class_lookup_lines": sorted(dynamic),
            "optional_imports": sorted(optional, key=lambda item: (item["line"], item["module"]))}
