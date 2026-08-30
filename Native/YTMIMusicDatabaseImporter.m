#import "YTMIMusicDatabaseImporter.h"
#import "YTMIConstants.h"
#import <AVFoundation/AVFoundation.h>
#import <dlfcn.h>
#import <math.h>
#import <objc/message.h>

static NSError *YTMIImportError(NSInteger code, NSString *message) {
    return [NSError errorWithDomain:@"com.aaz.ytmusicimporter" code:code userInfo:@{NSLocalizedDescriptionKey:message ?: @"Music import failed."}];
}

static NSString *YTMIProperty(void *handle, const char *symbol, NSString *fallback) {
    NSString *__unsafe_unretained *value = handle ? (NSString *__unsafe_unretained *)dlsym(handle, symbol) : NULL;
    return (value && *value) ? *value : fallback;
}

static NSString *YTMISafeText(id value, NSString *fallback) {
    if (![value isKindOfClass:NSString.class]) return fallback;
    NSString *text = [(NSString *)value stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    return text.length ? text : fallback;
}

static NSString *YTMIMediaFolder(id library) {
    SEL mediaFolderSEL = NSSelectorFromString(@"mediaFolderPath");
    if (library && [library respondsToSelector:mediaFolderSEL]) {
        id path = ((id (*)(id, SEL))objc_msgSend)(library, mediaFolderSEL);
        if ([path isKindOfClass:NSString.class] && [path length]) return path;
    }
    for (NSString *candidate in @[@"/var/mobile/Media/iTunes_Control/Music", @"/private/var/mobile/Media/iTunes_Control/Music"]) {
        BOOL directory = NO;
        if ([NSFileManager.defaultManager fileExistsAtPath:candidate isDirectory:&directory] && directory) return candidate;
    }
    return nil;
}

static NSString *YTMILocalMusicDirectory(NSString *mediaFolder, NSError **error) {
    if (!mediaFolder.length) return nil;
    NSFileManager *fm = NSFileManager.defaultManager;
    for (NSUInteger index = 0; index < 50; index++) {
        NSString *candidate = [mediaFolder stringByAppendingPathComponent:[NSString stringWithFormat:@"F%02lu", (unsigned long)index]];
        BOOL directory = NO;
        if ([fm fileExistsAtPath:candidate isDirectory:&directory] && directory) return candidate;
    }
    NSString *fallback = [mediaFolder stringByAppendingPathComponent:@"F00"];
    if ([fm createDirectoryAtPath:fallback withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions:@0755} error:error]) return fallback;
    return nil;
}

@implementation YTMIMusicDatabaseImporter

