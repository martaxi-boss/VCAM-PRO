#include "HookInstallationReadinessProofState.h"
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
constexpr const char* kHookProviderSymbolName =
    "MSHookFunction";

int gHookInstallationReadinessStateToken = -1;

bool SymbolIsResolvable(
    const char* symbolName) noexcept {
    return
        symbolName != nullptr &&
        dlsym(
            RTLD_DEFAULT,
            symbolName) != nullptr;
}

void PublishHookInstallationReadinessProof() noexcept {
    const char* process = getprogname();

    if (process == nullptr ||
        strcmp(process, "mediaserverd") != 0) {
        return;
    }

    if (!SymbolIsResolvable(kTargetSymbolName)) {
        os_log_with_type(
            OS_LOG_DEFAULT,
            OS_LOG_TYPE_DEFAULT,
            "[VCAM PRO HOOK READY GATE] "
            "version=%{public}s "
            "process=mediaserverd "
            "runtime.start=PASS "
            "hook-call-path=REACHED "
            "target-symbol=NOT_RESOLVED "
            "hook-provider=NOT_CHECKED "
            "hook-install=NOT_EXECUTED "
            "frame-access=INACTIVE "
            "frame-substitution=INACTIVE",
            VCAM_HOOK_READY_GATE_VERSION);
        return;
    }

    if (!SymbolIsResolvable(kHookProviderSymbolName)) {
        os_log_with_type(
            OS_LOG_DEFAULT,
            OS_LOG_TYPE_DEFAULT,
            "[VCAM PRO HOOK READY GATE] "
            "version=%{public}s "
            "process=mediaserverd "
            "runtime.start=PASS "
            "hook-call-path=REACHED "
            "target-symbol=RESOLVED "
            "hook-provider=NOT_RESOLVED "
            "hook-install=NOT_EXECUTED "
            "frame-access=INACTIVE "
            "frame-substitution=INACTIVE",
            VCAM_HOOK_READY_GATE_VERSION);
        return;
    }

    const pid_t pidValue = getpid();
    const time_t nowValue = time(nullptr);

    if (pidValue <= 0 ||
        (uint64_t)pidValue >
            UINT32_C(0x01ffffff) ||
        nowValue < 0 ||
        (uint64_t)nowValue > UINT32_MAX) {
        return;
    }

    const uint64_t state =
        vcam_hook_ready_encode_state(
            (uint32_t)nowValue,
            (uint32_t)pidValue);

    int token = 0;

    if (notify_register_check(
            VCAM_HOOK_READY_GATE_NOTIFICATION,
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
            VCAM_HOOK_READY_GATE_NOTIFICATION) !=
        NOTIFY_STATUS_OK) {
        (void)notify_cancel(token);
        return;
    }

    gHookInstallationReadinessStateToken = token;

    os_log_with_type(
        OS_LOG_DEFAULT,
        OS_LOG_TYPE_DEFAULT,
        "[VCAM PRO HOOK READY GATE] "
        "version=%{public}s "
        "process=mediaserverd "
        "runtime.start=PASS "
        "hook-call-path=REACHED "
        "target-symbol=RESOLVED "
        "hook-provider=RESOLVED "
        "hook-install=NOT_EXECUTED "
        "frame-access=INACTIVE "
        "frame-substitution=INACTIVE "
        "pid=%{public}d",
        VCAM_HOOK_READY_GATE_VERSION,
        pidValue);
}

}  // namespace

bool InstallReferenceCameraHook() {
    PublishHookInstallationReadinessProof();

    // Diagnostic readiness gate only: resolved addresses are never invoked,
    // patched, replaced, retained, or passed to a hook provider.
    return false;
}

}  // namespace vcam::product
