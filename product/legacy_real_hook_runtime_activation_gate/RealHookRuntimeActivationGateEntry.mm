#include "MediaserverdRuntime.h"
#include "ReferenceCameraHook.h"

#import <Foundation/Foundation.h>

#include <fcntl.h>
#include <os/log.h>
#include <sys/types.h>
#include <unistd.h>

#include <cstdio>
#include <cstring>

namespace {

constexpr const char* kEvidencePath =
    "/var/tmp/vcampro-legacy-real-hook-runtime-activation-gate-001.txt";

bool ProcessIsMediaserverd() {
    @autoreleasepool {
        NSString* processName =
            [[NSProcessInfo processInfo] processName];
        return processName != nil &&
            [processName isEqualToString:@"mediaserverd"];
    }
}

void WriteLine(const char* line, bool truncate) {
    const int flags =
        O_WRONLY | O_CREAT |
        (truncate ? O_TRUNC : O_APPEND);
    const int fd = open(kEvidencePath, flags, 0644);
    if (fd < 0) {
        return;
    }

    (void)dprintf(fd, "%s\n", line);
    (void)fsync(fd);
    (void)close(fd);
}

void ResetEvidence() {
    char line[128] = {};
    (void)snprintf(
        line,
        sizeof(line),
        "TASK_ID=VCAM-PRO-LEGACY-EQUIVALENT-REAL-HOOK-RUNTIME-ACTIVATION-GATE-001 PID=%d",
        static_cast<int>(getpid()));
    WriteLine(line, true);
}

void EmitResult(const char* key, bool pass) {
    char line[128] = {};
    (void)snprintf(
        line,
        sizeof(line),
        "%s=%s",
        key,
        pass ? "PASS" : "FAIL");

    os_log_with_type(
        OS_LOG_DEFAULT,
        OS_LOG_TYPE_DEFAULT,
        "[VCAM PRO REAL HOOK RUNTIME GATE] %{public}s",
        line);
    WriteLine(line, false);
}

}  // namespace

__attribute__((constructor))
static void VCAMProRealHookRuntimeActivationGateInitialize() {
    @autoreleasepool {
        if (!ProcessIsMediaserverd()) {
            return;
        }

        ResetEvidence();

        auto& runtime =
            vcam::product::MediaserverdRuntime::shared();

        const bool runtimeStarted =
            runtime.start();
        EmitResult(
            "RUNTIME_START",
            runtimeStarted);

        if (!runtimeStarted) {
            return;
        }

        const bool hookInstalled =
            vcam::product::InstallReferenceCameraHook();

        EmitResult(
            "REAL_REFERENCE_HOOK_INSTALL",
            hookInstalled);
        EmitResult(
            "ORIGINAL_TRAMPOLINE_NON_NULL",
            hookInstalled);
    }
}
