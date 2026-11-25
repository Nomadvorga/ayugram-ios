"""Check production conversion data against Android reference source on Windows.

This verifies the actual Swift catalog, not a duplicate catalog in a test. It does
not execute Swift or replace the XCTest suite. Run with Python 3.12 or later.
"""
from pathlib import Path
import ast
import math
import re
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[2]
REFERENCE = Path(sys.argv[1]) if len(sys.argv) > 1 else ROOT.parent / "exteragram-reference"
ANDROID_PREFIX = "TMessagesProj/src/main/java/com/exteragram/messenger/inline/"


def reference(name):
    return subprocess.check_output(
        ["git", "-C", str(REFERENCE), "show", f"HEAD:{ANDROID_PREFIX}{name}"],
    ).decode("utf-8")


def split_arguments(text):
    result, start, depth, quoted, escaped = [], 0, 0, False, False
    for index, char in enumerate(text):
        if quoted:
            if escaped:
                escaped = False
            elif char == "\\":
                escaped = True
            elif char == '"':
                quoted = False
        elif char == '"':
            quoted = True
        elif char == "(":
            depth += 1
        elif char == ")":
            depth -= 1
        elif char == "," and depth == 0:
            result.append(text[start:index].strip())
            start = index + 1
    result.append(text[start:].strip())
    return result


def calls(source, prefix):
    for match in re.finditer(prefix, source):
        start = match.end()
        depth, quoted, escaped = 1, False, False
        for index in range(start, len(source)):
            char = source[index]
            if quoted:
                if escaped:
                    escaped = False
                elif char == "\\":
                    escaped = True
                elif char == '"':
                    quoted = False
            elif char == '"':
                quoted = True
            elif char == "(":
                depth += 1
            elif char == ")":
                depth -= 1
                if depth == 0:
                    yield split_arguments(source[start:index])
                    break
        else:
            raise AssertionError("Unclosed call")


def number(text):
    constants = {"CELSIUS_OFFSET": 273.15, "FAHRENHEIT_SCALE": 5 / 9}

    def evaluate(node):
        if isinstance(node, ast.Constant) and isinstance(node.value, (int, float)):
            return node.value
        if isinstance(node, ast.Name):
            return constants[node.id]
        if isinstance(node, ast.BinOp):
            left, right = evaluate(node.left), evaluate(node.right)
            if isinstance(node.op, ast.Add):
                return left + right
            if isinstance(node.op, ast.Sub):
                return left - right
            if isinstance(node.op, ast.Mult):
                return left * right
            if isinstance(node.op, ast.Div):
                return left / right
        raise AssertionError(f"Unsupported numeric expression: {text}")

    return float(evaluate(ast.parse(text.strip(), mode="eval").body))


android_units = {}
for args in calls(reference("units/Measures.kt"), r"(?m)^        unit\("):
    code = ast.literal_eval(args[0])
    offsets = [item.split("=", 1)[1].strip() for item in args[6:] if item.startswith("offset =")]
    android_units[code] = (
        ast.literal_eval(args[1]), ast.literal_eval(args[2]),
        args[3].split(".")[-1].lower(), number(args[4]),
        None if args[5] == "null" else ast.literal_eval(args[5]),
        number(offsets[0]) if offsets else 0,
    )

swift_source = (ROOT / "submodules/TelegramUI/Sources/ExteraMathUnits.swift").read_text(encoding="utf-8")
swift_units = {}
for args in calls(swift_source, r"(?m)^        c\.add\("):
    code = ast.literal_eval(args[0])
    swift_units[code] = (
        ast.literal_eval(args[1]), ast.literal_eval(args[2]), args[3][1:],
        number(args[4]), None if args[5] == "nil" else ast.literal_eval(args[5]),
        number(args[7].split(":", 1)[1]) if len(args) > 7 else 0,
    )

assert android_units.keys() == swift_units.keys(), (android_units.keys() - swift_units.keys(), swift_units.keys() - android_units.keys())
for code, upstream in android_units.items():
    actual = swift_units[code]
    assert upstream[:3] == actual[:3], (code, upstream, actual)
    assert upstream[4] == actual[4], (code, upstream, actual)
    for index in (3, 5):
        assert math.isclose(upstream[index], actual[index], rel_tol=1e-14, abs_tol=1e-14), (code, upstream, actual)
print(f"PASS: {len(swift_units)} actual Swift units match Android labels/dimensions/scales/offsets/counterparts")


def normalize(name):
    return name.lower().replace("ё", "е").replace("-", " ")


android_zones = {}
for args in calls(reference("time/TimeZones.kt"), r"(?m)^        add\("):
    zone = ast.literal_eval(args[0])
    for alias in args[1:]:
        android_zones[normalize(ast.literal_eval(alias))] = zone
swift_zones = {}
zone_source = (ROOT / "submodules/TelegramUI/Sources/ExteraMathTimeZones.swift").read_text(encoding="utf-8")
for zone, forms in re.findall(r'\("([^"]+)", "([^"]+)"\)', zone_source):
    for alias in forms.split("|"):
        swift_zones[normalize(alias)] = zone
assert android_zones == swift_zones, {key: (value, swift_zones.get(key)) for key, value in android_zones.items() if swift_zones.get(key) != value}
print(f"PASS: {len(swift_zones)} actual Swift time-zone aliases match Android")

# Evaluate known conversions using the scales/offsets extracted from production.
for value, source, target, expected in [
    (5, "kg", "lb", 11.02311310924388),
    (100, "kmh", "mph", 62.1371192237334),
    (32, "F", "C", 0), (-40, "C", "F", -40),
    (0, "C", "K", 273.15), (1, "gal", "l", 3.785411784),
    (1, "floz", "ml", 29.5735295625),
    (1, "m2", "ft2", 10.7639104167097),
    (90, "min", "h", 1.5), (1, "mo", "d", 30), (1, "y", "d", 365),
]:
    first, second = swift_units[source], swift_units[target]
    assert first[2] == second[2]
    actual = (value * first[3] + first[5] - second[5]) / second[3]
    assert math.isclose(actual, expected, rel_tol=1e-12, abs_tol=1e-12), (value, source, target, expected, actual)
print("PASS: 11 numerical conversion regressions from extracted production data")
