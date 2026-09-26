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
#include <sys/stat.h>
#include <unistd.h>

namespace {

using vcam::product::ProductControlOwner;
using vcam::product::ProductControlSnapshot;
using vcam::product::ProductMediaKind;
using vcam::product::ProductPlaybackIntent;
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
                        @"vcam-storage-recovery-%@",
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

bool WriteText(
    const std::string& path,
    NSString* text = @"foreign") {
    return [text
        writeToFile:
            [NSString
                stringWithUTF8String:
                    path.c_str()]
           atomically:YES
             encoding:NSUTF8StringEncoding
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
    SharedMediaStager* stager,
    const std::string& source,
    std::uint64_t generation,
    std::string* path) {
    return
        stager != nullptr &&
        stager->stageAndValidate(
            source,
            ProductMediaKind::Photo,
            generation,
            path,
            nullptr);
}

bool SaveSnapshot(
    const Fixture& fixture,
    const ProductControlSnapshot& snapshot) {
    SharedControlStore store(
        fixture.controlPath,
        "com.vcampro.test.storage.save");
    return store.save(
        snapshot,
        false);
}

bool LoadSnapshot(
    const Fixture& fixture,
    ProductControlSnapshot* snapshot) {
    SharedControlStore store(
        fixture.controlPath,
        "com.vcampro.test.storage.load");
    return store.load(snapshot);
}

bool SameSnapshot(
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

ProductControlSnapshot ActivePhoto(
    const std::string& path,
    std::uint64_t generation,
    bool enabled = false) {
    ProductControlSnapshot snapshot;
    snapshot.enabled = enabled;
    snapshot.mediaKind =
        ProductMediaKind::Photo;
    snapshot.mediaPath = path;
    snapshot.selectionGeneration =
        generation;
    snapshot.loopEnabled = false;
    snapshot.playbackIntent =
        ProductPlaybackIntent::Playing;
    return snapshot;
}

bool TestValidOwnedPathRemovable() {
    Fixture fixture;
    CHECK(BuildFixture(&fixture));

    SharedMediaStager stager(
        fixture.mediaDirectory);

    std::string staged;
    CHECK(Stage(
        &stager,
        fixture.sourceA,
        1,
        &staged));
    CHECK(FileExists(staged));
    CHECK(stager.removeOwnedPath(
        staged));
    CHECK(!FileExists(staged));

    RemoveTree(fixture.root);
    return true;
}

bool TestSiblingPrefixRejected() {
    Fixture fixture;
    CHECK(BuildFixture(&fixture));

    const std::string sibling =
        fixture.mediaDirectory +
        "-sibling";
    CHECK(CreateDirectory(sibling));

    const std::string outside =
        sibling + "/" +
        OwnedName(
            1,
            "000000000001");
    CHECK(WriteText(outside));

    SharedMediaStager stager(
        fixture.mediaDirectory);

    CHECK(!stager.removeOwnedPath(
        outside));
    CHECK(FileExists(outside));

    RemoveTree(fixture.root);
    return true;
}

bool TestDotDotEscapeRejected() {
    Fixture fixture;
    CHECK(BuildFixture(&fixture));
    CHECK(CreateDirectory(
        fixture.mediaDirectory));

    const std::string basename =
        OwnedName(
            2,
            "000000000002");
    const std::string outside =
        fixture.root +
        "/" +
        basename;
    CHECK(WriteText(outside));

    const std::string escaped =
        fixture.mediaDirectory +
        "/../" +
        basename;

    SharedMediaStager stager(
        fixture.mediaDirectory);

    CHECK(!stager.removeOwnedPath(
        escaped));
    CHECK(FileExists(outside));

    RemoveTree(fixture.root);
    return true;
}

bool TestMediaDirectoryCannotBeRemoved() {
    Fixture fixture;
    CHECK(BuildFixture(&fixture));
    CHECK(CreateDirectory(
        fixture.mediaDirectory));

    SharedMediaStager stager(
        fixture.mediaDirectory);

    CHECK(!stager.removeOwnedPath(
        fixture.mediaDirectory));
    CHECK(FileExists(
        fixture.mediaDirectory));

    RemoveTree(fixture.root);
    return true;
}

bool TestSymlinkEscapeExternalSurvives() {
    Fixture fixture;
    CHECK(BuildFixture(&fixture));
    CHECK(CreateDirectory(
        fixture.mediaDirectory));

    const std::string external =
        fixture.root +
        "/external.png";
    CHECK(WriteText(external));

    const std::string link =
        fixture.mediaDirectory +
        "/" +
        OwnedName(
            3,
            "000000000003");

    CHECK(symlink(
        external.c_str(),
        link.c_str()) == 0);

    SharedMediaStager stager(
        fixture.mediaDirectory);

    CHECK(!stager.removeOwnedPath(
        link));
    CHECK(FileExists(external));

    RemoveTree(fixture.root);
    return true;
}

bool TestForeignFilePreservedByRecovery() {
    Fixture fixture;
    CHECK(BuildFixture(&fixture));
    CHECK(CreateDirectory(
        fixture.mediaDirectory));

    const std::string foreign =
        fixture.mediaDirectory +
        "/customer-note.txt";
    CHECK(WriteText(foreign));

    {
        ProductControlOwner owner(
            fixture.controlPath,
            "com.vcampro.test.storage.foreign",
            fixture.mediaDirectory);
        CHECK(!owner.snapshot().hasMedia());
    }

    CHECK(FileExists(foreign));

    RemoveTree(fixture.root);
    return true;
}

bool TestPreCommitOrphanRemoved() {
    Fixture fixture;
    CHECK(BuildFixture(&fixture));

    SharedMediaStager stager(
        fixture.mediaDirectory);

    std::string active;
    std::string orphan;
    CHECK(Stage(
        &stager,
        fixture.sourceA,
        1,
        &active));
    CHECK(Stage(
        &stager,
        fixture.sourceB,
        2,
        &orphan));
    CHECK(SaveSnapshot(
        fixture,
        ActivePhoto(
            active,
            1)));

    {
        ProductControlOwner owner(
            fixture.controlPath,
            "com.vcampro.test.storage.pre-orphan",
            fixture.mediaDirectory);
        CHECK(
            owner.snapshot().mediaPath ==
            active);
    }

    CHECK(!FileExists(orphan));

    RemoveTree(fixture.root);
    return true;
}

bool TestActiveSurvivesPreCommitRecovery() {
    Fixture fixture;
    CHECK(BuildFixture(&fixture));

    SharedMediaStager stager(
        fixture.mediaDirectory);

    std::string active;
    std::string orphan;
    CHECK(Stage(
        &stager,
        fixture.sourceA,
        4,
        &active));
    CHECK(Stage(
        &stager,
        fixture.sourceB,
        5,
        &orphan));
    CHECK(SaveSnapshot(
        fixture,
        ActivePhoto(
            active,
            4)));

    ProductControlOwner owner(
        fixture.controlPath,
        "com.vcampro.test.storage.pre-active",
        fixture.mediaDirectory);

    CHECK(FileExists(active));
    CHECK(
        owner.snapshot().mediaPath ==
        active);

    RemoveTree(fixture.root);
    return true;
}

bool TestPostCommitOldOrphanRemoved() {
    Fixture fixture;
    CHECK(BuildFixture(&fixture));

    SharedMediaStager stager(
        fixture.mediaDirectory);

    std::string oldPath;
    std::string currentPath;
    CHECK(Stage(
        &stager,
        fixture.sourceA,
        7,
        &oldPath));
    CHECK(Stage(
        &stager,
        fixture.sourceB,
        8,
        &currentPath));
    CHECK(SaveSnapshot(
        fixture,
        ActivePhoto(
            currentPath,
            8)));

    {
        ProductControlOwner owner(
            fixture.controlPath,
            "com.vcampro.test.storage.post-old",
            fixture.mediaDirectory);
        CHECK(
            owner.snapshot().mediaPath ==
            currentPath);
    }

    CHECK(!FileExists(oldPath));

    RemoveTree(fixture.root);
    return true;
}

bool TestCurrentSurvivesPostCommitRecovery() {
    Fixture fixture;
    CHECK(BuildFixture(&fixture));

    SharedMediaStager stager(
        fixture.mediaDirectory);

    std::string oldPath;
    std::string currentPath;
    CHECK(Stage(
        &stager,
        fixture.sourceA,
        10,
        &oldPath));
    CHECK(Stage(
        &stager,
        fixture.sourceB,
        11,
        &currentPath));
    CHECK(SaveSnapshot(
        fixture,
        ActivePhoto(
            currentPath,
            11)));

    ProductControlOwner owner(
        fixture.controlPath,
        "com.vcampro.test.storage.post-current",
        fixture.mediaDirectory);

    CHECK(FileExists(currentPath));
    CHECK(
        owner.snapshot().mediaPath ==
        currentPath);

    RemoveTree(fixture.root);
    return true;
}

bool TestMissingActiveRepairsFailOpen() {
    Fixture fixture;
    CHECK(BuildFixture(&fixture));
    CHECK(CreateDirectory(
        fixture.mediaDirectory));

    const std::string missing =
        fixture.mediaDirectory +
        "/" +
        OwnedName(
            13,
            "000000000013");

    CHECK(SaveSnapshot(
        fixture,
        ActivePhoto(
            missing,
            13)));

    ProductControlOwner owner(
        fixture.controlPath,
        "com.vcampro.test.storage.missing",
        fixture.mediaDirectory);

    const auto repaired =
        owner.snapshot();

    CHECK(
        repaired.mediaKind ==
        ProductMediaKind::None);
    CHECK(repaired.mediaPath.empty());
    CHECK(
        repaired.selectionGeneration ==
        14);
    CHECK(!repaired.loopEnabled);
    CHECK(
        repaired.playbackIntent ==
        ProductPlaybackIntent::Stopped);

    RemoveTree(fixture.root);
    return true;
}

bool TestExternalActiveRepairsAndSurvives() {
    Fixture fixture;
    CHECK(BuildFixture(&fixture));

    const std::string external =
        fixture.root +
        "/external-active.png";
    CHECK(WriteText(external));

    CHECK(SaveSnapshot(
        fixture,
        ActivePhoto(
            external,
            20)));

    ProductControlOwner owner(
        fixture.controlPath,
        "com.vcampro.test.storage.external",
        fixture.mediaDirectory);

    CHECK(
        owner.snapshot().mediaKind ==
        ProductMediaKind::None);
    CHECK(
        owner.snapshot().mediaPath.empty());
    CHECK(FileExists(external));

    RemoveTree(fixture.root);
    return true;
}

bool TestEnabledSurvivesInvalidRepair() {
    Fixture fixture;
    CHECK(BuildFixture(&fixture));

    const std::string missing =
        fixture.mediaDirectory +
        "/" +
        OwnedName(
            30,
            "000000000030");

    CHECK(SaveSnapshot(
        fixture,
        ActivePhoto(
            missing,
            30,
            true)));

    ProductControlOwner owner(
        fixture.controlPath,
        "com.vcampro.test.storage.enabled",
        fixture.mediaDirectory);

    CHECK(owner.snapshot().enabled);
    CHECK(
        owner.snapshot().mediaKind ==
        ProductMediaKind::None);

    RemoveTree(fixture.root);
    return true;
}

bool TestRepairedPersistentEqualsMemory() {
    Fixture fixture;
    CHECK(BuildFixture(&fixture));

    const std::string missing =
        fixture.mediaDirectory +
        "/" +
        OwnedName(
            40,
            "000000000040");

    CHECK(SaveSnapshot(
        fixture,
        ActivePhoto(
            missing,
            40,
            true)));

    ProductControlOwner owner(
        fixture.controlPath,
        "com.vcampro.test.storage.coherent",
        fixture.mediaDirectory);

    ProductControlSnapshot persisted;
    CHECK(LoadSnapshot(
        fixture,
        &persisted));

    CHECK(SameSnapshot(
        owner.snapshot(),
        persisted));

    RemoveTree(fixture.root);
    return true;
}

bool TestStartupRecoveryIdempotent() {
    Fixture fixture;
    CHECK(BuildFixture(&fixture));

    SharedMediaStager stager(
        fixture.mediaDirectory);

    std::string active;
    std::string orphan;
    CHECK(Stage(
        &stager,
        fixture.sourceA,
        50,
        &active));
    CHECK(Stage(
        &stager,
        fixture.sourceB,
        51,
        &orphan));
    CHECK(SaveSnapshot(
        fixture,
        ActivePhoto(
            active,
            50,
            true)));

    ProductControlSnapshot first;

    {
        ProductControlOwner owner(
            fixture.controlPath,
            "com.vcampro.test.storage.idempotent.1",
            fixture.mediaDirectory);
        first =
            owner.snapshot();
    }

    CHECK(!FileExists(orphan));
    CHECK(FileExists(active));

    {
        ProductControlOwner owner(
            fixture.controlPath,
            "com.vcampro.test.storage.idempotent.2",
            fixture.mediaDirectory);

        CHECK(SameSnapshot(
            first,
            owner.snapshot()));
    }

    CHECK(FileExists(active));

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
            "valid owned staged path removable",
            TestValidOwnedPathRemovable);
        Run(
            "sibling prefix rejected",
            TestSiblingPrefixRejected);
        Run(
            "dotdot escape rejected",
            TestDotDotEscapeRejected);
        Run(
            "media directory cannot be removed",
            TestMediaDirectoryCannotBeRemoved);
        Run(
            "symlink escape external survives",
            TestSymlinkEscapeExternalSurvives);
        Run(
            "foreign file preserved by recovery",
            TestForeignFilePreservedByRecovery);
        Run(
            "pre-commit orphan removed",
            TestPreCommitOrphanRemoved);
        Run(
            "active survives pre-commit recovery",
            TestActiveSurvivesPreCommitRecovery);
        Run(
            "post-commit old orphan removed",
            TestPostCommitOldOrphanRemoved);
        Run(
            "current survives post-commit recovery",
            TestCurrentSurvivesPostCommitRecovery);
        Run(
            "missing active repairs fail-open",
            TestMissingActiveRepairsFailOpen);
        Run(
            "external active repairs and survives",
            TestExternalActiveRepairsAndSurvives);
        Run(
            "enabled survives invalid repair",
            TestEnabledSurvivesInvalidRepair);
        Run(
            "repaired persistent equals memory",
            TestRepairedPersistentEqualsMemory);
        Run(
            "startup recovery idempotent",
            TestStartupRecoveryIdempotent);

        std::cout
            << "Storage recovery tests run: "
            << gTests
            << ", failures: "
            << gFailures
            << std::endl;

        return gFailures == 0
            ? 0
            : 1;
    }
}
