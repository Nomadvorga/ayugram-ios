"""``_ayu_xposed.fire`` against ``XposedBridge.handleHookedMethod``: one callback snapshot per firing."""
from __future__ import annotations

import unittest
from unittest import mock

import pymembers_fixtures  # noqa: F401  puts the SDK on the path
import _ayu_xposed

TARGET = _ayu_xposed.ACTIVITY_RESULT


class SnapshotTests(unittest.TestCase):
    def setUp(self):
        self.store, self.seen = {TARGET: []}, []
        for name, value in (("_store", lambda: self.store), ("method_of", lambda target: None)):
            patcher = mock.patch.object(_ayu_xposed, name, value)
            patcher.start()
            self.addCleanup(patcher.stop)

    def hook(self, label, priority=50, before=None, after=None):
        hook = _ayu_xposed._Hook()
        hook.target, hook.store, hook.active, hook.callback = TARGET, self.store, True, None
        hook.priority, hook.order, hook.before_filters, hook.after_filters = priority, len(self.store[TARGET]), (), ()

        def phase(name, extra):
            def run(param):
                self.seen.append(f"{label} {name}")
                if extra is not None:
                    extra(param)
            return run
        hook.before, hook.after = phase("before", before), phase("after", after)
        self.store[TARGET].append(hook)
        self.store[TARGET].sort(key=lambda item: (-item.priority, item.order))
        return _ayu_xposed.Unhook(hook)

    def test_a_hook_that_removes_itself_before_still_gets_its_after_phase(self):
        handle = []
        handle.append(self.hook("once", before=lambda param: handle[0].unhook()))
        _ayu_xposed.fire(TARGET, None, [1])
        self.assertEqual(self.seen, ["once before", "once after"])
        _ayu_xposed.fire(TARGET, None, [1])
        self.assertEqual((self.seen, _ayu_xposed.hook_count(TARGET)), (["once before", "once after"], 0))

    def test_a_hook_removed_by_a_higher_one_finishes_the_firing_it_was_snapshotted_for(self):
        low = []
        self.hook("high", priority=90, before=lambda param: low[0].unhook())
        low.append(self.hook("low", priority=10))
        _ayu_xposed.fire(TARGET, None, [])
        self.assertEqual(self.seen, ["high before", "low before", "low after", "high after"])
        del self.seen[:]
        _ayu_xposed.fire(TARGET, None, [])
        self.assertEqual(self.seen, ["high before", "high after"])

    def test_a_result_or_throwable_set_before_skips_lower_hooks_and_reaches_the_after_phase(self):
        results = []
        self.hook("high", priority=90, before=lambda param: param.setResult("early"),
                  after=lambda param: results.append((param.getResult(), param.hasThrowable(), param.args)))
        self.hook("low", priority=10)
        param = _ayu_xposed.fire(TARGET, "this", [1, 2])
        self.assertEqual((self.seen, results, param.thisObject), (["high before", "high after"], [("early", False, [1, 2])], "this"))
        del self.seen[:]
        self.store[TARGET].clear()
        error = ValueError("thrown")
        self.hook("thrower", priority=90, before=lambda param: param.setThrowable(error))
        self.hook("low", priority=10)
        with mock.patch.object(_ayu_xposed, "_log", lambda message: None):
            param = _ayu_xposed.fire(TARGET, None, [])
        self.assertEqual((self.seen, param.getThrowable(), param.getResult()), (["thrower before", "thrower after"], error, None))
        with self.assertRaises(ValueError):
            param.getResultOrThrowable()


if __name__ == "__main__":
    unittest.main()
