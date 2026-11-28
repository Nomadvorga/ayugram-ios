#!/usr/bin/env python3
"""Record what CPython's own ``audioop`` returns, as fixtures for the SDK's pure-Python port.

Run with a CPython that still has the C module (3.12 or older), on a little-endian host:
    python3.12 -W ignore submodules/AyuPluginBridge/Build/generate_audioop_vectors.py
It rewrites ``Tests/Python/audioop_golden.json``. The cases are generated from a fixed seed, so
the file changes only when this script or the interpreter's arithmetic does.
"""
from __future__ import annotations

import json
import platform
import random
import sys
from pathlib import Path

import audioop

OUTPUT = Path(__file__).resolve().parents[1] / "Tests" / "Python" / "audioop_golden.json"
WIDTHS = (1, 2, 3, 4)
FACTORS = (0.0, 1.0, -1.0, 0.5, 1.5, 2.0, -2.5, 0.35, 1.25, 1e-3, 1e10, -1e10, float("inf"), float("-inf"), float("nan"), 3)
STEREO_FACTORS = ((0.5, 0.5), (1, 0), (0, 1), (1.0, 1.0), (2.0, 2.0), (-1.0, -1.0), (0.35, 0.65), (1.25, -0.75),
                  (float("inf"), 0.0), (float("nan"), 1.0))
RATES = ((8000, 16000), (16000, 8000), (44100, 48000), (48000, 44100), (48000, 16000), (1, 1), (3, 7), (7, 3), (11025, 8000))
WEIGHTS = ((1, 0), (2, 1), (1, 1), (3, 5), (10, 90), (6, 4))


def encode(value):
    """JSON form that keeps bytes, tuples and non-finite floats apart from lists and numbers."""
    if isinstance(value, (bytes, bytearray)):
        return {"b": bytes(value).hex()}
    if isinstance(value, tuple):
        return {"t": [encode(item) for item in value]}
    if isinstance(value, list):
        return {"l": [encode(item) for item in value]}
    if isinstance(value, float):
        return {"f": repr(value)}
    if value is None or isinstance(value, (bool, int, str)):
        return value
    raise TypeError(type(value).__name__)


