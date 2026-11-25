"""Parse changed Swift files; this does not typecheck or replace the iOS build.

Run: uv run --with tree-sitter --with tree-sitter-swift python tools/check_extera_sources.py
"""
from pathlib import Path
from collections import Counter
import json
import subprocess
import sys

import tree_sitter
import tree_sitter_swift

ROOT = Path(__file__).resolve().parents[1]
parser = tree_sitter.Parser(tree_sitter.Language(tree_sitter_swift.language()))


def tracked_changes():
    names = set()
    for arguments in (["diff", "--name-only", "HEAD"], ["ls-files", "--others", "--exclude-standard"]):
        output = subprocess.check_output(["git", *arguments], cwd=ROOT).decode("utf-8")
        names.update(output.splitlines())
    return sorted(name for name in names if name.endswith(".swift") and (ROOT / name).is_file())


def errors(node):
    if node.type == "ERROR" or node.is_missing:
        yield node
    for child in node.children:
        if child.has_error or child.type == "ERROR" or child.is_missing:
            yield from errors(child)


report = []
new_error_count = 0
files = tracked_changes()
for name in files:
    source = (ROOT / name).read_bytes()
    tree = parser.parse(source)
    if not tree.root_node.has_error:
        continue
    baseline = subprocess.run(["git", "show", f"HEAD:{name}"], cwd=ROOT, capture_output=True)
    old_errors = list(errors(parser.parse(baseline.stdout).root_node)) if baseline.returncode == 0 else []
    current_errors = list(errors(tree.root_node))
    def fingerprint(error, content):
        return (error.type, error.is_missing, error.parent.type if error.parent else "", content[error.start_byte:error.end_byte])
    old_counts = Counter(fingerprint(error, baseline.stdout) for error in old_errors)
    current_counts = Counter(fingerprint(error, source) for error in current_errors)
    new_errors = sum((current_counts - old_counts).values())
    new_error_count += new_errors
    report.append({"file": name, "baseline_errors": len(old_errors), "new_errors": new_errors, "errors": [
        {"line": error.start_point.row + 1, "column": error.start_point.column + 1,
         "text": source[error.start_byte:error.end_byte].decode("utf-8", errors="replace")[:180]}
        for error in current_errors
    ]})

print(json.dumps({"files_parsed": len(files), "files_with_errors": report}, ensure_ascii=True, indent=2))
sys.exit(1 if new_error_count else 0)
