#import "YTMIMusicDatabaseImporter.h"
#import "YTMIConstants.h"
#import <AVFoundation/AVFoundation.h>
#import <AudioToolbox/AudioToolbox.h>
#import <CoreMedia/CoreMedia.h>
#import <MediaPlayer/MediaPlayer.h>
#import <dlfcn.h>
#import <math.h>
#import <objc/message.h>
#import <sqlite3.h>
#import <stdlib.h>

static NSString * const YTMIErrorDomain = @"com.aaz.ytmusicimporter";
static NSString * const YTMIOwnershipLedgerPath = @"/var/mobile/Media/YTMusicImporter/import-ownership.plist";
static NSString * const YTMIMediaDatabasePath = @"/var/mobile/Media/iTunes_Control/iTunes/MediaLibrary.sqlitedb";

static NSError *YTMIError(NSInteger code, NSString *message) {
    return [NSError errorWithDomain:YTMIErrorDomain code:code
                           userInfo:@{NSLocalizedDescriptionKey:message ?: @"Music import failed."}];
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
static id YTMINewObject(Class objectClass) {
    if (!objectClass) return nil;
    @try { return ((id (*)(id, SEL))objc_msgSend)(objectClass, @selector(new)); }
    @catch (__unused NSException *exception) { return nil; }
}
static id YTMINewObject2(Class objectClass, NSString *initializer, id first, id second) {
    if (!objectClass || !YTMISelector(objectClass, @"alloc", 0)) return nil;
    id allocated = ((id (*)(id, SEL))objc_msgSend)(objectClass, @selector(alloc));
    if (!YTMISelector(allocated, initializer, 2)) return nil;
    @try { return ((id (*)(id, SEL, id, id))objc_msgSend)(allocated, NSSelectorFromString(initializer), first, second); }
    @catch (__unused NSException *exception) { return nil; }
}
static BOOL YTMISetObject(id target, NSString *name, id value) {
    if (!value || !YTMISelector(target, name, 1)) return NO;
    @try { ((void (*)(id, SEL, id))objc_msgSend)(target, NSSelectorFromString(name), value); return YES; }
    @catch (__unused NSException *exception) { return NO; }
}
static BOOL YTMISetBool(id target, NSString *name, BOOL value) {
    if (!YTMISelector(target, name, 1)) return NO;
    @try { ((void (*)(id, SEL, BOOL))objc_msgSend)(target, NSSelectorFromString(name), value); return YES; }
    @catch (__unused NSException *exception) { return NO; }
}
static BOOL YTMISetInt(id target, NSString *name, int value) {
    if (!YTMISelector(target, name, 1)) return NO;
    @try { ((void (*)(id, SEL, int))objc_msgSend)(target, NSSelectorFromString(name), value); return YES; }
    @catch (__unused NSException *exception) { return NO; }
}
static BOOL YTMISetInt64(id target, NSString *name, int64_t value) {
    if (!YTMISelector(target, name, 1)) return NO;
    @try { ((void (*)(id, SEL, int64_t))objc_msgSend)(target, NSSelectorFromString(name), value); return YES; }
    @catch (__unused NSException *exception) { return NO; }
}
static NSString *YTMIProperty(void *framework, const char *symbol, NSString *fallback) {
    NSString *__unsafe_unretained *address = framework ? (NSString *__unsafe_unretained *)dlsym(framework, symbol) : NULL;
    return (address && *address) ? *address : fallback;
}
static NSString *YTMIMediaFolder(id library) {
    if (YTMISelector(library, @"mediaFolderPath", 0)) {
        id value = ((id (*)(id, SEL))objc_msgSend)(library, NSSelectorFromString(@"mediaFolderPath"));
        if ([value isKindOfClass:NSString.class] && [value length]) return value;
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
    return [fm createDirectoryAtPath:directory withIntermediateDirectories:YES
                          attributes:@{NSFilePosixPermissions:@0755} error:error] ? directory : nil;
}
static BOOL YTMIPlayablePath(NSString *path) {
    if (!path.length || ![NSFileManager.defaultManager isReadableFileAtPath:path]) return NO;
    AVURLAsset *asset = [AVURLAsset URLAssetWithURL:[NSURL fileURLWithPath:path] options:nil];
    AVAssetTrack *audio = [asset tracksWithMediaType:AVMediaTypeAudio].firstObject;
    return audio && CMTIME_IS_NUMERIC(asset.duration) && CMTimeGetSeconds(asset.duration) > 0.25;
}
static void YTMINotifyLibrary(id library) {
    for (NSString *name in @[@"notifyEntitiesAddedOrRemoved", @"notifyContentsDidChange", @"notifyLibraryImportDidFinish"]) {
        if (YTMISelector(library, name, 0)) {
            @try { ((void (*)(id, SEL))objc_msgSend)(library, NSSelectorFromString(name)); }
            @catch (__unused NSException *exception) {}
        }
    }
}
static BOOL YTMIReloadMediaPlayerLibrary(void) {
    @try {
        Class mediaLibraryClass = MPMediaLibrary.class;
        if (!YTMISelector(mediaLibraryClass, @"deviceMediaLibrary", 0)) return NO;
        id mediaLibrary = ((id (*)(id, SEL))objc_msgSend)(mediaLibraryClass, NSSelectorFromString(@"deviceMediaLibrary"));
        if (!YTMISelector(mediaLibrary, @"_reloadLibraryForContentsChangeWithNotificationInfo:", 1)) return NO;
        ((void (*)(id, SEL, id))objc_msgSend)(mediaLibrary, NSSelectorFromString(@"_reloadLibraryForContentsChangeWithNotificationInfo:"), nil);
        return YES;
    } @catch (__unused NSException *exception) { return NO; }
}
static unsigned long long YTMIExtractPersistentID(id value) {
    if ([value isKindOfClass:NSNumber.class]) return [value unsignedLongLongValue];
    if ([value isKindOfClass:NSDictionary.class]) {
        for (id nested in [(NSDictionary *)value allValues]) { unsigned long long pid = YTMIExtractPersistentID(nested); if (pid) return pid; }
    }
    if ([value isKindOfClass:NSArray.class] || [value isKindOfClass:NSSet.class]) {
        for (id nested in value) { unsigned long long pid = YTMIExtractPersistentID(nested); if (pid) return pid; }
    }
    return 0;
}
static BOOL YTMIRecordOwnership(NSString *importID, unsigned long long persistentID, NSString *path) {
    if (!persistentID || !path.length) return NO;
    NSFileManager *fm = NSFileManager.defaultManager;
    NSString *directory = YTMIOwnershipLedgerPath.stringByDeletingLastPathComponent;
    if (![fm createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions:@0755} error:nil]) return NO;
    NSDictionary *existing = [NSDictionary dictionaryWithContentsOfFile:YTMIOwnershipLedgerPath];
    NSMutableDictionary *ledger = [existing isKindOfClass:NSDictionary.class] ? [existing mutableCopy] : [NSMutableDictionary dictionary];
    NSMutableDictionary *entries = [ledger[@"entries"] isKindOfClass:NSDictionary.class] ? [ledger[@"entries"] mutableCopy] : [NSMutableDictionary dictionary];
    NSString *key = [NSString stringWithFormat:@"%llu", persistentID];
    entries[key] = @{@"persistentID":@(persistentID), @"path":path,
                     @"importID":importID.length ? importID : @"B61-UNKNOWN"};
    ledger[@"schema"] = @2;
    ledger[@"entries"] = entries;
    if (![ledger writeToFile:YTMIOwnershipLedgerPath atomically:YES]) return NO;
    if (![fm setAttributes:@{NSFilePosixPermissions:@0600} ofItemAtPath:YTMIOwnershipLedgerPath error:nil]) return NO;
    NSDictionary *saved = [NSDictionary dictionaryWithContentsOfFile:YTMIOwnershipLedgerPath];
    NSDictionary *savedEntry = [saved[@"entries"][key] isKindOfClass:NSDictionary.class] ? saved[@"entries"][key] : nil;
    return [savedEntry[@"persistentID"] unsignedLongLongValue] == persistentID && [savedEntry[@"path"] isEqualToString:path];
}
static void YTMIRollBackExactTrack(Class trackClass, id library, unsigned long long persistentID, NSString *path) {
    if (persistentID && YTMISelector(trackClass, @"deleteFromLibrary:deletionType:persistentIDs:count:", 4)) {
        int64_t identifier = (int64_t)persistentID;
        @try { ((BOOL (*)(id, SEL, id, int, const int64_t *, NSUInteger))objc_msgSend)(trackClass,
            NSSelectorFromString(@"deleteFromLibrary:deletionType:persistentIDs:count:"), library, 1, &identifier, 1); }
        @catch (__unused NSException *exception) {}
    }
    if (path.length) [NSFileManager.defaultManager removeItemAtPath:path error:nil];
    YTMINotifyLibrary(library);
    YTMIReloadMediaPlayerLibrary();
}
static BOOL YTMIIsLegacyOwnedName(NSString *name) {
    if (![name.pathExtension.lowercaseString isEqualToString:@"m4a"]) return NO;
    NSString *stem = name.stringByDeletingPathExtension;
    if (stem.length != 16) return NO;
    NSCharacterSet *hex = [NSCharacterSet characterSetWithCharactersInString:@"0123456789ABCDEFabcdef"];
    return [stem rangeOfCharacterFromSet:hex.invertedSet].location == NSNotFound;
}
static NSString *YTMICanonicalPath(NSString *path) {
    if (![path isKindOfClass:NSString.class] || !path.length) return nil;
    return path.stringByStandardizingPath.stringByResolvingSymlinksInPath;
}
static BOOL YTMIDeleteEntityIDs(Class entityClass, id library, NSArray<NSNumber *> *identifiers, BOOL canonicalize) {
    if (!identifiers.count) return YES;
    int64_t *values = calloc(identifiers.count, sizeof(int64_t));
    if (!values) return NO;
    for (NSUInteger index = 0; index < identifiers.count; index++) values[index] = identifiers[index].longLongValue;
    BOOL deleted = NO;
    @try {
        if (canonicalize && YTMISelector(entityClass, @"deleteFromLibrary:deletionType:canonicalizeCollections:persistentIDs:count:", 5)) {
            deleted = ((BOOL (*)(id, SEL, id, int, BOOL, const int64_t *, NSUInteger))objc_msgSend)(entityClass,
                NSSelectorFromString(@"deleteFromLibrary:deletionType:canonicalizeCollections:persistentIDs:count:"),
                library, 1, YES, values, identifiers.count);
        } else if (YTMISelector(entityClass, @"deleteFromLibrary:deletionType:persistentIDs:count:", 4)) {
            deleted = ((BOOL (*)(id, SEL, id, int, const int64_t *, NSUInteger))objc_msgSend)(entityClass,
                NSSelectorFromString(@"deleteFromLibrary:deletionType:persistentIDs:count:"),
                library, 1, values, identifiers.count);
        }
    } @catch (__unused NSException *exception) { deleted = NO; }
    free(values);
    return deleted;
}
static BOOL YTMICleanupLegacyOwnedDebris(id library, Class trackClass, Class albumClass,
                                         NSString *mediaFolder, NSMutableArray *trace) {
    sqlite3 *database = NULL;
    if (sqlite3_open_v2(YTMIMediaDatabasePath.fileSystemRepresentation, &database,
                        SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, NULL) != SQLITE_OK) {
        if (database) sqlite3_close(database);
        return NO;
    }
    NSMutableArray<NSNumber *> *trackIDs = [NSMutableArray array];
    NSMutableOrderedSet<NSNumber *> *candidateAlbumIDs = [NSMutableOrderedSet orderedSet];
    NSMutableArray<NSString *> *paths = [NSMutableArray array];
    const char *trackSQL =
        "SELECT i.item_pid, i.album_pid FROM item i JOIN item_extra e USING(item_pid) "
        "JOIN album a ON a.album_pid=i.album_pid WHERE a.album='YT Music Importer' "
        "AND e.location IS NOT NULL AND length(e.location)>0";
    sqlite3_stmt *statement = NULL;
    if (sqlite3_prepare_v2(database, trackSQL, -1, &statement, NULL) != SQLITE_OK) {
        sqlite3_close(database);
        return NO;
    }
    while (sqlite3_step(statement) == SQLITE_ROW) {
        unsigned long long persistentID = (unsigned long long)sqlite3_column_int64(statement, 0);
        long long albumID = sqlite3_column_int64(statement, 1);
        id track = YTMISelector(trackClass, @"newWithPersistentID:inLibrary:", 2) ?
            ((id (*)(id, SEL, unsigned long long, id))objc_msgSend)(trackClass,
                NSSelectorFromString(@"newWithPersistentID:inLibrary:"), persistentID, library) : nil;
        NSString *path = track && YTMISelector(track, @"absoluteFilePath", 0) ?
            ((id (*)(id, SEL))objc_msgSend)(track, NSSelectorFromString(@"absoluteFilePath")) : nil;
        NSString *standardPath = YTMICanonicalPath(path);
        NSString *standardRoot = YTMICanonicalPath(mediaFolder);
        if (persistentID && standardPath.length && [standardPath hasPrefix:[standardRoot stringByAppendingString:@"/"]] &&
            YTMIIsLegacyOwnedName(standardPath.lastPathComponent)) {
            [trackIDs addObject:@(persistentID)];
            if (albumID > 0) [candidateAlbumIDs addObject:@(albumID)];
            [paths addObject:standardPath];
        }
    }
    sqlite3_finalize(statement);
    if (trackIDs.count && !YTMIDeleteEntityIDs(trackClass, library, trackIDs, YES)) {
        sqlite3_close(database);
        return NO;
    }
    for (NSString *path in paths) [NSFileManager.defaultManager removeItemAtPath:path error:nil];

    NSMutableArray<NSNumber *> *orphanAlbumIDs = [NSMutableArray array];
    const char *albumSQL =
        "SELECT 1 FROM album a WHERE a.album_pid=? AND a.album='YT Music Importer' "
        "AND NOT EXISTS (SELECT 1 FROM item i WHERE i.album_pid=a.album_pid)";
    for (NSNumber *candidateAlbumID in candidateAlbumIDs) {
        statement = NULL;
        if (sqlite3_prepare_v2(database, albumSQL, -1, &statement, NULL) != SQLITE_OK) {
            sqlite3_close(database);
            return NO;
        }
        sqlite3_bind_int64(statement, 1, candidateAlbumID.longLongValue);
        if (sqlite3_step(statement) == SQLITE_ROW) [orphanAlbumIDs addObject:candidateAlbumID];
        sqlite3_finalize(statement);
    }
    sqlite3_close(database);
    if (orphanAlbumIDs.count && !YTMIDeleteEntityIDs(albumClass, library, orphanAlbumIDs, NO)) return NO;
    if (trackIDs.count || orphanAlbumIDs.count) {
        YTMINotifyLibrary(library);
        YTMIReloadMediaPlayerLibrary();
        YTMITrace(trace, @"music.legacy-cleanup.removed-owned-debris");
    } else {
        YTMITrace(trace, @"music.legacy-cleanup.nothing-owned");
    }
    return YES;
}

@implementation YTMIMusicDatabaseImporter
- (BOOL)importAudioAtURL:(NSURL *)audioURL metadata:(NSDictionary *)metadata trace:(NSMutableArray *)trace error:(NSError **)error {
    NSFileManager *fm = NSFileManager.defaultManager;
    if (!audioURL.isFileURL || ![fm fileExistsAtPath:audioURL.path]) { if (error) *error = YTMIError(19, @"The prepared audio file is unavailable."); return NO; }
    YTMITrace(trace, @"music.source.present");
    AVURLAsset *sourceAsset = [AVURLAsset URLAssetWithURL:audioURL options:nil];
    AVAssetTrack *sourceTrack = [sourceAsset tracksWithMediaType:AVMediaTypeAudio].firstObject;
    double seconds = CMTIME_IS_NUMERIC(sourceAsset.duration) ? CMTimeGetSeconds(sourceAsset.duration) : 0;
    if (!sourceTrack || seconds <= 0.25) { if (error) *error = YTMIError(80, @"The prepared audio is not playable."); return NO; }
    YTMITrace(trace, @"music.source.playable");

    void *music = dlopen("/System/Library/PrivateFrameworks/MusicLibrary.framework/MusicLibrary", RTLD_NOW | RTLD_LOCAL);
    Class libraryClass = NSClassFromString(@"ML3MusicLibrary"), trackClass = NSClassFromString(@"ML3Track");
    Class legacyAlbumClass = NSClassFromString(@"ML3Album");
    Class configurationClass = NSClassFromString(@"ML3ClientImportSessionConfiguration"), sessionClass = NSClassFromString(@"ML3ClientImportSession");
    Class clientItemClass = NSClassFromString(@"ML3ClientImportItem"), mediaItemClass = NSClassFromString(@"MIPMediaItem");
    Class songClass = NSClassFromString(@"MIPSong"), artistClass = NSClassFromString(@"MIPArtist"), albumClass = NSClassFromString(@"MIPAlbum");
    Class playbackClass = NSClassFromString(@"MIPPlaybackInfo"), identifierClass = NSClassFromString(@"MIPMultiverseIdentifier");
    if (!music || !libraryClass || !trackClass || !legacyAlbumClass || !configurationClass || !sessionClass || !clientItemClass ||
        !mediaItemClass || !songClass || !artistClass || !albumClass || !playbackClass || !identifierClass ||
        !YTMISelector(libraryClass, @"sharedLibrary", 0)) {
        if (error) *error = YTMIError(146, @"Music's client-import service is unavailable on this system."); return NO;
    }
    YTMITrace(trace, @"music.client-import.classes.available");

    id library = ((id (*)(id, SEL))objc_msgSend)(libraryClass, NSSelectorFromString(@"sharedLibrary"));
    NSError *copyError = nil;
    NSString *mediaFolder = YTMIMediaFolder(library);
    NSString *directory = mediaFolder ? YTMIDestinationDirectory(mediaFolder, &copyError) : nil;
    if (!library || !directory) { if (error) *error = copyError ?: YTMIError(96, @"Music's local media folder is unavailable."); return NO; }
    if (!YTMICleanupLegacyOwnedDebris(library, trackClass, legacyAlbumClass, mediaFolder, trace)) {
        if (error) *error = YTMIError(155, @"Music could not safely remove the importer's legacy owned debris."); return NO;
    }
    NSString *destinationPath = [directory stringByAppendingPathComponent:[NSString stringWithFormat:@"YTMI-%@.m4a", NSUUID.UUID.UUIDString]];
    if (![fm copyItemAtPath:audioURL.path toPath:destinationPath error:&copyError]) { if (error) *error = copyError ?: YTMIError(97, @"Music could not copy the local audio payload."); return NO; }
    [fm setAttributes:@{NSFilePosixPermissions:@0644, NSFileProtectionKey:NSFileProtectionNone} ofItemAtPath:destinationPath error:nil];
    if (!YTMIPlayablePath(destinationPath)) { [fm removeItemAtPath:destinationPath error:nil]; if (error) *error = YTMIError(110, @"Music's copied local audio is not playable."); return NO; }
    YTMITrace(trace, @"music.payload.copied");

    NSString *title = YTMISafeText(metadata[YTMIJobTitleKey], @"YouTube Audio");
    NSString *artistName = YTMISafeText(metadata[YTMIJobArtistKey], @"YouTube");
    NSString *albumName = YTMISafeText(metadata[YTMIJobAlbumKey], @"YT Music Importer");
    NSString *importID = YTMISafeText(metadata[YTMIJobImportIDKey], @"B61-UNKNOWN");
    NSDictionary *attributes = [fm attributesOfItemAtPath:destinationPath error:nil];
    int64_t milliseconds = (int64_t)llround(seconds * 1000.0);
    int64_t absoluteTime = (int64_t)floor(NSDate.date.timeIntervalSinceReferenceDate);
    id artist = YTMINewObject(artistClass), albumArtist = YTMINewObject(artistClass), album = YTMINewObject(albumClass);
    id playback = YTMINewObject(playbackClass), song = YTMINewObject(songClass), mediaItem = YTMINewObject(mediaItemClass);
    id identifier = YTMINewObject(identifierClass);
    BOOL payloadOK = artist && albumArtist && album && playback && song && mediaItem && identifier &&
        YTMISetObject(artist, @"setName:", artistName) && YTMISetObject(albumArtist, @"setName:", artistName) &&
        YTMISetObject(album, @"setName:", albumName) && YTMISetObject(album, @"setArtist:", albumArtist) &&
        YTMISetInt(album, @"setNumTracks:", 1) && YTMISetInt(album, @"setNumDiscs:", 1) &&
        YTMISetObject(playback, @"setDataUrl:", [NSURL fileURLWithPath:destinationPath].absoluteString) &&
        YTMISetInt(playback, @"setDataKind:", 0) && YTMISetObject(song, @"setArtist:", artist) &&
        YTMISetObject(song, @"setAlbum:", album) && YTMISetObject(song, @"setPlaybackInfo:", playback) &&
        YTMISetInt(song, @"setTrackNumber:", 1) && YTMISetInt(song, @"setDiscNumber:", 1) &&
        YTMISetObject(mediaItem, @"setTitle:", title) && YTMISetInt(mediaItem, @"setMediaType:", 1) &&
        YTMISetInt64(mediaItem, @"setDuration:", milliseconds) && YTMISetInt64(mediaItem, @"setFileSize:", [attributes[NSFileSize] longLongValue]) &&
        YTMISetInt64(mediaItem, @"setCreationDateTime:", absoluteTime) && YTMISetInt64(mediaItem, @"setModificationDateTime:", absoluteTime) &&
        YTMISetInt64(mediaItem, @"setPurchaseDateTime:", absoluteTime) && YTMISetBool(mediaItem, @"setHasLocalAsset:", YES) &&
        YTMISetBool(mediaItem, @"setIsInUsersLibrary:", YES) && YTMISetBool(mediaItem, @"setHidden:", NO) &&
        YTMISetInt64(mediaItem, @"setFamilyAccountId:", 0) && YTMISetInt(mediaItem, @"setStoreProtectionType:", 0) &&
        YTMISetObject(mediaItem, @"setSong:", song) && YTMISetInt(identifier, @"setMediaObjectType:", 6) &&
        YTMISetInt(identifier, @"setMediaType:", 1) && YTMISetObject(identifier, @"setName:", importID);

    CMAudioFormatDescriptionRef formatDescription = (__bridge CMAudioFormatDescriptionRef)sourceTrack.formatDescriptions.firstObject;
    const AudioStreamBasicDescription *asbd = formatDescription ? CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription) : NULL;
    if (asbd) {
        if (asbd->mSampleRate > 0) YTMISetInt(playback, @"setSampleRate:", (int)llround(asbd->mSampleRate));
        if (asbd->mFormatID) YTMISetInt(song, @"setAudioFormat:", (int)asbd->mFormatID);
        int64_t samples = (int64_t)llround(seconds * asbd->mSampleRate);
        if (samples > 0) YTMISetInt64(playback, @"setDurationInSamples:", samples);
    }
    if (sourceTrack.estimatedDataRate > 0) YTMISetInt(playback, @"setBitRate:", (int)llround(sourceTrack.estimatedDataRate));

    id clientItem = payloadOK ? YTMINewObject2(clientItemClass, @"initWithMultiverseIdentifier:mediaItem:", identifier, mediaItem) : nil;
    id configuration = YTMINewObject(configurationClass);
    if (!clientItem || !configuration || !YTMISetInt64(configuration, @"setOperationCount:", 1)) {
        [fm removeItemAtPath:destinationPath error:nil]; if (error) *error = YTMIError(147, @"Music rejected the client-import payload contract."); return NO;
    }
    YTMITrace(trace, @"music.client-import.payload.created");
    id session = YTMINewObject2(sessionClass, @"initWithConfiguration:delegate:", configuration, nil);
    if (!session || !YTMISelector(session, @"start", 0) || !YTMISelector(session, @"addItemsReturningResult:", 1) ||
        !YTMISelector(session, @"finish", 0) || !YTMISelector(session, @"cancel", 0)) {
        [fm removeItemAtPath:destinationPath error:nil]; if (error) *error = YTMIError(148, @"Music's client-import transaction interface is unavailable."); return NO;
    }
    BOOL started = NO;
    @try { started = ((BOOL (*)(id, SEL))objc_msgSend)(session, NSSelectorFromString(@"start")); }
    @catch (__unused NSException *exception) { started = NO; }
    if (!started) { [fm removeItemAtPath:destinationPath error:nil]; if (error) *error = YTMIError(149, @"Music could not start its client-import transaction."); return NO; }
    YTMITrace(trace, @"music.client-import.session.started");

    id result = nil;
    @try { result = ((id (*)(id, SEL, id))objc_msgSend)(session, NSSelectorFromString(@"addItemsReturningResult:"), @[clientItem]); }
    @catch (__unused NSException *exception) { result = nil; }
    BOOL added = result && YTMISelector(result, @"success", 0) && ((BOOL (*)(id, SEL))objc_msgSend)(result, NSSelectorFromString(@"success"));
    id resultIDs = added && YTMISelector(result, @"resultingDatabasePersistentIDs", 0) ? ((id (*)(id, SEL))objc_msgSend)(result, NSSelectorFromString(@"resultingDatabasePersistentIDs")) : nil;
    unsigned long long persistentID = YTMIExtractPersistentID(resultIDs);
    if (!added || !persistentID) {
        @try { ((BOOL (*)(id, SEL))objc_msgSend)(session, NSSelectorFromString(@"cancel")); } @catch (__unused NSException *exception) {}
        [fm removeItemAtPath:destinationPath error:nil]; if (error) *error = YTMIError(150, @"Music's client-import service rejected the local song."); return NO;
    }
    YTMITrace(trace, @"music.client-import.item.accepted");
    YTMITrace(trace, @"music.client-import.persistent-id.returned");
    BOOL finished = NO;
    @try { finished = ((BOOL (*)(id, SEL))objc_msgSend)(session, NSSelectorFromString(@"finish")); }
    @catch (__unused NSException *exception) { finished = NO; }
    if (!finished) { YTMIRollBackExactTrack(trackClass, library, persistentID, destinationPath); if (error) *error = YTMIError(151, @"Music could not commit its client-import transaction."); return NO; }
    YTMITrace(trace, @"music.client-import.session.committed");

    id importedTrack = nil;
    NSDate *recordDeadline = [NSDate dateWithTimeIntervalSinceNow:3.0];
    do {
        BOOL importedTrackExists = YTMISelector(trackClass, @"trackWithPersistentID:existsInLibrary:", 2) &&
            ((BOOL (*)(id, SEL, unsigned long long, id))objc_msgSend)(trackClass,
                NSSelectorFromString(@"trackWithPersistentID:existsInLibrary:"), persistentID, library);
        if (importedTrackExists && YTMISelector(trackClass, @"newWithPersistentID:inLibrary:", 2)) {
            importedTrack = ((id (*)(id, SEL, unsigned long long, id))objc_msgSend)(trackClass,
                NSSelectorFromString(@"newWithPersistentID:inLibrary:"), persistentID, library);
        }
        if (importedTrack) break;
        [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.10]];
    } while (recordDeadline.timeIntervalSinceNow > 0);
    if (!importedTrack) {
        YTMIRollBackExactTrack(trackClass, library, persistentID, destinationPath);
        if (error) *error = YTMIError(156, @"Music returned an identifier without retaining its imported record.");
        return NO;
    }
    YTMITrace(trace, @"music.client-import.track.reopened");

    NSString *locationSelectorName = @"populateLocationPropertiesWithPath:protectionType:";
    if (!YTMISelector(importedTrack, locationSelectorName, 2)) {
        YTMIRollBackExactTrack(trackClass, library, persistentID, destinationPath);
        if (error) *error = YTMIError(157, @"Music's local-file location transaction is unavailable.");
        return NO;
    }
    BOOL locationTransactionReturned = NO;
    YTMITrace(trace, @"music.location.transaction.started");
    @try {
        ((void (*)(id, SEL, id, int64_t))objc_msgSend)(importedTrack,
            NSSelectorFromString(locationSelectorName), destinationPath, (int64_t)0);
        locationTransactionReturned = YES;
    } @catch (__unused NSException *exception) { locationTransactionReturned = NO; }
    if (!locationTransactionReturned) {
        YTMIRollBackExactTrack(trackClass, library, persistentID, destinationPath);
        if (error) *error = YTMIError(157, @"Music's local-file location transaction failed.");
        return NO;
    }
    YTMITrace(trace, @"music.location.transaction.returned");

    YTMINotifyLibrary(library);
    if (YTMIReloadMediaPlayerLibrary()) YTMITrace(trace, @"music.mediaplayer.reload.completed");
    id freshTrack = nil;
    NSString *resolvedPath = nil;
    NSString *expectedPath = YTMICanonicalPath(destinationPath);
    BOOL readable = NO;
    BOOL playable = NO;
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:5.0];
    do {
        BOOL exists = YTMISelector(trackClass, @"trackWithPersistentID:existsInLibrary:", 2) &&
            ((BOOL (*)(id, SEL, unsigned long long, id))objc_msgSend)(trackClass, NSSelectorFromString(@"trackWithPersistentID:existsInLibrary:"), persistentID, library);
        if (exists && YTMISelector(trackClass, @"newWithPersistentID:inLibrary:", 2)) freshTrack = ((id (*)(id, SEL, unsigned long long, id))objc_msgSend)(trackClass, NSSelectorFromString(@"newWithPersistentID:inLibrary:"), persistentID, library);
        id candidatePath = freshTrack && YTMISelector(freshTrack, @"absoluteFilePath", 0) ?
            ((id (*)(id, SEL))objc_msgSend)(freshTrack, NSSelectorFromString(@"absoluteFilePath")) : nil;
        resolvedPath = [candidatePath isKindOfClass:NSString.class] ? candidatePath : nil;
        BOOL exactPath = expectedPath.length && [YTMICanonicalPath(resolvedPath) isEqualToString:expectedPath];
        readable = exactPath && [fm isReadableFileAtPath:resolvedPath];
        playable = readable && YTMIPlayablePath(resolvedPath);
        if (freshTrack && exactPath && readable && playable) break;
        [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.10]];
    } while (deadline.timeIntervalSinceNow > 0);
    if (!freshTrack) {
        YTMIRollBackExactTrack(trackClass, library, persistentID, destinationPath);
        if (error) *error = YTMIError(156, @"Music did not retain the exact imported record after linking its file.");
        return NO;
    }
    if (!expectedPath.length || ![YTMICanonicalPath(resolvedPath) isEqualToString:expectedPath]) {
        YTMIRollBackExactTrack(trackClass, library, persistentID, destinationPath);
        if (error) *error = YTMIError(158, @"Music did not commit the imported record's exact local-file location.");
        return NO;
    }
    YTMITrace(trace, @"music.location.path.verified");
    if (!readable) {
        YTMIRollBackExactTrack(trackClass, library, persistentID, destinationPath);
        if (error) *error = YTMIError(159, @"Music's resolved local audio file is not readable.");
        return NO;
    }
    YTMITrace(trace, @"music.location.readable");
    if (!playable) {
        YTMIRollBackExactTrack(trackClass, library, persistentID, destinationPath);
        if (error) *error = YTMIError(160, @"Music's resolved local audio file is not playable.");
        return NO;
    }
    YTMITrace(trace, @"music.location.playable");

    NSString *titleProperty = YTMIProperty(music, "ML3TrackPropertyTitle", @"title");
    NSString *artistProperty = YTMIProperty(music, "ML3TrackPropertyArtist", @"artist");
    NSString *albumProperty = YTMIProperty(music, "ML3TrackPropertyAlbum", @"album");
    NSString *membershipProperty = YTMIProperty(music, "ML3TrackPropertyIsInMyLibrary", @"in_my_library");
    NSString *needsRestoreProperty = YTMIProperty(music, "ML3TrackPropertyNeedsRestore", @"needs_restore");
    NSString *familyProperty = YTMIProperty(music, "ML3TrackPropertyStoreFamilyAccountID", @"store_family_account_id");
    SEL valueSelector = NSSelectorFromString(@"valueForProperty:");
    id actualMembership = YTMISelector(freshTrack, @"valueForProperty:", 1) ?
        ((id (*)(id, SEL, id))objc_msgSend)(freshTrack, valueSelector, membershipProperty) : nil;
    if (![actualMembership respondsToSelector:@selector(boolValue)] || ![actualMembership boolValue]) {
        YTMIRollBackExactTrack(trackClass, library, persistentID, resolvedPath);
        if (error) *error = YTMIError(161, @"Music did not retain the imported song in the user's local library.");
        return NO;
    }
    YTMITrace(trace, @"music.membership.verified");

    id actualTitle = YTMISelector(freshTrack, @"valueForProperty:", 1) ? ((id (*)(id, SEL, id))objc_msgSend)(freshTrack, valueSelector, titleProperty) : nil;
    id actualArtist = YTMISelector(freshTrack, @"valueForProperty:", 1) ? ((id (*)(id, SEL, id))objc_msgSend)(freshTrack, valueSelector, artistProperty) : nil;
    id actualAlbum = YTMISelector(freshTrack, @"valueForProperty:", 1) ? ((id (*)(id, SEL, id))objc_msgSend)(freshTrack, valueSelector, albumProperty) : nil;
    id actualNeedsRestore = YTMISelector(freshTrack, @"valueForProperty:", 1) ? ((id (*)(id, SEL, id))objc_msgSend)(freshTrack, valueSelector, needsRestoreProperty) : nil;
    id actualFamily = YTMISelector(freshTrack, @"valueForProperty:", 1) ? ((id (*)(id, SEL, id))objc_msgSend)(freshTrack, valueSelector, familyProperty) : nil;
    if (![actualTitle isEqual:title] || ![actualArtist isEqual:artistName] || ![actualAlbum isEqual:albumName] ||
        ![actualNeedsRestore respondsToSelector:@selector(boolValue)] || [actualNeedsRestore boolValue] ||
        ![actualFamily respondsToSelector:@selector(unsignedLongLongValue)] || [actualFamily unsignedLongLongValue] != 0) {
        YTMIRollBackExactTrack(trackClass, library, persistentID, destinationPath); if (error) *error = YTMIError(153, @"Music did not retain the imported song's ownership metadata."); return NO;
    }
    YTMITrace(trace, @"music.client-import.metadata.verified");
    if (!YTMIRecordOwnership(importID, persistentID, resolvedPath)) {
        YTMIRollBackExactTrack(trackClass, library, persistentID, resolvedPath); if (error) *error = YTMIError(154, @"The exact cleanup ownership record could not be saved."); return NO;
    }
    YTMITrace(trace, @"music.ownership.recorded");
    return YES;
}
@end
