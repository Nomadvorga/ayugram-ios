#import <UIKit/UIKit.h>

#include "NativeSmokeBridge.h"

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

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSLog(@"Vosk native smoke started; model=%@ fixture=%@", modelURL.path, pcmURL.path);
        int result = extera_vosk_native_smoke(modelURL.fileSystemRepresentation, pcmURL.fileSystemRepresentation,
                                             nativeResultsURL.fileSystemRepresentation);
        NSLog(@"Vosk native smoke returned with status %d", result);
        NSDictionary *status = @{
            @"exit_code": @(result),
            @"status": result == 0 ? @"passed" : @"failed",
            @"native_results": nativeResultsURL.lastPathComponent
        };
        NSError *error = nil;
        NSData *data = [NSJSONSerialization dataWithJSONObject:status options:NSJSONWritingPrettyPrinted error:&error];
        if (data && !error) {
            [data writeToURL:statusURL options:NSDataWritingAtomic error:&error];
        }
        if (error) {
            NSLog(@"Vosk smoke status write failed: %@", error);
        } else {
            NSLog(@"Vosk smoke status saved: %@", statusURL.path);
        }
    });

    return YES;
}

@end

int main(int argc, char *argv[]) {
    @autoreleasepool {
        return UIApplicationMain(argc, argv, nil, NSStringFromClass(VoskSmokeAppDelegate.class));
    }
}
