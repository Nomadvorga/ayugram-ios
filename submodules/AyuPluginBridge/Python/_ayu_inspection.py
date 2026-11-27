"""Bounded static import inventory; neither SDK nor plugin source is executed.

This inventories possible imports, not Python control flow or runtime support.
In particular an ImportError handler is evidence of an optional import, never
evidence that an unsupported API is implemented.
"""
from __future__ import annotations

import ast
import re
from functools import lru_cache
from pathlib import Path

import _ayu_intents
import _ayu_xposed


_SDK_ROOT = Path(__file__).resolve().parent
_MAX_SOURCE_BYTES = 4 * 1024 * 1024
_MAX_NODES = 100_000
_MAX_DEPTH = 64
# Package roots that name Java classes; everything below them is resolved by the
# class registry (host adapters first, then Python-local classes), never as SDK modules.
NATIVE_ROOTS = ("android", "androidx", "org", "java", "javax", "com", "dalvik", "kotlin", "de")
NATIVE_PREFIXES = tuple(root + "." for root in NATIVE_ROOTS)
# Chaquopy's ``java`` package re-exports its extension module ``java.chaquopy``; the bundled
# ``java`` module registers that name with the same public surface.
_MODULE_ALIASES = {"java.chaquopy": "java"}


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
    module = _MODULE_ALIASES.get(module, module)
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


def _absorbs_import_error(statement):
    """Whether a ``try`` handles an ImportError raised in its body without re-raising it."""
    names = {"ImportError", "ModuleNotFoundError", "Exception", "BaseException"}

    def matches(node):
        return (isinstance(node, ast.Name) and node.id in names
                or isinstance(node, ast.Attribute) and isinstance(node.value, ast.Name)
                and node.value.id == "builtins" and node.attr in names)
    for handler in statement.handlers:
        kind = handler.type
        if kind is None or matches(kind) or isinstance(kind, ast.Tuple) and any(matches(item) for item in kind.elts):
            # The first handler that matches is the one that runs.
            return not any(isinstance(item, ast.Raise) for part in handler.body for item in ast.walk(part))
    return False


_SEND_HOOK = "on_send_message_hook"
# Calls that read nothing from the parameters object, and the builtins that name a field.
_PARAMS_NEUTRAL = frozenset({"HookResult", "isinstance", "type", "str", "repr", "bool"})
_PARAMS_FIELD = frozenset({"getattr", "hasattr", "setattr", "delattr"})


