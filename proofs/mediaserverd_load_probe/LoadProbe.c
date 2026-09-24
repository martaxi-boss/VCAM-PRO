#include <os/log.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#define VCAM_PRO_LOAD_PROBE_MARKER "VCAM_PRO_LOAD_PROBE_001"

__attribute__((constructor))
static void vcam_pro_load_probe_init(void)
{
    const char *process_name = getprogname();

    if (process_name == NULL || strcmp(process_name, "mediaserverd") != 0) {
        return;
    }

    os_log_with_type(
        OS_LOG_DEFAULT,
        OS_LOG_TYPE_DEFAULT,
        VCAM_PRO_LOAD_PROBE_MARKER " process=%{public}s pid=%{public}d",
        process_name,
        getpid()
    );
}
