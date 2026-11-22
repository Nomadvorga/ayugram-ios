"""Static import/member inventory. Reads bundled SDK syntax, never imports plugins."""
from __future__ import annotations

import ast
from functools import lru_cache
from pathlib import Path


@lru_cache(maxsize=32)
def sdk_symbols(module):
    if not module or not all(part.isidentifier() for part in module.split(".")):
        raise ValueError("Invalid SDK module name")
    root = Path(__file__).resolve().parent
    relative = Path(*module.split("."))
    path = root / relative.with_suffix(".py")
    if not path.is_file():
        path = root / relative / "__init__.py"
    if not path.resolve().is_relative_to(root):
        raise ValueError("SDK module must stay inside bundled SDK")
    tree = ast.parse(path.read_text(encoding="utf-8"))
    result = set()
    for statement in tree.body:
        if isinstance(statement, (ast.FunctionDef, ast.AsyncFunctionDef, ast.ClassDef)):
            result.add(statement.name)
        elif isinstance(statement, (ast.Import, ast.ImportFrom)):
            result.update(alias.asname or (alias.name.split(".")[0] if isinstance(statement, ast.Import) else alias.name)
                          for alias in statement.names if alias.name != "*")
        elif isinstance(statement, (ast.Assign, ast.AnnAssign)):
            targets = statement.targets if isinstance(statement, ast.Assign) else [statement.target]
            for target in targets:
                if isinstance(target, ast.Name):
                    if target.id == "__all__":
                        names = ast.literal_eval(statement.value)
                        if not isinstance(names, (list, tuple)) or not all(isinstance(name, str) for name in names):
                            raise ValueError("Invalid bundled SDK export declaration")
                        return frozenset(names)
                    result.add(target.id)
    if path.name == "__init__.py":
        result.update(child.stem for child in path.parent.glob("*.py") if child.name != "__init__.py")
        result.update(child.name for child in path.parent.iterdir() if child.is_dir() and (child / "__init__.py").is_file())
    return frozenset(name for name in result if not name.startswith("_"))


def import_inventory(tree, sdk_modules):
    imports, aliases, classes = {}, {}, set()
    for node in ast.walk(tree):
        if isinstance(node, ast.Import):
            for alias in node.names:
                aliases[alias.asname or alias.name.split(".")[0]] = alias.name if alias.asname else alias.name.split(".")[0]
        elif isinstance(node, ast.ImportFrom) and node.module:
            symbols = imports.setdefault(node.module, set())
            for alias in node.names:
                symbols.add(alias.name)
                if alias.name == "*" and node.module in sdk_modules:
                    aliases.update({symbol: node.module + "." + symbol for symbol in sdk_symbols(node.module)})
                else:
                    aliases[alias.asname or alias.name] = node.module + "." + alias.name
                if node.module.startswith(("android.", "androidx.", "org.telegram.", "java.", "javax.", "com.")) and alias.name != "*":
                    classes.add(node.module + "." + alias.name)

    def qualified(node):
        if isinstance(node, ast.Name):
            return aliases.get(node.id, node.id)
        if isinstance(node, ast.Attribute):
            return qualified(node.value) + "." + node.attr
        return ""

    dynamic = []
    for node in ast.walk(tree):
        if not isinstance(node, ast.Call):
            continue
        if qualified(node.func) not in ("java.jclass", "hook_utils.find_class"):
            continue
        argument = node.args[0] if node.args else next((item.value for item in node.keywords if item.arg == "name"), None)
        if isinstance(argument, ast.Constant) and isinstance(argument.value, str):
            classes.add(argument.value)
        else:
            dynamic.append(node.lineno)

    unsupported = {}
    for module, symbols in imports.items():
        if module not in sdk_modules:
            continue
        missing = symbols - sdk_symbols(module) - {"*"}
        if missing:
            unsupported[module] = sorted(missing)
    for node in ast.walk(tree):
        if not isinstance(node, ast.Attribute):
            continue
        module = qualified(node.value)
        if module in sdk_modules and node.attr not in sdk_symbols(module):
            unsupported.setdefault(module, [])
            unsupported[module] = sorted(set(unsupported[module]) | {node.attr})
    return {"imported_symbols": {module: sorted(symbols) for module, symbols in sorted(imports.items())},
            "unsupported_sdk_symbols": unsupported, "classes": sorted(classes),
            "dynamic_class_lookup_lines": sorted(set(dynamic))}
