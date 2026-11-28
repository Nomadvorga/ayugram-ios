#!/usr/bin/env python3
"""Constructor ids of the API functions `telegram.request` refuses to send for plugins.

The table is derived from the functions section of the TL scheme the iOS client speaks
(``submodules/TelegramApi/swift_scheme.tl``), read as text:

- every ``auth.*`` function;
- ``account.deleteAccount``, ``account.resetAuthorization``, ``account.resetPassword`` and
  ``account.updatePasswordSettings``;
- every generic function (``{X:Type} ... query:!X = X``): ``invokeAfterMsg(s)``, ``invokeWith*`` and
  ``initConnection`` wrap another request, which the bridge cannot inspect.

Run without arguments to print the Swift literal kept in
``Integration/AyuPluginTelegramBackend.swift`` (``AyuPluginTelegramRefusedFunctions.table``);
``Tests/Python/test_telegram_refusals.py`` compares that literal with this derivation.
"""
from __future__ import annotations

import pathlib
import re
import sys

BRIDGE = pathlib.Path(__file__).resolve().parents[1]
SCHEME = BRIDGE.parent / "TelegramApi" / "swift_scheme.tl"
SWIFT = BRIDGE / "Integration" / "AyuPluginTelegramBackend.swift"
ACCOUNT_FUNCTIONS = frozenset({
    "account.deleteAccount", "account.resetAuthorization", "account.resetPassword", "account.updatePasswordSettings",
})
_DECLARATION = re.compile(r"^([A-Za-z_][A-Za-z0-9_.]*)#([0-9a-fA-F]{1,8})\s+(.*?)=\s*[^=;]+;\s*$")
_GENERIC = re.compile(r"\{\s*[A-Za-z_][A-Za-z0-9_]*\s*:\s*Type\s*\}")
_SWIFT_TABLE = re.compile(r"static let table: \[UInt32: String\] = \[(.*?)\n    \]", re.S)
_SWIFT_ENTRY = re.compile(r"0x([0-9a-f]{8}): \"([A-Za-z0-9_.]+)\"")


def functions(scheme_text: str) -> list[tuple[str, int, str]]:
    """``(name, constructor id, parameters)`` of every declaration after ``---functions---``."""
    result, in_functions = [], False
    for line in scheme_text.splitlines():
        line = line.strip()
        if line == "---functions---":
            in_functions = True
        elif line == "---types---":
            in_functions = False
        elif in_functions and line and not line.startswith("//"):
            match = _DECLARATION.match(line)
            if match is None:
                raise ValueError("Unreadable function declaration in the TL scheme")
            result.append((match.group(1), int(match.group(2), 16), match.group(3)))
    if not result:
        raise ValueError("The TL scheme has no functions section")
    return result


def refused_functions(scheme_text: str) -> dict[int, str]:
    """Constructor id -> function name for everything the bridge refuses."""
    refused = {}
    for name, constructor, parameters in functions(scheme_text):
        if name.startswith("auth.") or name in ACCOUNT_FUNCTIONS or _GENERIC.search(parameters):
            if refused.setdefault(constructor, name) != name:
                raise ValueError("Two refused functions share a constructor id")
    missing = ACCOUNT_FUNCTIONS.difference(refused.values())
    if missing or "initConnection" not in refused.values():
        raise ValueError("The TL scheme lacks a function the contract names")
    return refused


def swift_literal(refused: dict[int, str]) -> str:
    entries = [f'0x{constructor:08x}: "{name}"' for constructor, name in sorted(refused.items())]
    lines = ["        " + ", ".join(entries[index:index + 3]) + "," for index in range(0, len(entries), 3)]
    return "    static let table: [UInt32: String] = [\n" + "\n".join(lines) + "\n    ]"


def swift_table(swift_text: str) -> dict[int, str]:
    """The literal as written in the Swift source."""
    match = _SWIFT_TABLE.search(swift_text)
    if match is None:
        raise ValueError("The Swift refusal table literal was not found")
    entries = _SWIFT_ENTRY.findall(match.group(1))
    table = {int(constructor, 16): name for constructor, name in entries}
    if len(table) != len(entries) or len(entries) != match.group(1).count(":"):
        raise ValueError("The Swift refusal table literal has duplicate or unreadable entries")
    return table


def main() -> int:
    print(swift_literal(refused_functions(SCHEME.read_text("utf-8"))))
    return 0


if __name__ == "__main__":
    sys.exit(main())
