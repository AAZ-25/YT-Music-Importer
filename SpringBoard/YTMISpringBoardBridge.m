#import <Foundation/Foundation.h>
#import <CoreFoundation/CoreFoundation.h>
#import <dlfcn.h>
#import <objc/message.h>
#import <sys/stat.h>
#import "../Native/YTMIMusicDatabaseImporter.h"
#import "../Shared/YTMIConstants.h"

static NSString * const YTMIRequestNotification = @"com.aaz.ytmusicimporter.request";
static NSString * const YTMIMusicRequestNotification = @"com.aaz.ytmusicimporter.music.request";
static NSString * const YTMISharedRoot = @"/var/mobile/Media/YTMusicImporter";

static BOOL YTMIIsMediaLibraryProcess(void) {
    NSString *name = NSProcessInfo.processInfo.processName ?: @"";
    return [name isEqualToString:@"medialibraryd"];
}

static NSString *YTMIYouTubeContainerPath(void) {
    dlopen("/System/Library/Frameworks/MobileCoreServices.framework/MobileCoreServices", RTLD_LAZY | RTLD_LOCAL);
    Class proxyClass = NSClassFromString(@"LSApplicationProxy");
    SEL proxySEL = NSSelectorFromString(@"applicationProxyForIdentifier:");
    if (proxyClass && [proxyClass respondsToSelector:proxySEL]) {
        id proxy = ((id (*)(id, SEL, id))objc_msgSend)(proxyClass, proxySEL, @"com.google.ios.youtube");
        SEL containerSEL = NSSelectorFromString(@"dataContainerURL");
        if (proxy && [proxy respondsToSelector:containerSEL]) {
            id url = ((id (*)(id, SEL))objc_msgSend)(proxy, containerSEL);
            if ([url isKindOfClass:NSURL.class] && [url isFileURL]) return [url path];
        }
    }
    return nil;
}

static NSString *YTMIFindYouTubeJobDirectory(void) {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSString *container = YTMIYouTubeContainerPath();
    if (container.length) {
        NSString *candidate = [container stringByAppendingPathComponent:@"Library/Caches/YTMusicImporter"];
        if ([fm fileExistsAtPath:[candidate stringByAppendingPathComponent:@"pending.plist"]]) return candidate;
    }
    NSString *root = @"/var/mobile/Containers/Data/Application";
    for (NSString *child in [fm contentsOfDirectoryAtPath:root error:nil] ?: @[]) {
        NSString *candidate = [[root stringByAppendingPathComponent:child] stringByAppendingPathComponent:@"Library/Caches/YTMusicImporter"];
        if ([fm fileExistsAtPath:[candidate stringByAppendingPathComponent:@"pending.plist"]]) return candidate;
    }
    return nil;
}

static BOOL YTMIPathBelongsToYouTubeContainer(NSString *audioPath, NSString *jobDirectory) {
    if (!audioPath.length || !jobDirectory.length) return NO;
    NSString *suffix = @"/Library/Caches/YTMusicImporter";
    if (![jobDirectory hasSuffix:suffix]) return NO;
    NSString *container = [jobDirectory substringToIndex:jobDirectory.length - suffix.length];
    NSString *standardAudio = audioPath.stringByStandardizingPath;
    NSString *standardContainer = container.stringByStandardizingPath;
    return [standardAudio hasPrefix:[standardContainer stringByAppendingString:@"/"]];
}

static void YTMIWriteYouTubeResult(NSString *directory, NSString *nonce, BOOL success, NSInteger code) {
    if (!directory.length || !nonce.length) return;
    NSDictionary *result = @{@"nonce":nonce, @"success":@(success), @"code":@(code)};
    [result writeToFile:[directory stringByAppendingPathComponent:@"result.plist"] atomically:YES];
}

