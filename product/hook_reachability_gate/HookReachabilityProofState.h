#pragma once

#include <stdint.h>

#define VCAM_HOOK_REACH_GATE_VERSION "0.1.0+roothide5~hookreach1"
#define VCAM_HOOK_REACH_GATE_NOTIFICATION \
    "com.vcampro.gate.reference-hook-reachability.001"
#define VCAM_HOOK_REACH_GATE_FRESHNESS_SECONDS 180U
#define VCAM_HOOK_REACH_GATE_FUTURE_SKEW_SECONDS 5U

#define VCAM_HOOK_REACH_FLAG_RUNTIME_START_PASS UINT32_C(0x01)
#define VCAM_HOOK_REACH_FLAG_CALL_PATH_REACHED UINT32_C(0x02)
#define VCAM_HOOK_REACH_FLAG_TARGET_RESOLVED UINT32_C(0x04)
#define VCAM_HOOK_REACH_FLAG_HOOK_DISABLED UINT32_C(0x08)
#define VCAM_HOOK_REACH_FLAG_FRAME_ACCESS_INACTIVE UINT32_C(0x10)
#define VCAM_HOOK_REACH_FLAG_FRAME_SUBSTITUTION_INACTIVE UINT32_C(0x20)

#define VCAM_HOOK_REACH_REQUIRED_FLAGS \
    (VCAM_HOOK_REACH_FLAG_RUNTIME_START_PASS | \
     VCAM_HOOK_REACH_FLAG_CALL_PATH_REACHED | \
     VCAM_HOOK_REACH_FLAG_TARGET_RESOLVED | \
     VCAM_HOOK_REACH_FLAG_HOOK_DISABLED | \
     VCAM_HOOK_REACH_FLAG_FRAME_ACCESS_INACTIVE | \
     VCAM_HOOK_REACH_FLAG_FRAME_SUBSTITUTION_INACTIVE)

static inline uint64_t
vcam_hook_reach_encode_state(
    uint32_t timestamp,
    uint32_t pid)
{
    return
        ((uint64_t)timestamp << 32) |
        ((uint64_t)(pid & UINT32_C(0x03ffffff)) << 6) |
        (uint64_t)VCAM_HOOK_REACH_REQUIRED_FLAGS;
}

static inline uint32_t
vcam_hook_reach_state_timestamp(
    uint64_t state)
{
    return (uint32_t)(state >> 32);
}

static inline uint32_t
vcam_hook_reach_state_pid(
    uint64_t state)
{
    return
        (uint32_t)((state >> 6) &
                   UINT64_C(0x03ffffff));
}

static inline uint32_t
vcam_hook_reach_state_flags(
    uint64_t state)
{
    return (uint32_t)(state & UINT64_C(0x3f));
}

static inline int
vcam_hook_reach_state_is_valid_fresh(
    uint64_t state,
    uint32_t now)
{
    const uint32_t timestamp =
        vcam_hook_reach_state_timestamp(state);
    const uint32_t pid =
        vcam_hook_reach_state_pid(state);
    const uint32_t flags =
        vcam_hook_reach_state_flags(state);

    if (timestamp == 0U ||
        pid == 0U ||
        flags != VCAM_HOOK_REACH_REQUIRED_FLAGS) {
        return 0;
    }

    if (timestamp > now) {
        return
            (timestamp - now) <=
            VCAM_HOOK_REACH_GATE_FUTURE_SKEW_SECONDS;
    }

    return
        (now - timestamp) <=
        VCAM_HOOK_REACH_GATE_FRESHNESS_SECONDS;
}
