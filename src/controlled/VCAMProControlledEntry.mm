#include "ControlledPreviewHost.h"
#include "SpringBoardControlHost.h"

#include <cstring>
#include <stdlib.h>
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
static void VCAMProControlledInitialize() {
    if (!ProcessIs("SpringBoard")) {
        return;
    }

    vcam::product::
        StartSpringBoardControlHost();

    vcam::controlled::
        StartControlledPreviewHost();
}