static void YTMILaunchMusic(void) {
    dlopen("/System/Library/Frameworks/MobileCoreServices.framework/MobileCoreServices", RTLD_LAZY | RTLD_LOCAL);
    Class workspaceClass = NSClassFromString(@"LSApplicationWorkspace");
    SEL defaultSEL = NSSelectorFromString(@"defaultWorkspace");
    SEL openSEL = NSSelectorFromString(@"openApplicationWithBundleID:");
    if (workspaceClass && [workspaceClass respondsToSelector:defaultSEL]) {
        id workspace = ((id (*)(id, SEL))objc_msgSend)(workspaceClass, defaultSEL);
        if (workspace && [workspace respondsToSelector:openSEL]) {
            ((BOOL (*)(id, SEL, id))objc_msgSend)(workspace, openSEL, @"com.apple.Music");
        }
    }
}

static void YTMIHandleMediaLibraryRequest(void) {
    @autoreleasepool {
        NSString *pendingPath = [YTMISharedRoot stringByAppendingPathComponent:@"pending.plist"];
        NSDictionary *job = [NSDictionary dictionaryWithContentsOfFile:pendingPath];
        NSString *nonce = [job[@"nonce"] isKindOfClass:NSString.class] ? job[@"nonce"] : nil;
        NSString *audioPath = [job[@"audioPath"] isKindOfClass:NSString.class] ? job[@"audioPath"] : nil;
        if (!nonce.length || !audioPath.length || ![audioPath.stringByStandardizingPath hasPrefix:[YTMISharedRoot stringByAppendingString:@"/"]] || ![NSFileManager.defaultManager fileExistsAtPath:audioPath]) return;

        NSDictionary *metadata = @{
            YTMIJobTitleKey: [job[@"title"] isKindOfClass:NSString.class] ? job[@"title"] : @"",
            YTMIJobArtistKey: [job[@"artist"] isKindOfClass:NSString.class] ? job[@"artist"] : @"",
            YTMIJobAlbumKey: [job[@"album"] isKindOfClass:NSString.class] ? job[@"album"] : @""
        };
        __block NSError *error = nil;
        __block BOOL success = NO;
        void (^importBlock)(void) = ^{
            success = [[YTMIMusicDatabaseImporter new] importAudioAtURL:[NSURL fileURLWithPath:audioPath] metadata:metadata error:&error];
        };
        if ([NSThread isMainThread]) importBlock();
        else dispatch_sync(dispatch_get_main_queue(), importBlock);

        NSInteger code = success ? 0 : ([error.domain isEqualToString:@"com.aaz.ytmusicimporter"] && error.code > 0 ? error.code : 44);
        NSDictionary *result = @{@"nonce":nonce, @"success":@(success), @"code":@(code)};
        [result writeToFile:[YTMISharedRoot stringByAppendingPathComponent:@"music-result.plist"] atomically:YES];
        [NSFileManager.defaultManager removeItemAtPath:pendingPath error:nil];
        if (!success) [NSFileManager.defaultManager removeItemAtPath:audioPath error:nil];
    }
}

