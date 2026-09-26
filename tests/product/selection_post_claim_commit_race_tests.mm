#include "ProductControlOwner.h"
#include "SelectionCompletionGate.h"

#import <Foundation/Foundation.h>
#import <ImageIO/ImageIO.h>

#include <CoreGraphics/CoreGraphics.h>

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
using vcam::product::ProductMediaKind;

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
                        @"vcam-post-claim-%@",
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

std::string TempPhoto(
    const std::string& root,
    const char* label) {
    NSString* name =
        [NSString
            stringWithFormat:
                @"%s-%@.png",
                label,
                NSUUID.UUID.UUIDString];

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

    const bool ok =
        CGImageDestinationFinalize(
            destination);

    CFRelease(destination);
    CGImageRelease(image);
    return ok;
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
    const std::string& mediaDirectory) {
    NSMutableArray<NSString*>* names =
        [NSMutableArray array];

    NSArray<NSString*>* entries =
        [[NSFileManager defaultManager]
            contentsOfDirectoryAtPath:
                [NSString
                    stringWithUTF8String:
                        mediaDirectory.c_str()]
                              error:nil];

    if (entries != nil) {
        [names addObjectsFromArray:entries];
    }

    std::vector<std::string> result;
    result.reserve(names.count);

    NSString* directory =
        [NSString
            stringWithUTF8String:
                mediaDirectory.c_str()];

    for (NSString* name in names) {
        result.push_back(
            ToStd(
                [directory
                    stringByAppendingPathComponent:
                        name]));
    }

    return result;
}

