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
    FrameTimelineScheduler scheduler(kThreshold);

    const auto first = MakeFrame(
        0, 1, 2, 0, CMTimeMake(0, 30));
    const auto second = MakeFrame(
        1, 1, 2, 0, CMTimeMake(1, 30));

    CHECK(scheduler.evaluate(first, 1, 2, 1'000ULL).status ==
          TimelineScheduleStatus::ReadyNow);

    const auto wait =
        scheduler.evaluate(second, 1, 2, 1'000ULL);
    CHECK(wait.status == TimelineScheduleStatus::WaitUntilDue);
    const auto due = *wait.dueHostTimeNs;

    CHECK(scheduler.evaluate(second, 1, 2, due + kThreshold).status ==
          TimelineScheduleStatus::ReadyNow);
    CHECK(scheduler.evaluate(
              second,
              1,
              2,
              due + kThreshold + 1)
              .status == TimelineScheduleStatus::DropLate);
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

    std::cout << "Stage F1 scheduler tests run: "
              << gTestsRun
              << ", failures: " << gFailures << std::endl;

    return gFailures == 0 ? EXIT_SUCCESS : EXIT_FAILURE;
}
