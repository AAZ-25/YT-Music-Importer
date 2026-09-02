#import "YTMIMusicDatabaseImporter.h"
#import "YTMIConstants.h"
#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>
#import <AudioToolbox/AudioToolbox.h>
#import <MediaPlayer/MediaPlayer.h>
#import <dlfcn.h>
#import <math.h>
#import <objc/message.h>

static NSString * const YTMIErrorDomain = @"com.aaz.ytmusicimporter";

static NSError *YTMIError(NSInteger code, NSString *message) {
    return [NSError errorWithDomain:YTMIErrorDomain code:code userInfo:@{NSLocalizedDescriptionKey:message ?: @"Music import failed."}];
}

static void YTMITrace(NSMutableArray *trace, NSString *stage) { if (trace && stage.length) [trace addObject:stage]; }

static NSString *YTMISafeText(id value, NSString *fallback) {
    if (![value isKindOfClass:NSString.class]) return fallback;
    NSString *text = [(NSString *)value stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    return text.length ? text : fallback;
}

static BOOL YTMISelector(id target, NSString *name, NSUInteger arguments) {
    SEL selector = NSSelectorFromString(name);
    if (!target || ![target respondsToSelector:selector]) return NO;
    NSMethodSignature *signature = [target methodSignatureForSelector:selector];
    return signature && signature.numberOfArguments == arguments + 2;
}

static NSString *YTMIProperty(void *framework, const char *symbol, NSString *fallback) {
    NSString *__unsafe_unretained *address = framework ? (NSString *__unsafe_unretained *)dlsym(framework, symbol) : NULL;
    return (address && *address) ? *address : fallback;
}

static void YTMISetValue(NSMutableDictionary *values, void *framework, const char *symbol, NSString *fallback, id value) {
    NSString *key = YTMIProperty(framework, symbol, fallback);
    if (key.length && value) values[key] = value;
}

static void YTMISetOptionalValue(NSMutableDictionary *values, void *framework, const char *symbol, id value) {
    NSString *__unsafe_unretained *address = framework ? (NSString *__unsafe_unretained *)dlsym(framework, symbol) : NULL;
    NSString *key = (address && *address) ? *address : nil;
    if (key.length && value) values[key] = value;
}

static NSString *YTMIMediaFolder(id library) {
    if (YTMISelector(library, @"mediaFolderPath", 0)) {
        id path = ((id (*)(id, SEL))objc_msgSend)(library, NSSelectorFromString(@"mediaFolderPath"));
        if ([path isKindOfClass:NSString.class] && [path length]) return path;
    }
    NSFileManager *fm = NSFileManager.defaultManager;
    for (NSString *candidate in @[@"/var/mobile/Media/iTunes_Control/Music", @"/private/var/mobile/Media/iTunes_Control/Music"]) {
        BOOL directory = NO;
        if ([fm fileExistsAtPath:candidate isDirectory:&directory] && directory) return candidate;
    }
    return nil;
}

static NSString *YTMIDestinationDirectory(NSString *mediaFolder, NSError **error) {
    NSFileManager *fm = NSFileManager.defaultManager;
    for (NSUInteger index = 0; index < 50; index++) {
        NSString *candidate = [mediaFolder stringByAppendingPathComponent:[NSString stringWithFormat:@"F%02lu", (unsigned long)index]];
        BOOL directory = NO;
        if ([fm fileExistsAtPath:candidate isDirectory:&directory] && directory) return candidate;
    }
    NSString *directory = [mediaFolder stringByAppendingPathComponent:@"F00"];
    return [fm createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions:@0755} error:error] ? directory : nil;
}

static BOOL YTMIPlayablePath(NSString *path) {
    if (!path.length || ![NSFileManager.defaultManager isReadableFileAtPath:path]) return NO;
    AVURLAsset *asset = [AVURLAsset URLAssetWithURL:[NSURL fileURLWithPath:path] options:nil];
    AVAssetTrack *audio = [asset tracksWithMediaType:AVMediaTypeAudio].firstObject;
    return audio && CMTIME_IS_NUMERIC(asset.duration) && CMTimeGetSeconds(asset.duration) > 0.25;
}