std::string FindStagedOtherThan(
    const std::string& mediaDirectory,
    const std::string& excluded) {
    for (const auto& path :
         OwnedFiles(mediaDirectory)) {
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

struct Fixture {
    std::string root;
    std::string mediaDirectory;
    std::string previousSource;
    std::string aSource;
    std::string bSource;
};

bool BuildFixture(
    Fixture* fixture) {
    if (fixture == nullptr) {
        return false;
    }

    fixture->root =
        TempRoot();
    fixture->mediaDirectory =
        fixture->root + "/Media";

    if (!CreateDirectory(
            fixture->root)) {
        return false;
    }

    fixture->previousSource =
        TempPhoto(
            fixture->root,
            "previous");
    fixture->aSource =
        TempPhoto(
            fixture->root,
            "request-a");
    fixture->bSource =
        TempPhoto(
            fixture->root,
            "request-b");

    return
        CreatePhoto(
            fixture->previousSource,
            60) &&
        CreatePhoto(
            fixture->aSource,
            120) &&
        CreatePhoto(
            fixture->bSource,
            200);
}

bool PrepareOwner(
    const Fixture& fixture,
    ProductControlOwner* owner) {
    return owner != nullptr &&
        owner->selectFromTemporaryPath(
            fixture.previousSource,
            ProductMediaKind::Photo,
            nullptr);
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

bool TestCancellationBlocksAAndCleansStage() {
    Fixture fixture;
    CHECK(BuildFixture(&fixture));

    ProductControlOwner owner(
        fixture.root + "/control.plist",
        "com.vcampro.test.postclaim.cancel",
        fixture.mediaDirectory);

    CHECK(PrepareOwner(
        fixture,
        &owner));

    const auto before =
        owner.snapshot();

    SelectionCompletionGate gate;
    std::uint64_t a = 0;
    CHECK(BeginClaimedRequest(
        &gate,
        &a));

    CommitBarrier barrier;
    bool aResult = true;
    std::string aError;

    std::thread worker(
        [&] {
            aResult =
                owner.selectFromTemporaryPath(
                    fixture.aSource,
                    ProductMediaKind::Photo,
                    barrier.makeGate(
                        gate,
                        a),
                    &aError);
        });

    barrier.waitUntilReached();

    const std::string aStaged =
        FindStagedOtherThan(
            fixture.mediaDirectory,
            before.mediaPath);

    CHECK(!aStaged.empty());
    CHECK(FileExists(aStaged));
    CHECK(FileExists(before.mediaPath));

    const std::uint64_t b =
        gate.beginRequest();
    CHECK(gate.accept(b));

    barrier.resume();
    worker.join();

    CHECK(!aResult);
    CHECK(!aError.empty());

    const auto after =
        owner.snapshot();

    CHECK(
        after.mediaPath ==
        before.mediaPath);
    CHECK(
        after.selectionGeneration ==
        before.selectionGeneration);
    CHECK(FileExists(before.mediaPath));
    CHECK(!FileExists(aStaged));

    RemoveTree(fixture.root);
    return true;
}

bool TestFailedBDoesNotReviveA() {
    Fixture fixture;
    CHECK(BuildFixture(&fixture));

    ProductControlOwner owner(
        fixture.root + "/control.plist",
        "com.vcampro.test.postclaim.fail",
        fixture.mediaDirectory);

    CHECK(PrepareOwner(
        fixture,
        &owner));

    const auto before =
        owner.snapshot();

    SelectionCompletionGate gate;
    std::uint64_t a = 0;
    CHECK(BeginClaimedRequest(
        &gate,
        &a));

    CommitBarrier barrier;
    bool aResult = true;

    std::thread worker(
        [&] {
            aResult =
                owner.selectFromTemporaryPath(
                    fixture.aSource,
                    ProductMediaKind::Photo,
                    barrier.makeGate(
                        gate,
                        a),
                    nullptr);
        });

    barrier.waitUntilReached();

    const std::string aStaged =
        FindStagedOtherThan(
            fixture.mediaDirectory,
            before.mediaPath);

    CHECK(!aStaged.empty());

    std::uint64_t b = 0;
    CHECK(BeginClaimedRequest(
        &gate,
        &b));

    std::string bError;
    CHECK(!owner.selectFromTemporaryPath(
        fixture.root + "/missing.png",
        ProductMediaKind::Photo,
        [&gate, b](
            const ProductControlOwner::
                CommitAction&
                    commitAction) {
            return gate.commitIfCurrent(
                b,
                commitAction);
        },
        &bError));
    CHECK(!bError.empty());

    barrier.resume();
    worker.join();

    CHECK(!aResult);

    const auto after =
        owner.snapshot();

    CHECK(
        after.mediaPath ==
        before.mediaPath);
    CHECK(
        after.selectionGeneration ==
        before.selectionGeneration);
    CHECK(FileExists(before.mediaPath));
    CHECK(!FileExists(aStaged));

    RemoveTree(fixture.root);
    return true;
}

bool TestSuccessfulBIsOnlyWinner() {
    Fixture fixture;
    CHECK(BuildFixture(&fixture));

    ProductControlOwner owner(
        fixture.root + "/control.plist",
        "com.vcampro.test.postclaim.win",
        fixture.mediaDirectory);

    CHECK(PrepareOwner(
        fixture,
        &owner));

    const auto before =
        owner.snapshot();

    SelectionCompletionGate gate;
    std::uint64_t a = 0;
    CHECK(BeginClaimedRequest(
        &gate,
        &a));

    CommitBarrier barrier;
    bool aResult = true;

    std::thread worker(
        [&] {
            aResult =
                owner.selectFromTemporaryPath(
                    fixture.aSource,
                    ProductMediaKind::Photo,
                    barrier.makeGate(
                        gate,
                        a),
                    nullptr);
        });

    barrier.waitUntilReached();

    const std::string aStaged =
        FindStagedOtherThan(
            fixture.mediaDirectory,
            before.mediaPath);

    CHECK(!aStaged.empty());

    std::uint64_t b = 0;
    CHECK(BeginClaimedRequest(
        &gate,
        &b));

    CHECK(owner.selectFromTemporaryPath(
        fixture.bSource,
        ProductMediaKind::Photo,
        [&gate, b](
            const ProductControlOwner::
                CommitAction&
                    commitAction) {
            return gate.commitIfCurrent(
                b,
                commitAction);
        },
        nullptr));

    const auto bWinner =
        owner.snapshot();

    CHECK(
        bWinner.mediaPath !=
        before.mediaPath);
    CHECK(
        bWinner.mediaPath !=
        aStaged);
    CHECK(
        bWinner.selectionGeneration ==
        before.selectionGeneration + 1);
    CHECK(FileExists(
        bWinner.mediaPath));

    barrier.resume();
    worker.join();

    CHECK(!aResult);

    const auto after =
        owner.snapshot();

    CHECK(
        after.mediaPath ==
        bWinner.mediaPath);
    CHECK(
        after.selectionGeneration ==
        bWinner.selectionGeneration);
    CHECK(!FileExists(aStaged));

    RemoveTree(fixture.root);
    return true;
}

bool TestACommitBeforeBStartRemainsValid() {
    Fixture fixture;
    CHECK(BuildFixture(&fixture));

    ProductControlOwner owner(
        fixture.root + "/control.plist",
        "com.vcampro.test.postclaim.order",
        fixture.mediaDirectory);

    CHECK(PrepareOwner(
        fixture,
        &owner));

    const auto before =
        owner.snapshot();

    SelectionCompletionGate gate;
    std::uint64_t a = 0;
    CHECK(BeginClaimedRequest(
        &gate,
        &a));

    CHECK(owner.selectFromTemporaryPath(
        fixture.aSource,
        ProductMediaKind::Photo,
        [&gate, a](
            const ProductControlOwner::
                CommitAction&
                    commitAction) {
            return gate.commitIfCurrent(
                a,
                commitAction);
        },
        nullptr));

    const auto aWinner =
        owner.snapshot();

    CHECK(
        aWinner.mediaPath !=
        before.mediaPath);
    CHECK(
        aWinner.selectionGeneration ==
        before.selectionGeneration + 1);
    CHECK(FileExists(
        aWinner.mediaPath));

    const std::uint64_t b =
        gate.beginRequest();
    CHECK(gate.accept(b));

    const auto afterBStart =
        owner.snapshot();

    CHECK(
        afterBStart.mediaPath ==
        aWinner.mediaPath);
    CHECK(
        afterBStart.selectionGeneration ==
        aWinner.selectionGeneration);

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
            "B cancellation blocks A and cleans stage",
            TestCancellationBlocksAAndCleansStage);
        Run(
            "failed B does not revive A",
            TestFailedBDoesNotReviveA);
        Run(
            "successful B is only winner",
            TestSuccessfulBIsOnlyWinner);
        Run(
            "A commit before B start remains valid",
            TestACommitBeforeBStartRemainsValid);

        std::cout
            << "Post-claim commit race tests run: "
            << gTests
            << ", failures: "
            << gFailures
            << std::endl;

        return gFailures == 0
            ? 0
            : 1;
    }
}
