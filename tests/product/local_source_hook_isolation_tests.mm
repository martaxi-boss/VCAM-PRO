#include "LocalSourceAccess.h"
#include "LocalVideoReader.h"
#import <AVFoundation/AVFoundation.h>
#import <Foundation/Foundation.h>
#include <chrono>
#include <string>
#include "MediaserverdRuntime.h"
#include "ReferenceCameraHook.h"

#include <atomic>
#include <cstdlib>
#include <cstring>
#include <iostream>
#include <thread>

namespace {
#define CHECK(x) do { if (!(x)) { std::cerr << "Failed: " #x "\n"; return false; } } while (false)

bool WaitForWriterInput(AVAssetWriterInput* input) {
    for (int attempt = 0; attempt < 5000; ++attempt) {
        if (input.readyForMoreMediaData) {
            return true;
        }
        [NSThread sleepForTimeInterval:0.001];
    }
    return false;
}

bool CreateLocalVideoFixture(const std::string& path,
                             int frameCount = 3,
                             int width = 64,
                             int height = 48) {
    @autoreleasepool {
        NSString* nsPath =
            [[NSString alloc] initWithUTF8String:path.c_str()];
        if (nsPath == nil) {
            return false;
        }

        [[NSFileManager defaultManager] removeItemAtPath:nsPath error:nil];
        NSURL* url = [NSURL fileURLWithPath:nsPath];

        NSError* writerError = nil;
        AVAssetWriter* writer =
            [[AVAssetWriter alloc] initWithURL:url
                                      fileType:AVFileTypeQuickTimeMovie
                                         error:&writerError];
        if (writer == nil) {
            return false;
        }

        NSDictionary* compression = @{
            AVVideoAverageBitRateKey : @(150000)
        };
        NSDictionary* settings = @{
            AVVideoCodecKey : AVVideoCodecTypeH264,
            AVVideoWidthKey : @(width),
            AVVideoHeightKey : @(height),
            AVVideoCompressionPropertiesKey : compression,
        };

        AVAssetWriterInput* input =
            [AVAssetWriterInput assetWriterInputWithMediaType:AVMediaTypeVideo
                                               outputSettings:settings];
        input.expectsMediaDataInRealTime = NO;

        // BGRA is TEST-ONLY for deterministic AVAssetWriter fixture creation.
        // It is not a VCAM PRO production output-format decision.
        NSDictionary* attributes = @{
            (NSString*)kCVPixelBufferPixelFormatTypeKey :
                @(kCVPixelFormatType_32BGRA),
            (NSString*)kCVPixelBufferWidthKey : @(width),
            (NSString*)kCVPixelBufferHeightKey : @(height),
        };

        AVAssetWriterInputPixelBufferAdaptor* adaptor =
            [AVAssetWriterInputPixelBufferAdaptor
                assetWriterInputPixelBufferAdaptorWithAssetWriterInput:input
                sourcePixelBufferAttributes:attributes];

        if (![writer canAddInput:input]) {
            return false;
        }
        [writer addInput:input];

        if (![writer startWriting]) {
            return false;
        }
        [writer startSessionAtSourceTime:kCMTimeZero];

        CVPixelBufferPoolRef pool = adaptor.pixelBufferPool;
        if (pool == nullptr) {
            return false;
        }

        for (int index = 0; index < frameCount; ++index) {
            if (!WaitForWriterInput(input)) {
                return false;
            }

            CVPixelBufferRef pixelBuffer = nullptr;
            if (CVPixelBufferPoolCreatePixelBuffer(
                    kCFAllocatorDefault,
                    pool,
                    &pixelBuffer) != kCVReturnSuccess ||
                pixelBuffer == nullptr) {
                return false;
            }

            CVPixelBufferLockBaseAddress(pixelBuffer, 0);
            auto* bytes = static_cast<unsigned char*>(
                CVPixelBufferGetBaseAddress(pixelBuffer));
            const std::size_t bytesPerRow =
                CVPixelBufferGetBytesPerRow(pixelBuffer);
            const std::size_t rows =
                CVPixelBufferGetHeight(pixelBuffer);
            std::memset(bytes,
                        static_cast<unsigned char>(32 + index * 32),
                        bytesPerRow * rows);
            CVPixelBufferUnlockBaseAddress(pixelBuffer, 0);

            const CMTime pts = CMTimeMake(index, 30);
            const BOOL appended =
                [adaptor appendPixelBuffer:pixelBuffer
                      withPresentationTime:pts];
            CVPixelBufferRelease(pixelBuffer);

            if (!appended) {
                return false;
            }
        }

        [input markAsFinished];

        dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);
        [writer finishWritingWithCompletionHandler:^{
            dispatch_semaphore_signal(semaphore);
        }];

        const dispatch_time_t timeout =
            dispatch_time(DISPATCH_TIME_NOW,
                          static_cast<int64_t>(10 * NSEC_PER_SEC));
        if (dispatch_semaphore_wait(semaphore, timeout) != 0) {
            return false;
        }

        return writer.status == AVAssetWriterStatusCompleted;
    }
}

void RemoveFixture(const std::string& path) {
    @autoreleasepool {
        NSString* nsPath =
            [[NSString alloc] initWithUTF8String:path.c_str()];
        if (nsPath != nil) {
            [[NSFileManager defaultManager]
                removeItemAtPath:nsPath
                           error:nil];
        }
    }
}

