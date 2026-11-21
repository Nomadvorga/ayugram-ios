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
- (void)loadPluginSource:(NSString *)source filename:(NSString *)filename completion:(APBCompletion)completion NS_SWIFT_NAME(load(source:filename:completion:));
- (void)unloadPlugin:(NSString *)pluginID completion:(APBCompletion)completion NS_SWIFT_NAME(unload(pluginID:completion:));
- (void)settingsForPlugin:(NSString *)pluginID completion:(APBCompletion)completion NS_SWIFT_NAME(settings(pluginID:completion:));
- (void)invokeCallbackJSON:(NSString *)json forPlugin:(NSString *)pluginID completion:(APBCompletion)completion NS_SWIFT_NAME(invokeCallback(json:pluginID:completion:));
- (void)emitEventJSON:(NSString *)json forPlugin:(NSString *)pluginID completion:(APBCompletion)completion NS_SWIFT_NAME(emitEvent(json:pluginID:completion:));
@end

NS_ASSUME_NONNULL_END