- (BOOL)importAudioAtURL:(NSURL *)audioURL metadata:(NSDictionary *)metadata error:(NSError **)error {
    if (![NSThread isMainThread]) {
        __block BOOL result = NO;
        __block NSError *innerError = nil;
        dispatch_sync(dispatch_get_main_queue(), ^{
            result = [self importAudioAtURL:audioURL metadata:metadata error:&innerError];
        });
        if (error) *error = innerError;
        return result;
    }

    if (!audioURL.isFileURL || ![NSFileManager.defaultManager fileExistsAtPath:audioURL.path]) {
        if (error) *error = YTMIImportError(19, @"The prepared audio file is unavailable.");
        return NO;
    }

    NSString *destinationPath = nil;
    @try {
        void *framework = dlopen("/System/Library/PrivateFrameworks/MusicLibrary.framework/MusicLibrary", RTLD_LAZY | RTLD_LOCAL);
        Class libraryClass = NSClassFromString(@"ML3MusicLibrary");
        Class trackClass = NSClassFromString(@"ML3Track");
        SEL sharedSEL = NSSelectorFromString(@"sharedLibrary");
        if (!framework || !libraryClass || !trackClass || ![libraryClass respondsToSelector:sharedSEL]) {
            if (error) *error = YTMIImportError(50, @"The local Music library interface is unavailable.");
            return NO;
        }

        id library = ((id (*)(id, SEL))objc_msgSend)(libraryClass, sharedSEL);
        NSString *mediaFolder = YTMIMediaFolder(library);
        if (!library || !mediaFolder.length) {
            if (error) *error = YTMIImportError(51, @"The local Music storage could not be located.");
            return NO;
        }

        NSError *fileError = nil;
        NSString *destinationDirectory = YTMILocalMusicDirectory(mediaFolder, &fileError);
        if (!destinationDirectory.length) {
            if (error) *error = YTMIImportError(52, @"The local Music storage could not be prepared.");
            return NO;
        }

        NSString *compact = [NSUUID.UUID.UUIDString stringByReplacingOccurrencesOfString:@"-" withString:@""];
        NSString *fileName = [NSString stringWithFormat:@"%@.m4a", [compact substringToIndex:MIN((NSUInteger)12, compact.length)]];
        destinationPath = [destinationDirectory stringByAppendingPathComponent:fileName];
        if (![NSFileManager.defaultManager copyItemAtPath:audioURL.path toPath:destinationPath error:&fileError]) {
            if (error) *error = YTMIImportError(53, @"The audio could not be copied into local Music storage.");
            return NO;
        }

        NSDictionary *attributes = [NSFileManager.defaultManager attributesOfItemAtPath:destinationPath error:nil];
        AVURLAsset *asset = [AVURLAsset URLAssetWithURL:[NSURL fileURLWithPath:destinationPath] options:nil];
        double seconds = CMTimeGetSeconds(asset.duration);
        if (!isfinite(seconds) || seconds < 0) seconds = 0;
        NSDate *now = NSDate.date;
        NSString *title = YTMISafeText(metadata[YTMIJobTitleKey], @"YouTube Audio");
        NSString *artist = YTMISafeText(metadata[YTMIJobArtistKey], @"Unknown Artist");
        NSString *album = YTMISafeText(metadata[YTMIJobAlbumKey], @"YT Music Importer");

        NSDictionary *values = @{
            YTMIProperty(framework, "ML3TrackPropertyTitle", @"title"):title,
            YTMIProperty(framework, "ML3TrackPropertyArtist", @"artist"):artist,
            YTMIProperty(framework, "ML3TrackPropertyAlbum", @"album"):album,
            YTMIProperty(framework, "ML3TrackPropertyMediaType", @"media_type"):@1,
            YTMIProperty(framework, "ML3TrackPropertyMediaKind", @"media_kind"):@1,
            YTMIProperty(framework, "ML3TrackPropertyTotalSize", @"total_size"):attributes[NSFileSize] ?: @0,
            YTMIProperty(framework, "ML3TrackPropertyTotalTime", @"total_time"):@((long long)(seconds * 1000.0)),
            YTMIProperty(framework, "ML3TrackPropertyDateAdded", @"date_added"):now,
            YTMIProperty(framework, "ML3TrackPropertyDateModified", @"date_modified"):now,
            YTMIProperty(framework, "ML3TrackPropertyTrackNumber", @"track_number"):@1,
            YTMIProperty(framework, "ML3TrackPropertyDiscNumber", @"disc_number"):@1,
            YTMIProperty(framework, "ML3TrackPropertyHidden", @"hidden"):@NO,
            YTMIProperty(framework, "ML3TrackPropertyIsInMyLibrary", @"is_in_my_library"):@YES
        };

        SEL transactionSEL = NSSelectorFromString(@"performDatabaseTransactionWithBlock:");
        SEL initConnectionSEL = NSSelectorFromString(@"initWithDictionary:inLibrary:cachedNameOrders:usingConnection:");
        if (![library respondsToSelector:transactionSEL] || ![trackClass instancesRespondToSelector:initConnectionSEL]) {
            [NSFileManager.defaultManager removeItemAtPath:destinationPath error:nil];
            if (error) *error = YTMIImportError(58, @"The transactional Music import interface is unavailable.");
            return NO;
        }

        __block id track = nil;
        __block BOOL locationStored = NO;
        void (^transactionBlock)(id) = ^(id connection) {
            if (!connection) return;
            id allocated = ((id (*)(id, SEL))objc_msgSend)(trackClass, @selector(alloc));
            track = ((id (*)(id, SEL, id, id, id, id))objc_msgSend)(allocated, initConnectionSEL, values, library, [NSMutableDictionary dictionary], connection);
            if (!track) return;
            SEL internalPopulateSEL = NSSelectorFromString(@"_populateLocationPropertiesWithPath:protectionType:fromLibrary:usingConnection:");
            if ([track respondsToSelector:internalPopulateSEL]) {
                locationStored = ((BOOL (*)(id, SEL, id, long long, id, id))objc_msgSend)(track, internalPopulateSEL, destinationPath, 0, library, connection);
            }
        };
        ((void (*)(id, SEL, id))objc_msgSend)(library, transactionSEL, transactionBlock);

        if (!track) {
            [NSFileManager.defaultManager removeItemAtPath:destinationPath error:nil];
            if (error) *error = YTMIImportError(59, @"Music rejected the transactional track record.");
            return NO;
        }
        if (!locationStored) {
            [NSFileManager.defaultManager removeItemAtPath:destinationPath error:nil];
            if (error) *error = YTMIImportError(60, @"Music rejected the local track location.");
            return NO;
        }

        for (NSString *name in @[@"notifyEntitiesAddedOrRemoved", @"notifyContentsDidChange", @"notifyLibraryImportDidFinish"]) {
            SEL selector = NSSelectorFromString(name);
            if ([library respondsToSelector:selector]) ((void (*)(id, SEL))objc_msgSend)(library, selector);
        }

        [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:1.0]];

        BOOL verified = NO;
        SEL persistentSEL = NSSelectorFromString(@"persistentID");
        unsigned long long persistentID = [track respondsToSelector:persistentSEL] ? ((unsigned long long (*)(id, SEL))objc_msgSend)(track, persistentSEL) : 0;
        SEL visibleSEL = NSSelectorFromString(@"trackWithPersistentID:visibleInLibrary:");
        SEL existsSEL = NSSelectorFromString(@"trackWithPersistentID:existsInLibrary:");
        if (persistentID && [trackClass respondsToSelector:visibleSEL]) {
            verified = ((BOOL (*)(id, SEL, unsigned long long, id))objc_msgSend)(trackClass, visibleSEL, persistentID, library);
        }
        if (!verified && persistentID && [trackClass respondsToSelector:existsSEL]) {
            BOOL exists = ((BOOL (*)(id, SEL, unsigned long long, id))objc_msgSend)(trackClass, existsSEL, persistentID, library);
            if (exists && [library respondsToSelector:NSSelectorFromString(@"isLibraryEmpty")]) {
                verified = !((BOOL (*)(id, SEL))objc_msgSend)(library, NSSelectorFromString(@"isLibraryEmpty"));
            }
        }
        if (!verified) {
            [NSFileManager.defaultManager removeItemAtPath:destinationPath error:nil];
            if (error) *error = YTMIImportError(61, @"The new track is not visible in the Music library.");
            return NO;
        }

        return YES;
    } @catch (__unused NSException *exception) {
        if (destinationPath.length) [NSFileManager.defaultManager removeItemAtPath:destinationPath error:nil];
        if (error) *error = YTMIImportError(57, @"Music rejected the local import.");
        return NO;
    }
}

@end
