#import <Foundation/Foundation.h>

// Keeps track of downloaded playlists. Songs stay where they always were
// (Documents/YTMusicUltimate/*.m4a); a playlist is just an ordered list of song names
// stored as Documents/YTMusicUltimate/Playlists/<id>.json plus a cover <id>.png.
@interface YTMUPlaylistStore : NSObject
+ (NSURL *)downloadsFolder;
+ (NSURL *)playlistsFolder;

// Each entry: @{@"id", @"name", @"tracks" (existing songs only, in order), @"cover" (png path or @"")}
+ (NSArray<NSDictionary *> *)allPlaylists;

+ (void)savePlaylistNamed:(NSString *)name tracks:(NSArray<NSString *> *)tracks;
+ (void)deletePlaylistWithID:(NSString *)playlistID;
+ (void)renameTrack:(NSString *)oldName to:(NSString *)newName; // keeps playlists valid when a song is renamed

+ (NSURL *)audioURLForTrack:(NSString *)track; // .m4a or .mp3, nil if missing
+ (NSString *)coverPathForTrack:(NSString *)track; // nil if missing
@end
