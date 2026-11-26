#define PY_SSIZE_T_CLEAN
#import "APBPythonRuntime.h"
#include <Python/Python.h>
#include "APBPythonRuntimeQueueBudget.h"

static NSString *const APBErrorDomain = @"AyuPluginPython";
static APBPythonRuntime *APBProcessRuntime;
static __thread void *APBTrustedOwner;

/// NSString length is measured in UTF-16 code units. Charge four bytes per
/// unit (twice UTF-16 storage) plus object/array overhead so ASCII-backed
/// NSStrings, callbacks, event JSON and source strings are conservatively
/// represented before their retaining job is admitted.
static NSUInteger APBQueuePayloadCost(NSArray<NSString *> *strings) {
    size_t total = apb_queue_payload_cost_begin();
    for (NSString *string in strings) {
        if (!apb_queue_payload_cost_add_string(&total, (size_t)string.length)) return NSUIntegerMax;
    }
    return (NSUInteger)total;
}

@interface APBQueuedJob : NSObject
@property (nonatomic, copy) void (^block)(NSUInteger outstandingCost);
@property (nonatomic) NSUInteger outstandingCost;
@end

@implementation APBQueuedJob
@end

@interface APBCompletionPayload : NSObject
@property (nonatomic, strong) NSString *result;
@property (nonatomic, strong) NSError *error;
@end

@implementation APBCompletionPayload
@end

@interface APBPythonRuntime () {
    NSCondition *_condition;
    NSMutableArray<APBQueuedJob *> *_jobs;
    APBQueueBudget _queueBudget;
    NSThread *_worker;
    APBHostDispatch _hostDispatch;
    PyObject *_sdk;
    BOOL _ready;
    BOOL _starting;
}
- (NSString *)dispatchRequest:(NSString *)request owner:(NSString *)owner;
- (void)completeAdmitted:(APBCompletion)completion result:(NSString *)result error:(NSError *)error outstandingCost:(NSUInteger)outstandingCost;
- (void)rejectWithoutQueue:(APBCompletion)completion error:(NSError *)error;
@end

static NSError *APBError(NSInteger code, NSString *message) {
    return [NSError errorWithDomain:APBErrorDomain code:code userInfo:@{NSLocalizedDescriptionKey: message}];
}

static NSError *APBPythonError(void) {
    // Do not print traceback/source/locals: plugins may contain user credentials.
    PyErr_Clear();
    return APBError(2, @"Python operation failed. See the plugin compatibility report.");
}

static BOOL APBUTF8LengthExceedsResultLimit(PyObject *string) {
    Py_ssize_t length = PyUnicode_GetLength(string);
    if (length < 0) return NO; // Preserve the Python error for the caller.
    if ((NSUInteger)length > APB_QUEUE_MAXIMUM_RESULT_UTF8_BYTES) return YES;

    int kind = PyUnicode_KIND(string);
    void *characters = PyUnicode_DATA(string);
    size_t utf8Length = 0;
    for (Py_ssize_t index = 0; index < length; index++) {
        Py_UCS4 character = PyUnicode_READ(kind, characters, index);
        if (!apb_result_utf8_size_add(&utf8Length, character, APB_QUEUE_MAXIMUM_RESULT_UTF8_BYTES)) return YES;
    }
    return NO;
}

