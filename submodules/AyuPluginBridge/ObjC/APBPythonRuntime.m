#define PY_SSIZE_T_CLEAN
#import "APBPythonRuntime.h"
#include <Python/Python.h>

static NSString *const APBErrorDomain = @"AyuPluginPython";
static APBPythonRuntime *APBProcessRuntime;
static __thread void *APBTrustedOwner;

@interface APBPythonRuntime () {
    NSCondition *_condition;
    NSMutableArray<dispatch_block_t> *_jobs;
    NSThread *_worker;
    APBHostDispatch _hostDispatch;
    PyObject *_sdk;
    BOOL _ready;
    BOOL _starting;
}
- (NSString *)dispatchRequest:(NSString *)request owner:(NSString *)owner;
@end

static NSError *APBError(NSInteger code, NSString *message) {
    return [NSError errorWithDomain:APBErrorDomain code:code userInfo:@{NSLocalizedDescriptionKey: message}];
}

static NSError *APBPythonError(void) {
    // Do not print traceback/source/locals: plugins may contain user credentials.
    PyObject *exception = PyErr_GetRaisedException();
    PyObject *name = exception ? PyObject_GetAttrString((PyObject *)Py_TYPE(exception), "__name__") : NULL;
    const char *typeName = name ? PyUnicode_AsUTF8(name) : NULL;
    NSString *message = typeName ? [NSString stringWithFormat:@"Python %@. See the plugin compatibility report.", [NSString stringWithUTF8String:typeName]] : @"Python operation failed";
    Py_XDECREF(name);
    Py_XDECREF(exception);
    PyErr_Clear();
    return APBError(2, message);
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
        _worker = [[NSThread alloc] initWithTarget:self selector:@selector(workerMain) object:nil];
        _worker.name = @"AyuGram.PluginPython";
        _worker.qualityOfService = NSQualityOfServiceUtility;
        [_worker start];
    }
    return self;
}

- (BOOL)enqueue:(dispatch_block_t)job {
    [_condition lock];
    // Bound retained source/callback work even when Python is slow or blocked in I/O.
    if (_jobs.count >= 64) {
        [_condition unlock];
        return NO;
    }
    [_jobs addObject:[job copy]];
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
            dispatch_block_t job = _jobs.firstObject;
            [_jobs removeObjectAtIndex:0];
            [_condition unlock];
            job();
        }
    }
}

- (void)complete:(APBCompletion)completion result:(NSString *)result error:(NSError *)error {
    dispatch_async(dispatch_get_main_queue(), ^{ completion(result, error); });
}

- (NSString *)dispatchRequest:(NSString *)request owner:(NSString *)owner {
    return _hostDispatch(owner, request);
}

