#include <errno.h>
#include <fcntl.h>
#include <os/log.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

#define VCAM_PRO_LOAD_PROBE_MARKER "VCAM_PRO_LOAD_PROBE_001"
#define VCAM_PRO_LOAD_PROBE_VERSION "0.0.2~roothide1"
#define VCAM_PRO_LOAD_PROBE_DIRECTORY \
    "/var/mobile/Library/VCAMProMediaserverdProbe"
#define VCAM_PRO_LOAD_PROBE_PATH \
    "/var/mobile/Library/VCAMProMediaserverdProbe/load-proof.txt"

static void
vcam_pro_write_persistent_proof(
    const char *process_name,
    pid_t pid)
{
    char timestamp[32] = {0};
    const time_t now = time(NULL);
    struct tm utc_time;

    if (now == (time_t)-1 ||
        gmtime_r(&now, &utc_time) == NULL ||
        strftime(
            timestamp,
            sizeof(timestamp),
            "%Y-%m-%dT%H:%M:%SZ",
            &utc_time) == 0) {
        (void)snprintf(
            timestamp,
            sizeof(timestamp),
            "%s",
            "1970-01-01T00:00:00Z");
    }

    if (mkdir(
            VCAM_PRO_LOAD_PROBE_DIRECTORY,
            0755) != 0 &&
        errno != EEXIST) {
        return;
    }

    const int fd = open(
        VCAM_PRO_LOAD_PROBE_PATH,
        O_WRONLY |
            O_CREAT |
            O_TRUNC |
            O_CLOEXEC,
        0644);

    if (fd < 0) {
        return;
    }

    (void)dprintf(
        fd,
        "VCAM PRO MEDIASERVERD LOAD PROBE\n"
        "version=%s\n"
        "timestamp=%s\n"
        "process=%s\n"
        "pid=%d\n"
        "constructor=PASS\n",
        VCAM_PRO_LOAD_PROBE_VERSION,
        timestamp,
        process_name,
        (int)pid);

    (void)fsync(fd);
    (void)close(fd);
}

__attribute__((constructor))
static void
vcam_pro_load_probe_init(void)
{
    const char *process_name = getprogname();

    if (process_name == NULL ||
        strcmp(
            process_name,
            "mediaserverd") != 0) {
        return;
    }

    const pid_t pid = getpid();

    vcam_pro_write_persistent_proof(
        process_name,
        pid);

    os_log_with_type(
        OS_LOG_DEFAULT,
        OS_LOG_TYPE_DEFAULT,
        VCAM_PRO_LOAD_PROBE_MARKER
        " version=%{public}s"
        " process=%{public}s"
        " pid=%{public}d",
        VCAM_PRO_LOAD_PROBE_VERSION,
        process_name,
        pid);
}
