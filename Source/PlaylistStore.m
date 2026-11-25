#import "PlaylistStore.h"

static NSString *YTMUSafeName(NSString *name) {
    NSMutableString *s = [[name stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] mutableCopy];
    for (NSString *bad in @[@"/", @"\\", @":", @"\n", @"\r"]) {
        [s replaceOccurrencesOfString:bad withString:@"-" options:0 range:NSMakeRange(0, s.length)];
    }
    if (s.length > 80) [s deleteCharactersInRange:NSMakeRange(80, s.length - 80)];
    return s.length ? [s copy] : @"Playlist";
}

@implementation YTMUPlaylistStore

+ (NSURL *)downloadsFolder {
    NSURL *docs = [[[NSFileManager defaultManager] URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask] lastObject];
    return [docs URLByAppendingPathComponent:@"YTMusicUltimate"];
}

+ (NSURL *)playlistsFolder {
    return [[self downloadsFolder] URLByAppendingPathComponent:@"Playlists"];
}

+ (NSURL *)audioURLForTrack:(NSString *)track {
    NSFileManager *fm = [NSFileManager defaultManager];
    for (NSString *ext in @[@"m4a", @"mp3"]) {
        NSURL *url = [[self downloadsFolder] URLByAppendingPathComponent:[NSString stringWithFormat:@"%@.%@", track, ext]];
        if ([fm fileExistsAtPath:url.path]) return url;
    }
    return nil;
}

+ (NSString *)coverPathForTrack:(NSString *)track {
    NSURL *url = [[self downloadsFolder] URLByAppendingPathComponent:[NSString stringWithFormat:@"%@.png", track]];
    return [[NSFileManager defaultManager] fileExistsAtPath:url.path] ? url.path : nil;
}

+ (NSArray<NSString *> *)manifestFiles {
    NSArray *files = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:[self playlistsFolder].path error:nil] ?: @[];
    NSMutableArray *result = [NSMutableArray array];
    for (NSString *file in files) {
        if ([file.pathExtension.lowercaseString isEqualToString:@"json"]) [result addObject:file];
    }
    return result;
}

+ (NSDictionary *)readManifest:(NSString *)file {
    NSData *data = [NSData dataWithContentsOfURL:[[self playlistsFolder] URLByAppendingPathComponent:file]];
    id json = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    if (![json isKindOfClass:[NSDictionary class]]) return nil;
    if (![json[@"name"] isKindOfClass:[NSString class]] || ![json[@"tracks"] isKindOfClass:[NSArray class]]) return nil;
    return json;
}

+ (NSArray<NSDictionary *> *)allPlaylists {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSMutableArray<NSDictionary *> *result = [NSMutableArray array];

    for (NSString *file in [self manifestFiles]) {
        NSDictionary *json = [self readManifest:file];
        if (!json) continue;

        NSMutableArray<NSString *> *existing = [NSMutableArray array];
        for (id track in json[@"tracks"]) {
            if ([track isKindOfClass:[NSString class]] && [self audioURLForTrack:track]) [existing addObject:track];
        }
        if (existing.count == 0) continue;

        NSString *playlistID = [file stringByDeletingPathExtension];
        NSString *cover = [[[self playlistsFolder] URLByAppendingPathComponent:[playlistID stringByAppendingString:@".png"]] path];
        if (![fm fileExistsAtPath:cover]) {
            cover = nil;
            for (NSString *track in existing) {
                cover = [self coverPathForTrack:track];
                if (cover) break;
            }
        }

        [result addObject:@{@"id": playlistID, @"name": json[@"name"], @"tracks": existing, @"cover": cover ?: @""}];
    }

    [result sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        return [a[@"name"] caseInsensitiveCompare:b[@"name"]];
    }];
    return result;
}

+ (void)savePlaylistNamed:(NSString *)name tracks:(NSArray<NSString *> *)tracks {
    if (tracks.count == 0) return;
    NSFileManager *fm = [NSFileManager defaultManager];
    [fm createDirectoryAtURL:[self playlistsFolder] withIntermediateDirectories:YES attributes:nil error:nil];

    NSString *playlistID = YTMUSafeName(name);
    NSString *displayName = [name stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];

    NSData *data = [NSJSONSerialization dataWithJSONObject:@{@"name": displayName.length ? displayName : playlistID, @"tracks": tracks}
                                                   options:NSJSONWritingPrettyPrinted error:nil];
    [data writeToURL:[[self playlistsFolder] URLByAppendingPathComponent:[playlistID stringByAppendingString:@".json"]] atomically:YES];

    // The playlist cover is the cover of its first track that has one (copied, so it survives deleting the song)
    NSURL *coverDest = [[self playlistsFolder] URLByAppendingPathComponent:[playlistID stringByAppendingString:@".png"]];
    [fm removeItemAtURL:coverDest error:nil];
    for (NSString *track in tracks) {
        NSString *cover = [self coverPathForTrack:track];
        if (cover) {
            [fm copyItemAtURL:[NSURL fileURLWithPath:cover] toURL:coverDest error:nil];
            break;
        }
    }
}

+ (void)deletePlaylistWithID:(NSString *)playlistID {
    NSFileManager *fm = [NSFileManager defaultManager];
    [fm removeItemAtURL:[[self playlistsFolder] URLByAppendingPathComponent:[playlistID stringByAppendingString:@".json"]] error:nil];
    [fm removeItemAtURL:[[self playlistsFolder] URLByAppendingPathComponent:[playlistID stringByAppendingString:@".png"]] error:nil];
}

+ (void)renameTrack:(NSString *)oldName to:(NSString *)newName {
    for (NSString *file in [self manifestFiles]) {
        NSDictionary *json = [self readManifest:file];
        if (!json || ![json[@"tracks"] containsObject:oldName]) continue;

        NSMutableArray *tracks = [NSMutableArray array];
        for (id track in json[@"tracks"]) {
            [tracks addObject:[track isEqual:oldName] ? newName : track];
        }
        NSData *data = [NSJSONSerialization dataWithJSONObject:@{@"name": json[@"name"], @"tracks": tracks} options:NSJSONWritingPrettyPrinted error:nil];
        [data writeToURL:[[self playlistsFolder] URLByAppendingPathComponent:file] atomically:YES];
    }
}

@end
