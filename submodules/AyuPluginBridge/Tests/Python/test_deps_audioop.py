"""The SDK's pure-Python ``audioop`` against values recorded from CPython 3.12's C module.

``audioop_golden.json`` is written by ``Build/generate_audioop_vectors.py`` under a CPython that
still ships the C module. Nothing here needs that interpreter.
"""
import array
import json
import math
import sys
import unittest
from pathlib import Path
from unittest.mock import patch

import test_bridge as fixtures
import _ayu_inspection as inspection
import audioop
import ayu_bridge as bridge

GOLDEN = Path(__file__).with_name("audioop_golden.json")
FUNCTIONS = ("add", "max", "mul", "ratecv", "reverse", "rms", "tomono", "tostereo")
# Everything else CPython 3.12's module defined.
ABSENT = ("adpcm2lin", "alaw2lin", "avg", "avgpp", "bias", "byteswap", "cross", "findfactor", "findfit", "findmax",
          "getsample", "lin2adpcm", "lin2alaw", "lin2lin", "lin2ulaw", "maxpp", "minmax", "ulaw2lin")


def decode(value):
    if isinstance(value, dict):
        if "b" in value:
            return bytes.fromhex(value["b"])
        if "t" in value:
            return tuple(decode(item) for item in value["t"])
        if "l" in value:
            return [decode(item) for item in value["l"]]
        return float(value["f"])
    return value


def outcome(name, arguments):
    try:
        return "result", getattr(audioop, name)(*arguments)
    except Exception as failure:
        return "error", ["error" if isinstance(failure, audioop.error) else type(failure).__name__, str(failure)]


class GoldenVectorTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.document = json.loads(GOLDEN.read_text(encoding="utf-8"))

    def test_module_under_test_is_the_sdk_one_and_vectors_come_from_cpython_3_12(self):
        self.assertEqual(Path(audioop.__file__).resolve(), (fixtures.SDK / "audioop.py").resolve())
        self.assertTrue(self.document["interpreter"].startswith("CPython 3.12."))
        self.assertEqual(self.document["byteorder"], sys.byteorder)
        covered = {case["function"] for case in self.document["cases"]}
        self.assertEqual(covered, set(FUNCTIONS))
        for width in (1, 2, 3, 4):
            for name in FUNCTIONS:
                self.assertTrue(any(case["function"] == name and "result" in case and width in case["arguments"][1:3]
                                    for case in self.document["cases"]), (name, width))

    def test_every_recorded_call_returns_what_cpython_returned(self):
        mismatches = []
        for index, case in enumerate(self.document["cases"]):
            kind, value = outcome(case["function"], [decode(item) for item in case["arguments"]])
            if "result" in case:
                expected = decode(case["result"])
                same = kind == "result" and value == expected and type(value) is type(expected)
            else:
                # ``audioop.error`` messages are part of the contract; for interpreter-raised
                # TypeError and OverflowError the wording varies between CPython versions.
                same = kind == "error" and value[0] == case["error"][0] and (value[0] != "error" or value == case["error"])
            if not same:
                mismatches.append((index, case["function"], case.get("error", "result"), kind, str(value)[:80]))
        self.assertEqual(mismatches[:5], [])
        self.assertGreater(len(self.document["cases"]), 3000)

    def test_recorded_error_messages_cover_every_check(self):
        messages = {case["error"][1] for case in self.document["cases"] if case.get("error", [""])[0] == "error"}
        self.assertEqual(messages, {
            "Size should be 1, 2, 3 or 4", "not a whole number of frames", "Lengths should be the same",
            "# of channels should be >= 1", "weightA should be >= 1, weightB should be >= 0", "sampling rate not > 0",
            "illegal state argument"})


class SurfaceTests(unittest.TestCase):
    def test_only_the_ported_functions_exist(self):
        self.assertEqual(inspection.sdk_symbols("audioop"), frozenset(FUNCTIONS) | {"error", "MAX_FRAGMENT_BYTES"})
        self.assertEqual(set(audioop.__all__), set(FUNCTIONS) | {"error"})
        self.assertTrue(issubclass(audioop.error, Exception))
        for name in ABSENT:
            with self.subTest(name):
                self.assertFalse(hasattr(audioop, name))
                with self.assertRaises(AttributeError):
                    getattr(audioop, name)

    def test_arguments_are_positional_only_as_in_c(self):
        with self.assertRaises(TypeError):
            audioop.mul(b"\0\0", width=2, factor=1.0)
        with self.assertRaises(TypeError):
            audioop.ratecv(b"\0\0", 2, 1, 1, 1, state=None)

    def test_any_contiguous_buffer_is_a_fragment(self):
        samples = array.array("h", [100, -200, 300, -400])
        expected = array.array("h", [200, -400, 600, -800]).tobytes()
        for fragment in (samples, samples.tobytes(), bytearray(samples.tobytes()), memoryview(samples)):
            with self.subTest(type(fragment).__name__):
                self.assertEqual(audioop.mul(fragment, 2, 2), expected)
        with self.assertRaises(BufferError):
            audioop.max(memoryview(bytes(8))[::2], 2)

    def test_streaming_conversion_equals_one_call(self):
        data = bytes(range(256)) * 3
        whole, _ = audioop.ratecv(data, 2, 2, 44100, 48000, None)
        pieces, state = b"", None
        for start in range(0, len(data), 100):
            piece, state = audioop.ratecv(data[start:start + 100], 2, 2, 44100, 48000, state)
            pieces += piece
        self.assertEqual(pieces, whole)
        self.assertEqual(len(whole) % 4, 0)