static PyObject *APBDispatch(PyObject *self, PyObject *args) {
    (void)self;
    const char *bytes = NULL;
    Py_ssize_t length = 0;
    if (!PyArg_ParseTuple(args, "s#", &bytes, &length)) return NULL;
    if (!APBTrustedOwner || !APBProcessRuntime || [NSThread isMainThread]) {
        PyErr_SetString(PyExc_RuntimeError, "WRONG_QUEUE: native bridge requires its dedicated Python thread and owner");
        return NULL;
    }
    if (length < 0 || length > 262144) {
        PyErr_SetString(PyExc_ValueError, "LIMIT_EXCEEDED: bridge request too large");
        return NULL;
    }
    @autoreleasepool {
        NSString *request = [[NSString alloc] initWithBytes:bytes length:(NSUInteger)length encoding:NSUTF8StringEncoding];
        if (!request) {
            PyErr_SetString(PyExc_ValueError, "INVALID_JSON: request is not UTF-8");
            return NULL;
        }
        @try {
            NSString *response = [APBProcessRuntime dispatchRequest:request owner:(__bridge NSString *)APBTrustedOwner];
            NSData *data = [response dataUsingEncoding:NSUTF8StringEncoding];
            if (!data || data.length > 1048576) {
                PyErr_SetString(PyExc_RuntimeError, "INVALID_RESPONSE: native bridge response is unavailable or too large");
                return NULL;
            }
            return PyUnicode_DecodeUTF8(data.bytes, (Py_ssize_t)data.length, "strict");
        } @catch (NSException *exception) {
            (void)exception;
            PyErr_SetString(PyExc_RuntimeError, "HOST_EXCEPTION: native adapter failed");
            return NULL;
        }
    }
}

static PyMethodDef APBMethods[] = {
    {"dispatch", APBDispatch, METH_VARARGS, "Dispatch to the explicitly registered iOS adapters."},
    {NULL, NULL, 0, NULL}
};
static struct PyModuleDef APBModule = {PyModuleDef_HEAD_INIT, "_ayu_host", NULL, -1, APBMethods, NULL, NULL, NULL, NULL};
static PyObject *APBInitHost(void) { return PyModule_Create(&APBModule); }

@implementation APBPythonRuntime

- (instancetype)init {
    self = [super init];
    if (self) {
        _condition = [[NSCondition alloc] init];
        _jobs = [[NSMutableArray alloc] init];
        apb_queue_budget_init(&_queueBudget,
                              APB_QUEUE_MAXIMUM_JOBS,
                              APB_QUEUE_MAXIMUM_BYTES,
                              APB_QUEUE_MAXIMUM_RESULT_RETAINED_BYTES);
        _worker = [[NSThread alloc] initWithTarget:self selector:@selector(workerMain) object:nil];
        _worker.name = @"AyuGram.PluginPython";
        _worker.qualityOfService = NSQualityOfServiceUtility;
        [_worker start];
    }
    return self;
}

- (BOOL)enqueue:(void (^)(NSUInteger outstandingCost))job payloadCost:(NSUInteger)payloadCost {
    [_condition lock];
    // The same locked budget covers queued work, the executing job, and jobs
    // whose results are waiting for main-thread completion delivery.
    size_t outstandingCost = 0;
    if (!apb_queue_budget_admit(&_queueBudget, (size_t)payloadCost, &outstandingCost)) {
        [_condition unlock];
        return NO;
    }
    APBQueuedJob *queued = [[APBQueuedJob alloc] init];
    queued.block = job;
    queued.outstandingCost = (NSUInteger)outstandingCost;
    [_jobs addObject:queued];
    [_condition signal];
    [_condition unlock];
    return YES;
}

- (void)workerMain {
    // NSThread, not a GCD serial queue: Python callbacks must keep the same OS thread.
    for (;;) {
        @autoreleasepool {
            [_condition lock];
            while (_jobs.count == 0) [_condition wait];
            APBQueuedJob *queued = _jobs.firstObject;
            [_jobs removeObjectAtIndex:0];
            [_condition unlock];
            queued.block(queued.outstandingCost);
        }
    }
}

