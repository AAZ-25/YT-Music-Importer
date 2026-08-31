#import <Foundation/Foundation.h>
#import <CoreFoundation/CoreFoundation.h>
#import <dlfcn.h>
#import <objc/message.h>
#import <spawn.h>
#import <sys/stat.h>
#import <sys/wait.h>
#import "../Native/YTMIMusicDatabaseImporter.h"
#import "../Shared/YTMIConstants.h"

extern char **environ;
static NSString * const YTMIRequestNotification=@"com.aaz.ytmusicimporter.request";
static NSString * const YTMISharedRoot=@"/var/mobile/Media/YTMusicImporter";

static NSString *YTMIYouTubeContainerPath(void){
    dlopen("/System/Library/Frameworks/MobileCoreServices.framework/MobileCoreServices",RTLD_LAZY|RTLD_LOCAL);
    Class cls=NSClassFromString(@"LSApplicationProxy");SEL sel=NSSelectorFromString(@"applicationProxyForIdentifier:");
    if(cls&&[cls respondsToSelector:sel]){
        id proxy=((id(*)(id,SEL,id))objc_msgSend)(cls,sel,@"com.google.ios.youtube");
        SEL csel=NSSelectorFromString(@"dataContainerURL");
        id url=proxy&&[proxy respondsToSelector:csel]?((id(*)(id,SEL))objc_msgSend)(proxy,csel):nil;
        if([url isKindOfClass:NSURL.class]&&[url isFileURL])return [url path];
    }
    return nil;
}
static NSString *YTMIFindJobDirectory(void){
    NSFileManager *fm=NSFileManager.defaultManager;NSString *container=YTMIYouTubeContainerPath();
    if(container.length){NSString *p=[container stringByAppendingPathComponent:@"Library/Caches/YTMusicImporter"];if([fm fileExistsAtPath:[p stringByAppendingPathComponent:@"pending.plist"]])return p;}
    NSString *root=@"/var/mobile/Containers/Data/Application";
    for(NSString *child in [fm contentsOfDirectoryAtPath:root error:nil]?:@[]){NSString *p=[[root stringByAppendingPathComponent:child]stringByAppendingPathComponent:@"Library/Caches/YTMusicImporter"];if([fm fileExistsAtPath:[p stringByAppendingPathComponent:@"pending.plist"]])return p;}
    return nil;
}
static BOOL YTMIValidSource(NSString *path,NSString *directory){
    NSString *suffix=@"/Library/Caches/YTMusicImporter";if(!path.length||![directory hasSuffix:suffix])return NO;
    NSString *container=[directory substringToIndex:directory.length-suffix.length];
    return [path.stringByStandardizingPath hasPrefix:[container.stringByStandardizingPath stringByAppendingString:@"/"]];
}
static void YTMIWriteResult(NSString *directory,NSString *nonce,NSString *importID,BOOL success,NSInteger code,NSArray *trace){
    if(directory.length&&nonce.length)[@{@"nonce":nonce,@"success":@(success),@"code":@(code),YTMIJobImportIDKey:importID?:@"B42-UNKNOWN",@"trace":trace?:@[]}writeToFile:[directory stringByAppendingPathComponent:@"result.plist"]atomically:YES];
}
static void YTMIRunProcess(const char *program,char *const argv[]){
    pid_t pid=0;if(posix_spawnp(&pid,program,NULL,NULL,argv,environ)==0){int status=0;waitpid(pid,&status,0);}
}
static void YTMIQuiesceMusic(void){
    char *music[]={"killall","-9","Music",NULL};YTMIRunProcess("killall",music);
    char *mobile[]={"killall","-9","MobileMusicPlayer",NULL};YTMIRunProcess("killall",mobile);
    char *library[]={"killall","-9","medialibraryd",NULL};YTMIRunProcess("killall",library);
    [NSThread sleepForTimeInterval:0.5];
}
static void YTMILaunchMusic(void){
    dlopen("/System/Library/Frameworks/MobileCoreServices.framework/MobileCoreServices",RTLD_LAZY|RTLD_LOCAL);
    Class cls=NSClassFromString(@"LSApplicationWorkspace");SEL dsel=NSSelectorFromString(@"defaultWorkspace"),osel=NSSelectorFromString(@"openApplicationWithBundleID:");
    if(cls&&[cls respondsToSelector:dsel]){id ws=((id(*)(id,SEL))objc_msgSend)(cls,dsel);if(ws&&[ws respondsToSelector:osel])((BOOL(*)(id,SEL,id))objc_msgSend)(ws,osel,@"com.apple.Music");}
}
static void YTMIHandleRequest(void){
    @autoreleasepool{@synchronized(YTMIMusicDatabaseImporter.class){
        NSString *directory=YTMIFindJobDirectory();if(!directory.length)return;
        NSString *pending=[directory stringByAppendingPathComponent:@"pending.plist"];
        NSDictionary *job=[NSDictionary dictionaryWithContentsOfFile:pending];
        NSString *nonce=[job[@"nonce"]isKindOfClass:NSString.class]?job[@"nonce"]:nil;
        NSString *importID=[job[YTMIJobImportIDKey]isKindOfClass:NSString.class]?job[YTMIJobImportIDKey]:@"B42-UNKNOWN";
        NSMutableArray *trace=[NSMutableArray arrayWithObject:@"bridge.request.received"];
        NSString *audio=[job[@"audioPath"]isKindOfClass:NSString.class]?job[@"audioPath"]:nil;
        if(!nonce.length||!YTMIValidSource(audio,directory)||![NSFileManager.defaultManager fileExistsAtPath:audio]){[trace addObject:@"bridge.source.invalid"];if(nonce.length)YTMIWriteResult(directory,nonce,importID,NO,43,trace);return;}
        [trace addObject:@"bridge.source.valid"];
        NSFileManager *fm=NSFileManager.defaultManager;
        [fm createDirectoryAtPath:YTMISharedRoot withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions:@0755} error:nil];
        NSString *copy=[YTMISharedRoot stringByAppendingPathComponent:[nonce stringByAppendingPathExtension:@"m4a"]];
        [fm removeItemAtPath:copy error:nil];
        if(![fm copyItemAtPath:audio toPath:copy error:nil]){[trace addObject:@"bridge.staging.failed"];YTMIWriteResult(directory,nonce,importID,NO,38,trace);return;}
        [trace addObject:@"bridge.staging.complete"];
        chmod(copy.fileSystemRepresentation,0644);
        NSDictionary *metadata=@{YTMIJobTitleKey:[job[@"title"]isKindOfClass:NSString.class]?job[@"title"]:@"",YTMIJobArtistKey:[job[@"artist"]isKindOfClass:NSString.class]?job[@"artist"]:@"",YTMIJobAlbumKey:[job[@"album"]isKindOfClass:NSString.class]?job[@"album"]:@""};
        YTMIQuiesceMusic();
        [trace addObject:@"bridge.music.quiesced"];
        NSError *importError=nil;BOOL success=[[YTMIMusicDatabaseImporter new]importAudioAtURL:[NSURL fileURLWithPath:copy]metadata:metadata trace:trace error:&importError];
        NSInteger code=success?0:([importError.domain isEqualToString:@"com.aaz.ytmusicimporter"]&&importError.code>0?importError.code:44);
        [trace addObject:success?@"bridge.import.accepted":[NSString stringWithFormat:@"bridge.import.failed.%ld",(long)code]];
        [fm removeItemAtPath:copy error:nil];[fm removeItemAtPath:pending error:nil];YTMIWriteResult(directory,nonce,importID,success,code,trace);
        if(success)YTMILaunchMusic();
    }}
}
static void YTMIRequestCallback(CFNotificationCenterRef center,void *observer,CFStringRef name,const void *object,CFDictionaryRef userInfo){
    (void)center;(void)observer;(void)name;(void)object;(void)userInfo;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0),^{YTMIHandleRequest();});
}
__attribute__((constructor))static void YTMIBridgeInit(void){
    if([NSProcessInfo.processInfo.processName isEqualToString:@"SpringBoard"])CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),NULL,YTMIRequestCallback,(__bridge CFStringRef)YTMIRequestNotification,NULL,CFNotificationSuspensionBehaviorDeliverImmediately);
}