def send_hook_fields(tree):
    """Send-parameter fields a plugin's ``on_send_message_hook`` touches, sorted; None when unknown.

    The parameter is followed through aliases and into the plugin's own functions it is passed
    to. Any other use that lets the object escape (stored, returned, a computed attribute name,
    a call this cannot resolve) makes the answer unknown.
    """
    parents, functions = {}, {}
    for node in ast.walk(tree):
        for child in ast.iter_child_nodes(node):
            parents[id(child)] = node
        if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef)):
            functions.setdefault(node.name, []).append(node)
        elif (isinstance(node, ast.Constant) and node.value == _SEND_HOOK
              or isinstance(node, ast.Name) and node.id == _SEND_HOOK and isinstance(node.ctx, ast.Store)
              or isinstance(node, ast.Attribute) and node.attr == _SEND_HOOK and isinstance(node.ctx, ast.Store)):
            return None  # the hook is installed or looked up by name
    cache = {}

    def parameters(function, bound):
        """Positional parameter names, without the receiver of a bound call."""
        arguments = function.args
        names = [item.arg for item in arguments.posonlyargs + arguments.args]
        method = isinstance(parents.get(id(function)), ast.ClassDef)
        static = any(isinstance(item, ast.Name) and item.id == "staticmethod" for item in function.decorator_list)
        if method != bound:
            return None
        return names[1:] if method and not static else names

    def is_test(node):
        parent = parents.get(id(node))
        if isinstance(parent, (ast.If, ast.While, ast.IfExp, ast.Assert)):
            return parent.test is node
        if isinstance(parent, ast.UnaryOp) and isinstance(parent.op, ast.Not):
            return True
        return isinstance(parent, ast.BoolOp) and is_test(parent)

    def passed(call, node, keyword, depth):
        function = call.func
        name = function.id if isinstance(function, ast.Name) else function.attr if isinstance(function, ast.Attribute) else None
        if name in _PARAMS_FIELD and isinstance(function, ast.Name):
            literal = call.args[1] if len(call.args) > 1 and call.args[0] is node else None
            return {literal.value} if isinstance(literal, ast.Constant) and isinstance(literal.value, str) else None
        if name in _PARAMS_NEUTRAL:
            return set()
        bound = (isinstance(function, ast.Attribute) and isinstance(function.value, ast.Name)
                 and function.value.id in ("self", "cls"))
        if len(functions.get(name, ())) != 1 or not (bound or isinstance(function, ast.Name)):
            return None
        target = functions[name][0]
        names = parameters(target, bound)
        if names is None:
            return None
        if keyword is None:
            index = next(index for index, item in enumerate(call.args) if item is node)
            if index >= len(names) or any(isinstance(item, ast.Starred) for item in call.args[:index]):
                return None
            keyword = names[index]
        elif keyword not in names + [item.arg for item in target.args.kwonlyargs]:
            return None
        return uses(target, keyword, depth + 1)

    def uses(function, name, depth):
        key = (id(function), name)
        if key in cache:
            return cache[key]
        if depth > 8:
            return None
        cache[key] = set()  # a recursive call adds nothing new
        names, fields = {name}, set()
        changed = True
        while changed:
            changed = False
            for node in ast.walk(function):
                if isinstance(node, ast.Assign) and isinstance(node.value, ast.Name) and node.value.id in names:
                    for target in node.targets:
                        if isinstance(target, ast.Name) and target.id not in names:
                            names.add(target.id)
                            changed = True
        for node in ast.walk(function):
            if not (isinstance(node, ast.Name) and node.id in names and isinstance(node.ctx, ast.Load)):
                continue
            parent = parents.get(id(node))
            found = None
            if isinstance(parent, ast.Attribute):
                found = {parent.attr}
                if parent.attr == "get":
                    # The fallback object is also a mapping: ``params.get("message")``.
                    call = parents.get(id(parent))
                    key = call.args[0] if isinstance(call, ast.Call) and call.func is parent and call.args else None
                    found = {key.value} if isinstance(key, ast.Constant) and isinstance(key.value, str) else None
            elif isinstance(parent, ast.Subscript) and parent.value is node:
                key = parent.slice
                found = {key.value} if isinstance(key, ast.Constant) and isinstance(key.value, str) else None
            elif isinstance(parent, ast.Assign) and parent.value is node and all(
                    isinstance(target, ast.Name) or isinstance(target, ast.Attribute) and target.attr == "params"
                    for target in parent.targets):
                # An alias, or ``result.params = params`` on the hook result.
                found = set()
            elif isinstance(parent, ast.Compare):
                others = [item for item in [parent.left] + parent.comparators if item is not node]
                if all(isinstance(item, ast.Constant) and item.value is None for item in others):
                    found = set()
            elif isinstance(parent, ast.FormattedValue) or is_test(node):
                found = set()
            elif isinstance(parent, ast.Call) and parent.func is not node:
                found = passed(parent, node, None, depth)
            elif isinstance(parent, ast.keyword) and isinstance(parents.get(id(parent)), ast.Call) and parent.arg:
                found = passed(parents[id(parent)], node, parent.arg, depth)
            if found is None:
                cache[key] = None
                return None
            fields |= found
        cache[key] = fields
        return fields

    result = set()
    for function in functions.get(_SEND_HOOK, ()):
        method = isinstance(parents.get(id(function)), ast.ClassDef)
        names = parameters(function, method)
        # ``on_send_message_hook(account, params)``
        found = uses(function, names[1], 0) if names is not None and len(names) == 2 and not function.args.vararg else None
        if found is None:
            return None
        result |= found
    return sorted(result)


def _probed_attributes(nodes):
    """Ids of attribute nodes inside a ``try`` body whose handler names the error of a missing member."""
    found = set()
    for statement in nodes:
        if isinstance(statement, ast.Try) and _probes_member(statement):
            pending = list(statement.body)
            while pending:
                node = pending.pop()
                if isinstance(node, ast.Attribute):
                    found.add(id(node))
                # A function defined in the body runs later, outside the handler.
                if not isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef, ast.Lambda, ast.ClassDef)):
                    pending.extend(ast.iter_child_nodes(node))
    return found