class BoundTests(unittest.TestCase):
    def limited(self, call, *arguments):
        with self.assertRaises(bridge.BridgeError) as caught:
            call(*arguments)
        self.assertEqual(caught.exception.code, "RESOURCE_LIMIT")

    def test_fragments_beyond_the_per_call_limit_are_refused(self):
        self.assertEqual(audioop.MAX_FRAGMENT_BYTES, 16 * 1024 * 1024)
        with patch.object(audioop, "MAX_FRAGMENT_BYTES", 64):
            fragment = bytes(64)
            self.assertEqual(audioop.mul(fragment, 2, 1.0), fragment)
            self.assertEqual(len(audioop.tostereo(bytes(32), 2, 1, 1)), 64)
            for call, arguments in ((audioop.mul, (bytes(66), 2, 1.0)), (audioop.max, (bytes(66), 2)),
                                    (audioop.rms, (bytes(66), 2)), (audioop.reverse, (bytes(66), 2)),
                                    (audioop.tomono, (bytes(68), 2, 1, 1)), (audioop.add, (bytes(4), bytes(66), 2)),
                                    (audioop.tostereo, (bytes(34), 2, 1, 1)), (audioop.ratecv, (bytes(66), 2, 1, 1, 1, None))):
                with self.subTest(call.__name__):
                    self.limited(call, *arguments)
            # The output of an upsampling conversion is bounded too, wherever it is detected.
            self.limited(audioop.ratecv, bytes(32), 2, 1, 1, 8, None)
            self.limited(audioop.ratecv, b"", 2, 9, 1, 1, None)

    def test_forged_state_cannot_produce_unbounded_output(self):
        # CPython trusts the state and would write past its buffer here.
        with patch.object(audioop, "MAX_FRAGMENT_BYTES", 4096):
            self.limited(audioop.ratecv, b"", 2, 1, 1, 2**31 - 1, (2**31 - 1, ((1, 2),)))
        output, state = audioop.ratecv(b"", 2, 1, 1, 1, (3, ((0x10000, 0x20000),)))
        self.assertEqual((len(output), state[0]), (8, -1))
        output, _ = audioop.ratecv(b"", 4, 1, 3, 2, (5, ((2**31 - 1, -2**31),)))
        self.assertEqual(len(output) % 4, 0)

    def test_fused_multiply_add_handles_values_the_library_call_rejects(self):
        self.assertEqual(audioop._fused(2.0, 3.0, 1.0), 7.0)
        self.assertEqual(audioop._fused(1e300, 1e300, 0.0), math.inf)
        self.assertEqual(audioop._fused(1e300, 1e300, -math.inf), -math.inf)
        self.assertTrue(math.isnan(audioop._fused(math.inf, 0.0, 1.0)))
        self.assertTrue(math.isnan(audioop._fused(math.inf, 1.0, -math.inf)))
        # One rounding: the exact product 2**-104 survives the cancellation.
        self.assertEqual(audioop._fused(1.0 + 2.0**-52, 1.0 - 2.0**-52, -1.0), -(2.0**-104))


class PreflightTests(unittest.TestCase):
    setUp = fixtures.BridgeTests.setUp
    tearDown = fixtures.BridgeTests.tearDown

    def blockers(self, imports, body="    pass\n"):
        report = json.loads(bridge.preflight_plugin_json(fixtures.source("sample", body, imports)))
        return [(item["code"], item["detail"]) for item in report["blockers"]]

    def test_audioop_is_an_sdk_module(self):
        self.assertIn("audioop", bridge.SDK_MODULES)
        body = ("    def run(self, pcm):\n        pcm = audioop.tomono(pcm, 2, 0.5, 0.5)\n"
                "        return ratecv(pcm, 2, 1, 44100, 48000, None), audioop.error\n")
        self.assertEqual(self.blockers("import audioop\nfrom audioop import ratecv, rms\n", body), [])

    def test_unported_functions_are_reported_not_stubbed(self):
        body = "    def run(self, pcm):\n        return audioop.lin2lin(pcm, 2, 1), audioop.bias(pcm, 2, 1)\n"
        self.assertEqual(self.blockers("import audioop\nfrom audioop import ulaw2lin, mul\n", body), [
            ("SDK_MEMBER", "audioop.bias"), ("SDK_MEMBER", "audioop.lin2lin"), ("SDK_MEMBER", "audioop.ulaw2lin")])


if __name__ == "__main__":
    unittest.main()
