#include "InternalGalleryViewController.h"
#include "InternalGalleryMediaSession.h"
#include "SelectionCompletionGate.h"

#import <PhotosUI/PhotosUI.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

#include <cstdint>
#include <string>

using vcam::control::SelectionCompletionGate;
using vcam::frame_engine::PlaybackState;
using vcam::media_engine::InternalGalleryMediaSession;
using vcam::media_engine::SelectedMediaKind;

@interface VCAMInternalGalleryViewController () <PHPickerViewControllerDelegate>
@property(nonatomic, strong) UIButton* selectButton;
@property(nonatomic, strong) UIButton* changeButton;
@property(nonatomic, strong) UIButton* clearButton;
@property(nonatomic, strong) UIButton* playbackButton;
@property(nonatomic, strong) UISwitch* loopSwitch;
@property(nonatomic, strong) UILabel* selectedLabel;
@property(nonatomic, strong) UILabel* statusLabel;
@property(nonatomic, strong, nullable) NSURL* ownedMediaURL;
@end

@implementation VCAMInternalGalleryViewController {
    InternalGalleryMediaSession* _mediaSession;
    SelectionCompletionGate _selectionGate;
    std::uint64_t _presentedSelectionToken;
}

- (instancetype)initWithMediaSession:(InternalGalleryMediaSession*)session {
    self = [super initWithNibName:nil bundle:nil];
    if (self) {
        _mediaSession = session;
        _presentedSelectionToken = 0;
    }
    return self;
}

- (void)dealloc {
    if (_mediaSession != nullptr) _mediaSession->clearMedia();
    [self removeOwnedMediaFile];
}

- (UIButton*)buttonWithTitle:(NSString*)title action:(SEL)action {
    UIButton* button = [UIButton buttonWithType:UIButtonTypeSystem];
    [button setTitle:title forState:UIControlStateNormal];
    [button addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    return button;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor systemBackgroundColor];

    UILabel* title = [[UILabel alloc] init];
    title.text = @"VCAM PRO — Local Media";
    title.font = [UIFont preferredFontForTextStyle:UIFontTextStyleTitle2];

    self.selectedLabel = [[UILabel alloc] init];
    self.selectedLabel.numberOfLines = 2;
    self.statusLabel = [[UILabel alloc] init];
    self.statusLabel.numberOfLines = 3;
    self.statusLabel.textColor = [UIColor secondaryLabelColor];

    self.selectButton = [self buttonWithTitle:@"Select Media" action:@selector(selectMediaTapped:)];
    self.changeButton = [self buttonWithTitle:@"Change Media" action:@selector(selectMediaTapped:)];
    self.clearButton = [self buttonWithTitle:@"Clear Media" action:@selector(clearMediaTapped:)];
    self.playbackButton = [self buttonWithTitle:@"Start" action:@selector(playbackTapped:)];

    self.loopSwitch = [[UISwitch alloc] init];
    self.loopSwitch.on = YES;
    [self.loopSwitch addTarget:self action:@selector(loopChanged:)
              forControlEvents:UIControlEventValueChanged];

    UILabel* loopLabel = [[UILabel alloc] init];
    loopLabel.text = @"Video Loop";
    UIStackView* loopRow = [[UIStackView alloc] initWithArrangedSubviews:@[loopLabel, self.loopSwitch]];
    loopRow.axis = UILayoutConstraintAxisHorizontal;
    loopRow.distribution = UIStackViewDistributionEqualSpacing;

    UIStackView* stack = [[UIStackView alloc] initWithArrangedSubviews:@[
        title, self.selectedLabel, self.statusLabel, self.selectButton,
        self.changeButton, self.clearButton, self.playbackButton, loopRow
    ]];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 12.0;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[
        [stack.leadingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.leadingAnchor constant:20.0],
        [stack.trailingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.trailingAnchor constant:-20.0],
        [stack.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor constant:20.0]
    ]];
    [self refreshControls];
}

