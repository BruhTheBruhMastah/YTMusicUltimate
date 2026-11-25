#import "PlaylistViewController.h"
#import "PlaylistStore.h"
#import <AVFoundation/AVFoundation.h>
#import <objc/runtime.h>

static const NSInteger kLookahead = 3; // how many items are kept in the AVQueuePlayer at once
static const void *kIndexKey = &kIndexKey;
static void *kCurrentItemContext = &kCurrentItemContext;
static void *kRateContext = &kRateContext;

static UIImage *YTMUThumbnail(UIImage *image) {
    if (!image) return nil;
    CGFloat target = 37.5;
    CGFloat scale = target / MAX(image.size.width, image.size.height);
    CGSize size = CGSizeMake(image.size.width * scale, image.size.height * scale);
    UIGraphicsBeginImageContextWithOptions(size, NO, 0.0);
    [[UIBezierPath bezierPathWithRoundedRect:CGRectMake(0, 0, size.width, size.height) cornerRadius:6] addClip];
    [image drawInRect:CGRectMake(0, 0, size.width, size.height)];
    UIImage *result = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return [result imageWithRenderingMode:UIImageRenderingModeAlwaysOriginal];
}

@implementation YTMUPlaylistViewController {
    NSString *_name;
    NSArray<NSString *> *_tracks;
    NSInteger _startIndex;
    BOOL _started;

    AVQueuePlayer *_player;
    NSInteger _currentIndex;   // index (in _tracks) of the track that is playing
    NSInteger _nextToEnqueue;  // next index to put into the queue

    NSCache<NSString *, UIImage *> *_thumbs;
    UIBarButtonItem *_playPauseItem;
}

- (instancetype)initWithName:(NSString *)name tracks:(NSArray<NSString *> *)tracks startIndex:(NSInteger)startIndex {
    self = [super initWithStyle:UITableViewStylePlain];
    if (self) {
        _name = [name copy];
        _tracks = [tracks copy];
        _startIndex = MAX(0, MIN(startIndex, (NSInteger)tracks.count - 1));
        _currentIndex = _startIndex;
        _thumbs = [[NSCache alloc] init];
    }
    return self;
}

- (void)dealloc {
    [self stopPlayer];
}

#pragma mark - View

- (void)viewDidLoad {
    [super viewDidLoad];

    self.title = _name;
    self.view.backgroundColor = [UIColor colorWithRed:3/255.0 green:3/255.0 blue:3/255.0 alpha:1.0];
    self.tableView.backgroundColor = self.view.backgroundColor;
    self.tableView.separatorColor = [[UIColor whiteColor] colorWithAlphaComponent:0.15];

    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"Close" style:UIBarButtonItemStylePlain target:self action:@selector(closeTapped)];

    UIBarButtonItem *previous = [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"backward.fill"] style:UIBarButtonItemStylePlain target:self action:@selector(previousTapped)];
    UIBarButtonItem *next = [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"forward.fill"] style:UIBarButtonItemStylePlain target:self action:@selector(nextTapped)];
    _playPauseItem = [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"play.fill"] style:UIBarButtonItemStylePlain target:self action:@selector(playPauseTapped)];
    UIBarButtonItem *flex = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemFlexibleSpace target:nil action:nil];
    self.toolbarItems = @[flex, previous, flex, _playPauseItem, flex, next, flex];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self.navigationController setToolbarHidden:NO animated:NO];
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    if (!_started) {
        _started = YES;
        [self startFromIndex:_startIndex];
    }
}

- (void)closeTapped {
    [self stopPlayer];
    [self dismissViewControllerAnimated:YES completion:nil];
}

#pragma mark - Table

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return _tracks.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"track"];
    if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"track"];

    NSString *track = _tracks[indexPath.row];
    BOOL isCurrent = (indexPath.row == _currentIndex) && _player.currentItem != nil;

    cell.backgroundColor = [[UIColor grayColor] colorWithAlphaComponent:0.25];
    cell.textLabel.numberOfLines = 0;
    cell.textLabel.text = track;
    cell.textLabel.textColor = isCurrent ? [UIColor colorWithRed:30.0/255.0 green:150.0/255.0 blue:245.0/255.0 alpha:1.0] : [UIColor whiteColor];
    cell.detailTextLabel.text = [NSString stringWithFormat:@"#%ld", (long)indexPath.row + 1];
    cell.detailTextLabel.textColor = [[UIColor whiteColor] colorWithAlphaComponent:0.5];

    if (isCurrent) {
        UIImageView *icon = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"speaker.wave.2.fill"]];
        icon.tintColor = cell.textLabel.textColor;
        cell.accessoryView = icon;
    } else {
        cell.accessoryView = nil;
    }

    UIImage *thumb = [_thumbs objectForKey:track];
    if (!thumb) {
        NSString *path = [YTMUPlaylistStore coverPathForTrack:track];
        thumb = path ? YTMUThumbnail([UIImage imageWithContentsOfFile:path]) : nil;
        if (thumb) [_thumbs setObject:thumb forKey:track];
    }
    cell.imageView.image = thumb;

    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    [self startFromIndex:indexPath.row];
}