static void YTMINotifyLibrary(id library) {
    for (NSString *name in @[@"notifyEntitiesAddedOrRemoved", @"notifyContentsDidChange", @"notifyLibraryImportDidFinish"]) {
        if (YTMISelector(library, name, 0)) ((void (*)(id, SEL))objc_msgSend)(library, NSSelectorFromString(name));
    }
}

static BOOL YTMIQueryContainsTrack(unsigned long long persistentID,
                                   BOOL ignoreSystemFilters,
                                   BOOL ignoreRestrictions,
                                   NSString *property,
                                   id value) {
    @try {
        MPMediaQuery *query = [MPMediaQuery songsQuery];
        if (!query) return NO;
        if (ignoreSystemFilters && YTMISelector(query, @"setIgnoreSystemFilterPredicates:", 1)) {
            ((void (*)(id, SEL, BOOL))objc_msgSend)(query, NSSelectorFromString(@"setIgnoreSystemFilterPredicates:"), YES);
        }
        if (ignoreRestrictions && YTMISelector(query, @"setIgnoreRestrictionsPredicates:", 1)) {
            ((void (*)(id, SEL, BOOL))objc_msgSend)(query, NSSelectorFromString(@"setIgnoreRestrictionsPredicates:"), YES);
        }
        [query addFilterPredicate:[MPMediaPropertyPredicate predicateWithValue:@(persistentID)
            forProperty:MPMediaItemPropertyPersistentID]];
        if (property.length && value) {
            [query addFilterPredicate:[MPMediaPropertyPredicate predicateWithValue:value forProperty:property]];
        }
        for (MPMediaItem *item in query.items ?: @[]) {
            if (item.persistentID == persistentID) return YES;
        }
    } @catch (__unused NSException *exception) {}
    return NO;
}

static void YTMITraceCheck(NSMutableArray *trace, NSString *name, BOOL matched) {
    YTMITrace(trace, [NSString stringWithFormat:@"music.filter.%@.%@", name, matched ? @"match" : @"failed"]);
}

static void YTMIRollBackEntity(Class entityClass, id library, unsigned long long persistentID) {
    if (persistentID && YTMISelector(entityClass, @"deleteFromLibrary:deletionType:persistentIDs:count:", 4)) {
        int64_t identifier = (int64_t)persistentID;
        @try {
            ((BOOL (*)(id, SEL, id, int, const int64_t *, NSUInteger))objc_msgSend)(entityClass,
                NSSelectorFromString(@"deleteFromLibrary:deletionType:persistentIDs:count:"),
                library, 1, &identifier, 1);
        } @catch (__unused NSException *exception) {}
    }
}

static void YTMIRollBackImport(Class trackClass, unsigned long long trackID,
                               Class artistClass, unsigned long long artistID,
                               Class albumClass, unsigned long long albumID,
                               id library, NSString *path) {
    YTMIRollBackEntity(trackClass, library, trackID);
    YTMIRollBackEntity(albumClass, library, albumID);
    YTMIRollBackEntity(artistClass, library, artistID);
    if (path.length) [NSFileManager.defaultManager removeItemAtPath:path error:nil];
    YTMINotifyLibrary(library);
}

