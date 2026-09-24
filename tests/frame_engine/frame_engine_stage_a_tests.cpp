#include "FrameEngineState.h"
#include "PreparedFrame.h"

#include <CoreVideo/CoreVideo.h>

#include <cstdlib>
#include <functional>
#include <iostream>
#include <optional>
#include <string>
#include <utility>

namespace {

using namespace vcam::frame_engine;

int gFailures = 0;
int gTestsRun = 0;

#define CHECK(condition)                                                        \
    do {                                                                        \
        if (!(condition)) {                                                     \
            std::cerr << "CHECK failed at " << __FILE__ << ":" << __LINE__    \
                      << ": " #condition << std::endl;                          \
            return false;                                                       \
        }                                                                       \
    } while (false)

CVPixelBufferRef CreateFixturePixelBuffer(std::size_t width = 8,
                                          std::size_t height = 6) {
    CVPixelBufferRef pixelBuffer = nullptr;

    // BGRA is used only as a tiny host-test fixture because CVPixelBufferCreate
    // can create it without a decoder. It is NOT a VCAM PRO format decision.
    const CVReturn result = CVPixelBufferCreate(
        kCFAllocatorDefault,
        width,
        height,
        kCVPixelFormatType_32BGRA,
        nullptr,
        &pixelBuffer);

    if (result != kCVReturnSuccess) {
        return nullptr;
    }
    return pixelBuffer;
}

FrameTiming FixtureTiming() {
    FrameTiming timing;
    timing.sourcePTS = CMTimeMake(1, 30);
    timing.presentationTimestamp = CMTimeMake(2, 30);
    timing.duration = CMTimeMake(1, 30);
    timing.producedAtHostTime = 1234;
    return timing;
}

PreparedFrame MakeReadyFrame(CVPixelBufferRef pixelBuffer,
                             const FrameIdentity& identity) {
    return PreparedFrame(pixelBuffer,
                         identity,
                         FixtureTiming(),
                         OrientationState::SourceNotNormalized,
                         FrameValidity::Ready);
}

bool TestPreparedFrameRetainsPixelBuffer() {
    CVPixelBufferRef original = CreateFixturePixelBuffer();
    CHECK(original != nullptr);

    PreparedFrame frame = MakeReadyFrame(original, {0, 1, 1, 0});
    CVPixelBufferRelease(original);

    CHECK(frame.pixelBuffer() != nullptr);
    CHECK(frame.width() == 8);
    CHECK(frame.height() == 6);
    CHECK(frame.pixelFormat() == kCVPixelFormatType_32BGRA);
    CHECK(CVPixelBufferGetWidth(frame.pixelBuffer()) == 8);
    CHECK(frame.isInternallyConsistent());
    CHECK(frame.isEligible(1, 1));
    return true;
}

bool TestLeaseSurvivesPreparedFrameScope() {
    CVPixelBufferRef original = CreateFixturePixelBuffer(10, 4);
    CHECK(original != nullptr);

    std::optional<FrameLease> lease;
    {
        PreparedFrame frame = MakeReadyFrame(original, {2, 5, 7, 0});
        CVPixelBufferRelease(original);
        original = nullptr;

        lease = frame.acquireLease(5, 7);
        CHECK(lease.has_value());
        CHECK(lease->isValid());
    }

    CHECK(lease.has_value());
    CHECK(lease->pixelBuffer() != nullptr);
    CHECK(CVPixelBufferGetWidth(lease->pixelBuffer()) == 10);
    CHECK(CVPixelBufferGetHeight(lease->pixelBuffer()) == 4);
    CHECK(lease->identity().mediaGeneration == 5);
    return true;
}

bool TestCopyAndMoveOwnership() {
    CVPixelBufferRef original = CreateFixturePixelBuffer(7, 5);
    CHECK(original != nullptr);

    PreparedFrame first = MakeReadyFrame(original, {3, 2, 9, 1});
    CVPixelBufferRelease(original);

    PreparedFrame copy(first);
    PreparedFrame moved(std::move(first));

    CHECK(copy.isInternallyConsistent());
    CHECK(moved.isInternallyConsistent());
    CHECK(copy.width() == 7);
    CHECK(moved.height() == 5);

    auto copyLease = copy.acquireLease(2, 9);
    auto movedLease = moved.acquireLease(2, 9);
    CHECK(copyLease.has_value());
    CHECK(movedLease.has_value());

    FrameLease leaseCopy(*copyLease);
    FrameLease leaseMoved(std::move(*movedLease));
    CHECK(leaseCopy.isValid());
    CHECK(leaseMoved.isValid());
    return true;
}

bool TestInvalidatedAndFailedFramesAreIneligible() {
    CVPixelBufferRef original = CreateFixturePixelBuffer();
    CHECK(original != nullptr);

    PreparedFrame invalidated = MakeReadyFrame(original, {0, 1, 1, 0});
    PreparedFrame failed = invalidated;
    CVPixelBufferRelease(original);

    invalidated.invalidate();
    failed.markFailed();

    CHECK(!invalidated.isEligible(1, 1));
    CHECK(!failed.isEligible(1, 1));
    CHECK(!invalidated.acquireLease(1, 1).has_value());
    CHECK(!failed.acquireLease(1, 1).has_value());
    return true;
}

bool TestFirstMediaGeneration() {
    FrameEngineState state;
    CHECK(state.playbackState() == PlaybackState::Empty);
    CHECK(!state.hasMedia());
    CHECK(state.mediaGeneration() == 0);

    state.selectOrReplaceMedia();

    CHECK(state.hasMedia());
    CHECK(state.mediaGeneration() == 1);
    CHECK(state.playbackState() == PlaybackState::Ready);
    CHECK(state.loopIteration() == 0);
    CHECK(state.timelineEpoch() == 1);
    CHECK(state.nextSequence() == 0);
    return true;
}

bool TestMediaReplacementInvalidatesOldGeneration() {
    FrameEngineState state;
    state.selectOrReplaceMedia();
    const FrameIdentity oldIdentity = state.nextFrameIdentity();

    CVPixelBufferRef original = CreateFixturePixelBuffer();
    CHECK(original != nullptr);
    PreparedFrame oldFrame = MakeReadyFrame(original, oldIdentity);
    CVPixelBufferRelease(original);

    CHECK(oldFrame.isEligible(state.mediaGeneration(), state.timelineEpoch()));

    const auto oldGeneration = state.mediaGeneration();
    state.selectOrReplaceMedia();

    CHECK(state.mediaGeneration() == oldGeneration + 1);
    CHECK(state.loopIteration() == 0);
    CHECK(state.nextSequence() == 0);
    CHECK(!oldFrame.isEligible(state.mediaGeneration(), state.timelineEpoch()));
    return true;
}

bool TestStartAndSequenceRules() {
    FrameEngineState state;
    state.selectOrReplaceMedia();
    const auto preStartEpoch = state.timelineEpoch();

    CHECK(state.start());
    CHECK(state.playbackState() == PlaybackState::Playing);
    CHECK(state.timelineEpoch() == preStartEpoch + 1);

    const FrameIdentity a = state.nextFrameIdentity();
    const FrameIdentity b = state.nextFrameIdentity();
    const FrameIdentity c = state.nextFrameIdentity();

    CHECK(a.sequence == 0);
    CHECK(b.sequence == 1);
    CHECK(c.sequence == 2);
    CHECK(a.timelineEpoch == b.timelineEpoch);
    CHECK(b.timelineEpoch == c.timelineEpoch);
    return true;
}

bool TestPauseResumeCreatesFreshEpoch() {
    FrameEngineState state;
    state.selectOrReplaceMedia();
    CHECK(state.start());

    const FrameIdentity oldIdentity = state.nextFrameIdentity();
    CVPixelBufferRef original = CreateFixturePixelBuffer();
    CHECK(original != nullptr);
    PreparedFrame oldFrame = MakeReadyFrame(original, oldIdentity);
    CVPixelBufferRelease(original);

    const auto playingEpoch = state.timelineEpoch();
    CHECK(state.pause());
    CHECK(state.playbackState() == PlaybackState::Paused);
    CHECK(state.timelineEpoch() == playingEpoch);

    CHECK(state.resume());
    CHECK(state.playbackState() == PlaybackState::Playing);
    CHECK(state.timelineEpoch() == playingEpoch + 1);
    CHECK(state.nextSequence() == 0);
    CHECK(!oldFrame.isEligible(state.mediaGeneration(), state.timelineEpoch()));
    return true;
}

bool TestSeekReloadCreatesFreshEpoch() {
    FrameEngineState state;
    state.selectOrReplaceMedia();
    CHECK(state.start());

    const FrameIdentity oldIdentity = state.nextFrameIdentity();
    CVPixelBufferRef original = CreateFixturePixelBuffer();
    CHECK(original != nullptr);
    PreparedFrame oldFrame = MakeReadyFrame(original, oldIdentity);
    CVPixelBufferRelease(original);

    const auto oldEpoch = state.timelineEpoch();
    CHECK(state.seekOrReload());

    CHECK(state.timelineEpoch() == oldEpoch + 1);
    CHECK(state.nextSequence() == 0);
    CHECK(state.readerStatus().state == ReaderState::Uninitialized);
    CHECK(!oldFrame.isEligible(state.mediaGeneration(), state.timelineEpoch()));
    return true;
}

bool TestLoopRequiresConfirmedCompletion() {
    FrameEngineState state;
    state.selectOrReplaceMedia();

    CHECK(state.markReaderReady());
    CHECK(state.beginReading());
    CHECK(!state.canLoopRestart());

    const auto epochBefore = state.timelineEpoch();
    CHECK(state.markReaderCompleted());
    CHECK(state.readerIsCompletedEOS());
    CHECK(state.canLoopRestart());
    CHECK(state.confirmLoopRestart());

    CHECK(state.loopIteration() == 1);
    CHECK(state.readerStatus().state == ReaderState::Ready);
    CHECK(state.timelineEpoch() == epochBefore);
    return true;
}

bool TestFailedReaderIsNotEOS() {
    FrameEngineState state;
    state.selectOrReplaceMedia();
    CHECK(state.markReaderReady());
    CHECK(state.beginReading());

    state.markReaderFailed(ReaderErrorCode::ReadFailed);

    CHECK(state.readerStatus().state == ReaderState::Failed);
    CHECK(state.readerStatus().error == ReaderErrorCode::ReadFailed);
    CHECK(!state.readerIsCompletedEOS());
    CHECK(!state.canLoopRestart());
    CHECK(!state.confirmLoopRestart());
    return true;
}

bool TestCancelledReaderIsNotEOS() {
    FrameEngineState state;
    state.selectOrReplaceMedia();
    CHECK(state.markReaderReady());
    CHECK(state.beginReading());

    state.cancelReader();

    CHECK(state.readerStatus().state == ReaderState::Cancelled);
    CHECK(state.readerStatus().error == ReaderErrorCode::Cancelled);
    CHECK(!state.readerIsCompletedEOS());
    CHECK(!state.canLoopRestart());
    CHECK(!state.confirmLoopRestart());
    return true;
}

bool TestPlaybackTransitionsAreDeterministic() {
    FrameEngineState state;

    CHECK(!state.start());
    CHECK(!state.pause());
    CHECK(!state.resume());
    CHECK(!state.seekOrReload());

    state.selectOrReplaceMedia();
    CHECK(!state.pause());
    CHECK(state.start());
    CHECK(!state.start());
    CHECK(state.pause());
    CHECK(!state.pause());
    CHECK(state.resume());
    CHECK(state.markEnded());
    CHECK(state.playbackState() == PlaybackState::Ended);
    CHECK(state.start());

    state.markPlaybackFailed();
    CHECK(state.playbackState() == PlaybackState::Failed);
    CHECK(!state.seekOrReload());
    return true;
}

void Run(const std::string& name, const std::function<bool()>& test) {
    ++gTestsRun;
    if (!test()) {
        ++gFailures;
        std::cerr << "[FAIL] " << name << std::endl;
        return;
    }
    std::cout << "[PASS] " << name << std::endl;
}

}  // namespace

