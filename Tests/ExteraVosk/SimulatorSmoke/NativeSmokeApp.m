#import <UIKit/UIKit.h>

#include "NativeSmokeBridge.h"

#include <pthread.h>
#include <stdlib.h>
#include <string.h>

typedef struct {
    char *modelPath;
    char *pcmPath;
    char *nativeResultsPath;
    char *statusPath;
} VoskSmokeTask;

static BOOL writeStatus(NSURL *statusURL, NSString *status, NSString *phase, NSInteger exitCode) {
    NSDictionary *value = @{
        @"status": status,
        @"phase": phase,
        @"exit_code": @(exitCode),
        @"native_results": @"vosk-native-results.jsonl"
    };
    NSError *error = nil;
    NSData *data = [NSJSONSerialization dataWithJSONObject:value options:NSJSONWritingPrettyPrinted error:&error];
    return data != nil && error == nil && [data writeToURL:statusURL options:NSDataWritingAtomic error:&error];
}

static void *runNativeSmoke(void *opaqueTask) {
    VoskSmokeTask *task = opaqueTask;
    @autoreleasepool {
        NSURL *statusURL = [NSURL fileURLWithFileSystemRepresentation:task->statusPath
                                                          isDirectory:NO
                                                        relativeToURL:nil];
        writeStatus(statusURL, @"running", @"native_started", -1);

        int result = extera_vosk_native_smoke(task->modelPath, task->pcmPath, task->nativeResultsPath);
        writeStatus(statusURL, result == 0 ? @"passed" : @"failed", @"native_complete", result);
    }
    free(task->modelPath);
    free(task->pcmPath);
    free(task->nativeResultsPath);
    free(task->statusPath);
    free(task);
    return NULL;
}

@interface VoskSmokeAppDelegate : UIResponder <UIApplicationDelegate>
@property(nonatomic, strong) UIWindow *window;
@end

@implementation VoskSmokeAppDelegate

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    (void)application;
    (void)launchOptions;

    self.window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    UILabel *label = [[UILabel alloc] initWithFrame:self.window.bounds];
    label.text = @"Vosk native simulator smoke is running";
    label.textAlignment = NSTextAlignmentCenter;
    label.numberOfLines = 0;
    self.window.rootViewController = [[UIViewController alloc] init];
    self.window.rootViewController.view = label;
    [self.window makeKeyAndVisible];

    NSURL *bundleURL = NSBundle.mainBundle.bundleURL;
    NSURL *cacheURL = [NSFileManager.defaultManager URLsForDirectory:NSCachesDirectory inDomains:NSUserDomainMask].firstObject;
    NSURL *modelURL = [bundleURL URLByAppendingPathComponent:@"model" isDirectory:YES];
    NSURL *pcmURL = [bundleURL URLByAppendingPathComponent:@"fixture.pcm"];
    NSURL *nativeResultsURL = [cacheURL URLByAppendingPathComponent:@"vosk-native-results.jsonl"];
    NSURL *statusURL = [cacheURL URLByAppendingPathComponent:@"vosk-native-status.json"];

    writeStatus(statusURL, @"running", @"app_launched", -1);

    VoskSmokeTask *task = calloc(1, sizeof(VoskSmokeTask));
    if (!task) {
        writeStatus(statusURL, @"failed", @"task_allocation", 70);
        return YES;
    }
    task->modelPath = strdup(modelURL.fileSystemRepresentation);
    task->pcmPath = strdup(pcmURL.fileSystemRepresentation);
    task->nativeResultsPath = strdup(nativeResultsURL.fileSystemRepresentation);
    task->statusPath = strdup(statusURL.fileSystemRepresentation);
    if (!task->modelPath || !task->pcmPath || !task->nativeResultsPath || !task->statusPath) {
        free(task->modelPath);
        free(task->pcmPath);
        free(task->nativeResultsPath);
        free(task->statusPath);
        free(task);
        writeStatus(statusURL, @"failed", @"task_paths", 71);
        return YES;
    }

    pthread_t worker;
    int threadError = pthread_create(&worker, NULL, runNativeSmoke, task);
    if (threadError != 0) {
        free(task->modelPath);
        free(task->pcmPath);
        free(task->nativeResultsPath);
        free(task->statusPath);
        free(task);
        writeStatus(statusURL, @"failed", @"thread_create", threadError);
        return YES;
    }
    pthread_detach(worker);

    return YES;
}

@end

int main(int argc, char *argv[]) {
    @autoreleasepool {
        return UIApplicationMain(argc, argv, nil, NSStringFromClass(VoskSmokeAppDelegate.class));
    }
}
