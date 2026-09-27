#include "DarwinProofState.h"

#include <notify.h>
#include <os/log.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

#define VCAM_PRO_LOAD_PROBE_MARKER "VCAM_PRO_LOAD_PROBE_001"

__attribute__((constructor))
static void
vcam_pro_load_probe_init(void)
{
    const char *process_name =
        getprogname();

    if (process_name == NULL ||
        strcmp(
            process_name,
            "mediaserverd") != 0) {
        return;
    }

    const pid_t pid_value =
        getpid();
    const time_t now_value =
        time(NULL);

    if (pid_value <= 0 ||
        (uint64_t)pid_value >
            UINT32_MAX ||
        now_value < 0 ||
        (uint64_t)now_value >
            UINT32_MAX) {
        return;
    }

    const uint64_t state =
        vcam_pro_encode_load_state(
            (uint32_t)now_value,
            (uint32_t)pid_value);

    int token = 0;

    if (notify_register_check(
            VCAM_PRO_LOAD_PROBE_NOTIFICATION,
            &token) !=
        NOTIFY_STATUS_OK) {
        return;
    }

    const uint32_t set_status =
        notify_set_state(
            token,
            state);

    uint32_t post_status =
        NOTIFY_STATUS_FAILED;

    if (set_status ==
        NOTIFY_STATUS_OK) {
        post_status =
            notify_post(
                VCAM_PRO_LOAD_PROBE_NOTIFICATION);
    }

    (void)notify_cancel(token);

    if (set_status !=
            NOTIFY_STATUS_OK ||
        post_status !=
            NOTIFY_STATUS_OK) {
        return;
    }

    os_log_with_type(
        OS_LOG_DEFAULT,
        OS_LOG_TYPE_DEFAULT,
        VCAM_PRO_LOAD_PROBE_MARKER
        " version=%{public}s"
        " notification=%{public}s"
        " process=%{public}s"
        " pid=%{public}d"
        " constructor=PASS",
        VCAM_PRO_LOAD_PROBE_VERSION,
        VCAM_PRO_LOAD_PROBE_NOTIFICATION,
        process_name,
        pid_value);
}
