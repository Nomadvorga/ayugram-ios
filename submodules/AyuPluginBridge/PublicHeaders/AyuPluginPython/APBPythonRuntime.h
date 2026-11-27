#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NSString * _Nonnull (^APBHostDispatch)(NSString *trustedOwner, NSString *request);
typedef void (^APBCompletion)(NSString * _Nullable resultJSON, NSError * _Nullable error);

/// One process-owned interpreter on one dedicated OS thread. Main never waits for Python.
/// Bridge ownership is established by native entry points, never by request JSON.
@interface APBPythonRuntime : NSObject
- (instancetype)init;
- (void)startWithPythonHome:(NSString *)pythonHome
                  sdkPath:(NSString *)sdkPath
          dispatchHandler:(APBHostDispatch)dispatchHandler
               completion:(APBCompletion)completion NS_SWIFT_NAME(start(pythonHome:sdkPath:dispatchHandler:completion:));
- (void)inspectPluginSource:(NSString *)source filename:(NSString *)filename completion:(APBCompletion)completion NS_SWIFT_NAME(inspect(source:filename:completion:));
- (void)preflightPluginSource:(NSString *)source filename:(NSString *)filename completion:(APBCompletion)completion NS_SWIFT_NAME(preflight(source:filename:completion:));
- (void)loadPluginSource:(NSString *)source filename:(NSString *)filename completion:(APBCompletion)completion NS_SWIFT_NAME(load(source:filename:completion:));
/// `.elyx`/`.eaf` packages: `path` is the absolute path of the stored archive, which the SDK reads itself.
- (void)inspectPackageAtPath:(NSString *)path filename:(NSString *)filename completion:(APBCompletion)completion NS_SWIFT_NAME(inspectPackage(path:filename:completion:));
- (void)preflightPackageAtPath:(NSString *)path filename:(NSString *)filename completion:(APBCompletion)completion NS_SWIFT_NAME(preflightPackage(path:filename:completion:));
- (void)loadPackageAtPath:(NSString *)path filename:(NSString *)filename completion:(APBCompletion)completion NS_SWIFT_NAME(loadPackage(path:filename:completion:));
- (void)unloadPlugin:(NSString *)pluginID completion:(APBCompletion)completion NS_SWIFT_NAME(unload(pluginID:completion:));
- (void)settingsForPlugin:(NSString *)pluginID completion:(APBCompletion)completion NS_SWIFT_NAME(settings(pluginID:completion:));
/// Both answer with code 7, not the general code 2, when the callback or the event's generation
/// was released while the delivery waited: nothing ran, and it is not a failure of the plugin.
- (void)invokeCallbackJSON:(NSString *)json forPlugin:(NSString *)pluginID completion:(APBCompletion)completion NS_SWIFT_NAME(invokeCallback(json:pluginID:completion:));
- (void)emitEventJSON:(NSString *)json forPlugin:(NSString *)pluginID completion:(APBCompletion)completion NS_SWIFT_NAME(emitEvent(json:pluginID:completion:));
/// Called on main, once per episode, after a job has left the queue following a refusal with
/// code 4 (queue full): a client that keeps its refused work may offer it again. It must not block.
- (void)setQueueCapacityHandler:(nullable void (^)(void))handler NS_SWIFT_NAME(setQueueCapacityHandler(_:));
@end

NS_ASSUME_NONNULL_END
