#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

#include <cstdio>
#include <cstring>
#include <ctime>
#include <fcntl.h>
#include <unistd.h>

namespace {

constexpr const char* kProbeVersion = "0.1.0~probe2";
constexpr const char* kProofPath =
    "/var/mobile/Library/Preferences/"
    "com.vcampro.roothide-installation-probe.loaded";

UIWindow* gProbeWindow = nil;

bool IsSpringBoard() noexcept {
    const char* process = getprogname();
    return process != nullptr &&
           std::strcmp(process, "SpringBoard") == 0;
}

void WritePersistentProofMarker() noexcept {
    const int fd =
        open(
            kProofPath,
            O_WRONLY |
                O_CREAT |
                O_TRUNC |
                O_CLOEXEC,
            0644);

    if (fd < 0) {
        return;
    }

    char payload[256];
    const auto epoch =
        static_cast<long long>(
            std::time(nullptr));

    const int length =
        std::snprintf(
            payload,
            sizeof(payload),
            "VCAM ROOT HIDE PROBE\n"
            "version=%s\n"
            "epoch=%lld\n"
            "pid=%d\n",
            kProbeVersion,
            epoch,
            getpid());

    if (length > 0) {
        std::size_t offset = 0;
        const std::size_t total =
            static_cast<std::size_t>(
                length < static_cast<int>(
                    sizeof(payload))
                    ? length
                    : static_cast<int>(
                          sizeof(payload) - 1));

        while (offset < total) {
            const ssize_t written =
                write(
                    fd,
                    payload + offset,
                    total - offset);

            if (written < 0) {
                if (errno == EINTR) {
                    continue;
                }
                break;
            }

            offset +=
                static_cast<std::size_t>(
                    written);
        }
    }

    (void)fsync(fd);
    close(fd);
}

void ShowProbeMarker() {
    if (gProbeWindow != nil) {
        return;
    }

    const CGRect screenBounds =
        UIScreen.mainScreen.bounds;

    UIWindow* window =
        [[UIWindow alloc]
            initWithFrame:
                screenBounds];

    window.windowLevel =
        UIWindowLevelAlert + 1000.0;
    window.backgroundColor =
        UIColor.clearColor;
    window.userInteractionEnabled =
        NO;

    UIViewController* controller =
        [[UIViewController alloc] init];

    controller.view.backgroundColor =
        UIColor.clearColor;

    const CGFloat horizontalInset =
        16.0;
    const CGFloat height =
        64.0;
    const CGFloat width =
        MAX(
            1.0,
            screenBounds.size.width -
                (horizontalInset * 2.0));

    UILabel* label =
        [[UILabel alloc]
            initWithFrame:
                CGRectMake(
                    horizontalInset,
                    72.0,
                    width,
                    height)];

    label.autoresizingMask =
        UIViewAutoresizingFlexibleWidth |
        UIViewAutoresizingFlexibleBottomMargin;
    label.backgroundColor =
        [UIColor
            colorWithWhite:0.05
                     alpha:0.96];
    label.textColor =
        UIColor.whiteColor;
    label.textAlignment =
        NSTextAlignmentCenter;
    label.font =
        [UIFont
            boldSystemFontOfSize:
                18.0];
    label.numberOfLines = 2;
    label.text =
        @"VCAM ROOT HIDE PROBE\n"
         "SpringBoard load confirmed";
    label.accessibilityLabel =
        @"VCAM ROOT HIDE PROBE";

    [controller.view
        addSubview:label];

    window.rootViewController =
        controller;
    window.hidden =
        NO;

    gProbeWindow =
        window;

    dispatch_after(
        dispatch_time(
            DISPATCH_TIME_NOW,
            65 * NSEC_PER_SEC),
        dispatch_get_main_queue(),
        ^{
            gProbeWindow.hidden =
                YES;
            gProbeWindow =
                nil;
        });
}

}  // namespace

__attribute__((constructor))
static void VCAMRootHideProbeInitialize() {
    @autoreleasepool {
        if (!IsSpringBoard()) {
            return;
        }

        WritePersistentProofMarker();

        dispatch_after(
            dispatch_time(
                DISPATCH_TIME_NOW,
                2 * NSEC_PER_SEC),
            dispatch_get_main_queue(),
            ^{
                ShowProbeMarker();
            });
    }
}