#pragma mark - Playback

- (AVPlayerItem *)itemForIndex:(NSInteger)index {
    NSURL *url = [YTMUPlaylistStore audioURLForTrack:_tracks[index]];
    if (!url) return nil;

    AVPlayerItem *item = [AVPlayerItem playerItemWithURL:url];
    objc_setAssociatedObject(item, kIndexKey, @(index), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return item;
}

- (void)topUpQueue {
    while (_nextToEnqueue < (NSInteger)_tracks.count && (NSInteger)_player.items.count < kLookahead) {
        AVPlayerItem *item = [self itemForIndex:_nextToEnqueue];
        if (item) [_player insertItem:item afterItem:nil];
        _nextToEnqueue++;
    }
}

- (void)startFromIndex:(NSInteger)index {
    if (index < 0 || index >= (NSInteger)_tracks.count) return;

    if (!_player) {
        AVAudioSession *session = [AVAudioSession sharedInstance];
        [session setCategory:AVAudioSessionCategoryPlayback error:nil];
        [session setActive:YES error:nil];

        _player = [[AVQueuePlayer alloc] init];
        [_player addObserver:self forKeyPath:@"currentItem" options:NSKeyValueObservingOptionNew context:kCurrentItemContext];
        [_player addObserver:self forKeyPath:@"rate" options:NSKeyValueObservingOptionNew context:kRateContext];
    }

    [_player removeAllItems];
    _currentIndex = index;
    _nextToEnqueue = index;
    [self topUpQueue];
    [_player play];

    [self.tableView reloadData];
    [self updatePlayPauseIcon];
}

- (void)stopPlayer {
    if (!_player) return;
    [_player pause];
    [_player removeObserver:self forKeyPath:@"currentItem" context:kCurrentItemContext];
    [_player removeObserver:self forKeyPath:@"rate" context:kRateContext];
    [_player removeAllItems];
    _player = nil;
}

- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary *)change context:(void *)context {
    if (context == kCurrentItemContext) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self currentItemChanged]; });
    } else if (context == kRateContext) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self updatePlayPauseIcon]; });
    } else {
        [super observeValueForKeyPath:keyPath ofObject:object change:change context:context];
    }
}

- (void)currentItemChanged {
    if (!_player) return;

    NSNumber *index = objc_getAssociatedObject(_player.currentItem, kIndexKey);
    if (index) {
        _currentIndex = index.integerValue;
        [self.tableView reloadData];
        [self.tableView scrollToRowAtIndexPath:[NSIndexPath indexPathForRow:_currentIndex inSection:0]
                              atScrollPosition:UITableViewScrollPositionNone animated:YES];
    }
    [self topUpQueue];
}

- (void)updatePlayPauseIcon {
    BOOL playing = _player.rate > 0;
    _playPauseItem.image = [UIImage systemImageNamed:playing ? @"pause.fill" : @"play.fill"];
}

#pragma mark - Controls

- (void)playPauseTapped {
    if (!_player || !_player.currentItem) {
        [self startFromIndex:0]; // nothing playing (e.g. queue finished): start over
    } else if (_player.rate > 0) {
        [_player pause];
    } else {
        [_player play];
    }
}

- (void)nextTapped {
    if (!_player || _currentIndex + 1 >= (NSInteger)_tracks.count) return;
    if (_player.items.count > 1) {
        [_player advanceToNextItem];
    } else {
        [self startFromIndex:_currentIndex + 1];
    }
}

- (void)previousTapped {
    if (!_player) return;
    if (CMTimeGetSeconds(_player.currentTime) > 3.0 || _currentIndex <= 0) {
        [_player seekToTime:kCMTimeZero];
    } else {
        [self startFromIndex:_currentIndex - 1];
    }
}

@end
