#import "YTMIMusicImporter.h"
#import "YTMIConstants.h"
#import <CoreFoundation/CoreFoundation.h>
#import <sys/stat.h>

static NSString * const YTMIRequestNotification = @"com.aaz.ytmusicimporter.request";

static NSError *YTMIClientError(NSInteger code, NSString *message) {
    return [NSError errorWithDomain:@"com.aaz.ytmusicimporter" code:code userInfo:@{NSLocalizedDescriptionKey: message}];
}

static NSString *YTMIJobDirectory(void) {
    NSString *caches = NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES).firstObject;
    if (!caches.length) return nil;
    return [caches stringByAppendingPathComponent:@"YTMusicImporter"];
}

@interface YTMIMusicImporter ()
@property (nonatomic, copy, readwrite) NSDictionary *lastDiagnostics;
@end

@implementation YTMIMusicImporter

- (BOOL)importAudioAtURL:(NSURL *)audioURL metadata:(NSDictionary *)metadata error:(NSError **)error {
    NSString *importID = [metadata[YTMIJobImportIDKey] isKindOfClass:NSString.class] ? metadata[YTMIJobImportIDKey] : @"B45-UNKNOWN";
    if (!audioURL.isFileURL || ![NSFileManager.defaultManager fileExistsAtPath:audioURL.path]) {
        self.lastDiagnostics = @{YTMIJobImportIDKey:importID, @"trace":@[@"client.source.missing"]};
        if (error) *error = YTMIClientError(19, @"The prepared audio file is unavailable.");
        return NO;
    }

    NSString *directory = YTMIJobDirectory();
    if (!directory.length || ![NSFileManager.defaultManager createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions:@0700} error:nil]) {
        self.lastDiagnostics = @{YTMIJobImportIDKey:importID, @"trace":@[@"client.handoff.directory-failed"]};
        if (error) *error = YTMIClientError(40, @"The import handoff could not be prepared.");
        return NO;
    }

    NSString *nonce = NSUUID.UUID.UUIDString;
    NSString *pendingPath = [directory stringByAppendingPathComponent:@"pending.plist"];
    NSString *resultPath = [directory stringByAppendingPathComponent:@"result.plist"];
    [NSFileManager.defaultManager removeItemAtPath:resultPath error:nil];

    NSString *title = [metadata[YTMIJobTitleKey] isKindOfClass:NSString.class] ? metadata[YTMIJobTitleKey] : @"";
    NSString *artist = [metadata[YTMIJobArtistKey] isKindOfClass:NSString.class] ? metadata[YTMIJobArtistKey] : @"";
    NSString *album = [metadata[YTMIJobAlbumKey] isKindOfClass:NSString.class] ? metadata[YTMIJobAlbumKey] : @"";
    NSDictionary *job = @{@"nonce":nonce, @"audioPath":audioURL.path, @"title":title, @"artist":artist, @"album":album, YTMIJobImportIDKey:importID};

    if (![job writeToFile:pendingPath atomically:YES]) {
        if (error) *error = YTMIClientError(40, @"The import handoff could not be prepared.");
        self.lastDiagnostics = @{YTMIJobImportIDKey:importID, @"trace":@[@"client.handoff.failed"]};
        return NO;
    }
    chmod(pendingPath.fileSystemRepresentation, 0600);

    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(), (__bridge CFStringRef)YTMIRequestNotification, NULL, NULL, true);

    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:170.0];
    while ([deadline timeIntervalSinceNow] > 0) {
        NSDictionary *result = [NSDictionary dictionaryWithContentsOfFile:resultPath];
        if ([result[@"nonce"] isKindOfClass:NSString.class] && [result[@"nonce"] isEqualToString:nonce]) {
            self.lastDiagnostics = result;
            [NSFileManager.defaultManager removeItemAtPath:resultPath error:nil];
            [NSFileManager.defaultManager removeItemAtPath:pendingPath error:nil];
            BOOL success = [result[@"success"] boolValue];
            NSInteger code = [result[@"code"] integerValue];
            if (success) return YES;
            if (error) *error = YTMIClientError(code > 0 ? code : 42, @"Music rejected the import.");
            return NO;
        }
        if ([NSThread isMainThread]) [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
        else [NSThread sleepForTimeInterval:0.05];
    }

    [NSFileManager.defaultManager removeItemAtPath:pendingPath error:nil];
    self.lastDiagnostics = @{YTMIJobImportIDKey:importID, @"trace":@[@"client.bridge.timeout"]};
    if (error) *error = YTMIClientError(41, @"The Music import service did not respond.");
    return NO;
}

@end