- (void)completeAdmitted:(APBCompletion)completion result:(NSString *)result error:(NSError *)error outstandingCost:(NSUInteger)outstandingCost {
    // The output has already passed the UTF-8 limit. Charge its maximum UTF-16
    // storage plus a fixed object allowance (or bounded error objects), and
    // return unused temporary-result headroom before putting it on main.
    size_t actualResultBytes = result ? (size_t)result.length * 2 + 256 : 512;
    size_t reservationCost = (size_t)outstandingCost;
    [_condition lock];
    BOOL adjusted = apb_queue_budget_adjust_result(&_queueBudget, &reservationCost, actualResultBytes);
    NSCAssert(adjusted, @"Python runtime result exceeded its reserved queue budget");
    [_condition unlock];
    outstandingCost = (NSUInteger)reservationCost;

    APBCompletionPayload *payload = [[APBCompletionPayload alloc] init];
    payload.result = result;
    payload.error = error;
    dispatch_async(dispatch_get_main_queue(), ^{
        @try {
            completion(payload.result, payload.error);
        } @finally {
            // Keep both the job slot and its payload/result reservation until
            // client delivery returns. A stalled main queue therefore applies
            // backpressure instead of moving retention into an unbounded queue.
            payload.result = nil;
            payload.error = nil;
            [self->_condition lock];
            BOOL released = apb_queue_budget_complete(&self->_queueBudget, (size_t)outstandingCost);
            NSCAssert(released, @"Python runtime queue accounting underflow");
            [self->_condition unlock];
        }
    });
}

- (void)rejectWithoutQueue:(APBCompletion)completion error:(NSError *)error {
    // There is deliberately no async fallback here: rejected calls have no
    // reservation, so dispatching their captured completions to main could
    // create an unbounded secondary queue precisely when admission is full.
    // Successful operations retain the established asynchronous main delivery.
    completion(nil, error);
}

- (NSString *)dispatchRequest:(NSString *)request owner:(NSString *)owner {
    return _hostDispatch(owner, request);
}