def import_inventory(tree, sdk_modules):
    nodes = list(_bounded_nodes(tree))
    probed = _probed_attributes(nodes)
    # ``module.name.more``: the middle attribute is read as a namespace, the way a submodule is.
    namespaces = {id(node.value) for node in nodes if isinstance(node, ast.Attribute) and isinstance(node.value, ast.Attribute)}
    imports, classes, unsupported, packages = {}, set(), {}, set()
    unguarded_modules, unguarded_symbols = set(), set()
    scopes, optional = {}, []
    sdk_roots = {name.split(".")[0] for name in sdk_modules}
    resolution_steps = 0

    @lru_cache(maxsize=256)
    def module_path(module):
        return _module_path(module)

    def owned(module):
        # ``java`` is an SDK module whose ``java.<package>`` children are Java
        # packages; only a child that is really bundled is an SDK module.
        if module.split(".")[0] not in sdk_roots:
            return False
        return not module.startswith(NATIVE_PREFIXES) or module_path(module) is not None

    def shim(module):
        # A bundled public module that is not an SDK module (``requests``): the host declares it,
        # and its one source file is all a plugin can import or read under that name.
        root = module.split(".")[0]
        return root not in sdk_roots and not root.startswith("_") and module_path(root) is not None

    def shim_lacks(module, symbol):
        return symbol not in sdk_symbols(module) and not (symbol.startswith("__") and symbol.endswith("__"))

    def missing(module, symbol):
        unsupported.setdefault(module, set()).add(symbol)

    def check_module(module, guarded=False):
        bundled = shim(module)
        if not owned(module) and not bundled:
            return
        parts = module.split(".")
        for index in range(1, len(parts) + 1):
            name = ".".join(parts[:index])
            if module_path(name) is None:
                parent = ".".join(parts[:index - 1])
                # A shim publishes a submodule as an attribute of its module object; an import of any
                # other one raises, which blocks unless the plugin absorbs the ImportError.
                if bundled and (guarded or not shim_lacks(parent, parts[index - 1])):
                    return
                missing(parent or name, parts[index - 1])
                return

    def visit(node, scope, handlers=(), guarded=False):
        scopes[id(node)] = scope
        if isinstance(node, ast.Import):
            for alias in node.names:
                check_module(alias.name, guarded)
                if alias.name.startswith(NATIVE_PREFIXES) and not owned(alias.name):
                    packages.add(alias.name)
                    if not guarded:
                        unguarded_modules.add(alias.name)
                scope.bind(alias.asname or alias.name.split(".")[0],
                           alias.name if alias.asname else alias.name.split(".")[0])
                if handlers:
                    optional.append({"module": alias.name, "line": node.lineno, "handler_line": handlers[-1]})
        elif isinstance(node, ast.ImportFrom) and node.module and not node.level:
            check_module(node.module, guarded)
            symbols = imports.setdefault(node.module, set())
            if not guarded and shim(node.module) and module_path(node.module) is not None:
                for alias in node.names:
                    if alias.name != "*" and shim_lacks(node.module, alias.name):
                        missing(node.module, alias.name)
            for alias in node.names:
                symbols.add(alias.name)
                if alias.name == "*":
                    if owned(node.module) and module_path(node.module) is not None:
                        for symbol in _sdk_surface(node.module)[1]:
                            scope.bind(symbol, node.module + "." + symbol)
                else:
                    scope.bind(alias.asname or alias.name, node.module + "." + alias.name)
                    if node.module.startswith(NATIVE_PREFIXES) and not owned(node.module):
                        classes.add(node.module + "." + alias.name)
                        if not guarded:
                            unguarded_symbols.add(node.module + "." + alias.name)
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
            absorbs = _absorbs_import_error(node)
            for child in ast.iter_child_nodes(node):
                visit(child, scope, handlers + (handler.lineno,) if handler and id(child) in body_ids else handlers,
                      guarded or absorbs and id(child) in body_ids)
            return
        for child in ast.iter_child_nodes(node):
            visit(child, scope, handlers, guarded)

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
    # What the source references of the SDK itself: dotted symbols, and the names it calls as
    # methods without defining them (plugin and client methods are reached through any receiver).
    references = {module + "." + symbol for module, symbols in imports.items() if owned(module)
                  for symbol in symbols if symbol != "*"}
    called, defined = set(), set()
    packages.update(module for module in imports if module.startswith(NATIVE_PREFIXES) and not owned(module))
    package_parents = {".".join(name.split(".")[:index]) for name in packages
                       for index in range(1, name.count(".") + 2)}
    for module, symbols in imports.items():
        if owned(module) and module_path(module) is not None:
            for symbol in symbols - sdk_symbols(module) - {"*"}:
                missing(module, symbol)
    for node in nodes:
        if isinstance(node, ast.Attribute):
            for module in qualified(node.value):
                if module in packages:
                    # An attribute of an imported Java package is a class or a subpackage.
                    if not any(name.startswith(module + "." + node.attr + ".") or name == module + "." + node.attr
                               for name in packages):
                        classes.add(module + "." + node.attr)
                elif (owned(module) and module_path(module) is not None and node.attr not in sdk_symbols(module)
                      and module + "." + node.attr not in package_parents):
                    missing(module, node.attr)
                elif (id(node) in namespaces and id(node) not in probed and shim(module)
                      and module_path(module) is not None and shim_lacks(module, node.attr)):
                    missing(module, node.attr)
                if module.split(".")[0] in sdk_roots and not module.startswith(NATIVE_PREFIXES):
                    references.add(module + "." + node.attr)
        elif isinstance(node, ast.Call) and qualified(node.func) & {"java.jclass", "hook_utils.find_class"}:
            argument = node.args[0] if node.args else next((item.value for item in node.keywords if item.arg == "name"), None)
            if isinstance(argument, ast.Constant) and isinstance(argument.value, str):
                classes.add(argument.value)
            else:
                dynamic.add(node.lineno)
        if isinstance(node, ast.Call) and isinstance(node.func, ast.Attribute):
            called.add(node.func.attr)
        elif isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef)):
            defined.add(node.name)
    return {"sdk_references": sorted(references), "method_calls": sorted(called - defined),
            "send_hook_fields": send_hook_fields(tree),
            "hook_targets": _ayu_xposed.static_targets(tree), "intent_actions": _ayu_intents.static_actions(tree),
            "imported_symbols": {module: sorted(symbols) for module, symbols in sorted(imports.items())},
            "unsupported_sdk_symbols": {module: sorted(symbols) for module, symbols in sorted(unsupported.items())},
            "classes": sorted(classes), "dynamic_class_lookup_lines": sorted(dynamic),
            # Java imports outside any ``try`` that absorbs an ImportError: ``import <module>`` names
            # and ``from <module> import <symbol>`` pairs as ``module.symbol``.
            "unguarded_native_imports": {"modules": sorted(unguarded_modules), "symbols": sorted(unguarded_symbols)},
            "optional_imports": sorted(optional, key=lambda item: (item["line"], item["module"]))}


