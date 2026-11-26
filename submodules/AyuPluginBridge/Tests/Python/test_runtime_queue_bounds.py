"""Production queue-budget tests; no supplied plugin code is executed."""
from pathlib import Path
import os
import shlex
import shutil
import subprocess
import tempfile
import unittest


BRIDGE = Path(__file__).resolve().parents[2]
RUNTIME = BRIDGE / "ObjC/APBPythonRuntime.m"
BUDGET_HEADER = BRIDGE / "ObjC/APBPythonRuntimeQueueBudget.h"
BUDGET_FIXTURE = Path(__file__).with_name("APBPythonRuntimeQueueBudgetTests.c")


class RuntimeQueueBoundTests(unittest.TestCase):
    def test_portable_fixture_exercises_production_accounting_header(self):
        configured = os.environ.get("CC")
        candidates = shlex.split(configured) if configured else []
        if not candidates:
            candidates = [compiler for compiler in ("clang", "cc", "gcc") if shutil.which(compiler)]
        if not candidates or not shutil.which(candidates[0]):
            self.skipTest("No clang/cc/gcc available to compile the production C accounting fixture")

        with tempfile.TemporaryDirectory(prefix="apb-queue-budget-") as temporary:
            executable = Path(temporary) / ("queue_budget.exe" if os.name == "nt" else "queue_budget")
            subprocess.run(
                candidates + [
                    "-std=c11", "-Wall", "-Wextra", "-Werror",
                    "-I", str(BUDGET_HEADER.parent), str(BUDGET_FIXTURE),
                    "-o", str(executable),
                ],
                check=True,
                capture_output=True,
                text=True,
            )
            completed = subprocess.run([str(executable)], check=True, capture_output=True, text=True)
            self.assertIn("APBPythonRuntimeQueueBudgetTests: PASS", completed.stdout)

    def test_native_runtime_charges_until_main_completion_returns(self):
        source = RUNTIME.read_text(encoding="utf-8")
        header = BUDGET_HEADER.read_text(encoding="utf-8")

        self.assertIn("APB_QUEUE_MAXIMUM_JOBS ((size_t)64)", header)
        self.assertIn("APB_QUEUE_MAXIMUM_BYTES ((size_t)32 * 1024 * 1024)", header)
        self.assertIn("APB_QUEUE_MAXIMUM_RESULT_UTF8_BYTES ((size_t)1024 * 1024)", header)
        self.assertIn("APB_QUEUE_MAXIMUM_RESULT_RETAINED_BYTES (7 * APB_QUEUE_MAXIMUM_RESULT_UTF8_BYTES + 512)", header)
        self.assertIn("apb_queue_budget_adjust_result(&_queueBudget", source)
        self.assertIn("apb_result_utf8_size_add(&utf8Length, character, APB_QUEUE_MAXIMUM_RESULT_UTF8_BYTES)", source)
        self.assertIn("apb_queue_budget_admit(&_queueBudget", source)
        self.assertIn("apb_queue_budget_complete(&self->_queueBudget", source)
        self.assertIn("completion(payload.result, payload.error);\n        } @finally", source)
        self.assertIn("payload.result = nil;\n            payload.error = nil;", source)
        self.assertNotIn("apb_queue_budget_complete(&_queueBudget", source)
        delivery_start = source.index("- (void)completeAdmitted:", source.index("@implementation APBPythonRuntime"))
        delivery_end = source.index("- (void)rejectWithoutQueue:", delivery_start)
        delivery = source[delivery_start:delivery_end]
        self.assertLess(delivery.index("completion(payload.result, payload.error);"), delivery.index("payload.result = nil;"))
        self.assertLess(delivery.index("payload.error = nil;"), delivery.index("apb_queue_budget_complete(&self->_queueBudget"))
        self.assertIn("queued.block(queued.outstandingCost);", source)
        self.assertIn("NSThread alloc] initWithTarget:self selector:@selector(workerMain)", source)
        self.assertIn("dispatch_async(dispatch_get_main_queue()", source)
        self.assertNotIn("dispatch_sync(dispatch_get_main_queue()", source)

    def test_results_are_capped_before_retained_string_and_overflow_does_not_queue(self):
        source = RUNTIME.read_text(encoding="utf-8")
        start = source.index("- (NSString *)jsonForResult:")
        end = source.index("- (void)invoke:", start)
        serializer = source[start:end]
        self.assertLess(serializer.index("APBUTF8LengthExceedsResultLimit(string)"), serializer.index("PyUnicode_AsUTF8AndSize"))
        self.assertLess(serializer.index("PyUnicode_AsUTF8AndSize"), serializer.index("initWithBytes:utf8"))
        self.assertIn('APBError(5, @"Plugin runtime result exceeds the 1 MiB limit")', source)
        self.assertIn("completion(nil, error);", source)
        self.assertIn("create an unbounded secondary queue", source)
        self.assertNotIn("dispatch_async", source[source.index("- (void)rejectWithoutQueue:"):source.index("- (NSString *)dispatchRequest:")])
        self.assertGreaterEqual(source.count("[self rejectWithoutQueue:completion error:APBError(4, @\"Plugin runtime queue is full\")];"), 3)

    def test_all_payload_paths_keep_fifo_worker_and_source_limit(self):
        source = RUNTIME.read_text(encoding="utf-8")
        self.assertIn("APBQueuePayloadCost(@[stablePythonHome, stableSDKPath])", source)
        self.assertIn("APBQueuePayloadCost([@[functionName, stableOwner] arrayByAddingObjectsFromArray:stableArguments])", source)
        self.assertIn("APBQueuePayloadCost(@[stableSource, normalizedFilename, @\"$inspection\"])", source)
        self.assertIn("NSString *stableSource = [source copy];", source)
        self.assertIn("initWithArray:arguments copyItems:YES", source)
        load_start = source.index("- (void)loadPluginSource:")
        self.assertLess(source.index("inspection = nil;", load_start), source.index('[self call:"load_plugin"', load_start))
        self.assertGreaterEqual(source.count("lengthOfBytesUsingEncoding:NSUTF8StringEncoding] > 4194304"), 3)
        self.assertIn("APBQueuedJob *queued = _jobs.firstObject", source)
        self.assertIn("[_jobs removeObjectAtIndex:0]", source)
        self.assertIn("PyGILState_Ensure()", source)
        self.assertIn("PyGILState_Release(gil)", source)


if __name__ == "__main__":
    unittest.main()