- (void)startWithPythonHome:(NSString *)pythonHome sdkPath:(NSString *)sdkPath dispatchHandler:(APBHostDispatch)dispatchHandler completion:(APBCompletion)completion {
    NSString *stablePythonHome = [pythonHome copy];
    NSString *stableSDKPath = [sdkPath copy];
    BOOL alreadyStarted = NO;
    @synchronized(self) {
        if (_starting || _ready) {
            alreadyStarted = YES;
        } else {
            _starting = YES;
        }
    }
    if (alreadyStarted) {
        [self rejectWithoutQueue:completion error:APBError(1, @"Python runtime has already been started")];
        return;
    }
    NSUInteger payloadCost = APBQueuePayloadCost(@[stablePythonHome, stableSDKPath]);
    BOOL queued = [self enqueue:^(NSUInteger outstandingCost) {
        @synchronized([APBPythonRuntime class]) {
            if (APBProcessRuntime || Py_IsInitialized()) {
                @synchronized(self) { self->_starting = NO; }
                [self completeAdmitted:completion result:nil error:APBError(1, @"Only one plugin interpreter may own the process") outstandingCost:outstandingCost];
                return;
            }
            APBProcessRuntime = self;
        }
        if (![[NSFileManager defaultManager] fileExistsAtPath:[stablePythonHome stringByAppendingPathComponent:@"lib/python3.15/encodings/__init__.py"]] || ![[NSFileManager defaultManager] fileExistsAtPath:[stableSDKPath stringByAppendingPathComponent:@"ayu_bridge.py"]]) {
            @synchronized([APBPythonRuntime class]) { APBProcessRuntime = nil; }
            @synchronized(self) { self->_starting = NO; }
            [self completeAdmitted:completion result:nil error:APBError(1, @"Python resources or plugin SDK are missing from the app bundle") outstandingCost:outstandingCost];
            return;
        }
        self->_hostDispatch = [dispatchHandler copy];
        if (PyImport_AppendInittab("_ayu_host", APBInitHost) < 0) {
            @synchronized([APBPythonRuntime class]) { APBProcessRuntime = nil; }
            self->_hostDispatch = nil;
            @synchronized(self) { self->_starting = NO; }
            [self completeAdmitted:completion result:nil error:APBError(1, @"Unable to register the native Python bridge") outstandingCost:outstandingCost];
            return;
        }
        PyPreConfig preconfig;
        PyPreConfig_InitIsolatedConfig(&preconfig);
        preconfig.utf8_mode = 1;
        PyStatus status = Py_PreInitialize(&preconfig);
        PyConfig config;
        PyConfig_InitIsolatedConfig(&config);
        config.parse_argv = 0;
        config.install_signal_handlers = 0;
        config.write_bytecode = 0;
        config.use_environment = 0;
        config.site_import = 0;
        config.buffered_stdio = 0;
        if (!PyStatus_Exception(status)) status = PyConfig_SetBytesString(&config, &config.home, stablePythonHome.UTF8String);
        NSString *executable = NSBundle.mainBundle.executablePath;
        if (!PyStatus_Exception(status) && executable) status = PyConfig_SetBytesString(&config, &config.executable, executable.UTF8String);
        config.module_search_paths_set = 1;
        NSArray<NSString *> *paths = @[[stablePythonHome stringByAppendingPathComponent:@"lib/python3.15"], [stablePythonHome stringByAppendingPathComponent:@"lib/python3.15/lib-dynload"], stableSDKPath];
        for (NSString *path in paths) {
            if (PyStatus_Exception(status)) break;
            wchar_t *wide = Py_DecodeLocale(path.UTF8String, NULL);
            if (!wide) { status = PyStatus_Error("Invalid Python search path"); break; }
            status = PyWideStringList_Append(&config.module_search_paths, wide);
            PyMem_RawFree(wide);
        }
        if (!PyStatus_Exception(status)) status = Py_InitializeFromConfig(&config);
        BOOL failed = PyStatus_Exception(status);
        PyConfig_Clear(&config);
        if (failed) {
            @synchronized(self) { self->_starting = NO; }
            [self completeAdmitted:completion result:nil error:APBError(1, @"Unable to initialize embedded Python") outstandingCost:outstandingCost];
            return;
        }
        self->_sdk = PyImport_ImportModule("ayu_bridge");
        NSError *error = self->_sdk ? nil : APBPythonError();
        BOOL ready = self->_sdk != NULL;
        @synchronized(self) {
            self->_ready = ready;
            self->_starting = NO;
        }
        // Release between jobs. Every entry below reacquires on this same OS thread.
        PyEval_SaveThread();
        [self completeAdmitted:completion result:ready ? @"true" : nil error:error outstandingCost:outstandingCost];
    } payloadCost:payloadCost];
    if (!queued) {
        @synchronized(self) { _starting = NO; }
        [self rejectWithoutQueue:completion error:APBError(4, @"Plugin runtime queue is full")];
    }
}

- (PyObject *)call:(const char *)name arguments:(NSArray<NSString *> *)arguments {
    PyObject *function = PyObject_GetAttrString(_sdk, name);
    if (!function) return NULL;
    PyObject *tuple = PyTuple_New((Py_ssize_t)arguments.count);
    if (!tuple) { Py_DECREF(function); return NULL; }
    for (NSUInteger i = 0; i < arguments.count; i++) {
        NSData *data = [arguments[i] dataUsingEncoding:NSUTF8StringEncoding];
        PyObject *value = PyUnicode_DecodeUTF8(data.bytes, (Py_ssize_t)data.length, "strict");
        if (!value) { Py_DECREF(tuple); Py_DECREF(function); return NULL; }
        PyTuple_SET_ITEM(tuple, (Py_ssize_t)i, value);
    }
    PyObject *result = PyObject_CallObject(function, tuple);
    Py_DECREF(tuple);
    Py_DECREF(function);
    return result;
}

