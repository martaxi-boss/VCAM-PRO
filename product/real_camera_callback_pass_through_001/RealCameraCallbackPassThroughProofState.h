#pragma once

#include <stdint.h>

#define VCAM_REAL_CAMERA_CALLBACK_PASSTHROUGH_VERSION \
    "0.1.0+roothide9~callbackpass1"
#define VCAM_REAL_CAMERA_CALLBACK_PASSTHROUGH_NOTIFICATION \
    "com.vcampro.gate.real-camera-callback-pass-through.001"
#define VCAM_REAL_CAMERA_CALLBACK_PASSTHROUGH_FRESHNESS_SECONDS 180U
#define VCAM_REAL_CAMERA_CALLBACK_PASSTHROUGH_FUTURE_SKEW_SECONDS 5U

#define VCAM_REAL_CAMERA_CALLBACK_FLAG_EXERCISED UINT32_C(0x01)
#define VCAM_REAL_CAMERA_CALLBACK_FLAG_VCAM_DISABLED UINT32_C(0x02)
#define VCAM_REAL_CAMERA_CALLBACK_FLAG_NO_MEDIA UINT32_C(0x04)
#define VCAM_REAL_CAMERA_CALLBACK_FLAG_DECISION_ORIGINAL UINT32_C(0x08)
#define VCAM_REAL_CAMERA_CALLBACK_FLAG_ORIGINAL_RETURNED UINT32_C(0x10)
#define VCAM_REAL_CAMERA_CALLBACK_FLAG_SUBSTITUTION_INACTIVE UINT32_C(0x20)
#define VCAM_REAL_CAMERA_CALLBACK_FLAG_VIRTUAL_COUNT_ZERO UINT32_C(0x40)
#define VCAM_REAL_CAMERA_CALLBACK_FLAG_DISABLED_REASON UINT32_C(0x80)

#define VCAM_REAL_CAMERA_CALLBACK_REQUIRED_FLAGS \
    (VCAM_REAL_CAMERA_CALLBACK_FLAG_EXERCISED | \
     VCAM_REAL_CAMERA_CALLBACK_FLAG_VCAM_DISABLED | \
     VCAM_REAL_CAMERA_CALLBACK_FLAG_NO_MEDIA | \
     VCAM_REAL_CAMERA_CALLBACK_FLAG_DECISION_ORIGINAL | \
     VCAM_REAL_CAMERA_CALLBACK_FLAG_ORIGINAL_RETURNED | \
     VCAM_REAL_CAMERA_CALLBACK_FLAG_SUBSTITUTION_INACTIVE | \
     VCAM_REAL_CAMERA_CALLBACK_FLAG_VIRTUAL_COUNT_ZERO | \
     VCAM_REAL_CAMERA_CALLBACK_FLAG_DISABLED_REASON)

static inline uint64_t
vcam_real_camera_callback_passthrough_encode_state(
    uint32_t timestamp,
    uint32_t pid)
{
    return
        ((uint64_t)timestamp << 32) |
        ((uint64_t)(pid & UINT32_C(0x00ffffff)) << 8) |
        (uint64_t)VCAM_REAL_CAMERA_CALLBACK_REQUIRED_FLAGS;
}

static inline uint32_t
vcam_real_camera_callback_passthrough_state_timestamp(
    uint64_t state)
{
    return (uint32_t)(state >> 32);
}

static inline uint32_t
vcam_real_camera_callback_passthrough_state_pid(
    uint64_t state)
{
    return
        (uint32_t)((state >> 8) &
                   UINT64_C(0x00ffffff));
}

static inline uint32_t
vcam_real_camera_callback_passthrough_state_flags(
    uint64_t state)
{
    return (uint32_t)(state & UINT64_C(0xff));
}

static inline int
vcam_real_camera_callback_passthrough_state_is_valid_fresh(
    uint64_t state,
    uint32_t now)
{
    const uint32_t timestamp =
        vcam_real_camera_callback_passthrough_state_timestamp(state);
    const uint32_t pid =
        vcam_real_camera_callback_passthrough_state_pid(state);
    const uint32_t flags =
        vcam_real_camera_callback_passthrough_state_flags(state);

    if (timestamp == 0U ||
        pid == 0U ||
        flags != VCAM_REAL_CAMERA_CALLBACK_REQUIRED_FLAGS) {
        return 0;
    }

    if (timestamp > now) {
        return
            (timestamp - now) <=
            VCAM_REAL_CAMERA_CALLBACK_PASSTHROUGH_FUTURE_SKEW_SECONDS;
    }

    return
        (now - timestamp) <=
        VCAM_REAL_CAMERA_CALLBACK_PASSTHROUGH_FRESHNESS_SECONDS;
}