- (void)startWithPythonHome:(NSString *)pythonHome sdkPath:(NSString *)sdkPath dispatchHandler:(APBHostDispatch)dispatchHandler completion:(APBCompletion)completion {
    @synchronized(self) {
        if (_starting || _ready) {
            [self complete:completion result:nil error:APBError(1, @"Python runtime has already been started")];
            return;
        }
        _starting = YES;
    }
    BOOL queued = [self enqueue:^{
        @synchronized([APBPythonRuntime class]) {
            if (APBProcessRuntime || Py_IsInitialized()) {
                self->_starting = NO;
                [self complete:completion result:nil error:APBError(1, @"Only one plugin interpreter may own the process")];
                return;
            }
            APBProcessRuntime = self;
        }
        if (![[NSFileManager defaultManager] fileExistsAtPath:[pythonHome stringByAppendingPathComponent:@"lib/python3.15/encodings/__init__.py"]] || ![[NSFileManager defaultManager] fileExistsAtPath:[sdkPath stringByAppendingPathComponent:@"ayu_bridge.py"]]) {
            APBProcessRuntime = nil;
            self->_starting = NO;
            [self complete:completion result:nil error:APBError(1, @"Python resources or plugin SDK are missing from the app bundle")];
            return;
        }
        self->_hostDispatch = [dispatchHandler copy];
        if (PyImport_AppendInittab("_ayu_host", APBInitHost) < 0) {
            @synchronized([APBPythonRuntime class]) { APBProcessRuntime = nil; }
            self->_hostDispatch = nil;
            self->_starting = NO;
            [self complete:completion result:nil error:APBError(1, @"Unable to register the native Python bridge")];
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
        if (!PyStatus_Exception(status)) status = PyConfig_SetBytesString(&config, &config.home, pythonHome.UTF8String);
        NSString *executable = NSBundle.mainBundle.executablePath;
        if (!PyStatus_Exception(status) && executable) status = PyConfig_SetBytesString(&config, &config.executable, executable.UTF8String);
        config.module_search_paths_set = 1;
        NSArray<NSString *> *paths = @[[pythonHome stringByAppendingPathComponent:@"lib/python3.15"], [pythonHome stringByAppendingPathComponent:@"lib/python3.15/lib-dynload"], sdkPath];
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
            self->_starting = NO;
            [self complete:completion result:nil error:APBError(1, @"Unable to initialize embedded Python")];
            return;
        }
        self->_sdk = PyImport_ImportModule("ayu_bridge");
        NSError *error = self->_sdk ? nil : APBPythonError();
        self->_ready = self->_sdk != NULL;
        self->_starting = NO;
        // Release between jobs. Every entry below reacquires on this same OS thread.
        PyEval_SaveThread();
        [self complete:completion result:self->_ready ? @"true" : nil error:error];
    }];
    if (!queued) {
        @synchronized(self) { _starting = NO; }
        [self complete:completion result:nil error:APBError(4, @"Plugin runtime queue is full")];
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

- (NSString *)jsonForResult:(PyObject *)result {
    if (!result) return nil;
    if (PyUnicode_Check(result)) {
        const char *utf8 = PyUnicode_AsUTF8(result);
        return utf8 ? [NSString stringWithUTF8String:utf8] : nil;
    }
    PyObject *json = PyImport_ImportModule("json");
    PyObject *encoded = json ? PyObject_CallMethod(json, "dumps", "O", result) : NULL;
    const char *utf8 = encoded ? PyUnicode_AsUTF8(encoded) : NULL;
    NSString *output = utf8 ? [NSString stringWithUTF8String:utf8] : nil;
    Py_XDECREF(encoded);
    Py_XDECREF(json);
    return output;
}

- (void)invoke:(const char *)name arguments:(NSArray<NSString *> *)arguments owner:(NSString *)owner completion:(APBCompletion)completion {
    // Copy a C selector name before escaping (all callers currently pass literals).
    NSString *functionName = [NSString stringWithUTF8String:name];
    BOOL queued = [self enqueue:^{
        if (!self->_ready) { [self complete:completion result:nil error:APBError(1, @"Python runtime is not ready")]; return; }
        PyGILState_STATE gil = PyGILState_Ensure();
        APBTrustedOwner = (__bridge void *)owner;
        PyObject *result = [self call:functionName.UTF8String arguments:arguments];
        NSString *json = [self jsonForResult:result];
        NSError *error = json ? nil : APBPythonError();
        Py_XDECREF(result);
        APBTrustedOwner = NULL;
        PyGILState_Release(gil);
        [self complete:completion result:json error:error];
    }];
    if (!queued) [self complete:completion result:nil error:APBError(4, @"Plugin runtime queue is full")];
}

- (void)inspectPluginSource:(NSString *)source filename:(NSString *)filename completion:(APBCompletion)completion {
    if ([source lengthOfBytesUsingEncoding:NSUTF8StringEncoding] > 4194304) { [self complete:completion result:nil error:APBError(3, @"Plugin exceeds the 4 MiB source limit")]; return; }
    [self invoke:"inspect_plugin_json" arguments:@[source, filename.lastPathComponent] owner:@"$inspection" completion:completion];
}

- (void)preflightPluginSource:(NSString *)source filename:(NSString *)filename completion:(APBCompletion)completion {
    if ([source lengthOfBytesUsingEncoding:NSUTF8StringEncoding] > 4194304) { [self complete:completion result:nil error:APBError(3, @"Plugin exceeds the 4 MiB source limit")]; return; }
    [self invoke:"preflight_plugin_json" arguments:@[source, filename.lastPathComponent] owner:@"$inspection" completion:completion];
}

- (void)loadPluginSource:(NSString *)source filename:(NSString *)filename completion:(APBCompletion)completion {
    // Inspection is AST-only. Establish owner before executing any code from the source.
    [self inspectPluginSource:source filename:filename completion:^(NSString *inspection, NSError *error) {
        if (error || !inspection) { completion(nil, error); return; }
        NSData *data = [inspection dataUsingEncoding:NSUTF8StringEncoding];
        id value = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        id metadata = [value isKindOfClass:[NSDictionary class]] ? value[@"metadata"] : nil;
        id owner = [metadata isKindOfClass:[NSDictionary class]] ? metadata[@"__id__"] : nil;
        if (![owner isKindOfClass:[NSString class]] || [(NSString *)owner length] == 0) { completion(nil, APBError(3, @"Plugin has no literal identity")); return; }
        [self invoke:"load_plugin" arguments:@[source, filename.lastPathComponent, owner] owner:owner completion:completion];
    }];
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