- (NSString *)jsonForResult:(PyObject *)result resultTooLarge:(BOOL *)resultTooLarge {
    if (resultTooLarge) *resultTooLarge = NO;
    if (!result) return nil;

    PyObject *encoded = NULL;
    PyObject *string = result;
    if (!PyUnicode_Check(result)) {
        PyObject *json = PyImport_ImportModule("json");
        encoded = json ? PyObject_CallMethod(json, "dumps", "O", result) : NULL;
        Py_XDECREF(json);
        if (!encoded) return nil;
        string = encoded;
    }

    // Count UTF-8 bytes before CPython allocates its UTF-8 cache and before
    // creating the result NSString retained by the completion block.
    if (APBUTF8LengthExceedsResultLimit(string)) {
        if (resultTooLarge) *resultTooLarge = YES;
        PyErr_Clear();
        Py_XDECREF(encoded);
        return nil;
    }
    Py_ssize_t length = 0;
    const char *utf8 = PyUnicode_AsUTF8AndSize(string, &length);
    NSString *output = utf8 ? [[NSString alloc] initWithBytes:utf8 length:(NSUInteger)length encoding:NSUTF8StringEncoding] : nil;
    Py_XDECREF(encoded);
    return output;
}

- (void)invoke:(const char *)name arguments:(NSArray<NSString *> *)arguments owner:(NSString *)owner completion:(APBCompletion)completion {
    // Copy a C selector name before escaping (all callers currently pass literals).
    NSString *functionName = [NSString stringWithUTF8String:name];
    NSString *stableOwner = [owner copy];
    NSArray<NSString *> *stableArguments = [[NSArray alloc] initWithArray:arguments copyItems:YES];
    NSUInteger payloadCost = APBQueuePayloadCost([@[functionName, stableOwner] arrayByAddingObjectsFromArray:stableArguments]);
    BOOL queued = [self enqueue:^(NSUInteger outstandingCost) {
        if (!self->_ready) { [self completeAdmitted:completion result:nil error:APBError(1, @"Python runtime is not ready") outstandingCost:outstandingCost]; return; }
        PyGILState_STATE gil = PyGILState_Ensure();
        APBTrustedOwner = (__bridge void *)stableOwner;
        PyObject *result = [self call:functionName.UTF8String arguments:stableArguments];
        BOOL resultTooLarge = NO;
        NSString *json = [self jsonForResult:result resultTooLarge:&resultTooLarge];
        NSError *error = json ? nil : (resultTooLarge ? APBError(5, @"Plugin runtime result exceeds the 1 MiB limit") : APBPythonError());
        Py_XDECREF(result);
        APBTrustedOwner = NULL;
        PyGILState_Release(gil);
        [self completeAdmitted:completion result:json error:error outstandingCost:outstandingCost];
    } payloadCost:payloadCost];
    if (!queued) [self rejectWithoutQueue:completion error:APBError(4, @"Plugin runtime queue is full")];
}

- (void)inspectPluginSource:(NSString *)source filename:(NSString *)filename completion:(APBCompletion)completion {
    NSString *stableSource = [source copy];
    NSString *normalizedFilename = [filename.lastPathComponent copy];
    if ([stableSource lengthOfBytesUsingEncoding:NSUTF8StringEncoding] > 4194304) { [self rejectWithoutQueue:completion error:APBError(3, @"Plugin exceeds the 4 MiB source limit")]; return; }
    [self invoke:"inspect_plugin_json" arguments:@[stableSource, normalizedFilename] owner:@"$inspection" completion:completion];
}

- (void)preflightPluginSource:(NSString *)source filename:(NSString *)filename completion:(APBCompletion)completion {
    NSString *stableSource = [source copy];
    NSString *normalizedFilename = [filename.lastPathComponent copy];
    if ([stableSource lengthOfBytesUsingEncoding:NSUTF8StringEncoding] > 4194304) { [self rejectWithoutQueue:completion error:APBError(3, @"Plugin exceeds the 4 MiB source limit")]; return; }
    [self invoke:"preflight_plugin_json" arguments:@[stableSource, normalizedFilename] owner:@"$inspection" completion:completion];
}