@implementation YTMIMusicDatabaseImporter
- (BOOL)importAudioAtURL:(NSURL *)audioURL metadata:(NSDictionary *)metadata trace:(NSMutableArray *)trace error:(NSError **)error {
    if (![NSThread isMainThread]) {
        __block BOOL result = NO; __block NSError *inner = nil;
        dispatch_sync(dispatch_get_main_queue(), ^{ result = [self importAudioAtURL:audioURL metadata:metadata trace:trace error:&inner]; });
        if (error) *error = inner;
        return result;
    }

    NSFileManager *fm = NSFileManager.defaultManager;
    if (!audioURL.isFileURL || ![fm fileExistsAtPath:audioURL.path]) { if (error) *error = YTMIError(19, @"The prepared audio file is unavailable."); return NO; }
    YTMITrace(trace, @"music.source.present");

    AVURLAsset *sourceAsset = [AVURLAsset URLAssetWithURL:audioURL options:nil];
    AVAssetTrack *sourceTrack = [sourceAsset tracksWithMediaType:AVMediaTypeAudio].firstObject;
    if (!sourceTrack || !CMTIME_IS_NUMERIC(sourceAsset.duration) || CMTimeGetSeconds(sourceAsset.duration) <= 0.25) { if (error) *error = YTMIError(80, @"The prepared audio is not playable."); return NO; }
    YTMITrace(trace, @"music.source.playable");

    void *music = dlopen("/System/Library/PrivateFrameworks/MusicLibrary.framework/MusicLibrary", RTLD_NOW | RTLD_LOCAL);
    Class libraryClass = NSClassFromString(@"ML3MusicLibrary");
    Class trackClass = NSClassFromString(@"ML3Track");
    Class artistClass = NSClassFromString(@"ML3Artist");
    Class albumClass = NSClassFromString(@"ML3Album");
    if (!music || !libraryClass || !trackClass || !artistClass || !albumClass ||
        !YTMISelector(libraryClass, @"sharedLibrary", 0) ||
        !YTMISelector(trackClass, @"newWithDictionary:inLibrary:", 2) ||
        !YTMISelector(artistClass, @"newWithDictionary:inLibrary:", 2) ||
        !YTMISelector(albumClass, @"newWithDictionary:inLibrary:", 2)) {
        if (error) *error = YTMIError(97, @"Music's local-library interface is unavailable on this system.");
        return NO;
    }
    id library = ((id (*)(id, SEL))objc_msgSend)(libraryClass, NSSelectorFromString(@"sharedLibrary"));
    if (!library) { if (error) *error = YTMIError(97, @"Music's local library could not be opened."); return NO; }
    YTMITrace(trace, @"music.local-api.available");

    NSString *mediaFolder = YTMIMediaFolder(library);
    NSError *fileError = nil;
    NSString *directory = mediaFolder.length ? YTMIDestinationDirectory(mediaFolder, &fileError) : nil;
    if (!directory.length) { if (error) *error = YTMIError(51, @"Music's local storage could not be prepared."); return NO; }
    NSString *token = [NSUUID.UUID.UUIDString stringByReplacingOccurrencesOfString:@"-" withString:@""];
    NSString *destinationPath = [directory stringByAppendingPathComponent:[[token substringToIndex:MIN((NSUInteger)16, token.length)] stringByAppendingPathExtension:@"m4a"]];
    if (![fm copyItemAtPath:audioURL.path toPath:destinationPath error:&fileError] || !YTMIPlayablePath(destinationPath)) {
        [fm removeItemAtPath:destinationPath error:nil];
        if (error) *error = YTMIError(53, @"The playable audio could not be copied into Music storage.");
        return NO;
    }
    YTMITrace(trace, @"music.payload.copied");

    double seconds = CMTimeGetSeconds(sourceAsset.duration);
    long long milliseconds = (long long)llround(seconds * 1000.0);
    long long sampleRate = 0, durationSamples = 0, bitRate = (long long)llround(sourceTrack.estimatedDataRate / 1000.0);
    UInt32 audioFormat = 0;
    if (sourceTrack.formatDescriptions.count) {
        const AudioStreamBasicDescription *asbd = CMAudioFormatDescriptionGetStreamBasicDescription((__bridge CMAudioFormatDescriptionRef)sourceTrack.formatDescriptions.firstObject);
        if (asbd) {
            sampleRate = (long long)llround(asbd->mSampleRate);
            audioFormat = asbd->mFormatID;
        }
    }
    if (sampleRate > 0) durationSamples = CMTimeConvertScale(sourceAsset.duration, (int32_t)sampleRate, kCMTimeRoundingMethod_RoundHalfAwayFromZero).value;
    NSDictionary *attributes = [fm attributesOfItemAtPath:destinationPath error:nil];
    NSString *title = YTMISafeText(metadata[YTMIJobTitleKey], @"YouTube Audio");
    NSString *artist = YTMISafeText(metadata[YTMIJobArtistKey], @"YouTube");
    NSString *album = YTMISafeText(metadata[YTMIJobAlbumKey], @"YT Music Importer");
    NSDate *now = NSDate.date;

    // Artist and album are normalized collection entities in ML3. The readable
    // track properties are SQL joins; writing those strings directly never
    // establishes item_artist_pid / album_pid and produces a half-valid row.
    NSString *artistNameProperty = YTMIProperty(music, "ML3ArtistPropertyName", @"item_artist");
    NSString *albumNameProperty = YTMIProperty(music, "ML3AlbumPropertyName", @"album");
    id artistEntity = nil, albumEntity = nil;
    @try {
        artistEntity = ((id (*)(id, SEL, id, id))objc_msgSend)(artistClass,
            NSSelectorFromString(@"newWithDictionary:inLibrary:"),
            @{artistNameProperty: artist}, library);
        albumEntity = ((id (*)(id, SEL, id, id))objc_msgSend)(albumClass,
            NSSelectorFromString(@"newWithDictionary:inLibrary:"),
            @{albumNameProperty: album}, library);
    } @catch (__unused NSException *exception) {
        artistEntity = nil;
        albumEntity = nil;
    }
    unsigned long long artistID = artistEntity && YTMISelector(artistEntity, @"persistentID", 0) ? ((unsigned long long (*)(id, SEL))objc_msgSend)(artistEntity, NSSelectorFromString(@"persistentID")) : 0;
    unsigned long long albumID = albumEntity && YTMISelector(albumEntity, @"persistentID", 0) ? ((unsigned long long (*)(id, SEL))objc_msgSend)(albumEntity, NSSelectorFromString(@"persistentID")) : 0;
    if (!artistID || !albumID) {
        YTMIRollBackEntity(albumClass, library, albumID);
        YTMIRollBackEntity(artistClass, library, artistID);
        [fm removeItemAtPath:destinationPath error:nil];
        if (error) *error = YTMIError(115, @"Music could not create the artist and album relationships.");
        return NO;
    }
    YTMITrace(trace, @"music.collections.created");

    NSMutableDictionary *values = [NSMutableDictionary dictionary];
    YTMISetValue(values, music, "ML3TrackPropertyTitle", @"title", title);
    YTMISetValue(values, music, "ML3TrackPropertyArtistPersistentID", @"item_artist_pid", @(artistID));
    YTMISetValue(values, music, "ML3TrackPropertyAlbumPersistentID", @"album_pid", @(albumID));
    // MPMediaTypeMusic is 1 << 0. Value 8 is Audio iTunes U and is excluded
    // from Music's songs query even though the underlying ML3 row is visible.
    YTMISetValue(values, music, "ML3TrackPropertyMediaType", @"media_type", @1);
    YTMISetValue(values, music, "ML3TrackPropertyTotalSize", @"total_size", attributes[NSFileSize] ?: @0);
    YTMISetValue(values, music, "ML3TrackPropertyTotalTime", @"total_time", @(milliseconds));
    YTMISetValue(values, music, "ML3TrackPropertyDateAdded", @"date_added", now);
    YTMISetValue(values, music, "ML3TrackPropertyDateModified", @"date_modified", now);
    YTMISetValue(values, music, "ML3TrackPropertyTrackNumber", @"track_number", @1);
    YTMISetValue(values, music, "ML3TrackPropertyDiscNumber", @"disc_number", @1);
    YTMISetValue(values, music, "ML3TrackPropertyHidden", @"hidden", @NO);
    YTMISetValue(values, music, "ML3TrackPropertyIsInMyLibrary", @"in_my_library", @YES);
    if (audioFormat) YTMISetOptionalValue(values, music, "ML3TrackPropertyAudioFormat", @(audioFormat));
    YTMISetOptionalValue(values, music, "ML3TrackPropertyDataKind", @0);
    if (sampleRate > 0) YTMISetOptionalValue(values, music, "ML3TrackPropertySampleRate", @(sampleRate));
    if (durationSamples > 0) YTMISetOptionalValue(values, music, "ML3TrackPropertyDurationInSamples", @(durationSamples));
    if (bitRate > 0) YTMISetOptionalValue(values, music, "ML3TrackPropertyBitRate", @(bitRate));

    id track = nil;
    @try { track = ((id (*)(id, SEL, id, id))objc_msgSend)(trackClass, NSSelectorFromString(@"newWithDictionary:inLibrary:"), values, library); }
    @catch (__unused NSException *exception) { track = nil; }
    if (!track) {
        YTMIRollBackImport(trackClass, 0, artistClass, artistID, albumClass, albumID, library, destinationPath);
        if (error) *error = YTMIError(98, @"Music rejected the local track record.");
        return NO;
    }
    YTMITrace(trace, @"music.record.created");

    unsigned long long persistentID = YTMISelector(track, @"persistentID", 0) ? ((unsigned long long (*)(id, SEL))objc_msgSend)(track, NSSelectorFromString(@"persistentID")) : 0;
    NSString *representativeProperty = @"representative_item_pid";
    BOOL artistLinked = NO, albumLinked = NO;
    if (persistentID) {
        @try {
            artistLinked = YTMISelector(artistEntity, @"setValue:forProperty:", 2) &&
                ((BOOL (*)(id, SEL, id, id))objc_msgSend)(artistEntity, NSSelectorFromString(@"setValue:forProperty:"), @(persistentID), representativeProperty);
            albumLinked = YTMISelector(albumEntity, @"setValue:forProperty:", 2) &&
                ((BOOL (*)(id, SEL, id, id))objc_msgSend)(albumEntity, NSSelectorFromString(@"setValue:forProperty:"), @(persistentID), representativeProperty);
        } @catch (__unused NSException *exception) {
            artistLinked = NO;
            albumLinked = NO;
        }
    }
    if (!persistentID || !artistLinked || !albumLinked) {
        YTMIRollBackImport(trackClass, persistentID, artistClass, artistID, albumClass, albumID, library, destinationPath);
        if (error) *error = YTMIError(116, @"Music could not finalize the artist and album relationships.");
        return NO;
    }
    YTMITrace(trace, @"music.collections.linked");
    if (!persistentID || !YTMISelector(track, @"populateLocationPropertiesWithPath:protectionType:", 2)) {
        YTMIRollBackImport(trackClass, persistentID, artistClass, artistID, albumClass, albumID, library, destinationPath);
        if (error) *error = YTMIError(99, @"Music's supported local-location transaction is unavailable.");
        return NO;
    }
    YTMITrace(trace, @"music.location.transaction.started");
    @try { ((void (*)(id, SEL, id, long long))objc_msgSend)(track, NSSelectorFromString(@"populateLocationPropertiesWithPath:protectionType:"), destinationPath, 0); }
    @catch (__unused NSException *exception) { YTMIRollBackImport(trackClass, persistentID, artistClass, artistID, albumClass, albumID, library, destinationPath); if (error) *error = YTMIError(99, @"Music rejected the local-location transaction."); return NO; }
    YTMITrace(trace, @"music.location.transaction.returned");

    // Match MediaPlayer's own add-to-library path: membership is asserted after
    // the location transaction, then read back before a visible query is trusted.
    NSString *membershipProperty = YTMIProperty(music, "ML3TrackPropertyIsInMyLibrary", @"in_my_library");
    if (!YTMISelector(track, @"setValue:forProperty:", 2) || !YTMISelector(track, @"valueForProperty:", 1)) {
        YTMIRollBackImport(trackClass, persistentID, artistClass, artistID, albumClass, albumID, library, destinationPath);
        if (error) *error = YTMIError(103, @"Music could not finalize local-library membership.");
        return NO;
    }
    BOOL membershipSaved = NO;
    @try { membershipSaved = ((BOOL (*)(id, SEL, id, id))objc_msgSend)(track, NSSelectorFromString(@"setValue:forProperty:"), @YES, membershipProperty); }
    @catch (__unused NSException *exception) { membershipSaved = NO; }
    if (!membershipSaved) { YTMIRollBackImport(trackClass, persistentID, artistClass, artistID, albumClass, albumID, library, destinationPath); if (error) *error = YTMIError(103, @"Music rejected local-library membership."); return NO; }
    id membership = ((id (*)(id, SEL, id))objc_msgSend)(track, NSSelectorFromString(@"valueForProperty:"), membershipProperty);
    if (![membership respondsToSelector:@selector(boolValue)] || ![membership boolValue]) {
        YTMIRollBackImport(trackClass, persistentID, artistClass, artistID, albumClass, albumID, library, destinationPath);
        if (error) *error = YTMIError(104, @"Music did not retain local-library membership.");
        return NO;
    }
    YTMITrace(trace, @"music.membership.verified");

    // ML3Entity commits an explicit property dictionary synchronously through
    // its writer connection. Reassert user metadata after location linking so
    // the reopened record is verified from committed values, not constructor state.
    if (!YTMISelector(track, @"setValuesForPropertiesWithDictionary:", 1)) {
        YTMIRollBackImport(trackClass, persistentID, artistClass, artistID, albumClass, albumID, library, destinationPath);
        if (error) *error = YTMIError(111, @"Music's metadata transaction is unavailable.");
        return NO;
    }
    NSDictionary *committedMetadata = @{
        YTMIProperty(music, "ML3TrackPropertyTitle", @"title"): title,
        YTMIProperty(music, "ML3TrackPropertyArtistPersistentID", @"item_artist_pid"): @(artistID),
        YTMIProperty(music, "ML3TrackPropertyAlbumPersistentID", @"album_pid"): @(albumID),
        YTMIProperty(music, "ML3TrackPropertyMediaType", @"media_type"): @1
    };
    BOOL metadataSaved = NO;
    @try { metadataSaved = ((BOOL (*)(id, SEL, id))objc_msgSend)(track, NSSelectorFromString(@"setValuesForPropertiesWithDictionary:"), committedMetadata); }
    @catch (__unused NSException *exception) { metadataSaved = NO; }
    if (!metadataSaved) {
        YTMIRollBackImport(trackClass, persistentID, artistClass, artistID, albumClass, albumID, library, destinationPath);
        if (error) *error = YTMIError(111, @"Music rejected the metadata transaction.");
        return NO;
    }
    YTMITrace(trace, @"music.metadata.transaction.committed");

    YTMINotifyLibrary(library);

    id freshTrack = nil;
    NSString *resolvedPath = nil;
    BOOL recordExists = NO, recordVisible = NO, pathReadable = NO, pathPlayable = NO, songVisible = NO;
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:8.0];
    do {
        recordExists = YTMISelector(trackClass, @"trackWithPersistentID:existsInLibrary:", 2) && ((BOOL (*)(id, SEL, unsigned long long, id))objc_msgSend)(trackClass, NSSelectorFromString(@"trackWithPersistentID:existsInLibrary:"), persistentID, library);
        recordVisible = YTMISelector(trackClass, @"trackWithPersistentID:visibleInLibrary:", 2) && ((BOOL (*)(id, SEL, unsigned long long, id))objc_msgSend)(trackClass, NSSelectorFromString(@"trackWithPersistentID:visibleInLibrary:"), persistentID, library);
        if (recordExists && YTMISelector(trackClass, @"newWithPersistentID:inLibrary:", 2)) freshTrack = ((id (*)(id, SEL, unsigned long long, id))objc_msgSend)(trackClass, NSSelectorFromString(@"newWithPersistentID:inLibrary:"), persistentID, library);
        resolvedPath = freshTrack && YTMISelector(freshTrack, @"absoluteFilePath", 0) ? ((id (*)(id, SEL))objc_msgSend)(freshTrack, NSSelectorFromString(@"absoluteFilePath")) : nil;
        pathReadable = [resolvedPath isKindOfClass:NSString.class] && [fm isReadableFileAtPath:resolvedPath];
        pathPlayable = pathReadable && YTMIPlayablePath(resolvedPath);
        MPMediaQuery *songs = [MPMediaQuery songsQuery];
        MPMediaPropertyPredicate *identifier = [MPMediaPropertyPredicate predicateWithValue:@(persistentID) forProperty:MPMediaItemPropertyPersistentID];
        [songs addFilterPredicate:identifier];
        for (MPMediaItem *item in songs.items ?: @[]) {
            if (item.persistentID == persistentID) { songVisible = YES; break; }
        }
        if (freshTrack && pathPlayable && songVisible) break;
        [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.10]];
    } while (deadline.timeIntervalSinceNow > 0);
    if (!recordExists) { YTMIRollBackImport(trackClass, persistentID, artistClass, artistID, albumClass, albumID, library, destinationPath); if (error) *error = YTMIError(105, @"Music did not retain the created record."); return NO; }
    if (!freshTrack) { YTMIRollBackImport(trackClass, persistentID, artistClass, artistID, albumClass, albumID, library, destinationPath); if (error) *error = YTMIError(107, @"Music could not reopen the created record."); return NO; }
    if (![resolvedPath isKindOfClass:NSString.class] || !resolvedPath.length) { YTMIRollBackImport(trackClass, persistentID, artistClass, artistID, albumClass, albumID, library, destinationPath); if (error) *error = YTMIError(108, @"Music did not retain the local audio location."); return NO; }
    if (!pathReadable) { YTMIRollBackImport(trackClass, persistentID, artistClass, artistID, albumClass, albumID, library, destinationPath); if (error) *error = YTMIError(109, @"Music retained an unreadable local audio location."); return NO; }
    if (!pathPlayable) { YTMIRollBackImport(trackClass, persistentID, artistClass, artistID, albumClass, albumID, library, destinationPath); if (error) *error = YTMIError(110, @"Music retained the record, but its local audio is not playable."); return NO; }
    if (!songVisible) {
        // Inspect the exact unrestricted Songs row first, then add each known
        // MediaPlayer predicate independently. This keeps one failed filter
        // from being hidden inside another generic code-124 result.
        BOOL unrestrictedSong = YTMIQueryContainsTrack(persistentID, YES, YES, nil, nil);
        BOOL restrictionsOnlySong = YTMIQueryContainsTrack(persistentID, YES, NO, nil, nil);
        BOOL nonPurgeableSong = YTMIQueryContainsTrack(persistentID, YES, YES, @"hasNonPurgeableAsset", @YES);
        BOOL playableSong = YTMIQueryContainsTrack(persistentID, YES, YES, @"isPlayable", @YES);
        BOOL matchAudioSong = YTMIQueryContainsTrack(persistentID, YES, YES, @"isMatchAudio", @YES);
        BOOL nonRentalSong = YTMIQueryContainsTrack(persistentID, YES, YES, @"isRental", @NO);
        YTMITraceCheck(trace, @"unrestricted-songs", unrestrictedSong);
        YTMITraceCheck(trace, @"restrictions-only", restrictionsOnlySong);
        YTMITraceCheck(trace, @"non-purgeable", nonPurgeableSong);
        YTMITraceCheck(trace, @"playable", playableSong);
        YTMITraceCheck(trace, @"match-audio", matchAudioSong);
        YTMITraceCheck(trace, @"non-rental", nonRentalSong);

        NSInteger filterCode = 131;
        NSString *filterMessage = @"Music's active system-filter selection excluded the local song.";
        if (!unrestrictedSong) {
            filterCode = 125;
            filterMessage = @"Music excluded the record from the unrestricted Songs media classification.";
        } else if (!restrictionsOnlySong) {
            filterCode = 130;
            filterMessage = @"Music's restrictions predicate excluded the local song.";
        } else if (!nonRentalSong) {
            filterCode = 129;
            filterMessage = @"Music classified the local song as a rental.";
        } else if (!playableSong) {
            filterCode = 127;
            filterMessage = @"Music's playability predicate excluded the local song.";
        } else if (!nonPurgeableSong) {
            filterCode = 126;
            filterMessage = @"Music did not classify the local song as a non-purgeable asset.";
        } else if (!matchAudioSong) {
            filterCode = 128;
            filterMessage = @"Music's match-audio predicate excluded the local song.";
        }
        YTMIRollBackImport(trackClass, persistentID, artistClass, artistID, albumClass, albumID, library, destinationPath);
        if (error) *error = YTMIError(filterCode, filterMessage);
        return NO;
    }
    if (recordVisible) YTMITrace(trace, @"music.generic-filter.match");
    YTMITrace(trace, @"music.songs-query.match");

    SEL valueSEL = NSSelectorFromString(@"valueForProperty:");
    if (!YTMISelector(freshTrack, @"valueForProperty:", 1)) { YTMIRollBackImport(trackClass, persistentID, artistClass, artistID, albumClass, albumID, library, destinationPath); if (error) *error = YTMIError(111, @"Music could not read back the imported metadata."); return NO; }
    NSString *actualTitle = ((id (*)(id, SEL, id))objc_msgSend)(freshTrack, valueSEL, YTMIProperty(music, "ML3TrackPropertyTitle", @"title"));
    NSString *actualArtist = ((id (*)(id, SEL, id))objc_msgSend)(freshTrack, valueSEL, YTMIProperty(music, "ML3TrackPropertyArtist", @"artist"));
    NSString *actualAlbum = ((id (*)(id, SEL, id))objc_msgSend)(freshTrack, valueSEL, YTMIProperty(music, "ML3TrackPropertyAlbum", @"album"));
    id actualMediaType = ((id (*)(id, SEL, id))objc_msgSend)(freshTrack, valueSEL, YTMIProperty(music, "ML3TrackPropertyMediaType", @"media_type"));
    id actualArtistID = ((id (*)(id, SEL, id))objc_msgSend)(freshTrack, valueSEL, YTMIProperty(music, "ML3TrackPropertyArtistPersistentID", @"item_artist_pid"));
    id actualAlbumID = ((id (*)(id, SEL, id))objc_msgSend)(freshTrack, valueSEL, YTMIProperty(music, "ML3TrackPropertyAlbumPersistentID", @"album_pid"));
    if (![actualMediaType respondsToSelector:@selector(unsignedIntegerValue)] || [actualMediaType unsignedIntegerValue] != MPMediaTypeMusic) { YTMIRollBackImport(trackClass, persistentID, artistClass, artistID, albumClass, albumID, library, destinationPath); if (error) *error = YTMIError(120, @"Music did not retain the song media type."); return NO; }
    YTMITrace(trace, @"music.media-type.music");
    if (![actualTitle isEqualToString:title]) { YTMIRollBackImport(trackClass, persistentID, artistClass, artistID, albumClass, albumID, library, destinationPath); if (error) *error = YTMIError(112, @"Music saved a different title than requested."); return NO; }
    YTMITrace(trace, @"music.metadata.title-match");
    if (![actualArtistID respondsToSelector:@selector(unsignedLongLongValue)] || [actualArtistID unsignedLongLongValue] != artistID) { YTMIRollBackImport(trackClass, persistentID, artistClass, artistID, albumClass, albumID, library, destinationPath); if (error) *error = YTMIError(117, @"Music did not retain the artist relationship."); return NO; }
    YTMITrace(trace, @"music.artist.relationship-match");
    if (![actualAlbumID respondsToSelector:@selector(unsignedLongLongValue)] || [actualAlbumID unsignedLongLongValue] != albumID) { YTMIRollBackImport(trackClass, persistentID, artistClass, artistID, albumClass, albumID, library, destinationPath); if (error) *error = YTMIError(118, @"Music did not retain the album relationship."); return NO; }
    YTMITrace(trace, @"music.album.relationship-match");
    if (![actualArtist isEqualToString:artist]) { YTMIRollBackImport(trackClass, persistentID, artistClass, artistID, albumClass, albumID, library, destinationPath); if (error) *error = YTMIError(113, @"Music saved a different artist than requested."); return NO; }
    YTMITrace(trace, @"music.metadata.artist-match");
    if (![actualAlbum isEqualToString:album]) { YTMIRollBackImport(trackClass, persistentID, artistClass, artistID, albumClass, albumID, library, destinationPath); if (error) *error = YTMIError(114, @"Music saved a different album than requested."); return NO; }
    YTMITrace(trace, @"music.metadata.album-match");
    YTMITrace(trace, @"music.metadata.verified");

    YTMINotifyLibrary(library);
    YTMITrace(trace, @"music.payload.verified");
    return YES;
}
@end
