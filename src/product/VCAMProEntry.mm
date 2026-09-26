#include "MediaserverdRuntime.h"
#include "ReferenceCameraHook.h"
#include "SpringBoardControlHost.h"

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
        auto& runtime =
            vcam::product::
                MediaserverdRuntime::shared();

        if (runtime.start()) {
            (void)vcam::product::
                InstallReferenceCameraHook();
        }
        return;
    }

    if (ProcessIs("SpringBoard")) {
        vcam::product::
            StartSpringBoardControlHost();
        return;
    }
}