- (void)selectMediaTapped:(id)sender {
    (void)sender;
    PHPickerConfiguration* configuration = [[PHPickerConfiguration alloc] init];
    configuration.selectionLimit = 1;
    configuration.filter = [PHPickerFilter anyFilterMatchingSubfilters:@[
        [PHPickerFilter imagesFilter], [PHPickerFilter videosFilter]
    ]];

    _presentedSelectionToken = _selectionGate.beginRequest();
    PHPickerViewController* picker =
        [[PHPickerViewController alloc] initWithConfiguration:configuration];
    picker.delegate = self;
    [self presentViewController:picker animated:YES completion:nil];
}

- (void)picker:(PHPickerViewController*)picker
    didFinishPicking:(NSArray<PHPickerResult*>*)results {
    [picker dismissViewControllerAnimated:YES completion:nil];

    const std::uint64_t requestToken = _presentedSelectionToken;
    if (!_selectionGate.accept(requestToken)) return;

    PHPickerResult* result = results.firstObject;
    if (result == nil) {
        self.statusLabel.text = @"Selection cancelled.";
        return;
    }

    NSItemProvider* provider = result.itemProvider;
    const BOOL isVideo =
        [provider hasItemConformingToTypeIdentifier:UTTypeMovie.identifier];
    const BOOL isPhoto =
        [provider hasItemConformingToTypeIdentifier:UTTypeImage.identifier];
    if (!isVideo && !isPhoto) {
        self.statusLabel.text = @"Unsupported local media item.";
        return;
    }

    NSString* typeIdentifier =
        isVideo ? UTTypeMovie.identifier : UTTypeImage.identifier;
    __weak VCAMInternalGalleryViewController* weakSelf = self;

    [provider loadFileRepresentationForTypeIdentifier:typeIdentifier
        completionHandler:^(NSURL* url, NSError* error) {
            VCAMInternalGalleryViewController* strongSelf = weakSelf;
            if (strongSelf == nil) return;
            if (url == nil || error != nil || !url.isFileURL) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    strongSelf.statusLabel.text = @"Unable to obtain a local media file.";
                });
                return;
            }

            NSError* copyError = nil;
            NSURL* ownedURL =
                [strongSelf copyPickerFileToOwnedLocation:url isVideo:isVideo error:&copyError];

            dispatch_async(dispatch_get_main_queue(), ^{
                VCAMInternalGalleryViewController* currentSelf = weakSelf;
                if (currentSelf == nil) return;

                if (requestToken != currentSelf->_selectionGate.currentRequestToken()) {
                    if (ownedURL != nil) {
                        [[NSFileManager defaultManager] removeItemAtURL:ownedURL error:nil];
                    }
                    return;
                }

                if (ownedURL == nil || copyError != nil) {
                    currentSelf.statusLabel.text =
                        @"Unable to copy selected media into VCAM storage.";
                    return;
                }

                [currentSelf applyOwnedSelection:ownedURL isVideo:isVideo];
            });
        }];
}

- (NSURL*)copyPickerFileToOwnedLocation:(NSURL*)sourceURL
                                isVideo:(BOOL)isVideo
                                  error:(NSError**)error {
    NSFileManager* manager = [NSFileManager defaultManager];
    NSURL* caches = [[manager URLsForDirectory:NSCachesDirectory
                                      inDomains:NSUserDomainMask] firstObject];
    if (caches == nil) return nil;

    NSURL* directory =
        [[caches URLByAppendingPathComponent:@"VCAMPro" isDirectory:YES]
            URLByAppendingPathComponent:@"SelectedMedia" isDirectory:YES];

    if (![manager createDirectoryAtURL:directory
           withIntermediateDirectories:YES attributes:nil error:error]) {
        return nil;
    }

    NSString* extension = sourceURL.pathExtension;
    if (extension.length == 0) extension = isVideo ? @"mov" : @"image";
    NSString* filename =
        [NSString stringWithFormat:@"selected-%@.%@", NSUUID.UUID.UUIDString, extension];
    NSURL* destination =
        [directory URLByAppendingPathComponent:filename isDirectory:NO];

    return [manager copyItemAtURL:sourceURL toURL:destination error:error]
        ? destination : nil;
}

