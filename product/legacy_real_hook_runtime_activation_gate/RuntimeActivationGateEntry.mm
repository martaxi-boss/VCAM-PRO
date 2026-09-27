#include "MediaserverdRuntime.h"
#include "ReferenceCameraHook.h"

#include <cstring>
#include <os/log.h>
#include <unistd.h>

namespace {

bool ProcessIs(const char* expected) noexcept {
    const char* process = getprogname();
    return process != nullptr &&
           expected != nullptr &&
           std::strcmp(process, expected) == 0;
}

void EmitResult(const char* marker) noexcept {
    os_log_with_type(
        OS_LOG_DEFAULT,
        OS_LOG_TYPE_DEFAULT,
        "%{public}s",
        marker);
}

}  // namespace

__attribute__((constructor))
static void VCAMProLegacyRealHookRuntimeActivationGateInitialize() {
    if (!ProcessIs("mediaserverd")) {
        return;
    }

    auto& runtime =
        vcam::product::MediaserverdRuntime::shared();

    const bool runtimeStarted = runtime.start();
    EmitResult(
        runtimeStarted
            ? "VCAM_PRO_REAL_HOOK_GATE RUNTIME_START=PASS"
            : "VCAM_PRO_REAL_HOOK_GATE RUNTIME_START=FAIL");

    if (!runtimeStarted) {
        return;
    }

    const bool installed =
        vcam::product::InstallReferenceCameraHook();

    if (installed) {
        EmitResult(
            "VCAM_PRO_REAL_HOOK_GATE REAL_REFERENCE_HOOK_INSTALL=PASS");
        EmitResult(
            "VCAM_PRO_REAL_HOOK_GATE ORIGINAL_TRAMPOLINE_NON_NULL=PASS");
        return;
    }

    EmitResult(
        "VCAM_PRO_REAL_HOOK_GATE REAL_REFERENCE_HOOK_INSTALL=FAIL");
    EmitResult(
        "VCAM_PRO_REAL_HOOK_GATE ORIGINAL_TRAMPOLINE_NON_NULL=FAIL");
}