CMSampleBufferRef MakeSample(CVPixelBufferRef* buffer) {
    if (CVPixelBufferCreate(kCFAllocatorDefault, 64, 48,
            kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
            nullptr, buffer) != kCVReturnSuccess) return nullptr;
    CVPixelBufferLockBaseAddress(*buffer, 0);
    for (std::size_t plane = 0; plane < 2; ++plane) {
        std::memset(CVPixelBufferGetBaseAddressOfPlane(*buffer, plane),
            plane == 0 ? 90 : 128,
            CVPixelBufferGetBytesPerRowOfPlane(*buffer, plane) *
                CVPixelBufferGetHeightOfPlane(*buffer, plane));
    }
    CVPixelBufferUnlockBaseAddress(*buffer, 0);
    CMVideoFormatDescriptionRef format = nullptr;
    if (CMVideoFormatDescriptionCreateForImageBuffer(kCFAllocatorDefault,
            *buffer, &format) != noErr) return nullptr;
    CMSampleTimingInfo timing{CMTimeMake(1, 30), kCMTimeZero, kCMTimeInvalid};
    CMSampleBufferRef sample = nullptr;
    const OSStatus status = CMSampleBufferCreateReadyWithImageBuffer(
        kCFAllocatorDefault, *buffer, format, &timing, &sample);
    CFRelease(format);
    return status == noErr ? sample : nullptr;
}

std::uint8_t FirstLuma(CVPixelBufferRef buffer) {
    CVPixelBufferLockBaseAddress(buffer, kCVPixelBufferLock_ReadOnly);
    const auto value = *static_cast<const std::uint8_t*>(
        CVPixelBufferGetBaseAddressOfPlane(buffer, 0));
    CVPixelBufferUnlockBaseAddress(buffer, kCVPixelBufferLock_ReadOnly);
    return value;
}

bool Run() {
    using namespace vcam::media_engine;
    using namespace vcam::product;
    auto& runtime = MediaserverdRuntime::shared();
    auto& adapter = runtime.cameraAdapter();
    adapter.setEnabled(true);
    CVPixelBufferRef source = nullptr;
    CMSampleBufferRef sample = MakeSample(&source);
    CHECK(sample != nullptr);
    // Compile the unchanged reader body with its image accessor interposed
    // through the real camera callback, just as MSHookFunction does on iOS.
    const std::string path = std::string(NSTemporaryDirectory().UTF8String) +
        "vcam-source-hook-" + NSUUID.UUID.UUIDString.UTF8String + ".mov";
    CHECK(CreateLocalVideoFixture(path));
    vcam::frame_engine::FrameEngineState state;
    LocalVideoReader reader(state);
    LocalVideoReaderConfig config;
    config.outputPixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarFullRange;
    const auto beforeRead = adapter.decisionCount();
    CHECK(reader.open(path, config));
    CHECK(reader.start());
    auto read = reader.readNext();
    CHECK(read.kind == ReadResultKind::Frame);
    CHECK(read.frame.has_value());
    CHECK(FirstLuma(read.frame->pixelBuffer()) > 0);
    CHECK(adapter.decisionCount() == beforeRead);
    CHECK(!IsLocalSourceAccessActive());
    reader.stop();
    [[NSFileManager defaultManager] removeItemAtPath:
        [NSString stringWithUTF8String:path.c_str()] error:nil];
    std::cout << "REAL_VIDEO_READER_WITH_CAMERA_HOOK=PASS\n";
    const auto decisions = adapter.decisionCount();
    CHECK(!IsLocalSourceAccessActive());
    {
        ScopedLocalSourceAccess access;
        CHECK(InvokeReferenceCameraHookForTesting(sample) == source);
        CHECK(FirstLuma(source) == 90);
        CHECK(adapter.decisionCount() == decisions);
        {
            ScopedLocalSourceAccess nested;
            CHECK(InvokeReferenceCameraHookForTesting(sample) == source);
        }
        CHECK(IsLocalSourceAccessActive());
        std::atomic<bool> cameraOwned{false};
        std::thread camera([&] {
            CVPixelBufferRef physical = nullptr;
            CMSampleBufferRef cameraSample = MakeSample(&physical);
            if (cameraSample != nullptr) {
                cameraOwned.store(!IsLocalSourceAccessActive() &&
                    InvokeReferenceCameraHookForTesting(cameraSample) == physical &&
                    FirstLuma(physical) == 0);
                CFRelease(cameraSample);
                CVPixelBufferRelease(physical);
            }
        });
        camera.join();
        CHECK(cameraOwned.load());
        CHECK(FirstLuma(source) == 90);
    }
    CHECK(!IsLocalSourceAccessActive());
    CHECK(adapter.decisionCount() == decisions + 1);
    CHECK(InvokeReferenceCameraHookForTesting(sample) == source);
    CHECK(FirstLuma(source) == 0);
    CHECK(adapter.decisionCount() == decisions + 2);
    adapter.setEnabled(false);
    CVPixelBufferRef off = nullptr;
    CMSampleBufferRef offSample = MakeSample(&off);
    CHECK(offSample != nullptr);
    CHECK(InvokeReferenceCameraHookForTesting(offSample) == off);
    CHECK(FirstLuma(off) == 90);
    CFRelease(offSample);
    CVPixelBufferRelease(off);
    CFRelease(sample);
    CVPixelBufferRelease(source);
    std::cout << "LOCAL_SOURCE_PIXELS_PRESERVED=PASS\n"
              << "LOCAL_SOURCE_DOES_NOT_ENTER_CAMERA_DECISION=PASS\n"
              << "CONCURRENT_CAMERA_ON_OWNERSHIP=PASS\n"
              << "NESTED_SOURCE_SCOPE_RESTORED=PASS\n"
              << "CAMERA_ON_OWNERSHIP_AFTER_SOURCE_SCOPE=PASS\n"
              << "CAMERA_OFF_ORIGINAL=PASS\n";
    return true;
}
}  // namespace

int main() { return Run() ? EXIT_SUCCESS : EXIT_FAILURE; }
