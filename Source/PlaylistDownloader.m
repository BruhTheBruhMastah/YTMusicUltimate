#import "PlaylistDownloader.h"
#import "FFMpegDownloader.h"
#import "Headers/YTMWatchViewController.h"
#import "Headers/YTPlayerViewController.h"
#import "Headers/YTIThumbnailDetails_Thumbnail.h"

static const NSTimeInterval kNextTrackTimeout = 20.0; // wait this long for the next track to load
static const NSInteger kDefaultCount = 25;
static const NSInteger kMaxCount = 500;

// Same logic as -getURLFromManifest: in Downloading.x (blocking network call, run off the main thread)
static NSString *YTMUAudioURLFromManifest(NSString *manifestURL) {
    NSData *data = [NSData dataWithContentsOfURL:[NSURL URLWithString:manifestURL]];
    NSString *manifest = data ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : nil;
    if (!manifest) return nil;

    NSArray *lines = [manifest componentsSeparatedByString:@"\n"];
    for (NSString *groupID in @[@"234", @"233"]) {
        NSString *needle = [NSString stringWithFormat:@"TYPE=AUDIO,GROUP-ID=\"%@\"", groupID];
        for (NSString *line in lines) {
            if (![line containsString:needle]) continue;
            NSRange start = [line rangeOfString:@"https://"];
            NSRange end = [line rangeOfString:@"index.m3u8"];
            if (start.location != NSNotFound && end.location != NSNotFound) {
                return [line substringWithRange:NSMakeRange(start.location, NSMaxRange(end) - start.location)];
            }
        }
    }
    return nil;
}

static NSURL *YTMUDownloadsFolder(void) {
    NSURL *docs = [[[NSFileManager defaultManager] URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask] lastObject];
    return [docs URLByAppendingPathComponent:@"YTMusicUltimate"];
}

static UIViewController *YTMUTopViewController(UIViewController *vc) {
    while (vc.presentedViewController) vc = vc.presentedViewController;
    return vc;
}

@implementation YTMUPlaylistDownloader {
    __weak YTMNowPlayingViewController *_playingVC;
    NSInteger _total, _index, _saved, _skipped, _failed;
    NSString *_lastManifest;
    NSMutableSet<NSString *> *_seenIDs;
    BOOL _cancelled;
    MBProgressHUD *_hud;
    FFMpegDownloader *_current;
}

+ (instancetype)shared {
    static YTMUPlaylistDownloader *instance;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ instance = [[self alloc] init]; });
    return instance;
}

#pragma mark - Entry point

- (void)promptAndStartFromPlayingController:(YTMNowPlayingViewController *)playingVC {
    if (_running) return;
    _playingVC = playingVC;

    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Download playlist"
        message:@"Downloads the current track and the next ones in the queue. Enter how many tracks to download (including this one). Audio will play briefly as each track is skipped."
        preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *field) {
        field.keyboardType = UIKeyboardTypeNumberPad;
        field.text = [NSString stringWithFormat:@"%ld", (long)kDefaultCount];
    }];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Start" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        NSInteger count = [alert.textFields.firstObject.text integerValue];
        if (count < 1) count = 1;
        if (count > kMaxCount) count = kMaxCount;
        [self startWithCount:count];
    }]];
    [YTMUTopViewController(playingVC) presentViewController:alert animated:YES completion:nil];
}

- (void)startWithCount:(NSInteger)count {
    _running = YES;
    _cancelled = NO;
    _total = count;
    _index = _saved = _skipped = _failed = 0;
    _lastManifest = nil;
    _seenIDs = [NSMutableSet set];

    _hud = [MBProgressHUD showHUDAddedTo:[UIApplication sharedApplication].keyWindow animated:YES];
    _hud.mode = MBProgressHUDModeIndeterminate;
    _hud.label.text = @"Preparing…";
    [_hud.button setTitle:@"Cancel" forState:UIControlStateNormal];
    [_hud.button addTarget:self action:@selector(cancel) forControlEvents:UIControlEventTouchUpInside];

    [self pollForTrackUntil:[NSDate dateWithTimeIntervalSinceNow:kNextTrackTimeout]];
}

- (void)cancel {
    _cancelled = YES;
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        [MobileFFmpeg cancel];
    });
}

#pragma mark - Queue stepping

- (YTPlayerViewController *)playerVC {
    YTMNowPlayingViewController *vc = _playingVC;
    return vc.parentViewController.playerViewController;
}

