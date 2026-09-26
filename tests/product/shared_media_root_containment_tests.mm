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
                        @"vcam-media-root-%@",
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

bool IsRealDirectory(
    const std::string& path) {
    struct stat info {};
    return
        lstat(
            path.c_str(),
            &info) == 0 &&
        S_ISDIR(info.st_mode) &&
        !S_ISLNK(info.st_mode);
}

std::size_t EntryCount(
    const std::string& directory) {
    NSArray<NSString*>* entries =
        [[NSFileManager defaultManager]
            contentsOfDirectoryAtPath:
                [NSString
                    stringWithUTF8String:
                        directory.c_str()]
                              error:nil];

    return entries == nil
        ? 0
        : entries.count;
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

bool TestSymlinkRootBlocksStaging() {
    const std::string root =
        TempRoot();
    const std::string external =
        root + "/external";
    const std::string media =
        root + "/Media";
    const std::string source =
        root + "/source.png";

    CHECK(CreateDirectory(root));
    CHECK(CreateDirectory(external));
    CHECK(CreatePhoto(source, 91));
    CHECK(symlink(
        external.c_str(),
        media.c_str()) == 0);
    CHECK(IsSymlink(media));

    const std::size_t before =
        EntryCount(external);

    SharedMediaStager stager(media);
    std::string staged;
    std::string error;

    CHECK(!stager.stageAndValidate(
        source,
        ProductMediaKind::Photo,
        1,
        &staged,
        &error));
    CHECK(!error.empty());
    CHECK(staged.empty());
    CHECK(FileExists(source));
    CHECK(IsSymlink(media));
    CHECK(
        EntryCount(external) ==
        before);

    RemoveTree(root);
    return true;
}

bool TestSymlinkRootBlocksRecoveryAndDeletion() {
    const std::string root =
        TempRoot();
    const std::string external =
        root + "/external";
    const std::string media =
        root + "/Media";

    CHECK(CreateDirectory(root));
    CHECK(CreateDirectory(external));

    const std::string name =
        OwnedName(
            2,
            "000000000002");
    const std::string externalFile =
        external + "/" + name;
    const std::string viaMedia =
        media + "/" + name;

    CHECK(WriteText(
        externalFile,
        @"preserve-external-target"));

    NSData* before =
        ReadData(externalFile);
    CHECK(before != nil);

    CHECK(symlink(
        external.c_str(),
        media.c_str()) == 0);
    CHECK(IsSymlink(media));

    SharedMediaStager stager(media);
    std::string error;

    CHECK(!stager.isExistingOwnedMediaPath(
        viaMedia));
    CHECK(!stager.removeOwnedPath(
        viaMedia));
    CHECK(!stager.reconcileOwnedMedia(
        "",
        &error));
    CHECK(!error.empty());

    CHECK(FileExists(externalFile));
    NSData* after =
        ReadData(externalFile);
    CHECK(after != nil);
    CHECK([before isEqualToData:after]);
    CHECK(IsSymlink(media));

    RemoveTree(root);
    return true;
}

bool TestValidMediaRootOperations() {
    const std::string root =
        TempRoot();
    const std::string media =
        root + "/Media";
    const std::string source =
        root + "/source.png";

    CHECK(CreateDirectory(root));
    CHECK(CreatePhoto(source, 123));
    CHECK(!FileExists(media));

    SharedMediaStager stager(media);
    std::string staged;
    std::string error;

    CHECK(stager.stageAndValidate(
        source,
        ProductMediaKind::Photo,
        3,
        &staged,
        &error));
    CHECK(IsRealDirectory(media));
    CHECK(FileExists(staged));
    CHECK(stager.isExistingOwnedMediaPath(
        staged));
    CHECK(stager.removeOwnedPath(
        staged));
    CHECK(!FileExists(staged));

    std::string orphan;
    CHECK(stager.stageAndValidate(
        source,
        ProductMediaKind::Photo,
        4,
        &orphan,
        &error));
    CHECK(FileExists(orphan));
    CHECK(stager.reconcileOwnedMedia(
        "",
        &error));
    CHECK(!FileExists(orphan));

    RemoveTree(root);
    return true;
}

bool TestAncestorSymlinkCompatible() {
    const std::string root =
        TempRoot();
    const std::string realParent =
        root + "/real-parent";
    const std::string linkedParent =
        root + "/linked-parent";
    const std::string realMedia =
        realParent + "/VCAM/Media";
    const std::string configuredMedia =
        linkedParent + "/VCAM/Media";
    const std::string source =
        root + "/source.png";

    CHECK(CreateDirectory(root));
    CHECK(CreateDirectory(realMedia));
    CHECK(CreatePhoto(source, 177));
    CHECK(symlink(
        realParent.c_str(),
        linkedParent.c_str()) == 0);
    CHECK(IsSymlink(linkedParent));
    CHECK(IsRealDirectory(
        configuredMedia));

    SharedMediaStager stager(
        configuredMedia);

    std::string staged;
    std::string error;
    CHECK(stager.stageAndValidate(
        source,
        ProductMediaKind::Photo,
        5,
        &staged,
        &error));
    CHECK(FileExists(staged));
    CHECK(stager.isExistingOwnedMediaPath(
        staged));

    CHECK(stager.reconcileOwnedMedia(
        staged,
        &error));
    CHECK(FileExists(staged));
    CHECK(stager.removeOwnedPath(
        staged));
    CHECK(!FileExists(staged));
    CHECK(IsSymlink(linkedParent));
    CHECK(IsRealDirectory(
        configuredMedia));

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
            "symlink root blocks staging",
            TestSymlinkRootBlocksStaging);
        Run(
            "symlink root blocks recovery and deletion",
            TestSymlinkRootBlocksRecoveryAndDeletion);
        Run(
            "valid media root operations",
            TestValidMediaRootOperations);
        Run(
            "ancestor symlink remains compatible",
            TestAncestorSymlinkCompatible);

        std::cout
            << "Media root containment tests run: "
            << gTests
            << ", failures: "
            << gFailures
            << std::endl;

        return gFailures == 0
            ? 0
            : 1;
    }
}
