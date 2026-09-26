#include "ProductControlOwner.h"
#include "SharedControlStore.h"
#include "SharedMediaStager.h"

#import <Foundation/Foundation.h>
#import <ImageIO/ImageIO.h>

#include <CoreGraphics/CoreGraphics.h>

#include <cstdint>
#include <cstring>
#include <functional>
#include <iostream>
#include <string>
#include <vector>

namespace {

using vcam::product::ProductControlOwner;
using vcam::product::ProductControlSnapshot;
using vcam::product::ProductMediaKind;
using vcam::product::ProductPlaybackIntent;
using vcam::product::SharedControlLoadProvenance;
using vcam::product::SharedControlStore;
using vcam::product::SharedMediaStager;

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
                        @"vcam-store-provenance-%@",
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
        [NSURL fileURLWithPath:
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

void RemoveTree(
    const std::string& root) {
    [[NSFileManager defaultManager]
        removeItemAtPath:
            [NSString
                stringWithUTF8String:
                    root.c_str()]
                   error:nil];
}

NSData* ReadData(
    const std::string& path) {
    return [NSData
        dataWithContentsOfFile:
            [NSString
                stringWithUTF8String:
                    path.c_str()]];
}

bool WriteMalformed(
    const std::string& path) {
    static const unsigned char bytes[] = {
        0x00, 0xff, 0x13, 0x37,
        'c', 'o', 'r', 'r', 'u', 'p', 't'
    };

    NSData* data =
        [NSData
            dataWithBytes:bytes
                   length:sizeof(bytes)];

    return [data
        writeToFile:
            [NSString
                stringWithUTF8String:
                    path.c_str()]
           atomically:YES];
}

bool WriteTypeConfused(
    const std::string& path,
    const std::string& activePath) {
    NSString* mediaPath =
        [NSString
            stringWithUTF8String:
                activePath.c_str()];

    NSDictionary* dict = @{
        @"enabled" : @YES,
        @"mediaKind" : @[@"photo"],
        @"mediaPath" :
            mediaPath != nil
                ? mediaPath
                : @"",
        @"selectionGeneration" : @1,
        @"loopEnabled" : @NO,
        @"playbackIntent" : @"playing"
    };

    return [dict
        writeToFile:
            [NSString
                stringWithUTF8String:
                    path.c_str()]
           atomically:YES];
}

struct Fixture {
    std::string root;
    std::string controlPath;
    std::string mediaDirectory;
    std::string sourceA;
    std::string sourceB;
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
    fixture->sourceA =
        fixture->root +
        "/source-a.png";
    fixture->sourceB =
        fixture->root +
        "/source-b.png";

    return
        CreateDirectory(
            fixture->root) &&
        CreatePhoto(
            fixture->sourceA,
            70) &&
        CreatePhoto(
            fixture->sourceB,
            170);
}

bool Stage(
    const Fixture& fixture,
    const std::string& source,
    std::uint64_t generation,
    std::string* stagedPath) {
    SharedMediaStager stager(
        fixture.mediaDirectory);

    return stager.stageAndValidate(
        source,
        ProductMediaKind::Photo,
        generation,
        stagedPath,
        nullptr);
}

bool IsOwnerSafeFailOpen(
    const ProductControlOwner& owner) {
    const auto snapshot =
        owner.snapshot();

    return
        !snapshot.enabled &&
        snapshot.mediaKind ==
            ProductMediaKind::None &&
        snapshot.mediaPath.empty() &&
        !snapshot.loopEnabled &&
        snapshot.playbackIntent ==
            ProductPlaybackIntent::Stopped;
}

bool TestCorruptControlPreservesGeneratedMedia() {
    Fixture fixture;
    CHECK(BuildFixture(&fixture));

    std::string first;
    std::string second;
    CHECK(Stage(
        fixture,
        fixture.sourceA,
        1,
        &first));
    CHECK(Stage(
        fixture,
        fixture.sourceB,
        2,
        &second));

    CHECK(WriteMalformed(
        fixture.controlPath));

    NSData* before =
        ReadData(
            fixture.controlPath);
    CHECK(before != nil);

    SharedControlStore store(
        fixture.controlPath,
        "com.vcampro.test.provenance.corrupt");

    ProductControlSnapshot parsed;
    CHECK(
        store.loadWithProvenance(
            &parsed) ==
        SharedControlLoadProvenance::
            InvalidOrUnreadable);

    {
        ProductControlOwner owner(
            fixture.controlPath,
            "com.vcampro.test.provenance.corrupt.owner",
            fixture.mediaDirectory);

        CHECK(IsOwnerSafeFailOpen(
            owner));
    }

    CHECK(FileExists(first));
    CHECK(FileExists(second));

    NSData* after =
        ReadData(
            fixture.controlPath);
    CHECK(after != nil);
    CHECK([before isEqualToData:after]);

    RemoveTree(fixture.root);
    return true;
}

bool TestTypeConfusedControlPreservesGeneratedMedia() {
    Fixture fixture;
    CHECK(BuildFixture(&fixture));

    std::string first;
    std::string second;
    CHECK(Stage(
        fixture,
        fixture.sourceA,
        3,
        &first));
    CHECK(Stage(
        fixture,
        fixture.sourceB,
        4,
        &second));

    CHECK(WriteTypeConfused(
        fixture.controlPath,
        first));

    NSData* before =
        ReadData(
            fixture.controlPath);
    CHECK(before != nil);

    SharedControlStore store(
        fixture.controlPath,
        "com.vcampro.test.provenance.type");

    ProductControlSnapshot parsed;
    CHECK(
        store.loadWithProvenance(
            &parsed) ==
        SharedControlLoadProvenance::
            InvalidOrUnreadable);

    {
        ProductControlOwner owner(
            fixture.controlPath,
            "com.vcampro.test.provenance.type.owner",
            fixture.mediaDirectory);

        CHECK(IsOwnerSafeFailOpen(
            owner));
    }

    CHECK(FileExists(first));
    CHECK(FileExists(second));

    NSData* after =
        ReadData(
            fixture.controlPath);
    CHECK(after != nil);
    CHECK([before isEqualToData:after]);

    RemoveTree(fixture.root);
    return true;
}

bool TestAbsentControlAllowsRecovery() {
    Fixture fixture;
    CHECK(BuildFixture(&fixture));

    std::string orphan;
    CHECK(Stage(
        fixture,
        fixture.sourceA,
        5,
        &orphan));
    CHECK(FileExists(orphan));
    CHECK(!FileExists(
        fixture.controlPath));

    SharedControlStore store(
        fixture.controlPath,
        "com.vcampro.test.provenance.absent");

    ProductControlSnapshot parsed;
    CHECK(
        store.loadWithProvenance(
            &parsed) ==
        SharedControlLoadProvenance::
            Absent);

    {
        ProductControlOwner owner(
            fixture.controlPath,
            "com.vcampro.test.provenance.absent.owner",
            fixture.mediaDirectory);

        CHECK(IsOwnerSafeFailOpen(
            owner));
    }

    CHECK(!FileExists(orphan));
    CHECK(!FileExists(
        fixture.controlPath));

    RemoveTree(fixture.root);
    return true;
}

bool TestValidControlAllowsRecovery() {
    Fixture fixture;
    CHECK(BuildFixture(&fixture));

    std::string active;
    std::string orphan;
    CHECK(Stage(
        fixture,
        fixture.sourceA,
        6,
        &active));
    CHECK(Stage(
        fixture,
        fixture.sourceB,
        7,
        &orphan));

    ProductControlSnapshot snapshot;
    snapshot.enabled = true;
    snapshot.mediaKind =
        ProductMediaKind::Photo;
    snapshot.mediaPath =
        active;
    snapshot.selectionGeneration = 6;
    snapshot.loopEnabled = false;
    snapshot.playbackIntent =
        ProductPlaybackIntent::Playing;

    SharedControlStore store(
        fixture.controlPath,
        "com.vcampro.test.provenance.valid");
    CHECK(store.save(
        snapshot,
        false));

    ProductControlSnapshot parsed;
    CHECK(
        store.loadWithProvenance(
            &parsed) ==
        SharedControlLoadProvenance::
            Valid);

    {
        ProductControlOwner owner(
            fixture.controlPath,
            "com.vcampro.test.provenance.valid.owner",
            fixture.mediaDirectory);

        const auto loaded =
            owner.snapshot();

        CHECK(loaded.enabled);
        CHECK(
            loaded.mediaPath ==
            active);
        CHECK(
            loaded.selectionGeneration ==
            6);
    }

    CHECK(FileExists(active));
    CHECK(!FileExists(orphan));

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
            "corrupt control preserves generated media",
            TestCorruptControlPreservesGeneratedMedia);
        Run(
            "type confused control preserves generated media",
            TestTypeConfusedControlPreservesGeneratedMedia);
        Run(
            "absent control allows recovery",
            TestAbsentControlAllowsRecovery);
        Run(
            "valid control allows recovery",
            TestValidControlAllowsRecovery);

        std::cout
            << "Control provenance recovery tests run: "
            << gTests
            << ", failures: "
            << gFailures
            << std::endl;

        return gFailures == 0
            ? 0
            : 1;
    }
}