# ``java.jclass`` and ``hook_utils.find_class`` name a Java class by a string.
_CLASS_FINDERS = frozenset({"java.jclass", "hook_utils.find_class"})
# The error a missing member raises is an ``AttributeError``; a handler that names it is a probe.
# A blanket ``except Exception`` is not: the code behind it would silently never run.
_PROBE_ERRORS = frozenset({"AttributeError"})
_JAVA_STYLE = re.compile(r"[a-z][a-z0-9]*[A-Z]\w*\Z|[A-Z][A-Z0-9]*(?:_[A-Z0-9]+)*\Z")
_UNKNOWN, _PYTHON, _PYTHON_MODULE, _UNDECLARED, _FINDER = ("unknown",), ("python",), ("python module",), ("undeclared",), ("finder",)
_SKIP = ("skip",)
# ``java.lang.Class`` lookups whose literal first argument names the member that has to exist.
_REFLECTION_LOOKUPS = frozenset({"getDeclaredField", "getField", "getDeclaredMethod", "getMethod"})


@lru_cache(maxsize=1)
def _controller_getters():
    """``client_utils`` getters whose SDK source names the Java class of what they return.

    ``return _controller(helper, java_name, account)`` yields that class's instance: the local
    class's ``getInstance`` result, or the host's object for it.
    """
    path = _module_path("client_utils")
    with path.open("rb") as stream:
        tree = ast.parse(stream.read(_MAX_SOURCE_BYTES).decode("utf-8"))
    found = {}
    for function in tree.body:
        value = function.body[-1].value if isinstance(function, ast.FunctionDef) and isinstance(function.body[-1], ast.Return) else None
        if (isinstance(value, ast.Call) and isinstance(value.func, ast.Name) and value.func.id == "_controller"
                and len(value.args) == 3 and all(isinstance(item, ast.Constant) and isinstance(item.value, str)
                                                 for item in value.args[:2])
                and not any(isinstance(node, ast.Return) for node in ast.walk(function) if node is not function.body[-1])):
            found["client_utils." + function.name] = value.args[1].value
    return found


