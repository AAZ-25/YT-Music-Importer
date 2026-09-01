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
    if (sourceTrack.formatDescriptions.count) {
        const AudioStreamBasicDescription *asbd = CMAudioFormatDescriptionGetStreamBasicDescription((__bridge CMAudioFormatDescriptionRef)sourceTrack.formatDescriptions.firstObject);
        if (asbd) sampleRate = (long long)llround(asbd->mSampleRate);
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
    YTMISetValue(values, music, "ML3TrackPropertyMediaType", @"media_type", @1);
    YTMISetValue(values, music, "ML3TrackPropertyMediaKind", @"media_kind", @1);
    YTMISetValue(values, music, "ML3TrackPropertyTotalSize", @"total_size", attributes[NSFileSize] ?: @0);
    YTMISetValue(values, music, "ML3TrackPropertyTotalTime", @"total_time", @(milliseconds));
    YTMISetValue(values, music, "ML3TrackPropertyDateAdded", @"date_added", now);
    YTMISetValue(values, music, "ML3TrackPropertyDateModified", @"date_modified", now);
    YTMISetValue(values, music, "ML3TrackPropertyTrackNumber", @"track_number", @1);
    YTMISetValue(values, music, "ML3TrackPropertyDiscNumber", @"disc_number", @1);
    YTMISetValue(values, music, "ML3TrackPropertyHidden", @"hidden", @NO);
    YTMISetValue(values, music, "ML3TrackPropertyIsInMyLibrary", @"is_in_my_library", @YES);
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
        if (error) *error = YTMIError(99, @"Music's supported local-location transaction is unavailable.");
        return NO;
    }
    YTMITrace(trace, @"music.location.transaction.started");
    @try { ((void (*)(id, SEL, id, long long))objc_msgSend)(track, NSSelectorFromString(@"populateLocationPropertiesWithPath:protectionType:"), destinationPath, 0); }
    @catch (__unused NSException *exception) { if (error) *error = YTMIError(99, @"Music rejected the local-location transaction."); return NO; }
    YTMITrace(trace, @"music.location.transaction.returned");

    id freshTrack = nil;
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:8.0];
    do {
        BOOL visible = YTMISelector(trackClass, @"trackWithPersistentID:visibleInLibrary:", 2) && ((BOOL (*)(id, SEL, unsigned long long, id))objc_msgSend)(trackClass, NSSelectorFromString(@"trackWithPersistentID:visibleInLibrary:"), persistentID, library);
        if (visible && YTMISelector(trackClass, @"newWithPersistentID:inLibrary:", 2)) freshTrack = ((id (*)(id, SEL, unsigned long long, id))objc_msgSend)(trackClass, NSSelectorFromString(@"newWithPersistentID:inLibrary:"), persistentID, library);
        NSString *path = freshTrack && YTMISelector(freshTrack, @"absoluteFilePath", 0) ? ((id (*)(id, SEL))objc_msgSend)(freshTrack, NSSelectorFromString(@"absoluteFilePath")) : nil;
        if (freshTrack && [path isKindOfClass:NSString.class] && YTMIPlayablePath(path)) break;
        freshTrack = nil;
        [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.10]];
    } while (deadline.timeIntervalSinceNow > 0);
    if (!freshTrack) { if (error) *error = YTMIError(100, @"Music did not expose a playable local record after its transaction."); return NO; }
    YTMITrace(trace, @"music.record.visible");

    SEL valueSEL = NSSelectorFromString(@"valueForProperty:");
    if (!YTMISelector(freshTrack, @"valueForProperty:", 1)) { if (error) *error = YTMIError(102, @"Music could not verify the imported metadata."); return NO; }
    NSString *actualTitle = ((id (*)(id, SEL, id))objc_msgSend)(freshTrack, valueSEL, YTMIProperty(music, "ML3TrackPropertyTitle", @"title"));
    NSString *actualArtist = ((id (*)(id, SEL, id))objc_msgSend)(freshTrack, valueSEL, YTMIProperty(music, "ML3TrackPropertyArtist", @"artist"));
    NSString *actualAlbum = ((id (*)(id, SEL, id))objc_msgSend)(freshTrack, valueSEL, YTMIProperty(music, "ML3TrackPropertyAlbum", @"album"));
    if (![actualTitle isEqualToString:title] || ![actualArtist isEqualToString:artist] || ![actualAlbum isEqualToString:album]) { if (error) *error = YTMIError(102, @"Music saved different metadata than requested."); return NO; }
    YTMITrace(trace, @"music.metadata.verified");

    for (NSString *name in @[@"notifyEntitiesAddedOrRemoved", @"notifyContentsDidChange", @"notifyLibraryImportDidFinish"]) {
        if (YTMISelector(library, name, 0)) ((void (*)(id, SEL))objc_msgSend)(library, NSSelectorFromString(name));
    }
    YTMITrace(trace, @"music.payload.verified");
    return YES;
}
@end
