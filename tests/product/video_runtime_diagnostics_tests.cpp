#include "ProducerWakeupDriver.h"
#include "VideoRuntimeDiagnostics.h"

#include <CoreMedia/CoreMedia.h>

#include <cstdlib>
#include <iostream>

namespace {

using namespace vcam::media_engine;
namespace vd = vcam::product::video_diagnostics;

#define CHECK(condition) \
    do { \
        if (!(condition)) { \
            std::cerr << "CHECK failed at " << __FILE__ << ":" << __LINE__ \
                      << ": " #condition << std::endl; \
            return false; \
        } \
    } while (false)

bool TestProducerDiagnosticAccumulator() {
    ProducerRuntimeDiagnosticsSnapshot snapshot;

    FramePipelinePumpResult notStarted;
    notStarted.status =
        FramePipelinePumpStatus::NotReady;
    notStarted.readResult =
        ReadResultKind::NotReady;
    AccumulateProducerRuntimeDiagnostics(
        &snapshot,
        notStarted);

    CHECK(snapshot.readFrameCount == 0);
    CHECK(snapshot.normalizeSuccessCount == 0);
    CHECK(snapshot.normalizeFailureCount == 0);

    FramePipelinePumpResult success;
    success.status =
        FramePipelinePumpStatus::Published;
    success.readResult =
        ReadResultKind::Frame;
    success.normalizationStatus =
        NormalizationStatus::ReadyPassthrough;
    success.timelineStatus =
        vcam::frame_engine::
            TimelineScheduleStatus::ReadyNow;
    vcam::frame_engine::FrameTiming timing;
    timing.sourcePTS = CMTimeMake(7, 30);
    success.frameTiming = timing;
    AccumulateProducerRuntimeDiagnostics(
        &snapshot,
        success);

    CHECK(snapshot.readFrameCount == 1);
    CHECK(snapshot.normalizeSuccessCount == 1);
    CHECK(snapshot.normalizeFailureCount == 0);
    CHECK(snapshot.timelineReadyCount == 1);
    CHECK(snapshot.hasLastSourcePTS);
    CHECK(snapshot.lastSourcePTSValue == 7);
    CHECK(snapshot.lastSourcePTSTimescale == 30);

    FramePipelinePumpResult normalizeFailure;
    normalizeFailure.status =
        FramePipelinePumpStatus::
            NormalizationRejected;
    normalizeFailure.readResult =
        ReadResultKind::Frame;
    normalizeFailure.normalizationStatus =
        NormalizationStatus::InvalidFrame;
    AccumulateProducerRuntimeDiagnostics(
        &snapshot,
        normalizeFailure);

    CHECK(snapshot.readFrameCount == 2);
    CHECK(snapshot.normalizeFailureCount == 1);

    FramePipelinePumpResult transformSuccess;
    transformSuccess.status =
        FramePipelinePumpStatus::Published;
    transformSuccess.readResult =
        ReadResultKind::Frame;
    transformSuccess.normalizationStatus =
        NormalizationStatus::TransformRequired;
    transformSuccess.transformStatus =
        FrameTransformStatus::Transformed;
    transformSuccess.timelineStatus =
        vcam::frame_engine::
            TimelineScheduleStatus::WaitUntilDue;
    AccumulateProducerRuntimeDiagnostics(
        &snapshot,
        transformSuccess);

    CHECK(snapshot.readFrameCount == 3);
    CHECK(snapshot.normalizeSuccessCount == 2);
    CHECK(snapshot.transformSuccessCount == 1);
    CHECK(snapshot.timelineWaitCount == 1);

    FramePipelinePumpResult transformFailure;
    transformFailure.status =
        FramePipelinePumpStatus::TransformFailed;
    transformFailure.readResult =
        ReadResultKind::Frame;
    transformFailure.normalizationStatus =
        NormalizationStatus::TransformRequired;
    transformFailure.transformStatus =
        FrameTransformStatus::TransformFailure;
    AccumulateProducerRuntimeDiagnostics(
        &snapshot,
        transformFailure);

    CHECK(snapshot.readFrameCount == 4);
    CHECK(snapshot.normalizeSuccessCount == 3);
    CHECK(snapshot.transformFailureCount == 1);

    FramePipelinePumpResult late;
    late.status =
        FramePipelinePumpStatus::DroppedLate;
    late.readResult =
        ReadResultKind::Frame;
    late.normalizationStatus =
        NormalizationStatus::ReadyPassthrough;
    late.timelineStatus =
        vcam::frame_engine::
            TimelineScheduleStatus::DropLate;
    AccumulateProducerRuntimeDiagnostics(
        &snapshot,
        late);

    CHECK(snapshot.timelineDropCount == 1);

    FramePipelinePumpResult readerFailure;
    readerFailure.status =
        FramePipelinePumpStatus::ReaderFailed;
    readerFailure.readResult =
        ReadResultKind::Failed;
    readerFailure.readerError =
        vcam::frame_engine::
            ReaderErrorCode::ReadFailed;
    AccumulateProducerRuntimeDiagnostics(
        &snapshot,
        readerFailure);

    CHECK(snapshot.lastReadResult ==
          ReadResultKind::Failed);
    CHECK(snapshot.lastReaderError ==
          vcam::frame_engine::
              ReaderErrorCode::ReadFailed);

    std::cout
        << "VIDEO_DIAGNOSTIC_READER_NOT_STARTED=PASS\n"
        << "VIDEO_DIAGNOSTIC_SOURCE_FRAME_PATH=PASS\n"
        << "VIDEO_DIAGNOSTIC_NORMALIZE_FAILURE=PASS\n"
        << "VIDEO_DIAGNOSTIC_TRANSFORM_FAILURE=PASS\n"
        << "VIDEO_DIAGNOSTIC_TIMELINE_COUNTS=PASS\n"
        << "VIDEO_DIAGNOSTIC_READER_ERROR=PASS\n";
    return true;
}

bool TestFixedSizeTransport() {
    vd::Transport transport;
    CHECK(transport.valid());

    transport.clear();

    const std::uint64_t state =
        vd::kSelected |
        vd::kPlaying |
        vd::kReaderOpen |
        vd::kReaderStarted |
        vd::kDriverRunning |
        (UINT64_C(2) <<
            vd::kReaderErrorShift) |
        (UINT64_C(3) <<
            vd::kLastReadResultShift);

    CHECK(transport.set(
        vd::Field::State,
        state));
    CHECK(transport.set(
        vd::Field::NormalizeCounts,
        vd::PackPair32(9, 2)));
    CHECK(transport.set(
        vd::Field::CommitCounts,
        vd::PackPair32(17, 1)));

    vd::Snapshot readback;
    CHECK(transport.read(&readback));
    CHECK(readback.value(
        vd::Field::State) == state);

    const std::uint64_t normalize =
        readback.value(
            vd::Field::NormalizeCounts);
    CHECK(vd::Low32(normalize) == 9);
    CHECK(vd::High32(normalize) == 2);

    const std::uint64_t commits =
        readback.value(
            vd::Field::CommitCounts);
    CHECK(vd::Low32(commits) == 17);
    CHECK(vd::High32(commits) == 1);

    transport.clear();
    CHECK(transport.read(&readback));
    for (std::uint64_t value :
         readback.values) {
        CHECK(value == 0);
    }

    std::cout
        << "VIDEO_DIAGNOSTIC_TRANSPORT_FIXED_SIZE=PASS\n"
        << "VIDEO_DIAGNOSTIC_TRANSPORT_ROUNDTRIP=PASS\n"
        << "VIDEO_DIAGNOSTIC_TRANSPORT_CLEAR=PASS\n";
    return true;
}

}  // namespace

int main() {
    if (!TestProducerDiagnosticAccumulator()) {
        return EXIT_FAILURE;
    }
    if (!TestFixedSizeTransport()) {
        return EXIT_FAILURE;
    }

    std::cout
        << "VIDEO_RUNTIME_DIAGNOSTIC_COUNTERS=PASS\n";
    return EXIT_SUCCESS;
}