class _Frame:
    """One lexical scope of the member analysis: every binding of each name."""
    __slots__ = ("parent", "kind", "node", "bindings", "redirect")

    def __init__(self, parent, kind, node=None):
        self.parent, self.kind, self.node, self.bindings, self.redirect = parent, kind, node, {}, {}

    def bind(self, name, binding):
        self.redirect.get(name, self).bindings.setdefault(name, []).append(binding)

    def lookup(self, name):
        frame = self.redirect.get(name, self)
        while frame is not None:
            # A class body's names are not visible from the functions inside it.
            if name in frame.bindings and (frame.kind != "class" or frame is self):
                return frame.bindings[name]
            frame = frame.parent
        return None


def _probes_member(statement):
    """Whether a ``try`` handles the error of a missing member by name, without re-raising it."""
    def matches(node):
        return (isinstance(node, ast.Name) and node.id in _PROBE_ERRORS
                or isinstance(node, ast.Attribute) and isinstance(node.value, ast.Name)
                and node.value.id == "builtins" and node.attr in _PROBE_ERRORS)
    for handler in statement.handlers:
        kind = handler.type
        if kind is None or isinstance(kind, ast.Name) and kind.id in ("Exception", "BaseException"):
            return False  # the blanket handler runs first
        if matches(kind) or isinstance(kind, ast.Tuple) and any(matches(item) for item in kind.elts):
            return not any(isinstance(item, ast.Raise) for part in handler.body for item in ast.walk(part))
    return False