int main() {
    Run("PreparedFrame retains CVPixelBuffer", TestPreparedFrameRetainsPixelBuffer);
    Run("Lease survives PreparedFrame scope", TestLeaseSurvivesPreparedFrameScope);
    Run("Copy/move ownership", TestCopyAndMoveOwnership);
    Run("Invalidated/failed ineligible", TestInvalidatedAndFailedFramesAreIneligible);
    Run("First media generation", TestFirstMediaGeneration);
    Run("Media replacement invalidates old generation", TestMediaReplacementInvalidatesOldGeneration);
    Run("Start and sequence rules", TestStartAndSequenceRules);
    Run("Pause/resume fresh epoch", TestPauseResumeCreatesFreshEpoch);
    Run("Seek/reload fresh epoch", TestSeekReloadCreatesFreshEpoch);
    Run("Loop requires completion", TestLoopRequiresConfirmedCompletion);
    Run("Failed reader not EOS", TestFailedReaderIsNotEOS);
    Run("Cancelled reader not EOS", TestCancelledReaderIsNotEOS);
    Run("Playback transitions deterministic", TestPlaybackTransitionsAreDeterministic);

    std::cout << "Tests run: " << gTestsRun
              << ", failures: " << gFailures << std::endl;

    return gFailures == 0 ? EXIT_SUCCESS : EXIT_FAILURE;
}
