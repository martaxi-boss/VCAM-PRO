#include "ProductControlOwner.h"
#include "SelectionCompletionGate.h"
#include "SharedControlStore.h"

#import <AVFoundation/AVFoundation.h>
#import <Foundation/Foundation.h>
#import <ImageIO/ImageIO.h>

#include <CoreGraphics/CoreGraphics.h>
#include <CoreMedia/CoreMedia.h>
#include <CoreVideo/CoreVideo.h>

#include <condition_variable>
#include <cstdint>
#include <cstring>
#include <functional>
#include <iostream>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

namespace {

using vcam::control::SelectionCompletionGate;
using vcam::product::ProductControlOwner;
using vcam::product::ProductControlSnapshot;
using vcam::product::ProductMediaKind;
using vcam::product::ProductPlaybackIntent;
using vcam::product::SharedControlStore;

int gTests = 0;
int gFailures = 0;

#define CHECK(condition) \
    do { \
        if (!(condition)) { \
            std::cerr \
                << "CHECK failed at " \
                << __FILE__ << ":" \
                << __LINE__ << ": " \
                << #condition \
                << std::endl; \
            return false; \
        } \
    } while (false)

std::string ToStd(
    NSString* value) {
    const char* utf8 =
        value.UTF8String;
    return utf8 == nullptr
        ? std::string{}
        : std::string(utf8);
}

std::string TempRoot() {
    return ToStd(
        [NSTemporaryDirectory()
            stringByAppendingPathComponent:
                [NSString
                    stringWithFormat:
                        @"vcam-lost-update-%@",
                        NSUUID.UUID.UUIDString]]);
}

bool CreateDirectory(
    const std::string& path) {
    return [[NSFileManager defaultManager]
        createDirectoryAtPath:
            [NSString
                stringWithUTF8String:
                    path.c_str()]
  withIntermediateDirectories:YES
                   attributes:nil
                        error:nil];
}

std::string TempFile(
    const std::string& root,
    const char* label,
    NSString* extension) {
    NSString* name =
        [NSString
            stringWithFormat:
                @"%s-%@.%@",
                label,
                NSUUID.UUID.UUIDString,
                extension];

    return ToStd(
        [[NSString
            stringWithUTF8String:
                root.c_str()]
            stringByAppendingPathComponent:
                name]);
}

bool CreatePhoto(
    const std::string& path,
    std::uint8_t fill) {
    constexpr std::size_t width = 64;
    constexpr std::size_t height = 48;

    std::uint8_t bytes[
        width * height * 4];
    std::memset(
        bytes,
        fill,
        sizeof(bytes));

    CGColorSpaceRef colorSpace =
        CGColorSpaceCreateDeviceRGB();
    CGContextRef context =
        CGBitmapContextCreate(
            bytes,
            width,
            height,
            8,
            width * 4,
            colorSpace,
            kCGImageAlphaPremultipliedLast |
                kCGBitmapByteOrder32Big);
    CGColorSpaceRelease(colorSpace);

    if (context == nullptr) {
        return false;
    }

    CGImageRef image =
        CGBitmapContextCreateImage(
            context);
    CGContextRelease(context);

    if (image == nullptr) {
        return false;
    }

    NSURL* url =
        [NSURL
            fileURLWithPath:
                [NSString
                    stringWithUTF8String:
                        path.c_str()]];

    CGImageDestinationRef destination =
        CGImageDestinationCreateWithURL(
            (__bridge CFURLRef)url,
            CFSTR("public.png"),
            1,
            nullptr);

    if (destination == nullptr) {
        CGImageRelease(image);
        return false;
    }

    CGImageDestinationAddImage(
        destination,
        image,
        nullptr);

    const bool result =
        CGImageDestinationFinalize(
            destination);

    CFRelease(destination);
    CGImageRelease(image);
    return result;
}

bool WaitForWriterInput(
    AVAssetWriterInput* input) {
    for (int attempt = 0;
         attempt < 5000;
         ++attempt) {
        if (input.readyForMoreMediaData) {
            return true;
        }

        [NSThread
            sleepForTimeInterval:0.001];
    }

    return false;
}

bool CreateVideo(
    const std::string& path) {
    NSString* nsPath =
        [NSString
            stringWithUTF8String:
                path.c_str()];

    [[NSFileManager defaultManager]
        removeItemAtPath:nsPath
                   error:nil];

    AVAssetWriter* writer =
        [[AVAssetWriter alloc]
            initWithURL:
                [NSURL fileURLWithPath:nsPath]
               fileType:
                   AVFileTypeQuickTimeMovie
                  error:nil];

    if (writer == nil) {
        return false;
    }

    NSDictionary* settings = @{
        AVVideoCodecKey :
            AVVideoCodecTypeH264,
        AVVideoWidthKey :
            @64,
        AVVideoHeightKey :
            @48,
        AVVideoCompressionPropertiesKey :
            @{
                AVVideoAverageBitRateKey :
                    @150000
            }
    };

    AVAssetWriterInput* input =
        [AVAssetWriterInput
            assetWriterInputWithMediaType:
                AVMediaTypeVideo
                          outputSettings:
                              settings];

    NSDictionary* attributes = @{
        (NSString*)
            kCVPixelBufferPixelFormatTypeKey :
                @(kCVPixelFormatType_32BGRA),
        (NSString*)
            kCVPixelBufferWidthKey :
                @64,
        (NSString*)
            kCVPixelBufferHeightKey :
                @48
    };

    AVAssetWriterInputPixelBufferAdaptor*
        adaptor =
        [AVAssetWriterInputPixelBufferAdaptor
            assetWriterInputPixelBufferAdaptorWithAssetWriterInput:
                input
            sourcePixelBufferAttributes:
                attributes];

    if (![writer canAddInput:input]) {
        return false;
    }

    [writer addInput:input];

    if (![writer startWriting]) {
        return false;
    }

    [writer
        startSessionAtSourceTime:
            kCMTimeZero];

    for (int index = 0;
         index < 12;
         ++index) {
        if (!WaitForWriterInput(input)) {
            return false;
        }

        CVPixelBufferRef buffer =
            nullptr;

        if (CVPixelBufferPoolCreatePixelBuffer(
                kCFAllocatorDefault,
                adaptor.pixelBufferPool,
                &buffer) !=
                kCVReturnSuccess ||
            buffer == nullptr) {
            return false;
        }

        CVPixelBufferLockBaseAddress(
            buffer,
            0);

        std::memset(
            CVPixelBufferGetBaseAddress(
                buffer),
            30 + index,
            CVPixelBufferGetBytesPerRow(
                buffer) *
                CVPixelBufferGetHeight(
                    buffer));

        CVPixelBufferUnlockBaseAddress(
            buffer,
            0);

        const BOOL appended =
            [adaptor
                appendPixelBuffer:buffer
             withPresentationTime:
                 CMTimeMake(index, 30)];

        CVPixelBufferRelease(buffer);

        if (!appended) {
            return false;
        }
    }

    [input markAsFinished];

    dispatch_semaphore_t semaphore =
        dispatch_semaphore_create(0);

    [writer
        finishWritingWithCompletionHandler:^{
            dispatch_semaphore_signal(
                semaphore);
        }];

    return
        dispatch_semaphore_wait(
            semaphore,
            dispatch_time(
                DISPATCH_TIME_NOW,
                static_cast<int64_t>(
                    10 * NSEC_PER_SEC))) == 0 &&
        writer.status ==
            AVAssetWriterStatusCompleted;
}

bool FileExists(
    const std::string& path) {
    return [[NSFileManager defaultManager]
        fileExistsAtPath:
            [NSString
                stringWithUTF8String:
                    path.c_str()]];
}

std::vector<std::string> OwnedFiles(
    const std::string& directory) {
    NSString* nsDirectory =
        [NSString
            stringWithUTF8String:
                directory.c_str()];

    NSArray<NSString*>* entries =
        [[NSFileManager defaultManager]
            contentsOfDirectoryAtPath:
                nsDirectory
                              error:nil];

    std::vector<std::string> result;

    for (NSString* entry in entries) {
        result.push_back(
            ToStd(
                [nsDirectory
                    stringByAppendingPathComponent:
                        entry]));
    }

    return result;
}

std::string FindStagedOtherThan(
    const std::string& directory,
    const std::string& excluded) {
    for (const auto& path :
         OwnedFiles(directory)) {
        if (path != excluded) {
            return path;
        }
    }

    return {};
}

void RemoveTree(
    const std::string& root) {
    [[NSFileManager defaultManager]
        removeItemAtPath:
            [NSString
                stringWithUTF8String:
                    root.c_str()]
                   error:nil];
}

bool SamePersistentState(
    const ProductControlSnapshot& left,
    const ProductControlSnapshot& right) {
    return
        left.enabled == right.enabled &&
        left.mediaKind == right.mediaKind &&
        left.mediaPath == right.mediaPath &&
        left.selectionGeneration ==
            right.selectionGeneration &&
        left.loopEnabled ==
            right.loopEnabled &&
        left.playbackIntent ==
            right.playbackIntent;
}

bool LoadPersisted(
    const std::string& controlPath,
    ProductControlSnapshot* snapshot) {
    SharedControlStore store(
        controlPath,
        "com.vcampro.test.lost-update.read");
    return store.load(snapshot);
}

class CommitBarrier final {
public:
    ProductControlOwner::CommitGate makeGate(
        SelectionCompletionGate& gate,
        std::uint64_t requestToken) {
        return
            [this, &gate, requestToken](
                const ProductControlOwner::
                    CommitAction&
                        commitAction) {
                {
                    std::unique_lock<std::mutex>
                        lock(mutex_);

                    reached_ = true;
                    condition_.notify_all();

                    condition_.wait(
                        lock,
                        [this] {
                            return resume_;
                        });
                }

                return gate.commitIfCurrent(
                    requestToken,
                    commitAction);
            };
    }

