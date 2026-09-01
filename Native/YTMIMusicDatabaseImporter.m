#import "YTMIMusicDatabaseImporter.h"
#import "YTMIConstants.h"
#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>
#import <AudioToolbox/AudioToolbox.h>
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

static void YTMIRollBackTrack(Class trackClass, id library, unsigned long long persistentID, NSString *path) {
    if (persistentID && YTMISelector(trackClass, @"removeFromMyLibrary:deletionType:persistentIDs:count:", 4)) {
        int64_t identifier = (int64_t)persistentID;
        @try {
            ((BOOL (*)(id, SEL, id, int, const int64_t *, NSUInteger))objc_msgSend)(trackClass,
                NSSelectorFromString(@"removeFromMyLibrary:deletionType:persistentIDs:count:"),
                library, 1, &identifier, 1);
        } @catch (__unused NSException *exception) {}
    }
    if (path.length) [NSFileManager.defaultManager removeItemAtPath:path error:nil];
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
    if (!music || !libraryClass || !trackClass || !YTMISelector(libraryClass, @"sharedLibrary", 0) || !YTMISelector(trackClass, @"newWithDictionary:inLibrary:", 2)) {
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
    NSMutableDictionary *values = [NSMutableDictionary dictionary];
    YTMISetValue(values, music, "ML3TrackPropertyTitle", @"title", title);
    YTMISetValue(values, music, "ML3TrackPropertyArtist", @"artist", artist);
    YTMISetValue(values, music, "ML3TrackPropertyAlbum", @"album", album);
    // ML3 uses a bitmask here. 8 is a song; 1 is not the local-song type.
    YTMISetValue(values, music, "ML3TrackPropertyMediaType", @"media_type", @8);
    YTMISetValue(values, music, "ML3TrackPropertyMediaKind", @"media_kind", @1);
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
        [fm removeItemAtPath:destinationPath error:nil];
        if (error) *error = YTMIError(98, @"Music rejected the local track record.");
        return NO;
    }
    YTMITrace(trace, @"music.record.created");

    unsigned long long persistentID = YTMISelector(track, @"persistentID", 0) ? ((unsigned long long (*)(id, SEL))objc_msgSend)(track, NSSelectorFromString(@"persistentID")) : 0;
    if (!persistentID || !YTMISelector(track, @"populateLocationPropertiesWithPath:protectionType:", 2)) {
        YTMIRollBackTrack(trackClass, library, persistentID, destinationPath);
        if (error) *error = YTMIError(99, @"Music's supported local-location transaction is unavailable.");
        return NO;
    }
    YTMITrace(trace, @"music.location.transaction.started");
    @try { ((void (*)(id, SEL, id, long long))objc_msgSend)(track, NSSelectorFromString(@"populateLocationPropertiesWithPath:protectionType:"), destinationPath, 0); }
    @catch (__unused NSException *exception) { YTMIRollBackTrack(trackClass, library, persistentID, destinationPath); if (error) *error = YTMIError(99, @"Music rejected the local-location transaction."); return NO; }
    YTMITrace(trace, @"music.location.transaction.returned");

    // Match MediaPlayer's own add-to-library path: membership is asserted after
    // the location transaction, then read back before a visible query is trusted.
    NSString *membershipProperty = YTMIProperty(music, "ML3TrackPropertyIsInMyLibrary", @"in_my_library");
    if (!YTMISelector(track, @"setValue:forProperty:", 2) || !YTMISelector(track, @"valueForProperty:", 1)) {
        YTMIRollBackTrack(trackClass, library, persistentID, destinationPath);
        if (error) *error = YTMIError(103, @"Music could not finalize local-library membership.");
        return NO;
    }
    BOOL membershipSaved = NO;
    @try { membershipSaved = ((BOOL (*)(id, SEL, id, id))objc_msgSend)(track, NSSelectorFromString(@"setValue:forProperty:"), @YES, membershipProperty); }
    @catch (__unused NSException *exception) { membershipSaved = NO; }
    if (!membershipSaved) { YTMIRollBackTrack(trackClass, library, persistentID, destinationPath); if (error) *error = YTMIError(103, @"Music rejected local-library membership."); return NO; }
    id membership = ((id (*)(id, SEL, id))objc_msgSend)(track, NSSelectorFromString(@"valueForProperty:"), membershipProperty);
    if (![membership respondsToSelector:@selector(boolValue)] || ![membership boolValue]) {
        YTMIRollBackTrack(trackClass, library, persistentID, destinationPath);
        if (error) *error = YTMIError(104, @"Music did not retain local-library membership.");
        return NO;
    }
    YTMITrace(trace, @"music.membership.verified");

    // ML3Entity commits an explicit property dictionary synchronously through
    // its writer connection. Reassert user metadata after location linking so
    // the reopened record is verified from committed values, not constructor state.
    if (!YTMISelector(track, @"setValuesForPropertiesWithDictionary:", 1)) {
        YTMIRollBackTrack(trackClass, library, persistentID, destinationPath);
        if (error) *error = YTMIError(111, @"Music's metadata transaction is unavailable.");
        return NO;
    }
    NSDictionary *committedMetadata = @{
        YTMIProperty(music, "ML3TrackPropertyTitle", @"title"): title,
        YTMIProperty(music, "ML3TrackPropertyArtist", @"artist"): artist,
        YTMIProperty(music, "ML3TrackPropertyAlbum", @"album"): album
    };
    BOOL metadataSaved = NO;
    @try { metadataSaved = ((BOOL (*)(id, SEL, id))objc_msgSend)(track, NSSelectorFromString(@"setValuesForPropertiesWithDictionary:"), committedMetadata); }
    @catch (__unused NSException *exception) { metadataSaved = NO; }
    if (!metadataSaved) {
        YTMIRollBackTrack(trackClass, library, persistentID, destinationPath);
        if (error) *error = YTMIError(111, @"Music rejected the metadata transaction.");
        return NO;
    }
    YTMITrace(trace, @"music.metadata.transaction.committed");

    id freshTrack = nil;
    NSString *resolvedPath = nil;
    BOOL recordExists = NO, recordVisible = NO, pathReadable = NO, pathPlayable = NO;
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:8.0];
    do {
        recordExists = YTMISelector(trackClass, @"trackWithPersistentID:existsInLibrary:", 2) && ((BOOL (*)(id, SEL, unsigned long long, id))objc_msgSend)(trackClass, NSSelectorFromString(@"trackWithPersistentID:existsInLibrary:"), persistentID, library);
        recordVisible = YTMISelector(trackClass, @"trackWithPersistentID:visibleInLibrary:", 2) && ((BOOL (*)(id, SEL, unsigned long long, id))objc_msgSend)(trackClass, NSSelectorFromString(@"trackWithPersistentID:visibleInLibrary:"), persistentID, library);
        if (recordExists && YTMISelector(trackClass, @"newWithPersistentID:inLibrary:", 2)) freshTrack = ((id (*)(id, SEL, unsigned long long, id))objc_msgSend)(trackClass, NSSelectorFromString(@"newWithPersistentID:inLibrary:"), persistentID, library);
        resolvedPath = freshTrack && YTMISelector(freshTrack, @"absoluteFilePath", 0) ? ((id (*)(id, SEL))objc_msgSend)(freshTrack, NSSelectorFromString(@"absoluteFilePath")) : nil;
        pathReadable = [resolvedPath isKindOfClass:NSString.class] && [fm isReadableFileAtPath:resolvedPath];
        pathPlayable = pathReadable && YTMIPlayablePath(resolvedPath);
        if (freshTrack && recordVisible && pathPlayable) break;
        [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.10]];
    } while (deadline.timeIntervalSinceNow > 0);
    if (!recordExists) { YTMIRollBackTrack(trackClass, library, persistentID, destinationPath); if (error) *error = YTMIError(105, @"Music did not retain the created record."); return NO; }
    if (!recordVisible) { YTMIRollBackTrack(trackClass, library, persistentID, destinationPath); if (error) *error = YTMIError(106, @"Music retained the record but did not expose it in the library."); return NO; }
    if (!freshTrack) { YTMIRollBackTrack(trackClass, library, persistentID, destinationPath); if (error) *error = YTMIError(107, @"Music could not reopen the created record."); return NO; }
    if (![resolvedPath isKindOfClass:NSString.class] || !resolvedPath.length) { YTMIRollBackTrack(trackClass, library, persistentID, destinationPath); if (error) *error = YTMIError(108, @"Music did not retain the local audio location."); return NO; }
    if (!pathReadable) { YTMIRollBackTrack(trackClass, library, persistentID, destinationPath); if (error) *error = YTMIError(109, @"Music retained an unreadable local audio location."); return NO; }
    if (!pathPlayable) { YTMIRollBackTrack(trackClass, library, persistentID, destinationPath); if (error) *error = YTMIError(110, @"Music retained the record, but its local audio is not playable."); return NO; }
    YTMITrace(trace, @"music.record.visible");

    SEL valueSEL = NSSelectorFromString(@"valueForProperty:");
    if (!YTMISelector(freshTrack, @"valueForProperty:", 1)) { YTMIRollBackTrack(trackClass, library, persistentID, destinationPath); if (error) *error = YTMIError(111, @"Music could not read back the imported metadata."); return NO; }
    NSString *actualTitle = ((id (*)(id, SEL, id))objc_msgSend)(freshTrack, valueSEL, YTMIProperty(music, "ML3TrackPropertyTitle", @"title"));
    NSString *actualArtist = ((id (*)(id, SEL, id))objc_msgSend)(freshTrack, valueSEL, YTMIProperty(music, "ML3TrackPropertyArtist", @"artist"));
    NSString *actualAlbum = ((id (*)(id, SEL, id))objc_msgSend)(freshTrack, valueSEL, YTMIProperty(music, "ML3TrackPropertyAlbum", @"album"));
    if (![actualTitle isEqualToString:title]) { YTMIRollBackTrack(trackClass, library, persistentID, destinationPath); if (error) *error = YTMIError(112, @"Music saved a different title than requested."); return NO; }
    YTMITrace(trace, @"music.metadata.title-match");
    if (![actualArtist isEqualToString:artist]) { YTMIRollBackTrack(trackClass, library, persistentID, destinationPath); if (error) *error = YTMIError(113, @"Music saved a different artist than requested."); return NO; }
    YTMITrace(trace, @"music.metadata.artist-match");
    if (![actualAlbum isEqualToString:album]) { YTMIRollBackTrack(trackClass, library, persistentID, destinationPath); if (error) *error = YTMIError(114, @"Music saved a different album than requested."); return NO; }
    YTMITrace(trace, @"music.metadata.album-match");
    YTMITrace(trace, @"music.metadata.verified");

    for (NSString *name in @[@"notifyEntitiesAddedOrRemoved", @"notifyContentsDidChange", @"notifyLibraryImportDidFinish"]) {
        if (YTMISelector(library, name, 0)) ((void (*)(id, SEL))objc_msgSend)(library, NSSelectorFromString(name));
    }
    YTMITrace(trace, @"music.payload.verified");
    return YES;
}
@end
