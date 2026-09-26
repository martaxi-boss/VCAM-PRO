#include "SharedMediaStager.h"

#import <Foundation/Foundation.h>
#import <ImageIO/ImageIO.h>

#include <CoreGraphics/CoreGraphics.h>

#include <cstdint>
#include <cstring>
#include <functional>
#include <iostream>
#include <string>
#include <sys/stat.h>
#include <unistd.h>

namespace {

using vcam::product::ProductMediaKind;
using vcam::product::SetSharedMediaStagerTestHook;
using vcam::product::SharedMediaStager;
using vcam::product::SharedMediaStagerTestHook;
using vcam::product::SharedMediaStagerTestPoint;

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
                        @"vcam-media-root-toctou-%@",
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

bool WriteText(
    const std::string& path,
    NSString* text) {
    return [text
        writeToFile:
            [NSString
                stringWithUTF8String:
                    path.c_str()]
           atomically:YES
             encoding:NSUTF8StringEncoding
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

bool FileExists(
    const std::string& path) {
    return [[NSFileManager defaultManager]
        fileExistsAtPath:
            [NSString
                stringWithUTF8String:
                    path.c_str()]];
}

bool IsSymlink(
    const std::string& path) {
    struct stat info {};
    return
        lstat(
            path.c_str(),
            &info) == 0 &&
        S_ISLNK(info.st_mode);
}

std::size_t GeneratedEntryCount(
    const std::string& directory) {
    NSArray<NSString*>* entries =
        [[NSFileManager defaultManager]
            contentsOfDirectoryAtPath:
                [NSString
                    stringWithUTF8String:
                        directory.c_str()]
                              error:nil];

    if (entries == nil) {
        return 0;
    }

    std::size_t count = 0;
    for (NSString* entry in entries) {
        if ([entry hasPrefix:@"media-"]) {
            ++count;
        }
    }
    return count;
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

std::string OwnedName(
    std::uint64_t generation,
    const char* suffix) {
    return
        "media-" +
        std::to_string(generation) +
        "-00000000-0000-0000-0000-" +
        std::string(suffix) +
        ".png";
}

bool SwapRoot(
    const std::string& media,
    const std::string& detached,
    const std::string& external) {
    return
        rename(
            media.c_str(),
            detached.c_str()) == 0 &&
        symlink(
            external.c_str(),
            media.c_str()) == 0;
}

class HookReset final {
public:
    ~HookReset() {
        SetSharedMediaStagerTestHook(
            SharedMediaStagerTestHook{});
    }
};

bool TestStagingSwapBeforeCreateBlocked() {
    const std::string root =
        TempRoot();
    const std::string media =
        root + "/Media";
    const std::string detached =
        root + "/Media-detached";
    const std::string external =
        root + "/external";
    const std::string source =
        root + "/source.png";

    CHECK(CreateDirectory(media));
    CHECK(CreateDirectory(external));
    CHECK(CreatePhoto(source, 37));

    bool fired = false;
    HookReset reset;
    SetSharedMediaStagerTestHook(
        [&](SharedMediaStagerTestPoint point) {
            if (!fired &&
                point ==
                    SharedMediaStagerTestPoint::
                        BeforeDestinationCreate) {
                fired =
                    SwapRoot(
                        media,
                        detached,
                        external);
            }
        });

    SharedMediaStager stager(media);
    std::string staged;
    std::string error;

    CHECK(!stager.stageAndValidate(
        source,
        ProductMediaKind::Photo,
        101,
        &staged,
        &error));
    CHECK(fired);
    CHECK(staged.empty());
    CHECK(!error.empty());
    CHECK(FileExists(source));
    CHECK(IsSymlink(media));
    CHECK(
        GeneratedEntryCount(external) ==
        0);
    CHECK(
        GeneratedEntryCount(detached) ==
        0);

    RemoveTree(root);
    return true;
}

bool TestStagingPublicationIdentityVerified() {
    const std::string root =
        TempRoot();
    const std::string media =
        root + "/Media";
    const std::string detached =
        root + "/Media-detached";
    const std::string external =
        root + "/external";
    const std::string source =
        root + "/source.png";

    CHECK(CreateDirectory(media));
    CHECK(CreateDirectory(external));
    CHECK(CreatePhoto(source, 73));

    bool fired = false;
    HookReset reset;
    SetSharedMediaStagerTestHook(
        [&](SharedMediaStagerTestPoint point) {
            if (!fired &&
                point ==
                    SharedMediaStagerTestPoint::
                        BeforePublish) {
                fired =
                    SwapRoot(
                        media,
                        detached,
                        external);
            }
        });

    SharedMediaStager stager(media);
    std::string staged;
    std::string error;

    CHECK(!stager.stageAndValidate(
        source,
        ProductMediaKind::Photo,
        102,
        &staged,
        &error));
    CHECK(fired);
    CHECK(staged.empty());
    CHECK(!error.empty());
    CHECK(FileExists(source));
    CHECK(IsSymlink(media));
    CHECK(
        GeneratedEntryCount(external) ==
        0);
    CHECK(
        GeneratedEntryCount(detached) ==
        0);

    RemoveTree(root);
    return true;
}

bool TestDeleteSwapCannotRedirect() {
    const std::string root =
        TempRoot();
    const std::string media =
        root + "/Media";
    const std::string detached =
        root + "/Media-detached";
    const std::string external =
        root + "/external";
    const std::string basename =
        OwnedName(
            201,
            "000000000201");
    const std::string trustedFile =
        media + "/" + basename;
    const std::string detachedFile =
        detached + "/" + basename;
    const std::string externalFile =
        external + "/" + basename;

    CHECK(CreateDirectory(media));
    CHECK(CreateDirectory(external));
    CHECK(WriteText(
        trustedFile,
        @"trusted-delete"));
    CHECK(WriteText(
        externalFile,
        @"external-preserve-delete"));

    NSData* externalBefore =
        ReadData(externalFile);
    CHECK(externalBefore != nil);

    bool fired = false;
    HookReset reset;
    SetSharedMediaStagerTestHook(
        [&](SharedMediaStagerTestPoint point) {
            if (!fired &&
                point ==
                    SharedMediaStagerTestPoint::
                        BeforeDelete) {
                fired =
                    SwapRoot(
                        media,
                        detached,
                        external);
            }
        });

    SharedMediaStager stager(media);

    CHECK(stager.removeOwnedPath(
        trustedFile));
    CHECK(fired);
    CHECK(IsSymlink(media));
    CHECK(!FileExists(detachedFile));
    CHECK(FileExists(externalFile));

    NSData* externalAfter =
        ReadData(externalFile);
    CHECK(externalAfter != nil);
    CHECK(
        [externalBefore
            isEqualToData:
                externalAfter]);

    RemoveTree(root);
    return true;
}

bool TestReconciliationSwapCannotRedirect() {
    const std::string root =
        TempRoot();
    const std::string media =
        root + "/Media";
    const std::string detached =
        root + "/Media-detached";
    const std::string external =
        root + "/external";
    const std::string basename =
        OwnedName(
            301,
            "000000000301");
    const std::string trustedFile =
        media + "/" + basename;
    const std::string detachedFile =
        detached + "/" + basename;
    const std::string externalFile =
        external + "/" + basename;

    CHECK(CreateDirectory(media));
    CHECK(CreateDirectory(external));
    CHECK(WriteText(
        trustedFile,
        @"trusted-reconcile"));
    CHECK(WriteText(
        externalFile,
        @"external-preserve-reconcile"));

    NSData* externalBefore =
        ReadData(externalFile);
    CHECK(externalBefore != nil);

    bool fired = false;
    HookReset reset;
    SetSharedMediaStagerTestHook(
        [&](SharedMediaStagerTestPoint point) {
            if (!fired &&
                point ==
                    SharedMediaStagerTestPoint::
                        BeforeReconcileDelete) {
                fired =
                    SwapRoot(
                        media,
                        detached,
                        external);
            }
        });

    SharedMediaStager stager(media);
    std::string error;

    CHECK(!stager.reconcileOwnedMedia(
        "",
        &error));
    CHECK(fired);
    CHECK(!error.empty());
    CHECK(IsSymlink(media));
    CHECK(!FileExists(detachedFile));
    CHECK(FileExists(externalFile));

    NSData* externalAfter =
        ReadData(externalFile);
    CHECK(externalAfter != nil);
    CHECK(
        [externalBefore
            isEqualToData:
                externalAfter]);

    RemoveTree(root);
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
            "staging swap before create blocked",
            TestStagingSwapBeforeCreateBlocked);
        Run(
            "staging publication identity verified",
            TestStagingPublicationIdentityVerified);
        Run(
            "delete swap cannot redirect",
            TestDeleteSwapCannotRedirect);
        Run(
            "reconciliation swap cannot redirect",
            TestReconciliationSwapCannotRedirect);

        std::cout
            << "Media root TOCTOU tests run: "
            << gTests
            << ", failures: "
            << gFailures
            << std::endl;

        return gFailures == 0
            ? 0
            : 1;
    }
}
