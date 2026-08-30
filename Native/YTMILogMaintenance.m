#import <Foundation/Foundation.h>

static const unsigned long long YTMILogMaximumBytes = 256 * 1024;
static const NSUInteger YTMILogRetainedBytes = 128 * 1024;
static dispatch_source_t YTMILogMaintenanceTimer;

static NSString *YTMIMaintenanceLogPath(void) {
    NSString *cache = NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES).firstObject;
    if (!cache.length) return nil;
    return [[cache stringByAppendingPathComponent:@"YTMusicImporter"] stringByAppendingPathComponent:@"debug.log"];
}

static void YTMITrimDebugLog(void) {
    NSString *path = YTMIMaintenanceLogPath();
    if (!path.length) return;
    NSFileManager *fm = NSFileManager.defaultManager;
    NSDictionary *attributes = [fm attributesOfItemAtPath:path error:nil];
    unsigned long long size = [attributes[NSFileSize] unsignedLongLongValue];
    if (size <= YTMILogMaximumBytes) return;

    NSFileHandle *handle = [NSFileHandle fileHandleForReadingAtPath:path];
    if (!handle) return;
    unsigned long long offset = size > YTMILogRetainedBytes ? size - YTMILogRetainedBytes : 0;
    @try {
        [handle seekToFileOffset:offset];
        NSData *tail = [handle readDataToEndOfFile];
        [handle closeFile];
        if (!tail.length) return;

        const uint8_t *bytes = tail.bytes;
        NSUInteger start = 0;
        if (offset > 0) {
            while (start < tail.length && bytes[start] != '\n') start++;
            if (start < tail.length) start++;
        }
        NSData *trimmed = start < tail.length ? [tail subdataWithRange:NSMakeRange(start, tail.length - start)] : tail;
        [trimmed writeToFile:path atomically:YES];
    } @catch (__unused NSException *exception) {
        [handle closeFile];
    }
}

__attribute__((constructor)) static void YTMILogMaintenanceInstall(void) {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{ YTMITrimDebugLog(); });
    YTMILogMaintenanceTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_global_queue(QOS_CLASS_UTILITY, 0));
    dispatch_source_set_timer(YTMILogMaintenanceTimer, dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC), 10 * NSEC_PER_SEC, 2 * NSEC_PER_SEC);
    dispatch_source_set_event_handler(YTMILogMaintenanceTimer, ^{ YTMITrimDebugLog(); });
    dispatch_resume(YTMILogMaintenanceTimer);
}
