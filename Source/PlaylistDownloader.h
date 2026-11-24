#import <UIKit/UIKit.h>
#import "Headers/YTMNowPlayingViewController.h"

// Downloads the currently playing track and then the following tracks in the
// playback queue, one after another, reusing the tweak's single-track download path.
@interface YTMUPlaylistDownloader : NSObject
@property (nonatomic, readonly) BOOL running;
+ (instancetype)shared;
- (void)promptAndStartFromPlayingController:(YTMNowPlayingViewController *)playingVC;
@end
