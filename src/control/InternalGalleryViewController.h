#pragma once

#import <UIKit/UIKit.h>

#ifdef __cplusplus
namespace vcam::media_engine {
class InternalGalleryMediaSession;
}
namespace vcam::product {
class ProductControlOwner;
}
#endif

NS_ASSUME_NONNULL_BEGIN

typedef void (^VCAMAdjustPhotoRequestHandler)(void);

@interface VCAMInternalGalleryViewController : UIViewController

#ifdef __cplusplus
- (instancetype)initWithMediaSession:
    (vcam::media_engine::InternalGalleryMediaSession*)session
    NS_DESIGNATED_INITIALIZER;

- (instancetype)initWithProductControlOwner:
    (vcam::product::ProductControlOwner*)owner
    NS_DESIGNATED_INITIALIZER;
#endif

@property(nonatomic, copy, nullable)
    VCAMAdjustPhotoRequestHandler
        adjustPhotoRequestHandler;

- (instancetype)initWithNibName:(nullable NSString*)nibNameOrNil
                         bundle:(nullable NSBundle*)nibBundleOrNil
    NS_UNAVAILABLE;
- (instancetype)initWithCoder:(NSCoder*)coder
    NS_UNAVAILABLE;

@end

NS_ASSUME_NONNULL_END
