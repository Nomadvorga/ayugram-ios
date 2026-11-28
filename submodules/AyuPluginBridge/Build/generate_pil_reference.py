#!/usr/bin/env python3
"""Record what the real Pillow returns for the cases of the image end-to-end test.

`Tests/Swift/AyuPluginEndToEndImageTests.swift` holds one Python function, `pillow_cases`,
between `// BEGIN PILLOW CASES` and `// END PILLOW CASES`. The test runs it inside a synthetic
plugin against the SDK's `PIL` package and the Swift image service; this script runs the same
text against Pillow and rewrites the expected values between `// BEGIN PILLOW EXPECTED` and
`// END PILLOW EXPECTED`. Run it with an interpreter that has Pillow, never the system one:

    python3 -m venv /tmp/pillow && /tmp/pillow/bin/pip install pillow==13.0.0
    /tmp/pillow/bin/python -B submodules/AyuPluginBridge/Build/generate_pil_reference.py

The font cases need `FONT` (a TrueType file both FreeType and CoreText read); without it they
are left out and the test skips them.
"""
from __future__ import annotations

import json
import os
import re
import sys
import tempfile
import textwrap
import warnings
from pathlib import Path

TEST = Path(__file__).resolve().parents[1] / "Tests" / "Swift" / "AyuPluginEndToEndImageTests.swift"
FONT = "/System/Library/Fonts/Supplemental/Arial.ttf"
CASES = re.compile(r'// BEGIN PILLOW CASES\n\s*static let pillowCases = #"""\n(.*?)\n\s*"""#\n\s*// END PILLOW CASES', re.S)
EXPECTED = re.compile(r'(// BEGIN PILLOW EXPECTED\n)(.*?)(\n\s*// END PILLOW EXPECTED)', re.S)


def plain(value):
    if isinstance(value, (list, tuple)):
        return [plain(item) for item in value]
    if isinstance(value, float):
        return round(value, 4)
    return value


def main():
    import PIL
    text = TEST.read_text(encoding="utf-8")
    found = CASES.search(text)
    if found is None or EXPECTED.search(text) is None:
        sys.exit("The test file has lost its markers.")
    scope = {}
    exec(compile(textwrap.dedent(found.group(1)), "pillow_cases", "exec"), scope)
    results = {}

    def record(name, value):
        if name in results:
            sys.exit("Duplicate case " + name)
        results[name] = plain(value)

    with warnings.catch_warnings(), tempfile.TemporaryDirectory() as workdir:
        warnings.simplefilter("ignore")
        scope["pillow_cases"](record, workdir, FONT if os.path.isfile(FONT) else None)
    body = json.dumps(results, separators=(",", ":"), sort_keys=True)
    if '"""' in body or "\\" in body:
        sys.exit("The expected values need escaping the test does not do.")
    block = ("    /// Pillow " + PIL.__version__ + ", written by Build/generate_pil_reference.py.\n"
             '    static let pillowExpected = #"""\n    ' + body + '\n    """#')
    TEST.write_text(EXPECTED.sub(lambda match: match.group(1) + block + match.group(3), text), encoding="utf-8")
    print(f"{len(results)} cases from Pillow {PIL.__version__} written to {TEST.name}")


if __name__ == "__main__":
    main()
