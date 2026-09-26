#include "InternalGalleryViewController.h"
#include "InternalGalleryMediaSession.h"

#import <UIKit/UIKit.h>

#include <memory>

@interface VCAMGalleryHarnessAppDelegate : UIResponder <UIApplicationDelegate>
@property(nonatomic, strong) UIWindow* window;
@end

@implementation VCAMGalleryHarnessAppDelegate {
    std::unique_ptr<vcam::media_engine::InternalGalleryMediaSession> _session;
}

- (BOOL)application:(UIApplication*)application
    didFinishLaunchingWithOptions:(NSDictionary*)launchOptions {
    (void)application;
    (void)launchOptions;

    vcam::media_engine::InternalGalleryMediaConfig config;
    config.target.width = 1280;
    config.target.height = 720;
    config.target.pixelFormat =
        kCVPixelFormatType_420YpCbCr8BiPlanarFullRange;
    config.target.orientation =
        vcam::media_engine::OrientationRequirement::UprightIdentityTransform;
    config.target.colorMetadata =
        vcam::media_engine::ColorMetadataPolicy::PreserveSource;
    config.photo.cadenceNumerator = 30;
    config.photo.cadenceDenominator = 1;
    config.photo.outputPixelFormat =
        kCVPixelFormatType_420YpCbCr8BiPlanarFullRange;
    config.videoPixelFormat =
        kCVPixelFormatType_420YpCbCr8BiPlanarFullRange;

    _session =
        std::make_unique<vcam::media_engine::InternalGalleryMediaSession>(config);

    self.window =
        [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
    VCAMInternalGalleryViewController* controller =
        [[VCAMInternalGalleryViewController alloc]
            initWithMediaSession:_session.get()];
    self.window.rootViewController = controller;
    [self.window makeKeyAndVisible];
    return YES;
}
@end

int main(int argc, char* argv[]) {
    @autoreleasepool {
        return UIApplicationMain(
            argc, argv, nil,
            NSStringFromClass([VCAMGalleryHarnessAppDelegate class]));
    }
}