def member_inventory(tree, sdk_modules, tables, watch=frozenset()):
    """Java member accesses whose receiver class is certain, checked against ``tables``.

    The receiver of ``x.member`` is resolved without executing anything, from what ``x`` is bound
    to: a class imported from a Java package or named through ``jclass``/``find_class`` with a
    literal, an instance constructed from such a class, an attribute of the plugin's own ``self``
    assigned nothing else, a nested class or constant of a class, and a call whose result class
    is declared (by the host's table, by a Python-local definition that returns one class, or by
    a ``client_utils`` controller getter). A name with any other binding (a parameter, a loop variable, the
    result of an unknown call, two different classes) has no certain class: its accesses are
    counted as unknown and never reported as missing.

    ``tables`` answers ``named``, ``access``, ``call``, ``construct`` and ``label`` (see
    ``_ayu_members.Tables``). Returns counts of verified, missing and unknown accesses and the
    missing members; a missing member the source probes for (``hasattr``, a ``getattr`` default, a handler
    naming ``AttributeError``) is counted as guarded instead. ``unresolved`` lists the names of
    ``watch`` that are accessed at least once on an unknown receiver.
    """
    nodes = list(_bounded_nodes(tree))
    sdk_roots = {name.split(".")[0] for name in sdk_modules}
    getters = _controller_getters()
    module_frame = _Frame(None, "module")
    frames, owners, guarded_nodes, probes = {}, {}, set(), {}
    attribute_stores, class_frames = [], {}

    @lru_cache(maxsize=256)
    def bundled(module):
        try:
            return _module_path(module) is not None
        except ValueError:
            return False

    def owned(module):
        if module.split(".")[0] not in sdk_roots:
            return False
        return not module.startswith(NATIVE_PREFIXES) or bundled(module)

    def bind_unknown(target, frame):
        if isinstance(target, ast.Name):
            frame.bind(target.id, _UNKNOWN)
        elif isinstance(target, ast.Attribute):
            attribute_stores.append((target, None, frame))
        elif isinstance(target, (ast.Tuple, ast.List)):
            for item in target.elts:
                bind_unknown(item, frame)
        elif isinstance(target, ast.Starred):
            bind_unknown(target.value, frame)

    def bind_target(target, value, frame):
        if isinstance(target, ast.Name):
            frame.bind(target.id, ("value", value, frame))
        elif isinstance(target, ast.Attribute):
            attribute_stores.append((target, value, frame))
        elif (isinstance(target, (ast.Tuple, ast.List)) and isinstance(value, (ast.Tuple, ast.List))
              and len(target.elts) == len(value.elts)
              and not any(isinstance(item, ast.Starred) for item in target.elts + value.elts)):
            for item, part in zip(target.elts, value.elts):
                bind_target(item, part, frame)
        else:
            bind_unknown(target, frame)

    def visit(node, frame, owner, guarded):
        frames[id(node)], owners[id(node)] = frame, owner
        if guarded:
            guarded_nodes.add(id(node))
        if isinstance(node, ast.Import):
            for alias in node.names:
                frame.bind(alias.asname or alias.name.split(".")[0],
                           ("import", alias.name if alias.asname else alias.name.split(".")[0]))
        elif isinstance(node, ast.ImportFrom):
            for alias in node.names if node.module and not node.level else ():
                if alias.name != "*":
                    frame.bind(alias.asname or alias.name, ("from", node.module, alias.name))
                elif owned(node.module) and bundled(node.module):
                    for symbol in _sdk_surface(node.module)[1]:
                        frame.bind(symbol, ("from", node.module, symbol))
        elif isinstance(node, ast.Assign):
            for target in node.targets:
                bind_target(target, node.value, frame)
        elif isinstance(node, (ast.AnnAssign, ast.NamedExpr)):
            if node.value is not None:
                bind_target(node.target, node.value, frame)
        elif isinstance(node, (ast.AugAssign, ast.For, ast.AsyncFor, ast.comprehension)):
            bind_unknown(node.target, frame)
        elif isinstance(node, ast.withitem):
            if node.optional_vars is not None:
                bind_unknown(node.optional_vars, frame)
        elif isinstance(node, ast.Delete):
            for target in node.targets:
                bind_unknown(target, frame)
        elif isinstance(node, ast.ExceptHandler):
            if node.name:
                frame.bind(node.name, _UNKNOWN)
        elif isinstance(node, (ast.MatchAs, ast.MatchStar)):
            if node.name:
                frame.bind(node.name, _UNKNOWN)
        elif isinstance(node, ast.MatchMapping):
            if node.rest:
                frame.bind(node.rest, _UNKNOWN)
        elif isinstance(node, ast.Global):
            for name in node.names:
                frame.redirect[name] = module_frame
        elif isinstance(node, ast.Nonlocal):
            outer = frame.parent
            while outer is not None and outer.kind != "function":
                outer = outer.parent
            for name in node.names:
                frame.redirect[name] = outer or module_frame
        elif isinstance(node, ast.Call) and isinstance(node.func, ast.Name) and node.func.id in ("hasattr", "getattr"):
            name = node.args[1] if len(node.args) > 1 else None
            if (isinstance(name, ast.Constant) and isinstance(name.value, str)
                    and (node.func.id == "hasattr" or len(node.args) == 3)):
                probes.setdefault(id(owner), set()).add(name.value)

        if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef, ast.Lambda)):
            inner = _Frame(frame, "function", node)
            arguments = node.args
            positional = arguments.posonlyargs + arguments.args
            for argument in positional + arguments.kwonlyargs + [item for item in (arguments.vararg, arguments.kwarg) if item]:
                inner.bind(argument.arg, _UNKNOWN)
            if not isinstance(node, ast.Lambda):
                frame.bind(node.name, _PYTHON)
                plain = not any(isinstance(item, ast.Name) and item.id in ("staticmethod", "classmethod")
                                for item in node.decorator_list)
                if frame.kind == "class" and positional and plain:
                    inner.bindings[positional[0].arg] = [("self", frame.node)]
            body = node.body if not isinstance(node, ast.Lambda) else [node.body]
            body_ids = {id(child) for child in body}
            for child in ast.iter_child_nodes(node):
                # Decorators, defaults and annotations run in the enclosing scope.
                if id(child) in body_ids:
                    visit(child, inner, node, False)
                else:
                    visit(child, frame, owner, guarded)
            return
        if isinstance(node, ast.ClassDef):
            frame.bind(node.name, _PYTHON)
            inner = class_frames[id(node)] = _Frame(frame, "class", node)
            body_ids = {id(child) for child in node.body}
            for child in ast.iter_child_nodes(node):
                visit(child, inner if id(child) in body_ids else frame, owner, guarded)
            return
        if isinstance(node, (ast.ListComp, ast.SetComp, ast.DictComp, ast.GeneratorExp)):
            inner = _Frame(frame, "function", node)
            for child in ast.iter_child_nodes(node):
                visit(child, inner, owner, guarded)
            return
        if isinstance(node, (ast.Try, getattr(ast, "TryStar", ast.Try))):
            probing = _probes_member(node)
            body_ids = {id(child) for child in node.body}
            for child in ast.iter_child_nodes(node):
                visit(child, frame, owner, guarded or probing and id(child) in body_ids)
            return
        for child in ast.iter_child_nodes(node):
            visit(child, frame, owner, guarded)

    visit(tree, module_frame, tree, False)

    def self_class(node):
        """The plugin class whose instance a name certainly is."""
        if not isinstance(node, ast.Name):
            return None
        bindings = frames[id(node)].lookup(node.id)
        if bindings and all(item[0] == "self" for item in bindings) and len({id(item[1]) for item in bindings}) == 1:
            return bindings[0][1]
        return None

    # What each plugin class assigns to its own attributes; a name any other receiver is assigned
    # through (``other.view = ...``) is not certain for any class.
    class_attributes, foreign = {}, set()
    for target, value, frame in attribute_stores:
        owner = self_class(target.value)
        if owner is None:
            foreign.add(target.attr)
        else:
            class_attributes.setdefault(id(owner), {}).setdefault(target.attr, []).append(
                _UNKNOWN if value is None else ("value", value, frame))

    types, steps = {}, 0

    def join(found):
        """The one type all bindings agree on; ``None`` literals and self-references add nothing."""
        known = [item for item in found if item is not _SKIP]
        if not known:
            return _SKIP if found else None
        return known[0] if all(item == known[0] for item in known) else None

    def module_type(dotted):
        if owned(dotted):
            return ("module", dotted)
        return package_type(dotted) if dotted.split(".")[0] in NATIVE_ROOTS else _PYTHON_MODULE

    def package_type(dotted):
        reference = tables.named(dotted)
        return ("class", reference) if reference is not None else ("package", dotted)

    def binding_type(binding, depth):
        kind = binding[0]
        if kind == "import":
            return module_type(binding[1])
        if kind == "from":
            module, name = binding[1], binding[2]
            if owned(module):
                full = module + "." + name
                if full in getters:
                    return ("getter", getters[full])
                return _FINDER if full in _CLASS_FINDERS else ("module", full) if bundled(full) else _PYTHON
            if module.startswith(NATIVE_PREFIXES):
                reference = tables.named(module + "." + name)
                return ("class", reference) if reference is not None else _UNDECLARED
            return _PYTHON_MODULE
        if kind == "value":
            return typeof(binding[1], depth + 1)
        return binding if kind == "self" else _PYTHON if binding is _PYTHON else None

    def member_type(base, name):
        """What reading ``name`` of a typed receiver yields."""
        if base is None:
            return None
        kind = base[0]
        if kind in ("class", "instance"):
            return tables.access(base[1], name, kind == "class")[1]
        if kind == "self":
            if name in foreign:
                return None
            bindings = class_attributes.get(id(base[1]), {}).get(name, []) + class_frames[id(base[1])].bindings.get(name, [])
            return join([binding_type(item, 0) for item in bindings]) if bindings else None
        if kind == "module":
            full = base[1] + "." + name
            if full in getters:
                return ("getter", getters[full])
            if full in _CLASS_FINDERS:
                return _FINDER
            if owned(full) and bundled(full):
                return ("module", full)
            return package_type(full) if full.startswith(NATIVE_PREFIXES) else _PYTHON
        if kind == "package":
            return package_type(base[1] + "." + name)
        # Nothing of a class the host does not declare is checked; the class itself is the blocker.
        return base if base is _PYTHON_MODULE or base is _UNDECLARED else None

    def reads_member(node):
        """``getattr(x, "name")``: the same read as ``x.name``."""
        return (isinstance(node.func, ast.Name) and node.func.id == "getattr" and len(node.args) == 2
                and not node.keywords and isinstance(node.args[1], ast.Constant) and isinstance(node.args[1].value, str)
                and frames[id(node.func)].lookup("getattr") is None)

    def typeof(node, depth=0):
        nonlocal steps
        key = id(node)
        if key in types:
            return types[key]
        steps += 1
        if steps > _MAX_NODES * 4:
            raise ValueError("Static member inventory exceeds its resolution budget")
        if depth > _MAX_DEPTH:
            return None
        types[key] = _SKIP  # a binding that refers to itself adds nothing
        result = None
        if isinstance(node, ast.Name):
            bindings = frames[key].lookup(node.id)
            result = _PYTHON if bindings is None else join([binding_type(item, depth) for item in bindings])
        elif isinstance(node, ast.Attribute):
            result = member_type(typeof(node.value, depth + 1), node.attr)
        elif isinstance(node, ast.Call):
            function = node.func
            if reads_member(node):
                result = member_type(typeof(node.args[0], depth + 1), node.args[1].value)
            else:
                called = typeof(function, depth + 1)
                if called is _FINDER:
                    argument = node.args[0] if node.args else next(
                        (item.value for item in node.keywords if item.arg in ("name", "class_name")), None)
                    if isinstance(argument, ast.Constant) and isinstance(argument.value, str):
                        reference = tables.named(argument.value)
                        result = ("class", reference) if reference is not None else _UNDECLARED
                elif called is _UNDECLARED:
                    result = _UNDECLARED
                elif called is not None and called[0] == "getter":
                    reference = tables.named(called[1])
                    if isinstance(reference, str):
                        result = ("instance", reference)
                    elif reference is not None:
                        result = tables.call(reference, "getInstance", True)
                elif called is not None and called[0] == "class":
                    result = ("instance", called[1]) if tables.construct(called[1]) is not False else None
                elif isinstance(function, ast.Attribute):
                    receiver = typeof(function.value, depth + 1)
                    if receiver is not None and receiver[0] in ("class", "instance"):
                        result = tables.call(receiver[1], function.attr, receiver[0] == "class")
        elif isinstance(node, ast.IfExp):
            result = join([typeof(node.body, depth + 1), typeof(node.orelse, depth + 1)])
        elif isinstance(node, ast.BoolOp):
            result = join([typeof(item, depth + 1) for item in node.values])
        elif isinstance(node, ast.NamedExpr):
            result = typeof(node.value, depth + 1)
        elif isinstance(node, ast.Constant):
            result = _SKIP if node.value is None else _PYTHON
        elif isinstance(node, (ast.JoinedStr, ast.List, ast.Tuple, ast.Set, ast.Dict, ast.ListComp, ast.SetComp,
                               ast.DictComp, ast.GeneratorExp, ast.Lambda, ast.Compare)):
            result = _PYTHON
        types[key] = result
        return result

    counts = {"verified": 0, "guarded": 0, "missing_accesses": 0, "unknown": 0, "unknown_java_style": 0}
    missing, unresolved = {}, set()

    def unknown(name):
        counts["unknown"] += 1
        counts["unknown_java_style"] += bool(_JAVA_STYLE.match(name))
        if name in watch:
            unresolved.add(name)

    def record(node, base, name, use):
        if base is _SKIP or base is None:
            unknown(name)
            return
        if base[0] not in ("class", "instance"):
            return
        static = base[0] == "class"
        if use == "construct":
            # Literal positional arguments let a class refuse a construction it cannot honour.
            literal = None if node.keywords or any(isinstance(item, ast.Starred) for item in node.args) else tuple(
                item.value if isinstance(item, ast.Constant) else ... for item in node.args)
            provided = tables.construct(base[1], literal)
        else:
            provided = tables.access(base[1], name, static, use == "write")[0]
        if provided is None:
            unknown(name)
        elif provided:
            counts["verified"] += 1
        elif use != "construct" and (id(node) in guarded_nodes or name in probes.get(id(owners[id(node)]), ())):
            counts["guarded"] += 1
        else:
            counts["missing_accesses"] += 1
            missing.setdefault((tables.label(base[1]), name, use), node.lineno)

    def reflected(node):
        """``Class.getDeclaredField("name")`` and its siblings on a class that is certain: the named member."""
        base, lookup = typeof(node.func.value), node.func.attr
        if (base is None or base[0] not in ("class", "instance")
                or not tables.access(base[1], lookup, base[0] == "class")[0]):
            return  # an unknown receiver or a missing lookup: the attribute itself is counted or reported
        name = node.args[0] if node.args else None
        literal = isinstance(name, ast.Constant) and isinstance(name.value, str)
        found = tables.reflected(base[1], lookup, name.value) if literal else None
        if found:
            counts["verified"] += 1
        elif found is None:
            # The class is known but not which member is looked up: the curated net stays.
            unknown(lookup)
        elif id(node) in guarded_nodes:
            counts["guarded"] += 1
        else:
            counts["missing_accesses"] += 1
            missing.setdefault((tables.label(tables.reflects(base[1])), name.value, "read"), node.lineno)

    for node in nodes:
        if isinstance(node, ast.Attribute):
            if not node.attr.startswith("_") and not isinstance(node.ctx, ast.Del):
                record(node, typeof(node.value), node.attr, "write" if isinstance(node.ctx, ast.Store) else "read")
        elif isinstance(node, ast.Call):
            if reads_member(node):
                if not node.args[1].value.startswith("_"):
                    record(node, typeof(node.args[0]), node.args[1].value, "read")
            else:
                called = typeof(node.func)
                if called is not None and called[0] == "class":
                    record(node, called, "<init>", "construct")
                elif isinstance(node.func, ast.Attribute) and node.func.attr in _REFLECTION_LOOKUPS:
                    reflected(node)
    return dict(counts, unresolved=sorted(unresolved),
                missing=[{"class": name, "member": member, "use": use, "line": line}
                         for (name, member, use), line in sorted(missing.items())])
