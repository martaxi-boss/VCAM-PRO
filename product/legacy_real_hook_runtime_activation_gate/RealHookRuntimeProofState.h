#pragma once

#include <stdint.h>

#define VCAM_REAL_HOOK_RUNTIME_GATE_VERSION "0.1.0+roothide7~realhookruntime2"
#define VCAM_REAL_HOOK_RUNTIME_GATE_NOTIFICATION \
    "com.vcampro.gate.real-hook-runtime-install.002"
#define VCAM_REAL_HOOK_RUNTIME_GATE_FRESHNESS_SECONDS 180U
#define VCAM_REAL_HOOK_RUNTIME_GATE_FUTURE_SKEW_SECONDS 5U

#define VCAM_REAL_HOOK_RUNTIME_FLAG_RUNTIME_START_PASS UINT32_C(0x01)
#define VCAM_REAL_HOOK_RUNTIME_FLAG_REAL_HOOK_INSTALL_PASS UINT32_C(0x02)
#define VCAM_REAL_HOOK_RUNTIME_FLAG_ORIGINAL_TRAMPOLINE_NON_NULL UINT32_C(0x04)
#define VCAM_REAL_HOOK_RUNTIME_FLAG_CALLBACK_NOT_EXERCISED UINT32_C(0x08)
#define VCAM_REAL_HOOK_RUNTIME_FLAG_FRAME_SUBSTITUTION_INACTIVE UINT32_C(0x10)

#define VCAM_REAL_HOOK_RUNTIME_REQUIRED_FLAGS \
    (VCAM_REAL_HOOK_RUNTIME_FLAG_RUNTIME_START_PASS | \
     VCAM_REAL_HOOK_RUNTIME_FLAG_REAL_HOOK_INSTALL_PASS | \
     VCAM_REAL_HOOK_RUNTIME_FLAG_ORIGINAL_TRAMPOLINE_NON_NULL | \
     VCAM_REAL_HOOK_RUNTIME_FLAG_CALLBACK_NOT_EXERCISED | \
     VCAM_REAL_HOOK_RUNTIME_FLAG_FRAME_SUBSTITUTION_INACTIVE)

static inline uint64_t
vcam_real_hook_runtime_encode_state(
    uint32_t timestamp,
    uint32_t pid)
{
    return
        ((uint64_t)timestamp << 32) |
        ((uint64_t)(pid & UINT32_C(0x07ffffff)) << 5) |
        (uint64_t)VCAM_REAL_HOOK_RUNTIME_REQUIRED_FLAGS;
}

static inline uint32_t
vcam_real_hook_runtime_state_timestamp(
    uint64_t state)
{
    return (uint32_t)(state >> 32);
}

static inline uint32_t
vcam_real_hook_runtime_state_pid(
    uint64_t state)
{
    return
        (uint32_t)((state >> 5) &
                   UINT64_C(0x07ffffff));
}

static inline uint32_t
vcam_real_hook_runtime_state_flags(
    uint64_t state)
{
    return (uint32_t)(state & UINT64_C(0x1f));
}

static inline int
vcam_real_hook_runtime_state_is_valid_fresh(
    uint64_t state,
    uint32_t now)
{
    const uint32_t timestamp =
        vcam_real_hook_runtime_state_timestamp(state);
    const uint32_t pid =
        vcam_real_hook_runtime_state_pid(state);
    const uint32_t flags =
        vcam_real_hook_runtime_state_flags(state);

    if (timestamp == 0U ||
        pid == 0U ||
        flags != VCAM_REAL_HOOK_RUNTIME_REQUIRED_FLAGS) {
        return 0;
    }

    if (timestamp > now) {
        return
            (timestamp - now) <=
            VCAM_REAL_HOOK_RUNTIME_GATE_FUTURE_SKEW_SECONDS;
    }

    return
        (now - timestamp) <=
        VCAM_REAL_HOOK_RUNTIME_GATE_FRESHNESS_SECONDS;
}
