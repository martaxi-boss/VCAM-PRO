#include "MediaserverdRuntime.h"
#include "ReferenceCameraHook.h"
#include "SpringBoardControlHost.h"

#if defined(VCAM_FULL_PRODUCT_REAL_HOOK_PROOF)
#include "FullProductRealHookProof.h"
#endif

#include <cstring>
#include <unistd.h>

namespace {

bool ProcessIs(
    const char* expected) noexcept {
    const char* process =
        getprogname();

    return process != nullptr &&
           expected != nullptr &&
           std::strcmp(
               process,
               expected) == 0;
}

}  // namespace

__attribute__((constructor))
static void VCAMProInitialize() {
    if (ProcessIs("mediaserverd")) {
#if defined(VCAM_FULL_PRODUCT_REAL_HOOK_PROOF)
        vcam::product::proof::
            ResetFullProductRealHookProofState();
#endif

        auto& runtime =
            vcam::product::
                MediaserverdRuntime::shared();

        if (runtime.start()) {
            const bool hookInstalled =
                vcam::product::
                    InstallReferenceCameraHook();

#if defined(VCAM_FULL_PRODUCT_REAL_HOOK_PROOF)
            if (hookInstalled) {
                (void)vcam::product::proof::
                    PublishFullProductRealHookInstallProof();
            }
#else
            (void)hookInstalled;
#endif
        }
        return;
    }

    if (ProcessIs("SpringBoard")) {
        vcam::product::
            StartSpringBoardControlHost();
        return;
    }
}