def edge_samples(width):
    low, high = -(1 << (8 * width - 1)), (1 << (8 * width - 1)) - 1
    return [low, low + 1, low // 2 - 1, -3, -2, -1, 0, 1, 2, 3, high // 2 + 1, high - 1, high]


def pack(samples, width):
    return b"".join((sample & ((1 << (8 * width)) - 1)).to_bytes(width, sys.byteorder) for sample in samples)


def fragments(randomizer, width, multiple=1):
    """Edge values in both orders, then random fragments of several lengths."""
    edges = edge_samples(width)
    found = [b"", pack(edges + edges[:(-len(edges)) % multiple], width),
             pack((edges[::-1] + edges[:1] * multiple)[:len(edges) // multiple * multiple + multiple], width)]
    for frames in (1, 2, 5, 16):
        found.append(bytes(randomizer.getrandbits(8) for _ in range(frames * multiple * width)))
    # Quiet audio: small magnitudes exercise rounding rather than saturation.
    found.append(pack([randomizer.randint(-40, 40) for _ in range(12 * multiple)], width))
    return found


def main() -> int:
    if sys.byteorder != "little":
        print("error: fixtures are recorded in little-endian byte order", file=sys.stderr)
        return 2
    randomizer = random.Random(20261126)
    cases = []

    def record(name, *arguments):
        case = {"function": name, "arguments": [encode(item) for item in arguments]}
        try:
            case["result"] = encode(getattr(audioop, name)(*arguments))
        except Exception as failure:  # the error itself is the expected value
            case["error"] = ["error" if isinstance(failure, audioop.error) else type(failure).__name__, str(failure)]
        cases.append(case)
        return case

    for width in WIDTHS:
        for fragment in fragments(randomizer, width):
            record("max", fragment, width)
            record("rms", fragment, width)
            record("reverse", fragment, width)
            for factor in FACTORS:
                record("mul", fragment, width, factor)
            for left, right in STEREO_FACTORS:
                record("tostereo", fragment, width, left, right)
            other = bytes(randomizer.getrandbits(8) for _ in range(len(fragment)))
            record("add", fragment, other, width)
            record("add", fragment, fragment, width)
            record("add", fragment, pack([-1] * (len(fragment) // width), width), width)
        for fragment in fragments(randomizer, width, 2):
            for left, right in STEREO_FACTORS:
                record("tomono", fragment, width, left, right)
        for channels in (1, 2, 3):
            for inrate, outrate in RATES if channels == 1 else RATES[:4]:
                for weight_a, weight_b in WEIGHTS if channels == 1 else WEIGHTS[:2]:
                    for fragment in fragments(randomizer, width, channels)[1:4]:
                        record("ratecv", fragment, width, channels, inrate, outrate, None, weight_a, weight_b)
                # A stream converted in pieces: each call continues from the state the last returned.
                stream = bytes(randomizer.getrandbits(8) for _ in range(24 * channels * width))
                state = None
                for start, end in ((0, 7), (7, 8), (8, 8), (8, 24)):
                    piece = stream[start * channels * width:end * channels * width]
                    case = record("ratecv", piece, width, channels, inrate, outrate, state, 2, 1)
                    state = audioop.ratecv(piece, width, channels, inrate, outrate, state, 2, 1)[1]
                    assert case["result"]["t"][1] == encode(state)
        record("ratecv", pack(edge_samples(width), width), width, 1, 2, 3, None)
        record("ratecv", pack(edge_samples(width), width), width, 1, 5, 2, (-1, ((7, -9),)))
        # A hand-made state keeps d negative: CPython sizes its output buffer for such a state only.
        record("ratecv", pack(edge_samples(width)[:4], width), width, 2, 1, 1, (-1, ((1, 2), (3, 4))))
        record("ratecv", b"", width, 2, 3, 2, (-2, ((5, 6), (-7, -8))), 3, 1)
        record("ratecv", pack([1, -1], width), width, 1, 1, 2, (-1, ((False, True),)))
        # Factors that are not exact in binary: the sum of the two products lands within one
        # rounding of an integer often enough to tell a fused multiply-add from two roundings.
        for _ in range(60):
            fragment = bytes(randomizer.getrandbits(8) for _ in range(8 * width))
            record("tomono", fragment, width, 0.1 * randomizer.randint(-30, 30), 0.1 * randomizer.randint(-30, 30))
        for left, right in ((1e300, -1e300), (-1e300, 1e300), (1e300, float("-inf")), (float("inf"), float("-inf")),
                            (1e-320, 0.1), (float("nan"), float("nan")), (1e308, 1e308)):
            record("tomono", pack(edge_samples(width)[:12], width), width, left, right)

    # Squares beyond 2**53 are where the sum of squares depends on how each step is rounded.
    for _ in range(150):
        base = randomizer.randint(2**20, 2**31 - 4)
        record("rms", pack([base + randomizer.randint(-3, 3) for _ in range(randomizer.randint(1, 4))], 4), 4)
    for _ in range(120):
        inrate, outrate = randomizer.randint(1, 2**31 - 1), randomizer.randint(1, 2**31 - 1)
        state = (randomizer.randint(-5, -1), ((randomizer.randint(-2**31, 2**31 - 1), randomizer.randint(-2**31, 2**31 - 1)),))
        record("ratecv", bytes(randomizer.getrandbits(8) for _ in range(4 * randomizer.randint(0, 3))), 4, 1, inrate, outrate,
               randomizer.choice((None, state)), randomizer.randint(1, 2**31 - 1), randomizer.randint(0, 2**31 - 1))

    sample = pack([1, -2, 3, -4], 2)
    for name, tail in (("max", ()), ("rms", ()), ("reverse", ()), ("mul", (2.0,)), ("tomono", (1.0, 1.0)), ("tostereo", (1.0, 1.0))):
        for width in (0, 5, -1, 2**31, -2**31 - 1):
            record(name, sample, width, *tail)
        for width in (1.0, "2", None):
            record(name, sample, width, *tail)
        record(name, sample[:3], 2, *tail)
        record(name, sample[:5], 3, *tail)
        record(name, sample[:5], 4, *tail)
        record(name, "text", 2, *tail)
        record(name, None, 2, *tail)
        record(name, [1, 2], 2, *tail)
        record(name, sample)
    for factor in ("2", None, [1.0], 2, True, 10**400):
        record("mul", sample, 2, factor)
        record("tomono", sample, 2, factor, 1.0)
        record("tostereo", sample, 2, 1.0, factor)
    record("tomono", pack([1, 2, 3], 2), 2, 1.0, 1.0)
    record("tomono", pack([1, 2, 3], 1), 1, 1.0, 1.0)
    record("add", sample, sample[:4], 2)
    record("add", sample[:4], sample, 2)
    record("add", sample[:3], sample[:3], 2)
    record("add", sample, sample, 0)
    record("add", sample, sample, 5)
    record("add", sample, "text", 2)
    record("add", sample, sample, 2.0)
    record("add", sample, sample)
    for arguments in (
            (sample, 0, 1, 1, 1, None), (sample, 5, 1, 1, 1, None), (sample, 2, 0, 1, 1, None), (sample, 2, -1, 1, 1, None),
            (sample, 2, 2**31 - 1, 1, 1, None), (sample, 2, 1, 0, 1, None), (sample, 2, 1, 1, 0, None),
            (sample, 2, 1, -8000, 8000, None), (sample, 2, 1, 1, 1, None, 0, 0), (sample, 2, 1, 1, 1, None, 1, -1),
            (sample, 2, 1, 1, 1, None, 0, 1), (sample[:3], 2, 1, 1, 1, None), (sample[:6], 2, 2, 1, 1, None),
            (sample, 2, 3, 1, 1, None), (sample, 2, 1, 1, 1, [0, ((0, 0),)]), (sample, 2, 1, 1, 1, 0),
            (sample, 2, 1, 1, 1, (0,)), (sample, 2, 1, 1, 1, (0, ((0, 0),), 0)), (sample, 2, 1, 1, 1, (0, [(0, 0)])),
            (sample, 2, 1, 1, 1, (0, ((0, 0), (0, 0)))), (sample, 2, 2, 1, 1, (0, ((0, 0),))), (sample, 2, 1, 1, 1, (0, ())),
            (sample, 2, 1, 1, 1, (0, ([0, 0],))), (sample, 2, 1, 1, 1, (0, ((0,),))), (sample, 2, 1, 1, 1, (0, ((0, 0, 0),))),
            (sample, 2, 1, 1, 1, (0.0, ((0, 0),))), (sample, 2, 1, 1, 1, (0, ((0.5, 0),))), (sample, 2, 1, 1, 1, ("0", ((0, 0),))),
            (sample, 2, 1, 1, 1, (2**31, ((0, 0),))), (sample, 2, 1, 1, 1, (0, ((0, -2**31 - 1),))),
            (sample, 2, 1, 1.0, 1, None), (sample, 2, 1, 1, 1, None, 1.0), (sample, 2.0, 1, 1, 1, None),
            (sample, 2, 1, 2**31, 1, None), ("text", 2, 1, 1, 1, None), (sample, 2, 1, 1, 1), (sample, 2, 1, 1, 1, None, 1, 0, 0),
            (sample, 2, 1, 2**31 - 1, 2**31 - 2, None), (b"", 2, 1, 1, 1, None), (b"", 4, 3, 44100, 48000, None, 5, 5)):
        record("ratecv", *arguments)

    document = {"interpreter": platform.python_implementation() + " " + platform.python_version(),
                "machine": platform.machine(), "byteorder": sys.byteorder, "cases": cases}
    OUTPUT.write_text(json.dumps(document, separators=(",", ":")) + "\n")
    print(f"{len(cases)} cases from {document['interpreter']} ({document['machine']}) -> {OUTPUT.name}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
