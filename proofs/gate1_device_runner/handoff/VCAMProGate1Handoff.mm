#import <Foundation/Foundation.h>

#import "Gate1HandoffProtocol.h"

#include <cerrno>
#include <cstdlib>
#include <spawn.h>
#include <sys/wait.h>
#include <unistd.h>

extern char** environ;

namespace {

constexpr const char* kCoordinatorPath =
    "/var/jb/usr/libexec/vcampro-gate1-coordinator";

}  // namespace

@interface VCAMGate1Handoff : NSObject
    <NSXPCListenerDelegate, VCAMGate1HandoffProtocol>
@property(nonatomic, assign) BOOL runInProgress;
@property(nonatomic, assign) BOOL runConsumed;
@end

@implementation VCAMGate1Handoff

- (BOOL)listener:(NSXPCListener*)listener
    shouldAcceptNewConnection:(NSXPCConnection*)connection {
    (void)listener;

    connection.exportedInterface =
        [NSXPCInterface interfaceWithProtocol:
            @protocol(VCAMGate1HandoffProtocol)];
    connection.exportedObject = self;
    [connection resume];
    return YES;
}

- (void)runGate1WithReply:(void (^)(NSString* result))reply {
    @synchronized(self) {
        if (self.runInProgress || self.runConsumed) {
            reply(@"BUSY");
            return;
        }
        self.runInProgress = YES;
        self.runConsumed = YES;
    }

    dispatch_async(
        dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0),
        ^{
            pid_t child = -1;
            char* const argv[] = {
                const_cast<char*>(kCoordinatorPath),
                nullptr,
            };

            const int spawnResult =
                posix_spawn(
                    &child,
                    kCoordinatorPath,
                    nullptr,
                    nullptr,
                    argv,
                    environ);

            int exitCode = -1;
            if (spawnResult == 0 && child > 0) {
                int status = 0;
                pid_t waited = -1;
                do {
                    waited = waitpid(child, &status, 0);
                } while (waited < 0 && errno == EINTR);

                if (waited == child &&
                    WIFEXITED(status)) {
                    exitCode = WEXITSTATUS(status);
                }
            }

            dispatch_async(dispatch_get_main_queue(), ^{
                self.runInProgress = NO;
                reply(exitCode == 0 ? @"COMPLETED" : @"FAILED");

                dispatch_after(
                    dispatch_time(
                        DISPATCH_TIME_NOW,
                        static_cast<int64_t>(
                            250ULL * 1000ULL * 1000ULL)),
                    dispatch_get_main_queue(),
                    ^{
                        _exit(0);
                    });
            });
        });
}

@end

int main() {
    @autoreleasepool {
        VCAMGate1Handoff* delegate =
            [[VCAMGate1Handoff alloc] init];

        NSXPCListener* listener =
            [[NSXPCListener alloc]
                initWithMachServiceName:
                    VCAM_GATE1_MACH_SERVICE_NAME];
        listener.delegate = delegate;
        [listener resume];

        dispatch_after(
            dispatch_time(
                DISPATCH_TIME_NOW,
                static_cast<int64_t>(
                    30ULL * 1000ULL * 1000ULL * 1000ULL)),
            dispatch_get_main_queue(),
            ^{
                @synchronized(delegate) {
                    if (!delegate.runInProgress) {
                        _exit(0);
                    }
                }
            });

        [[NSRunLoop currentRunLoop] run];
    }
    return 0;
}
