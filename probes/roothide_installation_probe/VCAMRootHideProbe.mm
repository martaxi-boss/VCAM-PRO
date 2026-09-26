#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

#include <cstring>
#include <unistd.h>

namespace {

UIWindow* gProbeWindow = nil;
id gLaunchObserver = nil;

NSString* const kProbeVersion = @"0.1.0~probe2";
NSString* const kProofDirectory =
    @"/var/mobile/Library/VCAMProRootHideProbe";
NSString* const kProofPath =
    @"/var/mobile/Library/VCAMProRootHideProbe/load-proof.txt";

bool IsSpringBoard() noexcept {
    const char* process = getprogname();
    return process != nullptr &&
           std::strcmp(process, "SpringBoard") == 0;
}

void WritePersistentLoadProof() {
    NSFileManager* manager =
        [NSFileManager defaultManager];

    NSError* directoryError = nil;
    if (![manager
            createDirectoryAtPath:kProofDirectory
      withIntermediateDirectories:YES
                       attributes:nil
                            error:&directoryError]) {
        NSLog(
            @"[VCAM ROOT HIDE PROBE] unable to create proof directory: %@",
            directoryError);
        return;
    }

    NSISO8601DateFormatter* formatter =
        [[NSISO8601DateFormatter alloc] init];
    NSString* timestamp =
        [formatter stringFromDate:[NSDate date]];

    NSString* contents =
        [NSString
            stringWithFormat:
                @"VCAM ROOT HIDE PROBE\nversion=%@\ntimestamp=%@\nprocess=SpringBoard\n",
                kProbeVersion,
                (timestamp != nil ? timestamp : @"unknown")];

    NSError* writeError = nil;
    if (![contents
            writeToFile:kProofPath
             atomically:YES
               encoding:NSUTF8StringEncoding
                  error:&writeError]) {
        NSLog(
            @"[VCAM ROOT HIDE PROBE] unable to write proof marker: %@",
            writeError);
        return;
    }

    NSLog(
        @"[VCAM ROOT HIDE PROBE] persistent load proof written: %@",
        kProofPath);
}

void ShowProbeMarker() {
    if (gProbeWindow != nil) {
        return;
    }

    const CGRect screenBounds =
        UIScreen.mainScreen.bounds;
    const CGFloat horizontalInset = 12.0;
    const CGFloat height = 58.0;
    const CGFloat width =
        MIN(
            screenBounds.size.width -
                (horizontalInset * 2.0),
            360.0);
    const CGFloat x =
        (screenBounds.size.width - width) /
        2.0;
    const CGFloat y = 48.0;

    UIWindow* window =
        [[UIWindow alloc]
            initWithFrame:
                CGRectMake(
                    x,
                    y,
                    width,
                    height)];
    window.windowLevel =
        UIWindowLevelAlert + 10000.0;
    window.backgroundColor =
        UIColor.clearColor;
    window.userInteractionEnabled = NO;

    UIViewController* controller =
        [[UIViewController alloc] init];
    controller.view.backgroundColor =
        UIColor.clearColor;

    UILabel* label =
        [[UILabel alloc]
            initWithFrame:
                CGRectMake(
                    0.0,
                    0.0,
                    width,
                    height)];
    label.autoresizingMask =
        UIViewAutoresizingFlexibleWidth |
        UIViewAutoresizingFlexibleHeight;
    label.backgroundColor =
        [UIColor
            colorWithRed:0.45
                   green:0.0
                    blue:0.55
                   alpha:0.96];
    label.textColor = UIColor.whiteColor;
    label.textAlignment =
        NSTextAlignmentCenter;
    label.font =
        [UIFont boldSystemFontOfSize:16.0];
    label.numberOfLines = 2;
    label.text =
        @"VCAM ROOT HIDE PROBE\nSPRINGBOARD LOAD PASS";
    label.accessibilityLabel =
        @"VCAM ROOT HIDE PROBE";

    [controller.view addSubview:label];
    window.rootViewController = controller;
    window.hidden = NO;
    gProbeWindow = window;

    dispatch_after(
        dispatch_time(
            DISPATCH_TIME_NOW,
            60 * NSEC_PER_SEC),
        dispatch_get_main_queue(),
        ^{
            gProbeWindow.hidden = YES;
            gProbeWindow = nil;
        });
}

void ScheduleVisibleLoadProof() {
    dispatch_async(
        dispatch_get_main_queue(),
        ^{
            if (gLaunchObserver == nil) {
                gLaunchObserver =
                    [[NSNotificationCenter
                        defaultCenter]
                        addObserverForName:
                            UIApplicationDidFinishLaunchingNotification
                        object:nil
                        queue:
                            [NSOperationQueue
                                mainQueue]
                        usingBlock:^(
                            NSNotification*
                                notification) {
                            (void)notification;
                            ShowProbeMarker();
                        }];
            }

            dispatch_after(
                dispatch_time(
                    DISPATCH_TIME_NOW,
                    3 * NSEC_PER_SEC),
                dispatch_get_main_queue(),
                ^{
                    ShowProbeMarker();
                });
        });
}

}  // namespace

__attribute__((constructor))
static void VCAMRootHideProbeInitialize() {
    @autoreleasepool {
        if (!IsSpringBoard()) {
            return;
        }

        WritePersistentLoadProof();
        ScheduleVisibleLoadProof();
    }
}