- (void)applyOwnedSelection:(NSURL*)ownedURL isVideo:(BOOL)isVideo {
    if (_mediaSession == nullptr) {
        [[NSFileManager defaultManager] removeItemAtURL:ownedURL error:nil];
        self.statusLabel.text = @"Media engine unavailable.";
        return;
    }

    const char* utf8 = ownedURL.path.UTF8String;
    if (utf8 == nullptr) {
        [[NSFileManager defaultManager] removeItemAtURL:ownedURL error:nil];
        self.statusLabel.text = @"Selected media path is invalid.";
        return;
    }

    const std::string path(utf8);
    const BOOL selected =
        isVideo
            ? _mediaSession->selectVideo(path, self.loopSwitch.on)
            : _mediaSession->selectPhoto(path);

    [self removeOwnedMediaFile];
    if (selected) {
        self.ownedMediaURL = ownedURL;
    } else {
        [[NSFileManager defaultManager] removeItemAtURL:ownedURL error:nil];
    }
    [self refreshControls];
}

- (void)clearMediaTapped:(id)sender {
    (void)sender;
    if (_mediaSession != nullptr) _mediaSession->clearMedia();
    [self removeOwnedMediaFile];
    [self refreshControls];
}

- (void)playbackTapped:(id)sender {
    (void)sender;
    if (_mediaSession == nullptr) return;
    switch (_mediaSession->playbackState()) {
        case PlaybackState::Ready:
        case PlaybackState::Ended:
            (void)_mediaSession->start();
            break;
        case PlaybackState::Playing:
            (void)_mediaSession->pause();
            break;
        case PlaybackState::Paused:
            (void)_mediaSession->resume();
            break;
        case PlaybackState::Empty:
        case PlaybackState::Failed:
            break;
    }
    [self refreshControls];
}

- (void)loopChanged:(UISwitch*)sender {
    if (_mediaSession != nullptr &&
        _mediaSession->selectedMedia().kind == SelectedMediaKind::Video) {
        (void)_mediaSession->setVideoLoopEnabled(sender.on);
    }
    [self refreshControls];
}

- (void)removeOwnedMediaFile {
    NSURL* url = self.ownedMediaURL;
    self.ownedMediaURL = nil;
    if (url != nil) {
        [[NSFileManager defaultManager] removeItemAtURL:url error:nil];
    }
}

- (void)refreshControls {
    if (_mediaSession == nullptr) {
        self.selectedLabel.text = @"Media engine unavailable";
        self.statusLabel.text = @"Media engine unavailable.";
        return;
    }

    const auto& selected = _mediaSession->selectedMedia();
    if (!selected.valid) {
        self.selectedLabel.text = @"No media selected";
    } else {
        NSString* path = [NSString stringWithUTF8String:selected.localPath.c_str()];
        NSString* kind = selected.kind == SelectedMediaKind::Video ? @"Video" : @"Photo";
        NSString* displayName =
            path.lastPathComponent != nil
                ? path.lastPathComponent
                : @"local media";
        self.selectedLabel.text =
            [NSString stringWithFormat:@"%@ — %@", kind, displayName];
    }

    self.statusLabel.text =
        [NSString stringWithUTF8String:_mediaSession->statusMessage().c_str()];

    switch (_mediaSession->playbackState()) {
        case PlaybackState::Playing:
            [self.playbackButton setTitle:@"Pause" forState:UIControlStateNormal];
            break;
        case PlaybackState::Paused:
            [self.playbackButton setTitle:@"Resume" forState:UIControlStateNormal];
            break;
        default:
            [self.playbackButton setTitle:@"Start" forState:UIControlStateNormal];
            break;
    }

    const BOOL hasMedia = selected.valid;
    self.selectButton.hidden = hasMedia;
    self.changeButton.hidden = !hasMedia;
    self.clearButton.enabled = hasMedia;
    self.playbackButton.enabled = hasMedia;
    self.loopSwitch.enabled =
        hasMedia && selected.kind == SelectedMediaKind::Video;
}

@end