    void waitUntilReached() {
        std::unique_lock<std::mutex>
            lock(mutex_);

        condition_.wait(
            lock,
            [this] {
                return reached_;
            });
    }

    void resume() {
        {
            std::lock_guard<std::mutex>
                lock(mutex_);
            resume_ = true;
        }

        condition_.notify_all();
    }

private:
    std::mutex mutex_;
    std::condition_variable condition_;
    bool reached_ = false;
    bool resume_ = false;
};

class StartBarrier final {
public:
    void wait() {
        std::unique_lock<std::mutex>
            lock(mutex_);

        ++arrived_;
        condition_.notify_all();

        condition_.wait(
            lock,
            [this] {
                return released_;
            });
    }

    void releaseWhenBothArrived() {
        std::unique_lock<std::mutex>
            lock(mutex_);

        condition_.wait(
            lock,
            [this] {
                return arrived_ == 2;
            });

        released_ = true;
        lock.unlock();
        condition_.notify_all();
    }

private:
    std::mutex mutex_;
    std::condition_variable condition_;
    int arrived_ = 0;
    bool released_ = false;
};

struct Fixture {
    std::string root;
    std::string controlPath;
    std::string mediaDirectory;
    std::string photoA;
    std::string photoB;
    std::string videoA;
    std::string videoB;
};

bool BuildFixture(
    Fixture* fixture) {
    if (fixture == nullptr) {
        return false;
    }

    fixture->root =
        TempRoot();
    fixture->controlPath =
        fixture->root +
        "/control.plist";
    fixture->mediaDirectory =
        fixture->root +
        "/Media";

    if (!CreateDirectory(
            fixture->root)) {
        return false;
    }

    fixture->photoA =
        TempFile(
            fixture->root,
            "photo-a",
            @"png");
    fixture->photoB =
        TempFile(
            fixture->root,
            "photo-b",
            @"png");
    fixture->videoA =
        TempFile(
            fixture->root,
            "video-a",
            @"mov");
    fixture->videoB =
        TempFile(
            fixture->root,
            "video-b",
            @"mov");

    return
        CreatePhoto(
            fixture->photoA,
            80) &&
        CreatePhoto(
            fixture->photoB,
            180) &&
        CreateVideo(
            fixture->videoA) &&
        CreateVideo(
            fixture->videoB);
}

bool BeginClaimedRequest(
    SelectionCompletionGate* gate,
    std::uint64_t* token) {
    if (gate == nullptr ||
        token == nullptr) {
        return false;
    }

    *token =
        gate->beginRequest();

    return
        gate->accept(*token) &&
        gate->claimFileCompletion(
            *token);
}

bool TestClearInvalidatesInflightSelection() {
    Fixture fixture;
    CHECK(BuildFixture(&fixture));

    ProductControlOwner owner(
        fixture.controlPath,
        "com.vcampro.test.clear-authority",
        fixture.mediaDirectory);

    CHECK(owner.selectFromTemporaryPath(
        fixture.photoA,
        ProductMediaKind::Photo,
        nullptr));

    const auto before =
        owner.snapshot();

    SelectionCompletionGate gate;
    std::uint64_t token = 0;
    CHECK(BeginClaimedRequest(
        &gate,
        &token));

    CommitBarrier barrier;
    bool selectionResult = true;

    std::thread selection(
        [&] {
            selectionResult =
                owner.selectFromTemporaryPath(
                    fixture.photoB,
                    ProductMediaKind::Photo,
                    barrier.makeGate(
                        gate,
                        token),
                    nullptr);
        });

    barrier.waitUntilReached();

    const std::string staged =
        FindStagedOtherThan(
            fixture.mediaDirectory,
            before.mediaPath);

    CHECK(!staged.empty());
    CHECK(FileExists(staged));

    CHECK(owner.clearMedia());

    const auto cleared =
        owner.snapshot();

    CHECK(
        cleared.mediaKind ==
        ProductMediaKind::None);
    CHECK(cleared.mediaPath.empty());
    CHECK(
        cleared.playbackIntent ==
        ProductPlaybackIntent::Stopped);
    CHECK(
        cleared.selectionGeneration ==
        before.selectionGeneration + 1);

    barrier.resume();
    selection.join();

    CHECK(!selectionResult);
    CHECK(!FileExists(staged));

    const auto after =
        owner.snapshot();

    CHECK(
        after.mediaKind ==
        ProductMediaKind::None);
    CHECK(after.mediaPath.empty());
    CHECK(
        after.selectionGeneration ==
        cleared.selectionGeneration);
    CHECK(
        after.playbackIntent ==
        ProductPlaybackIntent::Stopped);

    ProductControlSnapshot persisted;
    CHECK(LoadPersisted(
        fixture.controlPath,
        &persisted));
    CHECK(SamePersistentState(
        after,
        persisted));

    RemoveTree(fixture.root);
    return true;
}

bool TestLatestEnabledPreserved() {
    Fixture fixture;
    CHECK(BuildFixture(&fixture));

    ProductControlOwner owner(
        fixture.controlPath,
        "com.vcampro.test.enabled-rebase",
        fixture.mediaDirectory);

    CHECK(owner.selectFromTemporaryPath(
        fixture.photoA,
        ProductMediaKind::Photo,
        nullptr));
    CHECK(owner.setEnabled(false));

    const auto before =
        owner.snapshot();

    SelectionCompletionGate gate;
    std::uint64_t token = 0;
    CHECK(BeginClaimedRequest(
        &gate,
        &token));

    CommitBarrier barrier;
    bool selectionResult = false;

    std::thread selection(
        [&] {
            selectionResult =
                owner.selectFromTemporaryPath(
                    fixture.photoB,
                    ProductMediaKind::Photo,
                    barrier.makeGate(
                        gate,
                        token),
                    nullptr);
        });

    barrier.waitUntilReached();

    CHECK(owner.setEnabled(true));

    barrier.resume();
    selection.join();

    CHECK(selectionResult);

    const auto after =
        owner.snapshot();

    CHECK(after.enabled);
    CHECK(after.hasMedia());
    CHECK(
        after.mediaPath !=
        before.mediaPath);
    CHECK(
        after.selectionGeneration ==
        before.selectionGeneration + 1);

    ProductControlSnapshot persisted;
    CHECK(LoadPersisted(
        fixture.controlPath,
        &persisted));
    CHECK(SamePersistentState(
        after,
        persisted));

    RemoveTree(fixture.root);
    return true;
}

bool TestLatestPlaybackIntentPreserved() {
    Fixture fixture;
    CHECK(BuildFixture(&fixture));

    ProductControlOwner owner(
        fixture.controlPath,
        "com.vcampro.test.playback-rebase",
        fixture.mediaDirectory);

    CHECK(owner.selectFromTemporaryPath(
        fixture.photoA,
        ProductMediaKind::Photo,
        nullptr));

    SelectionCompletionGate gate;
    std::uint64_t token = 0;
    CHECK(BeginClaimedRequest(
        &gate,
        &token));

    CommitBarrier barrier;
    bool selectionResult = false;

    std::thread selection(
        [&] {
            selectionResult =
                owner.selectFromTemporaryPath(
                    fixture.photoB,
                    ProductMediaKind::Photo,
                    barrier.makeGate(
                        gate,
                        token),
                    nullptr);
        });

    barrier.waitUntilReached();

    CHECK(owner.setPlaybackIntent(
        ProductPlaybackIntent::Paused));

    barrier.resume();
    selection.join();

    CHECK(selectionResult);

    const auto after =
        owner.snapshot();

    CHECK(
        after.playbackIntent ==
        ProductPlaybackIntent::Paused);

    ProductControlSnapshot persisted;
    CHECK(LoadPersisted(
        fixture.controlPath,
        &persisted));
    CHECK(SamePersistentState(
        after,
        persisted));

    RemoveTree(fixture.root);
    return true;
}

bool TestLatestLoopStatePreserved() {
    Fixture fixture;
    CHECK(BuildFixture(&fixture));

    ProductControlOwner owner(
        fixture.controlPath,
        "com.vcampro.test.loop-rebase",
        fixture.mediaDirectory);

    CHECK(owner.selectFromTemporaryPath(
        fixture.videoA,
        ProductMediaKind::Video,
        nullptr));
    CHECK(owner.setLoopEnabled(false));

    SelectionCompletionGate gate;
    std::uint64_t token = 0;
    CHECK(BeginClaimedRequest(
        &gate,
        &token));

    CommitBarrier barrier;
    bool selectionResult = false;

    std::thread selection(
        [&] {
            selectionResult =
                owner.selectFromTemporaryPath(
                    fixture.videoB,
                    ProductMediaKind::Video,
                    barrier.makeGate(
                        gate,
                        token),
                    nullptr);
        });

    barrier.waitUntilReached();

    CHECK(owner.setLoopEnabled(true));

    barrier.resume();
    selection.join();

    CHECK(selectionResult);

    const auto after =
        owner.snapshot();

    CHECK(
        after.mediaKind ==
        ProductMediaKind::Video);
    CHECK(after.loopEnabled);

    ProductControlSnapshot persisted;
    CHECK(LoadPersisted(
        fixture.controlPath,
        &persisted));
    CHECK(SamePersistentState(
        after,
        persisted));

    RemoveTree(fixture.root);
    return true;
}

bool TestConcurrentOrthogonalMutationsPreserved() {
    Fixture fixture;
    CHECK(BuildFixture(&fixture));

    ProductControlOwner owner(
        fixture.controlPath,
        "com.vcampro.test.concurrent-controls",
        fixture.mediaDirectory);

    CHECK(owner.selectFromTemporaryPath(
        fixture.photoA,
        ProductMediaKind::Photo,
        nullptr));
    CHECK(owner.setEnabled(false));
    CHECK(owner.setPlaybackIntent(
        ProductPlaybackIntent::Playing));

    StartBarrier barrier;
    bool enabledResult = false;
    bool playbackResult = false;

    std::thread enabledThread(
        [&] {
            barrier.wait();
            enabledResult =
                owner.setEnabled(true);
        });

    std::thread playbackThread(
        [&] {
            barrier.wait();
            playbackResult =
                owner.setPlaybackIntent(
                    ProductPlaybackIntent::Paused);
        });

    barrier.releaseWhenBothArrived();

    enabledThread.join();
    playbackThread.join();

    CHECK(enabledResult);
    CHECK(playbackResult);

    const auto after =
        owner.snapshot();

    CHECK(after.enabled);
    CHECK(
        after.playbackIntent ==
        ProductPlaybackIntent::Paused);
    CHECK(after.hasMedia());

    ProductControlSnapshot persisted;
    CHECK(LoadPersisted(
        fixture.controlPath,
        &persisted));
    CHECK(SamePersistentState(
        after,
        persisted));

    RemoveTree(fixture.root);
    return true;
}

void Run(
    const char* name,
    const std::function<bool()>& test) {
    ++gTests;

    const bool passed =
        test();

    std::cout
        << (passed ? "PASS " : "FAIL ")
        << name
        << std::endl;

    if (!passed) {
        ++gFailures;
    }
}

}  // namespace

int main() {
    @autoreleasepool {
        Run(
            "clear invalidates inflight selection",
            TestClearInvalidatesInflightSelection);
        Run(
            "latest enabled state preserved",
            TestLatestEnabledPreserved);
        Run(
            "latest playback intent preserved",
            TestLatestPlaybackIntentPreserved);
        Run(
            "latest video loop state preserved",
            TestLatestLoopStatePreserved);
        Run(
            "concurrent orthogonal mutations preserved",
            TestConcurrentOrthogonalMutationsPreserved);

        std::cout
            << "Product control lost-update tests run: "
            << gTests
            << ", failures: "
            << gFailures
            << std::endl;

        return gFailures == 0
            ? 0
            : 1;
    }
}
