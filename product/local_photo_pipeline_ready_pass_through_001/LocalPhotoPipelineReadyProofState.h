#pragma once

#include <stdint.h>

#define VCAM_LOCAL_PHOTO_PIPELINE_READY_VERSION \
    "0.1.0+roothide10~photoready1"
#define VCAM_LOCAL_PHOTO_PIPELINE_READY_NOTIFICATION \
    "com.vcampro.gate.local-photo-pipeline-ready.001"
#define VCAM_LOCAL_PHOTO_PIPELINE_READY_FRESHNESS_SECONDS 180U
#define VCAM_LOCAL_PHOTO_PIPELINE_READY_FUTURE_SKEW_SECONDS 5U

#define VCAM_LOCAL_PHOTO_FLAG_CALLBACK_EXERCISED UINT32_C(0x001)
#define VCAM_LOCAL_PHOTO_FLAG_VCAM_DISABLED UINT32_C(0x002)
#define VCAM_LOCAL_PHOTO_FLAG_MEDIA_PHOTO UINT32_C(0x004)
#define VCAM_LOCAL_PHOTO_FLAG_MEDIA_STAGED UINT32_C(0x008)
#define VCAM_LOCAL_PHOTO_FLAG_CONTROL_OBSERVED UINT32_C(0x010)
#define VCAM_LOCAL_PHOTO_FLAG_GEOMETRY_OBSERVED UINT32_C(0x020)
#define VCAM_LOCAL_PHOTO_FLAG_PRODUCER_PLAYING UINT32_C(0x040)
#define VCAM_LOCAL_PHOTO_FLAG_READY_QUEUE_NONEMPTY UINT32_C(0x080)
#define VCAM_LOCAL_PHOTO_FLAG_DECISION_ORIGINAL UINT32_C(0x100)
#define VCAM_LOCAL_PHOTO_FLAG_ORIGINAL_RETURNED UINT32_C(0x200)
#define VCAM_LOCAL_PHOTO_FLAG_SUBSTITUTION_INACTIVE UINT32_C(0x400)
#define VCAM_LOCAL_PHOTO_FLAG_VIRTUAL_COUNT_ZERO UINT32_C(0x800)

#define VCAM_LOCAL_PHOTO_REQUIRED_FLAGS \
    (VCAM_LOCAL_PHOTO_FLAG_CALLBACK_EXERCISED | \
     VCAM_LOCAL_PHOTO_FLAG_VCAM_DISABLED | \
     VCAM_LOCAL_PHOTO_FLAG_MEDIA_PHOTO | \
     VCAM_LOCAL_PHOTO_FLAG_MEDIA_STAGED | \
     VCAM_LOCAL_PHOTO_FLAG_CONTROL_OBSERVED | \
     VCAM_LOCAL_PHOTO_FLAG_GEOMETRY_OBSERVED | \
     VCAM_LOCAL_PHOTO_FLAG_PRODUCER_PLAYING | \
     VCAM_LOCAL_PHOTO_FLAG_READY_QUEUE_NONEMPTY | \
     VCAM_LOCAL_PHOTO_FLAG_DECISION_ORIGINAL | \
     VCAM_LOCAL_PHOTO_FLAG_ORIGINAL_RETURNED | \
     VCAM_LOCAL_PHOTO_FLAG_SUBSTITUTION_INACTIVE | \
     VCAM_LOCAL_PHOTO_FLAG_VIRTUAL_COUNT_ZERO)

static inline uint64_t
vcam_local_photo_pipeline_ready_encode_state(
    uint32_t timestamp,
    uint32_t pid)
{
    return
        ((uint64_t)timestamp << 32) |
        ((uint64_t)(pid & UINT32_C(0x000fffff)) << 12) |
        (uint64_t)VCAM_LOCAL_PHOTO_REQUIRED_FLAGS;
}

static inline uint32_t
vcam_local_photo_pipeline_ready_state_timestamp(
    uint64_t state)
{
    return (uint32_t)(state >> 32);
}

static inline uint32_t
vcam_local_photo_pipeline_ready_state_pid(
    uint64_t state)
{
    return
        (uint32_t)((state >> 12) &
                   UINT64_C(0x000fffff));
}

static inline uint32_t
vcam_local_photo_pipeline_ready_state_flags(
    uint64_t state)
{
    return (uint32_t)(state & UINT64_C(0x0fff));
}

static inline int
vcam_local_photo_pipeline_ready_generations_match(
    uint64_t callbackGeneration,
    uint64_t readyGeneration)
{
    return
        callbackGeneration != UINT64_C(0) &&
        callbackGeneration == readyGeneration;
}

static inline int
vcam_local_photo_pipeline_ready_state_is_valid_fresh(
    uint64_t state,
    uint32_t now)
{
    const uint32_t timestamp =
        vcam_local_photo_pipeline_ready_state_timestamp(state);
    const uint32_t pid =
        vcam_local_photo_pipeline_ready_state_pid(state);
    const uint32_t flags =
        vcam_local_photo_pipeline_ready_state_flags(state);

    if (timestamp == 0U ||
        pid == 0U ||
        flags != VCAM_LOCAL_PHOTO_REQUIRED_FLAGS) {
        return 0;
    }

    if (timestamp > now) {
        return
            (timestamp - now) <=
            VCAM_LOCAL_PHOTO_PIPELINE_READY_FUTURE_SKEW_SECONDS;
    }

    return
        (now - timestamp) <=
        VCAM_LOCAL_PHOTO_PIPELINE_READY_FRESHNESS_SECONDS;
}
