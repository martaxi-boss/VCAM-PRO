#pragma once

#include <stdint.h>

#define VCAM_PRO_LOAD_PROBE_VERSION "0.0.2~roothide2"
#define VCAM_PRO_LOAD_PROBE_NOTIFICATION \
    "com.vcampro.probe.mediaserverd-load.002.roothide2"
#define VCAM_PRO_LOAD_PROBE_FRESHNESS_SECONDS 180U
#define VCAM_PRO_LOAD_PROBE_FUTURE_SKEW_SECONDS 5U

static inline uint64_t
vcam_pro_encode_load_state(
    uint32_t timestamp,
    uint32_t pid)
{
    return
        ((uint64_t)timestamp << 32) |
        (uint64_t)pid;
}

static inline uint32_t
vcam_pro_load_state_timestamp(
    uint64_t state)
{
    return (uint32_t)(state >> 32);
}

static inline uint32_t
vcam_pro_load_state_pid(
    uint64_t state)
{
    return (uint32_t)(state & UINT32_C(0xffffffff));
}

static inline int
vcam_pro_load_state_is_fresh(
    uint64_t state,
    uint32_t now)
{
    const uint32_t timestamp =
        vcam_pro_load_state_timestamp(state);
    const uint32_t pid =
        vcam_pro_load_state_pid(state);

    if (timestamp == 0U ||
        pid == 0U) {
        return 0;
    }

    if (timestamp > now) {
        return
            (timestamp - now) <=
            VCAM_PRO_LOAD_PROBE_FUTURE_SKEW_SECONDS;
    }

    return
        (now - timestamp) <=
        VCAM_PRO_LOAD_PROBE_FRESHNESS_SECONDS;
}
