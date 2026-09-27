#include "MediaserverdRuntime.h"
#include "RealHookRuntimeProofState.h"
#include "ReferenceCameraHook.h"

#import <Foundation/Foundation.h>

#include <fcntl.h>
#include <notify.h>
#include <os/log.h>
#include <sys/types.h>
#include <time.h>
#include <unistd.h>

#include <cstdio>
#include <cstring>

namespace {

constexpr const char* kEvidencePath =
    "/var/tmp/vcampro-legacy-real-hook-runtime-activation-gate-001.txt";

int gProofStateToken = -1;

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
    char line[160] = {};
    (void)snprintf(
        line,
        sizeof(line),
        "TASK_ID=VCAM-PRO-LEGACY-REAL-HOOK-RUNTIME-ACTIVATION-VISIBLE-WITNESS-REMEDIATION-001 PID=%d",
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

void ResetProofState() noexcept {
    int token = 0;
    if (notify_register_check(
            VCAM_REAL_HOOK_RUNTIME_GATE_NOTIFICATION,
            &token) != NOTIFY_STATUS_OK) {
        return;
    }

    if (notify_set_state(token, UINT64_C(0)) !=
        NOTIFY_STATUS_OK) {
        (void)notify_cancel(token);
        return;
    }

    gProofStateToken = token;
}

bool PublishRealHookInstallProof() noexcept {
    if (gProofStateToken < 0) {
        return false;
    }

    const pid_t pidValue = getpid();
    const time_t nowValue = time(nullptr);

    if (pidValue <= 0 ||
        (uint64_t)pidValue > UINT32_C(0x07ffffff) ||
        nowValue < 0 ||
        (uint64_t)nowValue > UINT32_MAX) {
        return false;
    }

    const uint64_t state =
        vcam_real_hook_runtime_encode_state(
            (uint32_t)nowValue,
            (uint32_t)pidValue);

    if (notify_set_state(
            gProofStateToken,
            state) != NOTIFY_STATUS_OK) {
        return false;
    }

    if (notify_post(
            VCAM_REAL_HOOK_RUNTIME_GATE_NOTIFICATION) !=
        NOTIFY_STATUS_OK) {
        return false;
    }

    os_log_with_type(
        OS_LOG_DEFAULT,
        OS_LOG_TYPE_DEFAULT,
        "[VCAM PRO REAL HOOK RUNTIME GATE] "
        "version=%{public}s "
        "process=mediaserverd "
        "runtime.start=PASS "
        "real-reference-hook-install=PASS "
        "original-trampoline=NON_NULL "
        "callback=NOT_EXERCISED "
        "frame-substitution=INACTIVE "
        "pid=%{public}d",
        VCAM_REAL_HOOK_RUNTIME_GATE_VERSION,
        pidValue);

    return true;
}

}  // namespace

__attribute__((constructor))
static void VCAMProRealHookRuntimeActivationGateInitialize() {
    @autoreleasepool {
        if (!ProcessIsMediaserverd()) {
            return;
        }

        ResetEvidence();
        ResetProofState();

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

        if (!hookInstalled) {
            return;
        }

        (void)PublishRealHookInstallProof();
    }
}
