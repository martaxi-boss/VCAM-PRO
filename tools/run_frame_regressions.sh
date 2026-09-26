#!/bin/sh
set -eu

mkdir -p build/regressions

CXX="xcrun --sdk macosx clang++"
BASE="-std=c++17 -Wall -Wextra -Werror -pedantic"
OBJC="$BASE -fobjc-arc -Wno-deprecated-declarations"
INC="-Isrc/frame_engine -Isrc/media_engine"

$CXX $BASE -Isrc/frame_engine   src/frame_engine/PreparedFrame.cpp src/frame_engine/FrameEngineState.cpp   tests/frame_engine/frame_engine_stage_a_tests.cpp   -framework CoreFoundation -framework CoreMedia -framework CoreVideo   -o build/regressions/a
build/regressions/a | tee build/regressions/stage-a.txt
grep -q 'Tests run: 13, failures: 0' build/regressions/stage-a.txt

$CXX $OBJC $INC   src/frame_engine/PreparedFrame.cpp src/frame_engine/FrameEngineState.cpp   src/media_engine/LocalVideoReader.mm   tests/media_engine/local_video_reader_stage_b_tests.mm   -framework Foundation -framework AVFoundation -framework CoreFoundation   -framework CoreMedia -framework CoreVideo -framework CoreGraphics   -o build/regressions/b
build/regressions/b | tee build/regressions/stage-b.txt
grep -q 'Stage B tests run: 10, failures: 0' build/regressions/stage-b.txt

$CXX $BASE -pthread -Isrc/frame_engine   src/frame_engine/PreparedFrame.cpp src/frame_engine/ReadyFrameQueue.cpp   tests/frame_engine/ready_frame_queue_stage_c1_tests.cpp   -framework CoreFoundation -framework CoreMedia -framework CoreVideo   -o build/regressions/c1q
build/regressions/c1q | tee build/regressions/c1-queue.txt
grep -q 'Stage C1 queue tests run: 18, failures: 0' build/regressions/c1-queue.txt

$CXX $BASE $INC   src/frame_engine/PreparedFrame.cpp src/media_engine/FrameNormalizer.cpp   tests/media_engine/frame_normalizer_stage_c1_tests.cpp   -framework CoreFoundation -framework CoreMedia -framework CoreVideo   -framework CoreGraphics -o build/regressions/c1n
build/regressions/c1n | tee build/regressions/c1-normalizer.txt
grep -q 'Stage C1 normalizer tests run: 17, failures: 0' build/regressions/c1-normalizer.txt

$CXX $OBJC $INC   src/frame_engine/PreparedFrame.cpp src/frame_engine/FrameEngineState.cpp   src/frame_engine/ReadyFrameQueue.cpp src/media_engine/LocalVideoReader.mm   src/media_engine/FrameNormalizer.cpp src/media_engine/FramePipelinePump.cpp   tests/media_engine/frame_pipeline_stage_d1_tests.mm   -framework Foundation -framework AVFoundation -framework CoreFoundation   -framework CoreMedia -framework CoreVideo -framework CoreGraphics   -o build/regressions/d1
build/regressions/d1 | tee build/regressions/d1.txt
grep -q 'Stage D1 tests run: 19, failures: 0' build/regressions/d1.txt

$CXX $BASE -pthread -Isrc/frame_engine   src/frame_engine/PreparedFrame.cpp src/frame_engine/ReadyFrameQueue.cpp   tests/frame_engine/consumer_fast_path_stage_d2_tests.cpp   -framework CoreFoundation -framework CoreMedia -framework CoreVideo   -o build/regressions/d2c
build/regressions/d2c | tee build/regressions/d2-consumer.txt
grep -q 'Stage D2 consumer tests run: 5, failures: 0' build/regressions/d2-consumer.txt

$CXX $BASE -pthread -Isrc/frame_engine   src/frame_engine/PreparedFrame.cpp src/frame_engine/ReadyFrameQueue.cpp   tests/frame_engine/ready_frame_queue_stage_d2_stress_tests.cpp   -framework CoreFoundation -framework CoreMedia -framework CoreVideo   -o build/regressions/d2q
build/regressions/d2q | tee build/regressions/d2-queue.txt
grep -q 'Stage D2 queue stress tests run: 8, failures: 0' build/regressions/d2-queue.txt

