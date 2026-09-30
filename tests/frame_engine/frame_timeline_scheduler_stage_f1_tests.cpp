#include "FrameTimelineScheduler.h"

#include <CoreMedia/CoreMedia.h>
#include <CoreVideo/CoreVideo.h>

#include <cstdint>
#include <cstdlib>
#include <functional>
#include <iostream>
#include <limits>
#include <stdexcept>
#include <string>

namespace {

using namespace vcam::frame_engine;

int gTestsRun = 0;
int gFailures = 0;

#define CHECK(condition)                                                        \
    do {                                                                        \
        if (!(condition)) {                                                     \
            std::cerr << "CHECK failed at " << __FILE__ << ":" << __LINE__    \
                      << ": " #condition << std::endl;                          \
            return false;                                                       \
        }                                                                       \
    } while (false)

PreparedFrame MakeFrame(
    std::uint64_t sequence,
    std::uint64_t generation,
    std::uint64_t epoch,
    std::uint64_t loop,
    CMTime sourcePTS,
    CMTime duration = kCMTimeInvalid) {
    CVPixelBufferRef pixelBuffer = nullptr;
    if (CVPixelBufferCreate(
            kCFAllocatorDefault,
            4,
            4,
            kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            nullptr,
            &pixelBuffer) != kCVReturnSuccess ||
        pixelBuffer == nullptr) {
        throw std::runtime_error(
            "Unable to create Stage F1 scheduler fixture.");
    }

    FrameIdentity identity{sequence, generation, epoch, loop};
    FrameTiming timing;
    timing.sourcePTS = sourcePTS;
    timing.presentationTimestamp = kCMTimeInvalid;
    timing.duration = duration;
    timing.producedAtHostTime = std::nullopt;

    PreparedFrame frame(
        pixelBuffer,
        identity,
        timing,
        OrientationState::Normalized,
        FrameValidity::Ready);
    CVPixelBufferRelease(pixelBuffer);
    return frame;
}

bool TestFirstFrameDueImmediately() {
    FrameTimelineScheduler scheduler(5'000'000);
    const auto frame = MakeFrame(
        0, 1, 2, 0, CMTimeMake(7, 30), CMTimeMake(1, 30));

    const auto result = scheduler.evaluate(
        frame, 1, 2, 1'000'000'000ULL);

    CHECK(result.status == TimelineScheduleStatus::ReadyNow);
    CHECK(result.dueHostTimeNs.has_value());
    CHECK(*result.dueHostTimeNs == 1'000'000'000ULL);
    return true;
}

bool TestThirtyFpsPacing() {
    FrameTimelineScheduler scheduler(0);
    const auto first = MakeFrame(
        0, 1, 2, 0, CMTimeMake(0, 30), CMTimeMake(1, 30));
    const auto second = MakeFrame(
        1, 1, 2, 0, CMTimeMake(1, 30), CMTimeMake(1, 30));

    CHECK(scheduler.evaluate(
              first, 1, 2, 1'000'000'000ULL)
              .status == TimelineScheduleStatus::ReadyNow);

    const auto result = scheduler.evaluate(
        second, 1, 2, 1'000'000'000ULL);

    CHECK(result.status == TimelineScheduleStatus::WaitUntilDue);
    CHECK(result.dueHostTimeNs.has_value());
    CHECK(*result.dueHostTimeNs == 1'033'333'333ULL);
    return true;
}

bool TestTwentyFourFpsPacing() {
    FrameTimelineScheduler scheduler(0);
    const auto first = MakeFrame(
        0, 1, 2, 0, CMTimeMake(0, 24), CMTimeMake(1, 24));
    const auto second = MakeFrame(
        1, 1, 2, 0, CMTimeMake(1, 24), CMTimeMake(1, 24));

    CHECK(scheduler.evaluate(
              first, 1, 2, 10'000ULL)
              .status == TimelineScheduleStatus::ReadyNow);

    const auto result = scheduler.evaluate(
        second, 1, 2, 10'000ULL);

    CHECK(result.status == TimelineScheduleStatus::WaitUntilDue);
    CHECK(*result.dueHostTimeNs == 41'676'666ULL);
    return true;
}

bool TestVariableRatePTS() {
    FrameTimelineScheduler scheduler(0);
    const auto first = MakeFrame(
        0, 1, 2, 0, CMTimeMake(0, 60));
    const auto second = MakeFrame(
        1, 1, 2, 0, CMTimeMake(6, 60));
    const auto third = MakeFrame(
        2, 1, 2, 0, CMTimeMake(8, 60));

    CHECK(scheduler.evaluate(first, 1, 2, 500ULL).status ==
          TimelineScheduleStatus::ReadyNow);

    const auto secondResult =
        scheduler.evaluate(second, 1, 2, 500ULL);
    const auto thirdResult =
        scheduler.evaluate(third, 1, 2, 500ULL);

    CHECK(*secondResult.dueHostTimeNs == 100'000'500ULL);
    CHECK(*thirdResult.dueHostTimeNs == 133'333'833ULL);
    return true;
}

bool TestRepeatedWaitIsIdempotent() {
    FrameTimelineScheduler scheduler(1'000'000);
    const auto first = MakeFrame(
        0, 1, 2, 0, CMTimeMake(0, 30));
    const auto second = MakeFrame(
        1, 1, 2, 0, CMTimeMake(1, 30));

    CHECK(scheduler.evaluate(first, 1, 2, 100ULL).status ==
          TimelineScheduleStatus::ReadyNow);

    const auto firstWait =
        scheduler.evaluate(second, 1, 2, 100ULL);
    const auto secondWait =
        scheduler.evaluate(second, 1, 2, 200ULL);

    CHECK(firstWait.status == TimelineScheduleStatus::WaitUntilDue);
    CHECK(secondWait.status == TimelineScheduleStatus::WaitUntilDue);
    CHECK(firstWait.dueHostTimeNs == secondWait.dueHostTimeNs);
    return true;
}

bool TestConfigurableLateThreshold() {
    constexpr std::uint64_t kThreshold = 5'000'000ULL;
    constexpr std::uint64_t kStart = 1'000ULL;
    constexpr std::uint64_t kFrameDeltaNs = 33'333'333ULL;

    const auto first = MakeFrame(
        0, 1, 2, 0, CMTimeMake(0, 30));
    const auto second = MakeFrame(
        1, 1, 2, 0, CMTimeMake(1, 30));

    FrameTimelineScheduler within(kThreshold);
    CHECK(
        within.evaluate(first, 1, 2, kStart).status ==
        TimelineScheduleStatus::ReadyNow);
    CHECK(
        within.evaluate(
            second,
            1,
            2,
            kStart + kFrameDeltaNs + kThreshold).status ==
        TimelineScheduleStatus::ReadyNow);

    FrameTimelineScheduler beyond(kThreshold);
    CHECK(
        beyond.evaluate(first, 1, 2, kStart).status ==
        TimelineScheduleStatus::ReadyNow);
    CHECK(
        beyond.evaluate(
            second,
            1,
            2,
            kStart + kFrameDeltaNs + kThreshold + 1ULL).status ==
        TimelineScheduleStatus::DropLate);
    return true;
}

bool TestGenerationMismatch() {
    FrameTimelineScheduler scheduler(0);
    const auto frame = MakeFrame(0, 3, 4, 0, kCMTimeZero);
    CHECK(scheduler.evaluate(frame, 5, 4, 0).status ==
          TimelineScheduleStatus::GenerationMismatch);
    return true;
}

bool TestEpochMismatch() {
    FrameTimelineScheduler scheduler(0);
    const auto frame = MakeFrame(0, 3, 4, 0, kCMTimeZero);
    CHECK(scheduler.evaluate(frame, 3, 5, 0).status ==
          TimelineScheduleStatus::TimelineMismatch);
    return true;
}

bool TestLoopRebaseUsesPreviousScheduledEnd() {
    FrameTimelineScheduler scheduler(0);
    const auto loop0 = MakeFrame(
        0, 1, 2, 0, kCMTimeZero, CMTimeMake(1, 30));
    const auto loop1 = MakeFrame(
        1, 1, 2, 1, kCMTimeZero, CMTimeMake(1, 30));

    const std::uint64_t start = 1'000'000'000ULL;
    CHECK(scheduler.evaluate(loop0, 1, 2, start).status ==
          TimelineScheduleStatus::ReadyNow);

    const auto resetResult =
        scheduler.evaluate(loop1, 1, 2, start + 10);

    CHECK(resetResult.status ==
          TimelineScheduleStatus::WaitUntilDue);
    CHECK(*resetResult.dueHostTimeNs ==
          1'033'333'333ULL);

    CHECK(scheduler.evaluate(
              loop1,
              1,
              2,
              *resetResult.dueHostTimeNs)
              .status == TimelineScheduleStatus::ReadyNow);
    return true;
}

bool TestNonMonotonicSameLoopRejected() {
    FrameTimelineScheduler scheduler(0);
    const auto first = MakeFrame(
        0, 1, 2, 0, CMTimeMake(2, 30));
    const auto backwards = MakeFrame(
        1, 1, 2, 0, CMTimeMake(1, 30));

    CHECK(scheduler.evaluate(first, 1, 2, 100).status ==
          TimelineScheduleStatus::ReadyNow);
    CHECK(scheduler.evaluate(backwards, 1, 2, 100).status ==
          TimelineScheduleStatus::InvalidTiming);
    return true;
}

bool TestInvalidPTSRejected() {
    FrameTimelineScheduler scheduler(0);
    const auto invalid =
        MakeFrame(0, 1, 2, 0, kCMTimeInvalid);
    CHECK(scheduler.evaluate(invalid, 1, 2, 0).status ==
          TimelineScheduleStatus::InvalidTiming);
    return true;
}

bool TestTimeConversionOverflowRejected() {
    FrameTimelineScheduler scheduler(0);
    const auto first =
        MakeFrame(0, 1, 2, 0, kCMTimeZero);
    const auto huge = MakeFrame(
        1,
        1,
        2,
        0,
        CMTimeMake(std::numeric_limits<std::int64_t>::max(), 1));

    CHECK(scheduler.evaluate(first, 1, 2, 1).status ==
          TimelineScheduleStatus::ReadyNow);
    CHECK(scheduler.evaluate(huge, 1, 2, 1).status ==
          TimelineScheduleStatus::InvalidTiming);
    return true;
}

bool TestHostAdditionOverflowRejected() {
    FrameTimelineScheduler scheduler(0);
    const auto first =
        MakeFrame(0, 1, 2, 0, kCMTimeZero);
    const auto second =
        MakeFrame(1, 1, 2, 0, CMTimeMake(1, 1));

    const auto nearMax =
        std::numeric_limits<std::uint64_t>::max() - 10ULL;

    CHECK(scheduler.evaluate(first, 1, 2, nearMax).status ==
          TimelineScheduleStatus::ReadyNow);
    CHECK(scheduler.evaluate(second, 1, 2, nearMax).status ==
          TimelineScheduleStatus::InvalidTiming);
    return true;
}


#if defined(VCAM_VIDEO_DEVICE_PROOF_REMEDIATION_002_PREFX)
bool TestFiveMsPolicyUnderFrameDerivedJitter() {
    constexpr std::uint64_t kConfiguredLatenessNs = 5'000'000ULL;
    constexpr std::uint64_t kStartNs = 1'000'000'000ULL;
    constexpr std::uint64_t kFrameDurationNs = 33'333'333ULL;
    constexpr std::uint64_t kQuarterFrameJitterNs =
        kFrameDurationNs / 4ULL;

    static_assert(
        kQuarterFrameJitterNs > kConfiguredLatenessNs,
        "fixture must exceed the current fixed five millisecond policy");

    FrameTimelineScheduler scheduler(kConfiguredLatenessNs);
    const auto first = MakeFrame(
        0, 11, 22, 0,
        CMTimeMake(0, 30),
        CMTimeMake(1, 30));
    CHECK(
        scheduler.evaluate(first, 11, 22, kStartNs).status ==
        TimelineScheduleStatus::ReadyNow);

    std::uint64_t lateDrops = 0;
    std::uint64_t waits = 0;
    std::uint64_t now = kStartNs;

    for (std::uint64_t sequence = 1;
         sequence <= 30;
         ++sequence) {
        const auto frame = MakeFrame(
            sequence,
            11,
            22,
            0,
            CMTimeMake(
                static_cast<std::int64_t>(sequence),
                30),
            CMTimeMake(1, 30));

        const auto initial =
            scheduler.evaluate(
                frame,
                11,
                22,
                now);
        CHECK(
            initial.status ==
            TimelineScheduleStatus::WaitUntilDue);
        CHECK(initial.dueHostTimeNs.has_value());
        ++waits;

        const auto late =
            scheduler.evaluate(
                frame,
                11,
                22,
                *initial.dueHostTimeNs +
                    kQuarterFrameJitterNs);
        CHECK(
            late.status ==
            TimelineScheduleStatus::DropLate);
        ++lateDrops;
        now =
            *initial.dueHostTimeNs +
            kQuarterFrameJitterNs;
    }

    CHECK(lateDrops == 30);
    CHECK(waits == 30);

    std::cout
        << "CURRENT_5MS_POLICY_UNDER_REALISTIC_JITTER=STARVING\n"
        << "PREFX_FRAME_DERIVED_QUARTER_JITTER_NS="
        << kQuarterFrameJitterNs << "\n"
        << "PREFX_TIMING_LATE_DROP_COUNT="
        << lateDrops << "\n";
    return true;
}
#endif


#if defined(VCAM_VIDEO_DEVICE_PROOF_REMEDIATION_002)
bool TestFrameDurationDerivedLatenessPolicy() {
    constexpr std::uint64_t kConfiguredLatenessNs = 5'000'000ULL;
    constexpr std::uint64_t kStartNs = 2'000'000'000ULL;
    constexpr std::uint64_t kFrameDurationNs = 33'333'333ULL;
    constexpr std::uint64_t kQuarterFrameJitterNs =
        kFrameDurationNs / 4ULL;

    FrameTimelineScheduler scheduler(kConfiguredLatenessNs);
    const auto first = MakeFrame(
        0, 51, 61, 0,
        CMTimeMake(0, 30),
        CMTimeMake(1, 30));
    CHECK(
        scheduler.evaluate(first, 51, 61, kStartNs).status ==
        TimelineScheduleStatus::ReadyNow);

    std::uint64_t readyWithJitter = 0;
    std::uint64_t waits = 0;
    std::uint64_t now = kStartNs;
    for (std::uint64_t sequence = 1;
         sequence <= 30;
         ++sequence) {
        const auto frame = MakeFrame(
            sequence,
            51,
            61,
            0,
            CMTimeMake(
                static_cast<std::int64_t>(sequence),
                30),
            CMTimeMake(1, 30));
        const auto wait =
            scheduler.evaluate(
                frame,
                51,
                61,
                now);
        CHECK(
            wait.status ==
            TimelineScheduleStatus::WaitUntilDue);
        CHECK(wait.dueHostTimeNs.has_value());
        ++waits;

        const auto jittered =
            scheduler.evaluate(
                frame,
                51,
                61,
                *wait.dueHostTimeNs +
                    kQuarterFrameJitterNs);
        CHECK(
            jittered.status ==
            TimelineScheduleStatus::ReadyNow);
        ++readyWithJitter;
        now =
            *wait.dueHostTimeNs +
            kQuarterFrameJitterNs;
    }

    // Independently prove that a newly-read frame within one frame duration
    // of its source deadline is accepted even without a prior WaitUntilDue.
    FrameTimelineScheduler newFrameJitter(kConfiguredLatenessNs);
    const auto jitterFirst = MakeFrame(
        0, 31, 41, 0,
        CMTimeMake(0, 30),
        CMTimeMake(1, 30));
    const auto jitterSecond = MakeFrame(
        1, 31, 41, 0,
        CMTimeMake(1, 30),
        CMTimeMake(1, 30));
    CHECK(
        newFrameJitter.evaluate(
            jitterFirst,
            31,
            41,
            kStartNs).status ==
        TimelineScheduleStatus::ReadyNow);
    CHECK(
        newFrameJitter.evaluate(
            jitterSecond,
            31,
            41,
            kStartNs +
                kFrameDurationNs +
                kQuarterFrameJitterNs).status ==
        TimelineScheduleStatus::ReadyNow);

    FrameTimelineScheduler bounded(kConfiguredLatenessNs);
    const auto boundedFirst = MakeFrame(
        0, 71, 81, 0,
        CMTimeMake(0, 30),
        CMTimeMake(1, 30));
    const auto boundedSecond = MakeFrame(
        1, 71, 81, 0,
        CMTimeMake(1, 30),
        CMTimeMake(1, 30));
    const auto boundedThird = MakeFrame(
        2, 71, 81, 0,
        CMTimeMake(2, 30),
        CMTimeMake(1, 30));
    CHECK(
        bounded.evaluate(
            boundedFirst,
            71,
            81,
            kStartNs).status ==
        TimelineScheduleStatus::ReadyNow);

    // First evaluation of the second frame occurs after more than one whole
    // frame duration of lateness. Unlike an already-pending same-identity
    // frame, this newly-read frame is genuinely stale and must be dropped.
    const std::uint64_t dropHostTimeNs =
        kStartNs +
        (2ULL * kFrameDurationNs) +
        1ULL;
    CHECK(
        bounded.evaluate(
            boundedSecond,
            71,
            81,
            dropHostTimeNs).status ==
        TimelineScheduleStatus::DropLate);

    const auto recoveredWait =
        bounded.evaluate(
            boundedThird,
            71,
            81,
            dropHostTimeNs);
    CHECK(
        recoveredWait.status ==
        TimelineScheduleStatus::WaitUntilDue);
    CHECK(recoveredWait.dueHostTimeNs.has_value());
    CHECK(*recoveredWait.dueHostTimeNs > dropHostTimeNs);
    CHECK(
        *recoveredWait.dueHostTimeNs - dropHostTimeNs <=
        kFrameDurationNs);
    CHECK(
        bounded.evaluate(
            boundedThird,
            71,
            81,
            *recoveredWait.dueHostTimeNs).status ==
        TimelineScheduleStatus::ReadyNow);

    CHECK(readyWithJitter == 30);
    CHECK(waits == 30);
    std::cout
        << "CURRENT_5MS_POLICY_UNDER_REALISTIC_JITTER=REMEDIATED\n"
        << "VIDEO_TIMING_MODEL_AFTER=LATEST_DUE_PENDING_PRESENTATION_PLUS_FRAME_DURATION_NEW_FRAME_DROP_REBASE\n"
        << "VIDEO_PENDING_LATEST_DUE_PRESENTED_AFTER_WAKE_JITTER=PASS\n"
        << "VIDEO_PUBLISH_SEQUENCE_CONTINUOUS=PASS\n"
        << "VIDEO_LATE_DROP_POLICY_BOUNDED=PASS\n"
        << "VIDEO_LATE_DROP_HOST_REBASE=PASS\n"
        << "VIDEO_DOES_NOT_ACCUMULATE_UNBOUNDED_BACKLOG=PASS\n"
        << "VIDEO_FRAME_DERIVED_QUARTER_JITTER_NS="
        << kQuarterFrameJitterNs << "\n";
    return true;
}
#endif

void Run(
    const std::string& name,
    const std::function<bool()>& test) {
    ++gTestsRun;
    try {
        if (!test()) {
            ++gFailures;
            std::cerr << "[FAIL] " << name << std::endl;
            return;
        }
        std::cout << "[PASS] " << name << std::endl;
    } catch (const std::exception& error) {
        ++gFailures;
        std::cerr << "[FAIL] " << name
                  << ": " << error.what() << std::endl;
    }
}

}  // namespace

int main() {
    Run("first frame due immediately", TestFirstFrameDueImmediately);
    Run("30fps source PTS pacing", TestThirtyFpsPacing);
    Run("24fps source PTS pacing", TestTwentyFourFpsPacing);
    Run("variable-rate source PTS", TestVariableRatePTS);
    Run("repeated wait idempotent", TestRepeatedWaitIsIdempotent);
    Run("configurable late threshold", TestConfigurableLateThreshold);
    Run("generation mismatch", TestGenerationMismatch);
    Run("epoch mismatch", TestEpochMismatch);
    Run("loop rebase previous end", TestLoopRebaseUsesPreviousScheduledEnd);
    Run("non-monotonic PTS rejected", TestNonMonotonicSameLoopRejected);
    Run("invalid PTS rejected", TestInvalidPTSRejected);
    Run("time conversion overflow rejected", TestTimeConversionOverflowRejected);
    Run("host addition overflow rejected", TestHostAdditionOverflowRejected);
#if defined(VCAM_VIDEO_DEVICE_PROOF_REMEDIATION_002_PREFX)
    Run(
        "five millisecond policy under frame-derived jitter",
        TestFiveMsPolicyUnderFrameDerivedJitter);
#endif
#if defined(VCAM_VIDEO_DEVICE_PROOF_REMEDIATION_002)
    Run(
        "frame-duration-derived lateness policy",
        TestFrameDurationDerivedLatenessPolicy);
#endif

    std::cout << "Stage F1 scheduler tests run: "
              << gTestsRun
              << ", failures: " << gFailures << std::endl;

    return gFailures == 0 ? EXIT_SUCCESS : EXIT_FAILURE;
}
