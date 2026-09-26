#include "ControlledPreviewView.h"

#include "ControlledRuntime.h"

#import <AVFoundation/AVFoundation.h>

#include <CoreMedia/CoreMedia.h>
#include <CoreVideo/CoreVideo.h>

using vcam::controlled::ControlledAcquireKind;
using vcam::controlled::ControlledRuntime;

@implementation VCAMControlledPreviewView {
    ControlledRuntime* _runtime;
    CADisplayLink* _displayLink;
    std::uint64_t _observedPresentationSerial;
}

+ (Class)layerClass {
    return [AVSampleBufferDisplayLayer class];
}

- (instancetype)initWithRuntime:
    (ControlledRuntime*)runtime {
    self = [super initWithFrame:CGRectZero];
    if (self) {
        _runtime = runtime;
        _displayLink = nil;
        _observedPresentationSerial = 0;

        self.backgroundColor =
            [UIColor blackColor];
        self.layer.cornerRadius = 12.0;
        self.clipsToBounds = YES;

        AVSampleBufferDisplayLayer* layer =
            (AVSampleBufferDisplayLayer*)
                self.layer;
        layer.videoGravity =
            AVLayerVideoGravityResizeAspect;
    }
    return self;
}

- (void)dealloc {
    [_displayLink invalidate];
    _displayLink = nil;
}

- (void)didMoveToWindow {
    [super didMoveToWindow];

    if (self.window == nil) {
        [_displayLink invalidate];
        _displayLink = nil;

        [(AVSampleBufferDisplayLayer*)
            self.layer
            flushAndRemoveImage];
        return;
    }

    if (_displayLink == nil) {
        _displayLink =
            [CADisplayLink
                displayLinkWithTarget:self
                             selector:
                                 @selector(
                                     displayTick:)];
        _displayLink.preferredFramesPerSecond =
            30;
        [_displayLink
            addToRunLoop:
                [NSRunLoop mainRunLoop]
               forMode:
                   NSRunLoopCommonModes];
    }
}

- (void)displayTick:
    (CADisplayLink*)displayLink {
    (void)displayLink;

    if (_runtime == nullptr) {
        return;
    }

    AVSampleBufferDisplayLayer* layer =
        (AVSampleBufferDisplayLayer*)
            self.layer;

    const std::uint64_t serial =
        _runtime->
            presentationSerial();

    if (serial !=
        _observedPresentationSerial) {
        [layer flushAndRemoveImage];
        _observedPresentationSerial =
            serial;
    }

    auto acquired =
        _runtime->consumer().tryAcquire();

    if (acquired.kind !=
            ControlledAcquireKind::Presented ||
        !acquired.frame.has_value() ||
        !acquired.frame->valid()) {
        return;
    }

    CVPixelBufferRef pixelBuffer =
        acquired.frame->pixelBuffer();

    CMVideoFormatDescriptionRef
        formatDescription = nullptr;

    const OSStatus formatStatus =
        CMVideoFormatDescriptionCreateForImageBuffer(
            kCFAllocatorDefault,
            pixelBuffer,
            &formatDescription);

    if (formatStatus != noErr ||
        formatDescription == nullptr) {
        return;
    }

    CMSampleTimingInfo timing = {
        kCMTimeInvalid,
        kCMTimeInvalid,
        kCMTimeInvalid,
    };

    CMSampleBufferRef sampleBuffer =
        nullptr;

    const OSStatus sampleStatus =
        CMSampleBufferCreateReadyWithImageBuffer(
            kCFAllocatorDefault,
            pixelBuffer,
            formatDescription,
            &timing,
            &sampleBuffer);

    CFRelease(formatDescription);

    if (sampleStatus != noErr ||
        sampleBuffer == nullptr) {
        return;
    }

    CFArrayRef attachments =
        CMSampleBufferGetSampleAttachmentsArray(
            sampleBuffer,
            true);

    if (attachments != nullptr &&
        CFArrayGetCount(attachments) > 0) {
        CFMutableDictionaryRef attachment =
            (CFMutableDictionaryRef)
                CFArrayGetValueAtIndex(
                    attachments,
                    0);

        CFDictionarySetValue(
            attachment,
            kCMSampleAttachmentKey_DisplayImmediately,
            kCFBooleanTrue);
    }

    if (layer.status ==
        AVQueuedSampleBufferRenderingStatusFailed) {
        [layer flush];
    }

    if (layer.isReadyForMoreMediaData) {
        [layer enqueueSampleBuffer:
            sampleBuffer];
    }

    CFRelease(sampleBuffer);
}

@end