// Waits until the player has loaded a *new* track (its manifest differs from the previous one).
- (void)pollForTrackUntil:(NSDate *)deadline {
    if (_cancelled || !_playingVC) { [self finishWithNote:_cancelled ? @"Cancelled." : @"Player was closed."]; return; }

    YTPlayerViewController *player = [self playerVC];
    YTPlayerResponse *response = player.playerResponse;
    NSString *manifest = response.playerData.streamingData.hlsManifestURL;
    NSString *videoID = player.contentVideoID;
    BOOL ready = videoID.length && manifest.length && response.playerData.videoDetails.title.length
              && ![manifest isEqualToString:_lastManifest];

    if (ready) {
        if ([_seenIDs containsObject:videoID]) { [self finishWithNote:@"Reached the end of the queue."]; return; }
        [self downloadTrackWithPlayer:player videoID:videoID manifest:manifest];
        return;
    }

    if ([deadline timeIntervalSinceNow] < 0) {
        [self finishWithNote:_index == 0 ? @"No track is loaded yet. Start playing a track first." : @"No further track in the queue."];
        return;
    }

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [self pollForTrackUntil:deadline];
    });
}

- (void)advance {
    if (_cancelled || _index >= _total) { [self finishWithNote:_cancelled ? @"Cancelled." : nil]; return; }
    [_playingVC didTapNextButton];
    [self pollForTrackUntil:[NSDate dateWithTimeIntervalSinceNow:kNextTrackTimeout]];
}

#pragma mark - Single track

- (void)downloadTrackWithPlayer:(YTPlayerViewController *)player videoID:(NSString *)videoID manifest:(NSString *)manifest {
    YTIVideoDetails *details = player.playerResponse.playerData.videoDetails;
    NSString *title = [details.title stringByReplacingOccurrencesOfString:@"/" withString:@""];
    NSString *author = [details.author stringByReplacingOccurrencesOfString:@"/" withString:@""];
    NSString *mediaName = [NSString stringWithFormat:@"%@ - %@", author, title];
    NSInteger duration = (NSInteger)round(player.currentVideoTotalMediaTime);
    NSString *thumbURL = ((YTIThumbnailDetails_Thumbnail *)[details.thumbnail.thumbnailsArray lastObject]).URL;

    _lastManifest = manifest;
    [_seenIDs addObject:videoID];
    _index++;
    _hud.label.text = [NSString stringWithFormat:@"Downloading %ld/%ld", (long)_index, (long)_total];
    _hud.detailsLabel.text = mediaName;

    NSURL *folder = YTMUDownloadsFolder();
    NSURL *outputURL = [folder URLByAppendingPathComponent:[NSString stringWithFormat:@"%@.m4a", mediaName]];
    if ([[NSFileManager defaultManager] fileExistsAtPath:outputURL.path]) {
        _skipped++;
        [self advance];
        return;
    }

    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSString *audioURL = YTMUAudioURLFromManifest(manifest);
        dispatch_async(dispatch_get_main_queue(), ^{
            if (self->_cancelled) { [self finishWithNote:@"Cancelled."]; return; }
            if (audioURL.length == 0) { self->_failed++; [self advance]; return; }

            FFMpegDownloader *ffmpeg = [[FFMpegDownloader alloc] init];
            ffmpeg.quiet = YES;
            ffmpeg.tempName = videoID;
            ffmpeg.mediaName = mediaName;
            ffmpeg.duration = duration;
            ffmpeg.completion = ^(BOOL success) {
                self->_current = nil;
                if (success) {
                    self->_saved++;
                    [self saveCoverFromURL:thumbURL named:mediaName];
                } else if (!self->_cancelled) {
                    self->_failed++;
                }
                [self advance];
            };
            self->_current = ffmpeg;
            [ffmpeg downloadAudio:audioURL];
        });
    });
}

- (void)saveCoverFromURL:(NSString *)urlString named:(NSString *)mediaName {
    if (urlString.length == 0) return;
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSData *data = [NSData dataWithContentsOfURL:[NSURL URLWithString:urlString]];
        if (!data) return;
        NSURL *coverURL = [YTMUDownloadsFolder() URLByAppendingPathComponent:[NSString stringWithFormat:@"%@.png", mediaName]];
        [data writeToURL:coverURL atomically:YES];
    });
}

#pragma mark - Wrap up

- (void)finishWithNote:(NSString *)note {
    _running = NO;
    [_hud hideAnimated:YES];
    _hud = nil;
    _current = nil;
    [[NSNotificationCenter defaultCenter] postNotificationName:@"ReloadDataNotification" object:nil];

    NSString *summary = [NSString stringWithFormat:@"Saved: %ld\nAlready downloaded: %ld\nFailed: %ld%@",
                         (long)_saved, (long)_skipped, (long)_failed, note.length ? [@"\n\n" stringByAppendingString:note] : @""];
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Playlist download finished" message:summary preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    UIViewController *root = [UIApplication sharedApplication].keyWindow.rootViewController;
    [YTMUTopViewController(root) presentViewController:alert animated:YES completion:nil];
}

@end
