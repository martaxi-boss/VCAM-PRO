#include "LocalVideoReader.h"

#import <AVFoundation/AVFoundation.h>
#import <Foundation/Foundation.h>

#include <CoreFoundation/CoreFoundation.h>
#include <CoreMedia/CoreMedia.h>
#include <CoreVideo/CoreVideo.h>

#include <utility>

namespace vcam::media_engine {

using frame_engine::FrameIdentity;
using frame_engine::FrameTiming;
using frame_engine::FrameValidity;
using frame_engine::OrientationState;
using frame_engine::PreparedFrame;
using frame_engine::ReaderErrorCode;
using frame_engine::ReaderState;

namespace {

bool IsAllowedOutputPixelFormat(OSType pixelFormat) noexcept {
    return pixelFormat == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange ||
           pixelFormat == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange;
}

bool LooksLikeRemoteOrURLString(const std::string& path) noexcept {
    return path.find("://") != std::string::npos;
}

std::string StringFromNSString(NSString* value) {
    if (value == nil) {
        return {};
    }
    const char* utf8 = [value UTF8String];
    return utf8 == nullptr ? std::string{} : std::string(utf8);
}

std::string ErrorMessageFromNSError(NSError* error,
                                    const char* fallback) {
    if (error != nil) {
        NSString* description = [error localizedDescription];
        if (description != nil) {
            return StringFromNSString(description);
        }
    }
    return fallback == nullptr ? std::string{} : std::string(fallback);
}

bool CreateReaderObjects(AVURLAsset* asset,
                         AVAssetTrack* track,
                         OSType outputPixelFormat,
                         AVAssetReader* __strong* readerOut,
                         AVAssetReaderTrackOutput* __strong* outputOut,
                         std::string* errorMessage) {
    if (asset == nil || track == nil ||
        !IsAllowedOutputPixelFormat(outputPixelFormat)) {
        if (errorMessage != nullptr) {
            *errorMessage = "Invalid reader configuration.";
        }
        return false;
    }

    NSError* readerError = nil;
    AVAssetReader* reader =
        [[AVAssetReader alloc] initWithAsset:asset error:&readerError];
    if (reader == nil) {
        if (errorMessage != nullptr) {
            *errorMessage =
                ErrorMessageFromNSError(readerError,
                                        "Unable to create AVAssetReader.");
        }
        return false;
    }

    NSDictionary* outputSettings = @{
        (NSString*)kCVPixelBufferPixelFormatTypeKey :
            @(outputPixelFormat)
    };

    AVAssetReaderTrackOutput* output =
        [[AVAssetReaderTrackOutput alloc] initWithTrack:track
                                        outputSettings:outputSettings];
    if (output == nil) {
        if (errorMessage != nullptr) {
            *errorMessage = "Unable to create video track output.";
        }
        return false;
    }

    output.alwaysCopiesSampleData = NO;

    if (![reader canAddOutput:output]) {
        if (errorMessage != nullptr) {
            *errorMessage = "AVAssetReader rejected the video track output.";
        }
        return false;
    }

    [reader addOutput:output];

    *readerOut = reader;
    *outputOut = output;
    return true;
}

CFStringRef CopyStringAttachment(CVPixelBufferRef pixelBuffer,
                                 CFStringRef key) {
    if (pixelBuffer == nullptr || key == nullptr) {
        return nullptr;
    }

    CFTypeRef value = CVBufferCopyAttachment(pixelBuffer, key, nullptr);
    if (value == nullptr) {
        return nullptr;
    }

    if (CFGetTypeID(value) != CFStringGetTypeID()) {
        CFRelease(value);
        return nullptr;
    }

    return static_cast<CFStringRef>(value);
}

ReadResult MakeSimpleResult(ReadResultKind kind,
                            ReaderErrorCode error = ReaderErrorCode::None,
                            const std::string& message = {}) {
    ReadResult result;
    result.kind = kind;
    result.error = error;
    result.message = message;
    return result;
}

}  // namespace

struct LocalVideoReader::Impl {
    AVURLAsset* asset = nil;
    AVAssetTrack* track = nil;
    AVAssetReader* reader = nil;
    AVAssetReaderTrackOutput* output = nil;

