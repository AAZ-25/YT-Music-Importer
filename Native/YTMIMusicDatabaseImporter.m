#import "YTMIMusicDatabaseImporter.h"
#import "YTMIConstants.h"
#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>
#import <AudioToolbox/AudioToolbox.h>
#import <dlfcn.h>
#import <math.h>
#import <objc/message.h>
#import <sqlite3.h>

static NSString * const YTMIErrorDomain = @"com.aaz.ytmusicimporter";
static NSString * const YTMIDatabasePath = @"/var/mobile/Media/iTunes_Control/iTunes/MediaLibrary.sqlitedb";

static NSError *YTMIError(NSInteger code, NSString *message) {
    return [NSError errorWithDomain:YTMIErrorDomain code:code userInfo:@{NSLocalizedDescriptionKey: message ?: @"Music import failed."}];
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

static id YTMINewObject(Class cls, NSString *initializer, id argument) {
    if (!cls || !YTMISelector(cls, @"alloc", 0)) return nil;
    id object = ((id (*)(id, SEL))objc_msgSend)(cls, @selector(alloc));
    SEL selector = NSSelectorFromString(initializer);
    if (!YTMISelector(object, initializer, 1)) return nil;
    return ((id (*)(id, SEL, id))objc_msgSend)(object, selector, argument);
}

static BOOL YTMISetObject(id target, NSString *setter, id value) {
    if (!YTMISelector(target, setter, 1)) return NO;
    ((void (*)(id, SEL, id))objc_msgSend)(target, NSSelectorFromString(setter), value);
    return YES;
}

static NSArray *YTMIQueueDownloads(id queue) {
    if (!YTMISelector(queue, @"downloads", 0)) return nil;
    id value = ((id (*)(id, SEL))objc_msgSend)(queue, NSSelectorFromString(@"downloads"));
    return [value isKindOfClass:NSArray.class] ? value : nil;
}

static NSSet *YTMICompletedIDs(NSString *title, NSString *album) {
    sqlite3 *db = NULL; sqlite3_stmt *stmt = NULL; NSMutableSet *ids = [NSMutableSet set];
    NSString *path = YTMIDatabasePath;
    if (![[NSFileManager defaultManager] fileExistsAtPath:path]) path = [@"/private" stringByAppendingString:path];
    if (sqlite3_open_v2(path.UTF8String, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, NULL) != SQLITE_OK) { if (db) sqlite3_close(db); return nil; }
    sqlite3_busy_timeout(db, 1500);
    const char *sql = "SELECT e.item_pid FROM item_extra e JOIN item i USING(item_pid) JOIN album a ON a.album_pid=i.album_pid WHERE e.title=? AND a.album=? AND e.location IS NOT NULL AND length(e.location)>0";
    if (sqlite3_prepare_v2(db, sql, -1, &stmt, NULL) != SQLITE_OK) { sqlite3_close(db); return nil; }
    sqlite3_bind_text(stmt, 1, title.UTF8String, -1, SQLITE_TRANSIENT);
    sqlite3_bind_text(stmt, 2, album.UTF8String, -1, SQLITE_TRANSIENT);
    int status = SQLITE_ROW;
    while ((status = sqlite3_step(stmt)) == SQLITE_ROW) [ids addObject:@(sqlite3_column_int64(stmt, 0))];
    sqlite3_finalize(stmt); sqlite3_close(db);
    return status == SQLITE_DONE ? ids : nil;
}

static NSString *YTMIProperty(void *framework, const char *symbol) {
    NSString *__unsafe_unretained *address = framework ? (NSString *__unsafe_unretained *)dlsym(framework, symbol) : NULL;
    return address ? *address : nil;
}

@implementation YTMIMusicDatabaseImporter
- (BOOL)importAudioAtURL:(NSURL *)audioURL metadata:(NSDictionary *)metadata trace:(NSMutableArray *)trace error:(NSError **)error {
    if (![NSThread isMainThread]) {
        __block BOOL result = NO; __block NSError *inner = nil;
        dispatch_sync(dispatch_get_main_queue(), ^{ result = [self importAudioAtURL:audioURL metadata:metadata trace:trace error:&inner]; });
        if (error) *error = inner; return result;
    }
    NSFileManager *fm = NSFileManager.defaultManager;
    if (!audioURL.isFileURL || ![fm fileExistsAtPath:audioURL.path]) { if (error) *error = YTMIError(19, @"The prepared audio file is unavailable."); return NO; }
    YTMITrace(trace, @"music.source.present");
    AVURLAsset *sourceAsset = [AVURLAsset URLAssetWithURL:audioURL options:nil];
    AVAssetTrack *sourceTrack = [sourceAsset tracksWithMediaType:AVMediaTypeAudio].firstObject;
    if (!sourceTrack || !CMTIME_IS_NUMERIC(sourceAsset.duration) || CMTimeGetSeconds(sourceAsset.duration) <= 0.25) { if (error) *error = YTMIError(80, @"The prepared audio is not playable."); return NO; }
    YTMITrace(trace, @"music.source.playable");

    void *store = dlopen("/System/Library/PrivateFrameworks/StoreServices.framework/StoreServices", RTLD_NOW | RTLD_LOCAL);
    Class metadataClass = NSClassFromString(@"SSDownloadMetadata"), downloadClass = NSClassFromString(@"SSDownload"), queueClass = NSClassFromString(@"SSDownloadQueue");
    if (!store || !metadataClass || !downloadClass || !queueClass) { if (error) *error = YTMIError(82, @"Music's import service is unavailable on this system."); return NO; }
    NSString *title = YTMISafeText(metadata[YTMIJobTitleKey], @"YouTube Audio");
    NSString *artist = YTMISafeText(metadata[YTMIJobArtistKey], @"YouTube");
    NSString *album = YTMISafeText(metadata[YTMIJobAlbumKey], @"YT Music Importer");
    NSSet *before = YTMICompletedIDs(title, album);
    if (!before) { if (error) *error = YTMIError(83, @"Music's library could not be inspected safely."); return NO; }

    id storeMetadata = YTMINewObject(metadataClass, @"initWithKind:", @"song");
    NSNumber *duration = @((long long)llround(CMTimeGetSeconds(sourceAsset.duration) * 1000.0));
    BOOL metadataOK = storeMetadata && YTMISetObject(storeMetadata, @"setTitle:", title) && YTMISetObject(storeMetadata, @"setArtistName:", artist) && YTMISetObject(storeMetadata, @"setCollectionName:", album) && YTMISetObject(storeMetadata, @"setDurationInMilliseconds:", duration) && YTMISetObject(storeMetadata, @"setFileExtension:", @"m4a") && YTMISetObject(storeMetadata, @"setPrimaryAssetURL:", audioURL);
    if (!metadataOK) { if (error) *error = YTMIError(84, @"Music rejected the import metadata interface."); return NO; }
    id download = YTMINewObject(downloadClass, @"initWithDownloadMetadata:", storeMetadata);
    id kinds = YTMISelector(queueClass, @"mediaDownloadKinds", 0) ? ((id (*)(id, SEL))objc_msgSend)(queueClass, NSSelectorFromString(@"mediaDownloadKinds")) : nil;
    id queue = YTMINewObject(queueClass, @"initWithDownloadKinds:", kinds);
    if (!download || !queue || !YTMISelector(queue, @"addDownload:", 1) || !YTMISelector(queue, @"downloads", 0)) { if (error) *error = YTMIError(85, @"Music could not create its import queue."); return NO; }
    if (YTMISelector(queue, @"setShouldAutomaticallyFinishDownloads:", 1)) ((void (*)(id, SEL, BOOL))objc_msgSend)(queue, NSSelectorFromString(@"setShouldAutomaticallyFinishDownloads:"), YES);
    ((void (*)(id, SEL, id))objc_msgSend)(queue, NSSelectorFromString(@"addDownload:"), download);
    YTMITrace(trace, @"music.queue.accepted");

    BOOL observed = NO, finished = NO;
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:120.0];
    while (deadline.timeIntervalSinceNow > 0) {
        if (YTMISelector(download, @"failureError", 0)) {
            id failure = ((id (*)(id, SEL))objc_msgSend)(download, NSSelectorFromString(@"failureError"));
            if ([failure isKindOfClass:NSError.class]) { if (error) *error = YTMIError(86, @"Music's import service rejected the audio."); return NO; }
        }
        NSArray *downloads = YTMIQueueDownloads(queue);
        if (!downloads) { if (error) *error = YTMIError(87, @"Music's import queue became unavailable."); return NO; }
        BOOL present = [downloads containsObject:download];
        if (present) observed = YES;
        if (observed && !present) { finished = YES; break; }
        [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.20]];
    }
    if (!finished) { if (YTMISelector(queue, @"cancelDownload:", 1)) ((void (*)(id, SEL, id))objc_msgSend)(queue, NSSelectorFromString(@"cancelDownload:"), download); if (error) *error = YTMIError(88, @"Music did not finish the import in time."); return NO; }
    YTMITrace(trace, @"music.queue.finished");

    NSNumber *persistentID = nil;
    for (NSUInteger attempt = 0; attempt < 40 && !persistentID; attempt++) {
        NSSet *after = YTMICompletedIDs(title, album);
        NSMutableSet *created = after ? [after mutableCopy] : nil;
        [created minusSet:before]; persistentID = created.anyObject;
        if (!persistentID) [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.25]];
    }
    if (!persistentID) { if (error) *error = YTMIError(89, @"Music created no complete local track."); return NO; }
    YTMITrace(trace, @"music.record.created");

    void *music = dlopen("/System/Library/PrivateFrameworks/MusicLibrary.framework/MusicLibrary", RTLD_NOW | RTLD_LOCAL);
    Class libraryClass = NSClassFromString(@"ML3MusicLibrary"), trackClass = NSClassFromString(@"ML3Track");
    id library = libraryClass && YTMISelector(libraryClass, @"sharedLibrary", 0) ? ((id (*)(id, SEL))objc_msgSend)(libraryClass, NSSelectorFromString(@"sharedLibrary")) : nil;
    id track = nil;
    if (trackClass && YTMISelector(trackClass, @"newWithPersistentID:inLibrary:", 2)) track = ((id (*)(id, SEL, long long, id))objc_msgSend)(trackClass, NSSelectorFromString(@"newWithPersistentID:inLibrary:"), persistentID.longLongValue, library);
    NSString *path = track && YTMISelector(track, @"absoluteFilePath", 0) ? ((id (*)(id, SEL))objc_msgSend)(track, NSSelectorFromString(@"absoluteFilePath")) : nil;
    AVURLAsset *importedAsset = path.length ? [AVURLAsset URLAssetWithURL:[NSURL fileURLWithPath:path] options:nil] : nil;
    AVAssetTrack *audioTrack = [importedAsset tracksWithMediaType:AVMediaTypeAudio].firstObject;
    const AudioStreamBasicDescription *description = NULL;
    if (audioTrack.formatDescriptions.count) description = CMAudioFormatDescriptionGetStreamBasicDescription((__bridge CMAudioFormatDescriptionRef)audioTrack.formatDescriptions.firstObject);
    long long sampleRate = description ? llround(description->mSampleRate) : 0;
    long long samples = sampleRate > 0 && CMTIME_IS_NUMERIC(importedAsset.duration) ? CMTimeConvertScale(importedAsset.duration, (int32_t)sampleRate, kCMTimeRoundingMethod_RoundHalfAwayFromZero).value : 0;
    long long bitRate = audioTrack ? llround(audioTrack.estimatedDataRate / 1000.0) : 0;
    if (!track || !path.length || ![fm isReadableFileAtPath:path] || !audioTrack || sampleRate <= 0 || samples <= 0 || bitRate <= 0) { if (error) *error = YTMIError(90, @"Music imported a record without playable local audio."); return NO; }

    NSString *sampleProperty = YTMIProperty(music, "ML3TrackPropertySampleRate");
    NSString *samplesProperty = YTMIProperty(music, "ML3TrackPropertyDurationInSamples");
    NSString *bitRateProperty = YTMIProperty(music, "ML3TrackPropertyBitRate");
    SEL setValue = NSSelectorFromString(@"setValue:forProperty:");
    BOOL repaired = sampleProperty.length && samplesProperty.length && bitRateProperty.length && YTMISelector(track, @"setValue:forProperty:", 2);
    if (repaired) repaired = ((BOOL (*)(id, SEL, id, id))objc_msgSend)(track, setValue, @(sampleRate), sampleProperty);
    if (repaired) repaired = ((BOOL (*)(id, SEL, id, id))objc_msgSend)(track, setValue, @(samples), samplesProperty);
    if (repaired) repaired = ((BOOL (*)(id, SEL, id, id))objc_msgSend)(track, setValue, @(bitRate), bitRateProperty);
    if (repaired && YTMISelector(track, @"updateIntegrity", 0)) repaired = ((BOOL (*)(id, SEL))objc_msgSend)(track, NSSelectorFromString(@"updateIntegrity")); else repaired = NO;
    if (!repaired) { if (error) *error = YTMIError(91, @"Music rejected the playable-audio metadata repair."); return NO; }
    if (YTMISelector(library, @"notifyContentsDidChange", 0)) ((void (*)(id, SEL))objc_msgSend)(library, NSSelectorFromString(@"notifyContentsDidChange"));
    YTMITrace(trace, @"music.record.playable");
    return YES;
}
@end
