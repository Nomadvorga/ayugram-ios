from pathlib import Path
import hashlib
import json
import difflib
from tree_sitter import Language, Parser
import tree_sitter_swift

root = Path(__file__).resolve().parent
repository = root.parents[2]
manifest = json.loads((root / "base-sha256.json").read_text(encoding="utf-8"))
existing = 0
for name, expected in manifest.items():
    destination = repository / name
    if expected is None:
        assert not destination.exists(), f"New source destination already exists: {name}"
        continue
    actual = hashlib.sha256(destination.read_text(encoding="utf-8").encode()).hexdigest()
    assert actual == expected, f"Baseline changed; rebase required: {name}"
    existing += 1
print(f"PASS: {existing} existing source hashes match patch baseline; no new destination applied")

model_name = "AyuGram/SGSimpleSettings/Sources/ExteraPillStackSettings.swift"
fallback = '(Locale.current as NSLocale).object(forKey: .currencyCode) as? String ?? "USD"'
assert fallback in (repository / model_name).read_text(encoding="utf-8")
assert fallback in (root / "review" / model_name).read_text(encoding="utf-8")
print("PASS: root NSLocale fallback present in baseline and proposal")
parser = Parser(Language(tree_sitter_swift.language()))
files = sorted((root / "review").rglob("*.swift"))
for file in files:
    tree = parser.parse(file.read_bytes())
    if tree.root_node.has_error:
        raise AssertionError(f"Swift syntax error: {file.relative_to(root)}")
    text = file.read_text(encoding="utf-8")
    assert text.endswith("\n"), f"Missing final newline: {file}"
    name = file.relative_to(root / "review").as_posix()
    original = (repository / name).read_text(encoding="utf-8") if manifest[name] else ""
    for line in difflib.ndiff(original.splitlines(), text.splitlines()):
        if line.startswith("+ "):
            assert line[2:].rstrip() == line[2:], f"New trailing whitespace: {file}"
    print(f"PASS: {file.relative_to(root)}")
print(f"Syntax only: {len(files)} Swift files; no typecheck/runtime claim")