static void YTMIRelayFromSpringBoard(void) {
    @autoreleasepool {
        NSString *directory = YTMIFindYouTubeJobDirectory();
        if (!directory.length) return;
        NSString *pendingPath = [directory stringByAppendingPathComponent:@"pending.plist"];
        NSDictionary *job = [NSDictionary dictionaryWithContentsOfFile:pendingPath];
        NSString *nonce = [job[@"nonce"] isKindOfClass:NSString.class] ? job[@"nonce"] : nil;
        NSString *audioPath = [job[@"audioPath"] isKindOfClass:NSString.class] ? job[@"audioPath"] : nil;
        if (!nonce.length || !YTMIPathBelongsToYouTubeContainer(audioPath, directory) || ![NSFileManager.defaultManager fileExistsAtPath:audioPath]) {
            if (nonce.length) YTMIWriteYouTubeResult(directory, nonce, NO, 43);
            return;
        }

        [NSFileManager.defaultManager createDirectoryAtPath:YTMISharedRoot withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions:@0755} error:nil];
        NSString *sharedAudio = [YTMISharedRoot stringByAppendingPathComponent:[NSString stringWithFormat:@"%@.m4a", nonce]];
        [NSFileManager.defaultManager removeItemAtPath:sharedAudio error:nil];
        if (![NSFileManager.defaultManager copyItemAtPath:audioPath toPath:sharedAudio error:nil]) {
            YTMIWriteYouTubeResult(directory, nonce, NO, 38);
            return;
        }
        chmod(sharedAudio.fileSystemRepresentation, 0644);
        NSDictionary *sharedJob = @{
            @"nonce":nonce,
            @"audioPath":sharedAudio,
            @"title":[job[@"title"] isKindOfClass:NSString.class] ? job[@"title"] : @"",
            @"artist":[job[@"artist"] isKindOfClass:NSString.class] ? job[@"artist"] : @"",
            @"album":[job[@"album"] isKindOfClass:NSString.class] ? job[@"album"] : @""
        };
        NSString *sharedPending = [YTMISharedRoot stringByAppendingPathComponent:@"pending.plist"];
        NSString *sharedResult = [YTMISharedRoot stringByAppendingPathComponent:@"music-result.plist"];
        [NSFileManager.defaultManager removeItemAtPath:sharedResult error:nil];
        [sharedJob writeToFile:sharedPending atomically:YES];
        chmod(sharedPending.fileSystemRepresentation, 0644);

        YTMILaunchMusic();
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(), (__bridge CFStringRef)YTMIMusicRequestNotification, NULL, NULL, true);
        });

        NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:45.0];
        while (deadline.timeIntervalSinceNow > 0) {
            NSDictionary *result = [NSDictionary dictionaryWithContentsOfFile:sharedResult];
            if ([result[@"nonce"] isKindOfClass:NSString.class] && [result[@"nonce"] isEqualToString:nonce]) {
                BOOL success = [result[@"success"] boolValue];
                NSInteger code = [result[@"code"] integerValue];
                YTMIWriteYouTubeResult(directory, nonce, success, code);
                [NSFileManager.defaultManager removeItemAtPath:sharedResult error:nil];
                [NSFileManager.defaultManager removeItemAtPath:sharedPending error:nil];
                [NSFileManager.defaultManager removeItemAtPath:sharedAudio error:nil];
                return;
            }
            [NSThread sleepForTimeInterval:0.10];
        }
        YTMIWriteYouTubeResult(directory, nonce, NO, 49);
        [NSFileManager.defaultManager removeItemAtPath:sharedPending error:nil];
        [NSFileManager.defaultManager removeItemAtPath:sharedAudio error:nil];
    }
}

static void YTMIRequestCallback(CFNotificationCenterRef center, void *observer, CFStringRef name, const void *object, CFDictionaryRef userInfo) {
    (void)center; (void)observer; (void)name; (void)object; (void)userInfo;
    if ([NSProcessInfo.processInfo.processName isEqualToString:@"SpringBoard"]) {
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{ YTMIRelayFromSpringBoard(); });
    } else if (YTMIIsMediaLibraryProcess()) {
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{ YTMIHandleMediaLibraryRequest(); });
    }
}

__attribute__((constructor)) static void YTMIMusicBridgeInit(void) {
    NSString *name = NSProcessInfo.processInfo.processName ?: @"";
    if ([name isEqualToString:@"SpringBoard"]) {
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL, YTMIRequestCallback, (__bridge CFStringRef)YTMIRequestNotification, NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
        return;
    }
    if (YTMIIsMediaLibraryProcess()) {
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL, YTMIRequestCallback, (__bridge CFStringRef)YTMIMusicRequestNotification, NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.8 * NSEC_PER_SEC)), dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{ YTMIHandleMediaLibraryRequest(); });
    }
}