$CXX $OBJC -pthread $INC   src/frame_engine/PreparedFrame.cpp src/frame_engine/FrameEngineState.cpp   src/frame_engine/ReadyFrameQueue.cpp src/media_engine/LocalVideoReader.mm   src/media_engine/FrameNormalizer.cpp src/media_engine/FramePipelinePump.cpp   tests/media_engine/frame_pipeline_stage_d2_stress_tests.mm   -framework Foundation -framework AVFoundation -framework CoreFoundation   -framework CoreMedia -framework CoreVideo -framework CoreGraphics   -o build/regressions/d2p
build/regressions/d2p | tee build/regressions/d2-pipeline.txt
grep -q 'Stage D2 pipeline stress tests run: 5, failures: 0' build/regressions/d2-pipeline.txt

$CXX $BASE $INC   src/frame_engine/PreparedFrame.cpp src/media_engine/FrameNormalizer.cpp   src/media_engine/FrameTransformer.mm   tests/media_engine/frame_transformer_stage_e1_tests.mm   -framework Accelerate -framework CoreFoundation -framework CoreGraphics   -framework CoreMedia -framework CoreVideo -o build/regressions/e1t
build/regressions/e1t | tee build/regressions/e1-transformer.txt
grep -q 'Stage E1 transformer tests run: 27, failures: 0' build/regressions/e1-transformer.txt

$CXX $OBJC $INC   src/frame_engine/PreparedFrame.cpp src/frame_engine/FrameEngineState.cpp   src/frame_engine/ReadyFrameQueue.cpp src/media_engine/LocalVideoReader.mm   src/media_engine/FrameNormalizer.cpp src/media_engine/FrameTransformer.mm   src/media_engine/FramePipelinePump.cpp   tests/media_engine/frame_pipeline_stage_e1_tests.mm   -framework Accelerate -framework Foundation -framework AVFoundation   -framework CoreFoundation -framework CoreGraphics -framework CoreMedia   -framework CoreVideo -o build/regressions/e1p
build/regressions/e1p | tee build/regressions/e1-pipeline.txt
grep -q 'Stage E1 pipeline tests run: 3, failures: 0' build/regressions/e1-pipeline.txt

$CXX $BASE -Isrc/frame_engine   src/frame_engine/PreparedFrame.cpp src/frame_engine/FrameTimelineScheduler.cpp   tests/frame_engine/frame_timeline_scheduler_stage_f1_tests.cpp   -framework CoreFoundation -framework CoreMedia -framework CoreVideo   -o build/regressions/f1s
build/regressions/f1s | tee build/regressions/f1-scheduler.txt
grep -q 'Stage F1 scheduler tests run: 13, failures: 0' build/regressions/f1-scheduler.txt

$CXX $OBJC $INC   src/frame_engine/PreparedFrame.cpp src/frame_engine/FrameEngineState.cpp   src/frame_engine/ReadyFrameQueue.cpp src/frame_engine/FrameTimelineScheduler.cpp   src/media_engine/LocalVideoReader.mm src/media_engine/FrameNormalizer.cpp   src/media_engine/FrameTransformer.mm src/media_engine/FramePipelinePump.cpp   src/media_engine/FramePipelinePumpTimed.cpp   tests/media_engine/frame_pipeline_stage_f1_tests.mm   -framework Accelerate -framework Foundation -framework AVFoundation   -framework CoreFoundation -framework CoreGraphics -framework CoreMedia   -framework CoreVideo -o build/regressions/f1p
build/regressions/f1p | tee build/regressions/f1-pipeline.txt
grep -q 'Stage F1 timed pipeline tests run: 12, failures: 0' build/regressions/f1-pipeline.txt

$CXX $BASE $INC   src/media_engine/ProducerWakeupController.cpp   tests/media_engine/producer_wakeup_driver_stage_f2_tests.cpp   -framework CoreFoundation -framework CoreGraphics -framework CoreMedia   -framework CoreVideo -o build/regressions/f2
build/regressions/f2 | tee build/regressions/f2-driver.txt
grep -q 'Stage F2 driver tests run: 19, failures: 0' build/regressions/f2-driver.txt

echo "FRAME_ENGINE_A_TO_F2_REGRESSION=PASS"
