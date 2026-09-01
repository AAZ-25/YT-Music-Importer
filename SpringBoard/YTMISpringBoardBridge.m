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

static BOOL YTMIIsMusicProcess(void) { NSString *name = NSProcessInfo.processInfo.processName ?: @""; return [@[@"MobileMusicPlayer", @"Music~iphone", @"Music~ipad", @"Music"] containsObject:name]; }
static NSString *YTMIYouTubeContainerPath(void) {
    dlopen("/System/Library/Frameworks/MobileCoreServices.framework/MobileCoreServices", RTLD_LAZY | RTLD_LOCAL);
    Class cls=NSClassFromString(@"LSApplicationProxy"); SEL sel=NSSelectorFromString(@"applicationProxyForIdentifier:");
    if(cls&&[cls respondsToSelector:sel]){id proxy=((id(*)(id,SEL,id))objc_msgSend)(cls,sel,@"com.google.ios.youtube");SEL csel=NSSelectorFromString(@"dataContainerURL");id url=proxy&&[proxy respondsToSelector:csel]?((id(*)(id,SEL))objc_msgSend)(proxy,csel):nil;if([url isKindOfClass:NSURL.class]&&[url isFileURL])return [url path];} return nil;
}
static NSString *YTMIFindJobDirectory(void) {
    NSFileManager *fm=NSFileManager.defaultManager; NSString *container=YTMIYouTubeContainerPath();
    if(container.length){NSString *p=[container stringByAppendingPathComponent:@"Library/Caches/YTMusicImporter"];if([fm fileExistsAtPath:[p stringByAppendingPathComponent:@"pending.plist"]])return p;}
    NSString *root=@"/var/mobile/Containers/Data/Application";for(NSString *child in [fm contentsOfDirectoryAtPath:root error:nil]?:@[]){NSString *p=[[root stringByAppendingPathComponent:child]stringByAppendingPathComponent:@"Library/Caches/YTMusicImporter"];if([fm fileExistsAtPath:[p stringByAppendingPathComponent:@"pending.plist"]])return p;}return nil;
}
static BOOL YTMIValidSource(NSString *path,NSString *directory){NSString *suffix=@"/Library/Caches/YTMusicImporter";if(!path.length||![directory hasSuffix:suffix])return NO;NSString *container=[directory substringToIndex:directory.length-suffix.length];return [path.stringByStandardizingPath hasPrefix:[container.stringByStandardizingPath stringByAppendingString:@"/"]];}
static void YTMIWriteYouTubeResult(NSString *directory,NSString *nonce,NSString *importID,BOOL success,NSInteger code,NSArray *trace){if(directory.length&&nonce.length)[@{@"nonce":nonce,@"success":@(success),@"code":@(code),YTMIJobImportIDKey:importID?:@"B43-UNKNOWN",@"trace":trace?:@[]}writeToFile:[directory stringByAppendingPathComponent:@"result.plist"]atomically:YES];}
static void YTMILaunchMusic(void){dlopen("/System/Library/Frameworks/MobileCoreServices.framework/MobileCoreServices",RTLD_LAZY|RTLD_LOCAL);Class cls=NSClassFromString(@"LSApplicationWorkspace");SEL d=NSSelectorFromString(@"defaultWorkspace"),o=NSSelectorFromString(@"openApplicationWithBundleID:");if(cls&&[cls respondsToSelector:d]){id ws=((id(*)(id,SEL))objc_msgSend)(cls,d);if(ws&&[ws respondsToSelector:o])((BOOL(*)(id,SEL,id))objc_msgSend)(ws,o,@"com.apple.Music");}}
static void YTMIHandleMusicRequest(void) {
    @autoreleasepool {@synchronized(YTMIMusicDatabaseImporter.class) {
        NSString *pending=[YTMISharedRoot stringByAppendingPathComponent:@"pending.plist"],*resultPath=[YTMISharedRoot stringByAppendingPathComponent:@"music-result.plist"];
        NSDictionary *job=[NSDictionary dictionaryWithContentsOfFile:pending]; NSString *nonce=[job[@"nonce"]isKindOfClass:NSString.class]?job[@"nonce"]:nil; NSString *audio=[job[@"audioPath"]isKindOfClass:NSString.class]?job[@"audioPath"]:nil; NSString *importID=[job[YTMIJobImportIDKey]isKindOfClass:NSString.class]?job[YTMIJobImportIDKey]:@"B43-UNKNOWN";
        if(!nonce.length||![audio.stringByStandardizingPath hasPrefix:[YTMISharedRoot stringByAppendingString:@"/"]]||![NSFileManager.defaultManager fileExistsAtPath:audio])return;
        NSMutableArray *trace=[NSMutableArray arrayWithObjects:@"music.request.received",@"music.source.valid",nil]; NSDictionary *metadata=@{YTMIJobTitleKey:[job[@"title"]isKindOfClass:NSString.class]?job[@"title"]:@"",YTMIJobArtistKey:[job[@"artist"]isKindOfClass:NSString.class]?job[@"artist"]:@"",YTMIJobAlbumKey:[job[@"album"]isKindOfClass:NSString.class]?job[@"album"]:@""};
        NSError *importError=nil; BOOL success=[[YTMIMusicDatabaseImporter new]importAudioAtURL:[NSURL fileURLWithPath:audio]metadata:metadata trace:trace error:&importError]; NSInteger code=success?0:([importError.domain isEqualToString:@"com.aaz.ytmusicimporter"]&&importError.code>0?importError.code:44);
        [trace addObject:success?@"music.import.accepted":[NSString stringWithFormat:@"music.import.failed.%ld",(long)code]];
        [@{@"nonce":nonce,@"success":@(success),@"code":@(code),YTMIJobImportIDKey:importID,@"trace":trace}writeToFile:resultPath atomically:YES]; [NSFileManager.defaultManager removeItemAtPath:pending error:nil];
    }}
}
static void YTMIRelayFromSpringBoard(void) {
    @autoreleasepool {@synchronized(YTMIMusicDatabaseImporter.class) {
        NSString *directory=YTMIFindJobDirectory(); if(!directory.length)return; NSDictionary *job=[NSDictionary dictionaryWithContentsOfFile:[directory stringByAppendingPathComponent:@"pending.plist"]]; NSString *nonce=[job[@"nonce"]isKindOfClass:NSString.class]?job[@"nonce"]:nil; NSString *audio=[job[@"audioPath"]isKindOfClass:NSString.class]?job[@"audioPath"]:nil; NSString *importID=[job[YTMIJobImportIDKey]isKindOfClass:NSString.class]?job[YTMIJobImportIDKey]:@"B43-UNKNOWN"; NSMutableArray *trace=[NSMutableArray arrayWithObject:@"bridge.request.received"];
        if(!nonce.length||!YTMIValidSource(audio,directory)||![NSFileManager.defaultManager fileExistsAtPath:audio]){[trace addObject:@"bridge.source.invalid"];if(nonce.length)YTMIWriteYouTubeResult(directory,nonce,importID,NO,43,trace);return;}[trace addObject:@"bridge.source.valid"];
        NSFileManager *fm=NSFileManager.defaultManager;[fm createDirectoryAtPath:YTMISharedRoot withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions:@0755} error:nil];NSString *copy=[YTMISharedRoot stringByAppendingPathComponent:[nonce stringByAppendingPathExtension:@"m4a"]];[fm removeItemAtPath:copy error:nil];if(![fm copyItemAtPath:audio toPath:copy error:nil]){[trace addObject:@"bridge.staging.failed"];YTMIWriteYouTubeResult(directory,nonce,importID,NO,38,trace);return;}chmod(copy.fileSystemRepresentation,0644);[trace addObject:@"bridge.staging.complete"];
        NSString *sharedResult=[YTMISharedRoot stringByAppendingPathComponent:@"music-result.plist"],*sharedPending=[YTMISharedRoot stringByAppendingPathComponent:@"pending.plist"];[fm removeItemAtPath:sharedResult error:nil];NSDictionary *shared=@{@"nonce":nonce,@"audioPath":copy,YTMIJobImportIDKey:importID,@"title":[job[@"title"]isKindOfClass:NSString.class]?job[@"title"]:@"",@"artist":[job[@"artist"]isKindOfClass:NSString.class]?job[@"artist"]:@"",@"album":[job[@"album"]isKindOfClass:NSString.class]?job[@"album"]:@""};[shared writeToFile:sharedPending atomically:YES];chmod(sharedPending.fileSystemRepresentation,0644);YTMILaunchMusic();
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(1.0*NSEC_PER_SEC)),dispatch_get_global_queue(QOS_CLASS_UTILITY,0),^{CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),(__bridge CFStringRef)YTMIMusicRequestNotification,NULL,NULL,true);});
        NSDate *deadline=[NSDate dateWithTimeIntervalSinceNow:150.0];while(deadline.timeIntervalSinceNow>0){NSDictionary *result=[NSDictionary dictionaryWithContentsOfFile:sharedResult];if([result[@"nonce"]isEqualToString:nonce]){NSArray *musicTrace=[result[@"trace"]isKindOfClass:NSArray.class]?result[@"trace"]:@[];[trace addObjectsFromArray:musicTrace];BOOL success=[result[@"success"]boolValue];NSInteger code=[result[@"code"]integerValue];YTMIWriteYouTubeResult(directory,nonce,importID,success,code,trace);[fm removeItemAtPath:sharedResult error:nil];[fm removeItemAtPath:sharedPending error:nil];[fm removeItemAtPath:copy error:nil];[fm removeItemAtPath:[directory stringByAppendingPathComponent:@"pending.plist"] error:nil];return;}[NSThread sleepForTimeInterval:0.10];}
        [trace addObject:@"bridge.music.timeout"];YTMIWriteYouTubeResult(directory,nonce,importID,NO,92,trace);[fm removeItemAtPath:sharedPending error:nil];[fm removeItemAtPath:copy error:nil];
    }}
}
static void YTMIRequestCallback(CFNotificationCenterRef c,void *o,CFStringRef n,const void *obj,CFDictionaryRef u){(void)c;(void)o;(void)obj;(void)u;if([(__bridge NSString *)n isEqualToString:YTMIRequestNotification])dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0),^{YTMIRelayFromSpringBoard();});else dispatch_async(dispatch_get_main_queue(),^{YTMIHandleMusicRequest();});}
__attribute__((constructor))static void YTMIBridgeInit(void){NSString *name=NSProcessInfo.processInfo.processName?:@"";if([name isEqualToString:@"SpringBoard"])CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),NULL,YTMIRequestCallback,(__bridge CFStringRef)YTMIRequestNotification,NULL,CFNotificationSuspensionBehaviorDeliverImmediately);else if(YTMIIsMusicProcess()){CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),NULL,YTMIRequestCallback,(__bridge CFStringRef)YTMIMusicRequestNotification,NULL,CFNotificationSuspensionBehaviorDeliverImmediately);dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(0.8*NSEC_PER_SEC)),dispatch_get_main_queue(),^{YTMIHandleMusicRequest();});}}