- (void)loadPluginSource:(NSString *)source filename:(NSString *)filename completion:(APBCompletion)completion {
    NSString *stableSource = [source copy];
    NSString *normalizedFilename = [filename.lastPathComponent copy];
    if ([stableSource lengthOfBytesUsingEncoding:NSUTF8StringEncoding] > 4194304) {
        [self rejectWithoutQueue:completion error:APBError(3, @"Plugin exceeds the 4 MiB source limit")];
        return;
    }
    NSUInteger payloadCost = APBQueuePayloadCost(@[stableSource, normalizedFilename, @"$inspection"]);
    BOOL queued = [self enqueue:^(NSUInteger outstandingCost) {
        if (!self->_ready) { [self completeAdmitted:completion result:nil error:APBError(1, @"Python runtime is not ready") outstandingCost:outstandingCost]; return; }
        PyGILState_STATE gil = PyGILState_Ensure();

        // Keep inspection and load in one admitted job. Splitting them across a
        // main-queue completion briefly retained a 4 MiB source outside queue
        // accounting and could admit another full source before re-enqueueing.
        APBTrustedOwner = (__bridge void *)@"$inspection";
        PyObject *inspectionResult = [self call:"inspect_plugin_json" arguments:@[stableSource, normalizedFilename]];
        BOOL inspectionTooLarge = NO;
        NSString *inspection = [self jsonForResult:inspectionResult resultTooLarge:&inspectionTooLarge];
        Py_XDECREF(inspectionResult);
        NSError *error = inspection ? nil : (inspectionTooLarge ? APBError(5, @"Plugin runtime result exceeds the 1 MiB limit") : APBPythonError());
        NSString *resultJSON = nil;
        NSString *owner = nil;

        if (inspection) {
            @autoreleasepool {
                NSData *data = [inspection dataUsingEncoding:NSUTF8StringEncoding];
                id value = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
                id metadata = [value isKindOfClass:[NSDictionary class]] ? value[@"metadata"] : nil;
                id ownerValue = [metadata isKindOfClass:[NSDictionary class]] ? metadata[@"__id__"] : nil;
                if (![ownerValue isKindOfClass:[NSString class]] || [(NSString *)ownerValue length] == 0) {
                    error = APBError(3, @"Plugin has no literal identity");
                } else {
                    owner = [ownerValue copy];
                }
            }
        }
        // Drop the bounded inspection string and parsed metadata before building
        // the activation result, so they cannot coexist in the main completion.
        inspection = nil;

        if (owner) {
            APBTrustedOwner = (__bridge void *)owner;
            PyObject *loadResult = [self call:"load_plugin" arguments:@[stableSource, normalizedFilename, owner]];
            BOOL loadResultTooLarge = NO;
            resultJSON = [self jsonForResult:loadResult resultTooLarge:&loadResultTooLarge];
            error = resultJSON ? nil : (loadResultTooLarge ? APBError(5, @"Plugin runtime result exceeds the 1 MiB limit") : APBPythonError());
            Py_XDECREF(loadResult);
            owner = nil;
        }

        APBTrustedOwner = NULL;
        PyGILState_Release(gil);
        [self completeAdmitted:completion result:resultJSON error:error outstandingCost:outstandingCost];
    } payloadCost:payloadCost];
    if (!queued) [self rejectWithoutQueue:completion error:APBError(4, @"Plugin runtime queue is full")];
}

- (void)unloadPlugin:(NSString *)pluginID completion:(APBCompletion)completion {
    [self invoke:"unload_plugin" arguments:@[pluginID] owner:pluginID completion:completion];
}
- (void)settingsForPlugin:(NSString *)pluginID completion:(APBCompletion)completion {
    [self invoke:"serialize_settings" arguments:@[pluginID] owner:pluginID completion:completion];
}
- (void)invokeCallbackJSON:(NSString *)json forPlugin:(NSString *)pluginID completion:(APBCompletion)completion {
    [self invoke:"invoke_callback_json" arguments:@[json] owner:pluginID completion:completion];
}
- (void)emitEventJSON:(NSString *)json forPlugin:(NSString *)pluginID completion:(APBCompletion)completion {
    [self invoke:"emit_event_json" arguments:@[json] owner:pluginID completion:completion];
}
@end
