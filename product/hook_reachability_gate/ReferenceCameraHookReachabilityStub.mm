#include "HookReachabilityProofState.h"
#include "ReferenceCameraHook.h"

#include <dlfcn.h>
#include <notify.h>
#include <os/log.h>

#include <stdint.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

namespace vcam::product {

namespace {

constexpr const char* kTargetSymbolName =
    "CMSampleBufferGetImageBuffer";

int gHookReachabilityStateToken = -1;

bool TargetSymbolIsResolvable() noexcept {
    void* symbol =
        dlsym(
            RTLD_DEFAULT,
            kTargetSymbolName);

    return symbol != nullptr;
}

void PublishHookReachabilityProof() noexcept {
    const char* process = getprogname();

    if (process == nullptr ||
        strcmp(process, "mediaserverd") != 0) {
        return;
    }

    if (!TargetSymbolIsResolvable()) {
        os_log_with_type(
            OS_LOG_DEFAULT,
            OS_LOG_TYPE_DEFAULT,
            "[VCAM PRO HOOK REACH GATE] "
            "version=%{public}s "
            "process=mediaserverd "
            "runtime.start=PASS "
            "hook-call-path=REACHED "
            "target-symbol=NOT_RESOLVED "
            "hook-install=DISABLED "
            "frame-access=INACTIVE "
            "frame-substitution=INACTIVE",
            VCAM_HOOK_REACH_GATE_VERSION);
        return;
    }

    const pid_t pidValue = getpid();
    const time_t nowValue = time(nullptr);

    if (pidValue <= 0 ||
        (uint64_t)pidValue >
            UINT32_C(0x03ffffff) ||
        nowValue < 0 ||
        (uint64_t)nowValue > UINT32_MAX) {
        return;
    }

    const uint64_t state =
        vcam_hook_reach_encode_state(
            (uint32_t)nowValue,
            (uint32_t)pidValue);

    int token = 0;

    if (notify_register_check(
            VCAM_HOOK_REACH_GATE_NOTIFICATION,
            &token) != NOTIFY_STATUS_OK) {
        return;
    }

    if (notify_set_state(
            token,
            state) != NOTIFY_STATUS_OK) {
        (void)notify_cancel(token);
        return;
    }

    if (notify_post(
            VCAM_HOOK_REACH_GATE_NOTIFICATION) !=
        NOTIFY_STATUS_OK) {
        (void)notify_cancel(token);
        return;
    }

    gHookReachabilityStateToken = token;

    os_log_with_type(
        OS_LOG_DEFAULT,
        OS_LOG_TYPE_DEFAULT,
        "[VCAM PRO HOOK REACH GATE] "
        "version=%{public}s "
        "process=mediaserverd "
        "runtime.start=PASS "
        "hook-call-path=REACHED "
        "target-symbol=RESOLVED "
        "hook-install=DISABLED "
        "frame-access=INACTIVE "
        "frame-substitution=INACTIVE "
        "pid=%{public}d",
        VCAM_HOOK_REACH_GATE_VERSION,
        pidValue);
}

}  // namespace

bool InstallReferenceCameraHook() {
    PublishHookReachabilityProof();

    // Diagnostic gate only: no function is invoked, patched or replaced.
    return false;
}

}  // namespace vcam::product