    LocalVideoReaderConfig config{};
    SourceVideoInfo sourceInfo{};

    std::string fileIdentity;
    std::string lastErrorMessage;
    ReaderErrorCode lastErrorCode = ReaderErrorCode::None;

    bool opened = false;
    bool started = false;
    bool cancelled = false;
};

LocalVideoReader::LocalVideoReader(frame_engine::FrameEngineState& state)
    : state_(state), impl_(std::make_unique<Impl>()) {}

LocalVideoReader::~LocalVideoReader() {
    if (impl_ != nullptr && impl_->reader != nil) {
        const AVAssetReaderStatus status = impl_->reader.status;
        if (status == AVAssetReaderStatusReading ||
            status == AVAssetReaderStatusUnknown) {
            [impl_->reader cancelReading];
        }
    }
}

bool LocalVideoReader::open(const std::string& filesystemPath,
                            const LocalVideoReaderConfig& config) {
    @autoreleasepool {
        clearLastError();

        if (!IsAllowedOutputPixelFormat(config.outputPixelFormat)) {
            setLastError(ReaderErrorCode::Unsupported,
                         "Stage B supports only explicit 420v or 420f output.");
            return false;
        }

        if (filesystemPath.empty() ||
            LooksLikeRemoteOrURLString(filesystemPath)) {
            setLastError(ReaderErrorCode::InitializationFailed,
                         "Stage B accepts local filesystem paths only.");
            return false;
        }

        NSString* rawPath =
            [[NSString alloc] initWithUTF8String:filesystemPath.c_str()];
        if (rawPath == nil) {
            setLastError(ReaderErrorCode::InitializationFailed,
                         "The filesystem path is not valid UTF-8.");
            return false;
        }

        NSString* standardizedPath = [rawPath stringByStandardizingPath];
        BOOL isDirectory = NO;
        BOOL exists =
            [[NSFileManager defaultManager] fileExistsAtPath:standardizedPath
                                                 isDirectory:&isDirectory];
        if (!exists || isDirectory) {
            setLastError(ReaderErrorCode::InitializationFailed,
                         "Local video path does not exist or is a directory.");
            return false;
        }

        NSURL* url = [NSURL fileURLWithPath:standardizedPath
                                isDirectory:NO];
        if (url == nil || !url.isFileURL) {
            setLastError(ReaderErrorCode::InitializationFailed,
                         "Unable to create a local file URL.");
            return false;
        }

        AVURLAsset* candidateAsset =
            [AVURLAsset URLAssetWithURL:url options:nil];
        if (candidateAsset == nil) {
            setLastError(ReaderErrorCode::InitializationFailed,
                         "Unable to create AVURLAsset.");
            return false;
        }

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
        NSArray<AVAssetTrack*>* videoTracks =
            [candidateAsset tracksWithMediaType:AVMediaTypeVideo];
#pragma clang diagnostic pop

        if (videoTracks.count == 0) {
            setLastError(ReaderErrorCode::Unsupported,
                         "Local media contains no video track.");
            return false;
        }

        AVAssetTrack* candidateTrack = videoTracks.firstObject;
        if (candidateTrack == nil) {
            setLastError(ReaderErrorCode::Unsupported,
                         "Unable to select the first video track.");
            return false;
        }

        AVAssetReader* candidateReader = nil;
        AVAssetReaderTrackOutput* candidateOutput = nil;
        std::string readerError;
        if (!CreateReaderObjects(candidateAsset,
                                 candidateTrack,
                                 config.outputPixelFormat,
                                 &candidateReader,
                                 &candidateOutput,
                                 &readerError)) {
            setLastError(ReaderErrorCode::InitializationFailed, readerError);
            return false;
        }

        SourceVideoInfo candidateInfo;
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
        candidateInfo.naturalSize = candidateTrack.naturalSize;
        candidateInfo.preferredTransform =
            candidateTrack.preferredTransform;
        candidateInfo.duration = candidateAsset.duration;
#pragma clang diagnostic pop
        candidateInfo.outputPixelFormat = config.outputPixelFormat;

        cancelCurrentReaderForReplacement();

        impl_->asset = candidateAsset;
        impl_->track = candidateTrack;
        impl_->reader = candidateReader;
        impl_->output = candidateOutput;
        impl_->config = config;
        impl_->sourceInfo = candidateInfo;
        impl_->fileIdentity = StringFromNSString(url.path);
        impl_->opened = true;
        impl_->started = false;
        impl_->cancelled = false;

        state_.selectOrReplaceMedia();
        if (!state_.markReaderReady()) {
            impl_->opened = false;
            impl_->reader = nil;
            impl_->output = nil;
            impl_->track = nil;
            impl_->asset = nil;
            setLastError(ReaderErrorCode::Unknown,
                         "FrameEngineState rejected reader-ready transition.");
            state_.markPlaybackFailed();
            return false;
        }

        return true;
    }
}

bool LocalVideoReader::start() {
    @autoreleasepool {
        clearLastError();

        if (!impl_->opened || impl_->reader == nil ||
            impl_->output == nil || impl_->cancelled) {
            setLastError(ReaderErrorCode::InitializationFailed,
                         "No configured local video reader is available.");
            return false;
        }

        if (impl_->started) {
            setLastError(ReaderErrorCode::InitializationFailed,
                         "Reader is already started.");
            return false;
        }

        if (!state_.start()) {
            setLastError(ReaderErrorCode::InitializationFailed,
                         "Playback state rejected start.");
            return false;
        }

        if (![impl_->reader startReading]) {
            const std::string message =
                ErrorMessageFromNSError(impl_->reader.error,
                                        "AVAssetReader startReading failed.");
            state_.markReaderFailed(ReaderErrorCode::InitializationFailed);
            state_.markPlaybackFailed();
            setLastError(ReaderErrorCode::InitializationFailed, message);
            return false;
        }

        if (!state_.beginReading()) {
            [impl_->reader cancelReading];
            state_.markReaderFailed(ReaderErrorCode::Unknown);
            state_.markPlaybackFailed();
            setLastError(ReaderErrorCode::Unknown,
                         "FrameEngineState rejected reading transition.");
            return false;
        }

        impl_->started = true;
        return true;
    }
}

ReadResult LocalVideoReader::readNext() {
    @autoreleasepool {
        if (impl_->cancelled) {
            return MakeSimpleResult(ReadResultKind::Cancelled,
                                    ReaderErrorCode::Cancelled,
                                    "Reader was cancelled.");
        }

        if (!impl_->opened || !impl_->started ||
            impl_->reader == nil || impl_->output == nil) {
            return MakeSimpleResult(ReadResultKind::NotReady);
        }

        CMSampleBufferRef sample =
            [impl_->output copyNextSampleBuffer];

        if (sample != nullptr) {
            CVPixelBufferRef pixelBuffer =
                CMSampleBufferGetImageBuffer(sample);

            if (pixelBuffer == nullptr) {
                CFRelease(sample);
                [impl_->reader cancelReading];
                impl_->started = false;
                state_.markReaderFailed(ReaderErrorCode::ReadFailed);
                state_.markPlaybackFailed();
                setLastError(ReaderErrorCode::ReadFailed,
                             "Video sample has no CVPixelBuffer image buffer.");
                return MakeSimpleResult(ReadResultKind::Failed,
                                        lastErrorCode(),
                                        lastErrorMessage());
            }

            FrameTiming timing;
            timing.sourcePTS =
                CMSampleBufferGetPresentationTimeStamp(sample);
            timing.presentationTimestamp = kCMTimeInvalid;
            timing.duration = CMSampleBufferGetDuration(sample);
            timing.producedAtHostTime = std::nullopt;

            const FrameIdentity identity = state_.nextFrameIdentity();

            CFStringRef colorPrimaries =
                CopyStringAttachment(pixelBuffer,
                                     kCVImageBufferColorPrimariesKey);
            CFStringRef transferFunction =
                CopyStringAttachment(pixelBuffer,
                                     kCVImageBufferTransferFunctionKey);
            CFStringRef yCbCrMatrix =
                CopyStringAttachment(pixelBuffer,
                                     kCVImageBufferYCbCrMatrixKey);
            CFDictionaryRef attachments =
                CVBufferCopyAttachments(
                    pixelBuffer,
                    kCVAttachmentMode_ShouldPropagate);

            PreparedFrame frame(pixelBuffer,
                                identity,
                                timing,
                                OrientationState::SourceNotNormalized,
                                FrameValidity::Ready,
                                colorPrimaries,
                                transferFunction,
                                yCbCrMatrix,
                                attachments);

            if (colorPrimaries != nullptr) {
                CFRelease(colorPrimaries);
            }
            if (transferFunction != nullptr) {
                CFRelease(transferFunction);
            }
            if (yCbCrMatrix != nullptr) {
                CFRelease(yCbCrMatrix);
            }
            if (attachments != nullptr) {
                CFRelease(attachments);
            }

            CFRelease(sample);

            if (!frame.isInternallyConsistent()) {
                frame.markFailed();
                [impl_->reader cancelReading];
                impl_->started = false;
                state_.markReaderFailed(ReaderErrorCode::ReadFailed);
                state_.markPlaybackFailed();
                setLastError(ReaderErrorCode::ReadFailed,
                             "PreparedFrame invariant validation failed.");
                return MakeSimpleResult(ReadResultKind::Failed,
                                        lastErrorCode(),
                                        lastErrorMessage());
            }

            ReadResult result;
            result.kind = ReadResultKind::Frame;
            result.frame.emplace(std::move(frame));
            return result;
        }

        switch (impl_->reader.status) {
            case AVAssetReaderStatusCompleted: {
                if (state_.readerStatus().state != ReaderState::Completed &&
                    !state_.markReaderCompleted()) {
                    impl_->started = false;
                    state_.markReaderFailed(ReaderErrorCode::Unknown);
                    state_.markPlaybackFailed();
                    setLastError(
                        ReaderErrorCode::Unknown,
                        "FrameEngineState rejected completed transition.");
                    return MakeSimpleResult(ReadResultKind::Failed,
                                            lastErrorCode(),
                                            lastErrorMessage());
                }

                if (!impl_->config.loopEnabled) {
                    impl_->started = false;
                    state_.markEnded();
                    return MakeSimpleResult(ReadResultKind::EndOfStream);
                }

                if (!state_.confirmLoopRestart()) {
                    impl_->started = false;
                    state_.markReaderFailed(ReaderErrorCode::Unknown);
                    state_.markPlaybackFailed();
                    setLastError(
                        ReaderErrorCode::Unknown,
                        "Loop restart was not authorized from confirmed EOS.");
                    return MakeSimpleResult(ReadResultKind::Failed,
                                            lastErrorCode(),
                                            lastErrorMessage());
                }

                if (!rebuildReaderForLoop() ||
                    !startCurrentReaderWithoutNewTimeline()) {
                    impl_->started = false;
                    return MakeSimpleResult(ReadResultKind::Failed,
                                            lastErrorCode(),
                                            lastErrorMessage());
                }

                return MakeSimpleResult(ReadResultKind::LoopRestarted);
            }

            case AVAssetReaderStatusFailed: {
                impl_->started = false;
                const std::string message =
                    ErrorMessageFromNSError(
                        impl_->reader.error,
                        "AVAssetReader failed while reading.");
                state_.markReaderFailed(ReaderErrorCode::ReadFailed);
                state_.markPlaybackFailed();
                setLastError(ReaderErrorCode::ReadFailed, message);
                return MakeSimpleResult(ReadResultKind::Failed,
                                        lastErrorCode(),
                                        lastErrorMessage());
            }

            case AVAssetReaderStatusCancelled:
                impl_->started = false;
                impl_->cancelled = true;
                state_.cancelReader();
                setLastError(ReaderErrorCode::Cancelled,
                             "AVAssetReader was cancelled.");
                return MakeSimpleResult(ReadResultKind::Cancelled,
                                        lastErrorCode(),
                                        lastErrorMessage());

            case AVAssetReaderStatusReading:
            case AVAssetReaderStatusUnknown:
                return MakeSimpleResult(ReadResultKind::NotReady);
        }
    }
}

void LocalVideoReader::stop() {
    @autoreleasepool {
        if (impl_->reader != nil) {
            const AVAssetReaderStatus status = impl_->reader.status;
            if (status == AVAssetReaderStatusReading ||
                status == AVAssetReaderStatusUnknown) {
                [impl_->reader cancelReading];
            }
        }

        if (impl_->opened || impl_->started) {
            state_.cancelReader();
        }

        impl_->reader = nil;
        impl_->output = nil;
        impl_->track = nil;
        impl_->asset = nil;
        impl_->opened = false;
        impl_->started = false;
        impl_->cancelled = true;
        impl_->sourceInfo = {};
        impl_->fileIdentity.clear();
        setLastError(ReaderErrorCode::Cancelled,
                     "Reader stopped and cancelled.");
    }
}

bool LocalVideoReader::isOpen() const noexcept {
    return impl_->opened;
}

bool LocalVideoReader::isStarted() const noexcept {
    return impl_->started;
}

bool LocalVideoReader::loopEnabled() const noexcept {
    return impl_->config.loopEnabled;
}

std::optional<SourceVideoInfo> LocalVideoReader::sourceInfo() const {
    if (!impl_->opened) {
        return std::nullopt;
    }
    return impl_->sourceInfo;
}

const std::string& LocalVideoReader::fileIdentity() const noexcept {
    return impl_->fileIdentity;
}

ReaderErrorCode LocalVideoReader::lastErrorCode() const noexcept {
    return impl_->lastErrorCode;
}

const std::string& LocalVideoReader::lastErrorMessage() const noexcept {
    return impl_->lastErrorMessage;
}

bool LocalVideoReader::rebuildReaderForLoop() {
    @autoreleasepool {
        AVAssetReader* reader = nil;
        AVAssetReaderTrackOutput* output = nil;
        std::string message;

        if (!CreateReaderObjects(impl_->asset,
                                 impl_->track,
                                 impl_->config.outputPixelFormat,
                                 &reader,
                                 &output,
                                 &message)) {
            state_.markReaderFailed(ReaderErrorCode::InitializationFailed);
            state_.markPlaybackFailed();
            setLastError(ReaderErrorCode::InitializationFailed, message);
            return false;
        }

        impl_->reader = reader;
        impl_->output = output;
        impl_->started = false;
        impl_->cancelled = false;
        return true;
    }
}

bool LocalVideoReader::startCurrentReaderWithoutNewTimeline() {
    @autoreleasepool {
        if (impl_->reader == nil || impl_->output == nil) {
            state_.markReaderFailed(ReaderErrorCode::InitializationFailed);
            state_.markPlaybackFailed();
            setLastError(ReaderErrorCode::InitializationFailed,
                         "Loop reader reconstruction is incomplete.");
            return false;
        }

        if (![impl_->reader startReading]) {
            const std::string message =
                ErrorMessageFromNSError(
                    impl_->reader.error,
                    "Loop AVAssetReader startReading failed.");
            state_.markReaderFailed(ReaderErrorCode::InitializationFailed);
            state_.markPlaybackFailed();
            setLastError(ReaderErrorCode::InitializationFailed, message);
            return false;
        }

        if (!state_.beginReading()) {
            [impl_->reader cancelReading];
            state_.markReaderFailed(ReaderErrorCode::Unknown);
            state_.markPlaybackFailed();
            setLastError(
                ReaderErrorCode::Unknown,
                "FrameEngineState rejected loop reading transition.");
            return false;
        }

        impl_->started = true;
        return true;
    }
}

void LocalVideoReader::cancelCurrentReaderForReplacement() {
    if (!impl_->opened && !impl_->started && impl_->reader == nil) {
        return;
    }

    if (impl_->reader != nil) {
        const AVAssetReaderStatus status = impl_->reader.status;
        if (status == AVAssetReaderStatusReading ||
            status == AVAssetReaderStatusUnknown) {
            [impl_->reader cancelReading];
        }
    }

    state_.cancelReader();

    impl_->reader = nil;
    impl_->output = nil;
    impl_->track = nil;
    impl_->asset = nil;
    impl_->opened = false;
    impl_->started = false;
    impl_->cancelled = true;
}

void LocalVideoReader::clearLastError() noexcept {
    impl_->lastErrorCode = ReaderErrorCode::None;
    impl_->lastErrorMessage.clear();
}

void LocalVideoReader::setLastError(ReaderErrorCode code,
                                    const std::string& message) {
    impl_->lastErrorCode = code;
    impl_->lastErrorMessage = message;
}

}  // namespace vcam::media_engine
