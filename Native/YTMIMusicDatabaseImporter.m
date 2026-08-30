#import "YTMIMusicDatabaseImporter.h"
#import "YTMIConstants.h"
#import <AVFoundation/AVFoundation.h>
#import <arpa/inet.h>
#import <dlfcn.h>
#import <math.h>
#import <netinet/in.h>
#import <objc/message.h>
#import <sys/socket.h>
#import <unistd.h>

static NSError *YTMIQueueError(NSInteger code, NSString *message) {
    return [NSError errorWithDomain:@"com.aaz.ytmusicimporter" code:code userInfo:@{NSLocalizedDescriptionKey:message}];
}

static id QSend0(id object, SEL selector) {
    return object && selector && [object respondsToSelector:selector] ? ((id (*)(id, SEL))objc_msgSend)(object, selector) : nil;
}

static id QSend1(id object, SEL selector, id value) {
    return object && selector && [object respondsToSelector:selector] ? ((id (*)(id, SEL, id))objc_msgSend)(object, selector, value) : nil;
}

static NSString *QSafeText(id value, NSString *fallback) {
    if (![value isKindOfClass:NSString.class]) return fallback;
    NSString *text = [(NSString *)value stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    return text.length ? text : fallback;
}

static BOOL QWriteAll(int fd, const void *bytes, size_t length) {
    const uint8_t *cursor = bytes;
    while (length > 0) {
        ssize_t written = write(fd, cursor, length);
        if (written <= 0) return NO;
        cursor += written;
        length -= (size_t)written;
    }
    return YES;
}

@interface YTMIQueueMediaServer : NSObject
@property(nonatomic) int socketFD;
@property(nonatomic) uint16_t port;
@property(nonatomic, copy) NSString *filePath;
@property(nonatomic, strong) dispatch_semaphore_t servedSemaphore;
- (instancetype)initWithFilePath:(NSString *)path;
- (BOOL)start;
- (void)stop;
- (NSURL *)mediaURL;
- (BOOL)waitUntilServed:(NSTimeInterval)timeout;
@end

@implementation YTMIQueueMediaServer
- (instancetype)initWithFilePath:(NSString *)path {
    if ((self = [super init])) {
        _socketFD = -1;
        _filePath = [path copy];
        _servedSemaphore = dispatch_semaphore_create(0);
    }
    return self;
}
- (BOOL)start {
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) return NO;
    int one = 1;
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));
    struct sockaddr_in address;
    memset(&address, 0, sizeof(address));
    address.sin_family = AF_INET;
    address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    address.sin_port = 0;
    if (bind(fd, (struct sockaddr *)&address, sizeof(address)) != 0 || listen(fd, 4) != 0) { close(fd); return NO; }
    socklen_t len = sizeof(address);
    if (getsockname(fd, (struct sockaddr *)&address, &len) != 0) { close(fd); return NO; }
    self.socketFD = fd;
    self.port = ntohs(address.sin_port);
    NSString *path = [self.filePath copy];
    dispatch_semaphore_t served = self.servedSemaphore;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        @autoreleasepool {
            struct timeval timeout = {.tv_sec = 25, .tv_usec = 0};
            setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout));
            for (NSInteger attempt = 0; attempt < 8; attempt++) {
                int client = accept(fd, NULL, NULL);
                if (client < 0) break;
                setsockopt(client, SOL_SOCKET, SO_SNDTIMEO, &timeout, sizeof(timeout));
                char requestBuffer[4096] = {0};
                ssize_t requestLength = read(client, requestBuffer, sizeof(requestBuffer) - 1);
                NSString *request = requestLength > 0 ? [[NSString alloc] initWithBytes:requestBuffer length:(NSUInteger)requestLength encoding:NSUTF8StringEncoding] : @"";
                BOOL headOnly = [request hasPrefix:@"HEAD "];
                NSDictionary *attrs = [NSFileManager.defaultManager attributesOfItemAtPath:path error:nil];
                unsigned long long size = [attrs[NSFileSize] unsignedLongLongValue];
                unsigned long long start = 0;
                NSRange rangeHeader = [request rangeOfString:@"Range: bytes=" options:NSCaseInsensitiveSearch];
                BOOL partial = NO;
                if (rangeHeader.location != NSNotFound) {
                    NSString *tail = [request substringFromIndex:NSMaxRange(rangeHeader)];
                    NSString *first = [[tail componentsSeparatedByString:@"\r\n"].firstObject componentsSeparatedByString:@"-"].firstObject;
                    unsigned long long requested = strtoull(first.UTF8String, NULL, 10);
                    if (requested < size) { start = requested; partial = YES; }
                }
                unsigned long long bodyLength = size > start ? size - start : 0;
                NSString *headerText = partial ?
                    [NSString stringWithFormat:@"HTTP/1.1 206 Partial Content\r\nContent-Type: audio/mp4\r\nContent-Length: %llu\r\nContent-Range: bytes %llu-%llu/%llu\r\nAccept-Ranges: bytes\r\nConnection: close\r\nCache-Control: no-store\r\n\r\n", bodyLength, start, size ? size - 1 : 0, size] :
                    [NSString stringWithFormat:@"HTTP/1.1 200 OK\r\nContent-Type: audio/mp4\r\nContent-Length: %llu\r\nAccept-Ranges: bytes\r\nConnection: close\r\nCache-Control: no-store\r\n\r\n", bodyLength];
                NSData *header = [headerText dataUsingEncoding:NSUTF8StringEncoding];
                BOOL ok = header.length && QWriteAll(client, header.bytes, header.length);
                if (!headOnly && ok) {
                    NSFileHandle *handle = [NSFileHandle fileHandleForReadingAtPath:path];
                    @try { [handle seekToFileOffset:start]; } @catch (__unused NSException *e) { ok = NO; }
                    while (ok && handle) {
                        NSData *chunk = [handle readDataOfLength:64 * 1024];
                        if (!chunk.length) break;
                        ok = QWriteAll(client, chunk.bytes, chunk.length);
                    }
                    [handle closeFile];
                    if (ok) dispatch_semaphore_signal(served);
                }
                shutdown(client, SHUT_RDWR);
                close(client);
                if (!headOnly && ok) break;
            }
        }
    });
    return YES;
}
- (void)stop { if (self.socketFD >= 0) { shutdown(self.socketFD, SHUT_RDWR); close(self.socketFD); self.socketFD = -1; } }
- (NSURL *)mediaURL { return self.port ? [NSURL URLWithString:[NSString stringWithFormat:@"http://127.0.0.1:%u/audio.m4a", self.port]] : nil; }
- (BOOL)waitUntilServed:(NSTimeInterval)timeout { return dispatch_semaphore_wait(self.servedSemaphore, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(timeout * NSEC_PER_SEC))) == 0; }
- (void)dealloc { [self stop]; }
@end

static NSDictionary *QStoreMetadata(NSURL *mediaURL, NSURL *localURL, NSDictionary *metadata) {
    AVURLAsset *asset = [AVURLAsset URLAssetWithURL:localURL options:nil];
    double seconds = CMTimeGetSeconds(asset.duration);
    if (!isfinite(seconds) || seconds < 0) seconds = 0;
    NSString *title = QSafeText(metadata[YTMIJobTitleKey], @"YouTube Audio");
    NSString *artist = QSafeText(metadata[YTMIJobArtistKey], @"Unknown Artist");
    NSString *album = QSafeText(metadata[YTMIJobAlbumKey], @"YT Music Importer");
    NSNumber *itemID = @((uint32_t)arc4random_uniform(UINT32_MAX - 1) + 1);
    NSDate *now = NSDate.date;
    NSString *urlString = mediaURL.absoluteString ?: @"";
    NSString *copyright = @"Imported with YT Music Importer";
    return @{@"purchaseDate":now,
             @"is-purchased-redownload":@YES,
             @"URL":urlString,
             @"songId":itemID,
             @"metadata":@{
                 @"artistName":artist,
                 @"compilation":@NO,
                 @"composerName":@"",
                 @"copyright":copyright,
                 @"description":copyright,
                 @"longDescription":copyright,
                 @"drmVersionNumber":@0,
                 @"duration":@((long long)(seconds * 1000.0)),
                 @"explicit":@0,
                 @"fileExtension":@"m4a",
                 @"gapless":@NO,
                 @"genre":@"",
                 @"isMasteredForItunes":@NO,
                 @"itemId":itemID,
                 @"itemName":title,
                 @"kind":@"song",
                 @"playlistArtistName":artist,
                 @"playlistName":album,
                 @"releaseDate":now,
                 @"sort-album":album,
                 @"sort-artist":artist,
                 @"sort-composer":@"",
                 @"sort-name":title,
                 @"trackCount":@1,
                 @"trackNumber":@1,
                 @"year":@([[NSCalendar currentCalendar] component:NSCalendarUnitYear fromDate:now])
             }};
}

static NSUInteger QVisibleSongCount(void) {
    dlopen("/System/Library/Frameworks/MediaPlayer.framework/MediaPlayer", RTLD_LAZY | RTLD_LOCAL);
    Class queryClass = NSClassFromString(@"MPMediaQuery");
    id query = QSend0(queryClass, NSSelectorFromString(@"songsQuery"));
    id items = QSend0(query, NSSelectorFromString(@"items"));
    return [items respondsToSelector:@selector(count)] ? [items count] : NSNotFound;
}

static id YTMIActiveStoreQueue;

@implementation YTMIMusicDatabaseImporter
- (BOOL)importAudioAtURL:(NSURL *)audioURL metadata:(NSDictionary *)metadata error:(NSError **)error {
    if (!audioURL.isFileURL || ![NSFileManager.defaultManager fileExistsAtPath:audioURL.path]) { if (error) *error = YTMIQueueError(19, @"The prepared audio file is unavailable."); return NO; }
    NSString *root = @"/var/mobile/Media/YTMusicImporter";
    if (![NSFileManager.defaultManager createDirectoryAtPath:root withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions:@0755} error:nil]) { if (error) *error = YTMIQueueError(37, @"Music staging storage could not be prepared."); return NO; }
    NSString *path = [root stringByAppendingPathComponent:[NSString stringWithFormat:@"%@.m4a", NSUUID.UUID.UUIDString]];
    if (![NSFileManager.defaultManager copyItemAtPath:audioURL.path toPath:path error:nil]) { if (error) *error = YTMIQueueError(38, @"The audio could not be staged for Music."); return NO; }
    NSURL *stagingURL = [NSURL fileURLWithPath:path];
    YTMIQueueMediaServer *server = [[YTMIQueueMediaServer alloc] initWithFilePath:path];
    if (![server start] || !server.mediaURL) { [NSFileManager.defaultManager removeItemAtPath:path error:nil]; if (error) *error = YTMIQueueError(45, @"The local Music transfer could not be started."); return NO; }
    NSUInteger songsBefore = QVisibleSongCount();
    NSInteger code = 0;
    BOOL accepted = NO;
    @try {
        void *store = dlopen("/System/Library/PrivateFrameworks/StoreServices.framework/StoreServices", RTLD_LAZY | RTLD_LOCAL);
        if (!store) code = 31;
        Class metadataClass = NSClassFromString(@"SSDownloadMetadata");
        Class downloadClass = NSClassFromString(@"SSDownload");
        Class queueClass = NSClassFromString(@"SSDownloadQueue");
        SEL initMetadataSEL = NSSelectorFromString(@"initWithDictionary:");
        SEL initDownloadSEL = NSSelectorFromString(@"initWithDownloadMetadata:");
        SEL kindsSEL = NSSelectorFromString(@"mediaDownloadKinds");
        SEL initQueueSEL = NSSelectorFromString(@"initWithDownloadKinds:");
        SEL addSEL = NSSelectorFromString(@"addDownload:");
        if (!code && (!metadataClass || !downloadClass || !queueClass)) code = 32;
        if (!code && (![metadataClass instancesRespondToSelector:initMetadataSEL] || ![downloadClass instancesRespondToSelector:initDownloadSEL] || ![queueClass respondsToSelector:kindsSEL] || ![queueClass instancesRespondToSelector:initQueueSEL] || ![queueClass instancesRespondToSelector:addSEL])) code = 35;
        id metadataObject = nil, download = nil, queue = nil;
        if (!code) metadataObject = QSend1(((id (*)(id, SEL))objc_msgSend)(metadataClass, @selector(alloc)), initMetadataSEL, QStoreMetadata(server.mediaURL, stagingURL, metadata ?: @{}));
        if (!code && !metadataObject) code = 34;
        if (!code) {
            SEL setPrimarySEL = NSSelectorFromString(@"setPrimaryAssetURL:");
            if ([metadataObject respondsToSelector:setPrimarySEL]) ((void (*)(id, SEL, id))objc_msgSend)(metadataObject, setPrimarySEL, server.mediaURL);
            download = QSend1(((id (*)(id, SEL))objc_msgSend)(downloadClass, @selector(alloc)), initDownloadSEL, metadataObject);
            id kinds = QSend0(queueClass, kindsSEL);
            queue = QSend1(((id (*)(id, SEL))objc_msgSend)(queueClass, @selector(alloc)), initQueueSEL, kinds);
            if (!download || !queue) code = 36;
        }
        if (!code) {
            YTMIActiveStoreQueue = queue;
            accepted = ((BOOL (*)(id, SEL, id))objc_msgSend)(queue, addSEL, download);
            if (!accepted) code = 36;
        }
    } @catch (__unused NSException *exception) { code = 39; accepted = NO; }
    BOOL served = accepted ? [server waitUntilServed:30.0] : NO;
    [server stop];
    if (!accepted || !served) {
        YTMIActiveStoreQueue = nil;
        [NSFileManager.defaultManager removeItemAtPath:path error:nil];
        if (error) *error = YTMIQueueError(code ?: 48, @"Music did not complete the local import transfer.");
        return NO;
    }

    void *musicLibrary = dlopen("/System/Library/PrivateFrameworks/MusicLibrary.framework/MusicLibrary", RTLD_LAZY | RTLD_LOCAL);
    Class libraryClass = NSClassFromString(@"ML3MusicLibrary");
    id library = libraryClass && [libraryClass respondsToSelector:NSSelectorFromString(@"sharedLibrary")] ? QSend0(libraryClass, NSSelectorFromString(@"sharedLibrary")) : nil;
    for (NSString *name in @[@"notifyEntitiesAddedOrRemoved", @"notifyContentsDidChange", @"notifyLibraryImportDidFinish"]) {
        SEL selector = NSSelectorFromString(name);
        if (library && [library respondsToSelector:selector]) ((void (*)(id, SEL))objc_msgSend)(library, selector);
    }
    (void)musicLibrary;

    BOOL visible = NO;
    NSDate *visibilityDeadline = [NSDate dateWithTimeIntervalSinceNow:12.0];
    while (visibilityDeadline.timeIntervalSinceNow > 0) {
        NSUInteger songsAfter = QVisibleSongCount();
        if (songsBefore != NSNotFound && songsAfter != NSNotFound && songsAfter > songsBefore) {
            visible = YES;
            break;
        }
        [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.5]];
    }

    if (!visible) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(180 * NSEC_PER_SEC)), dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            [NSFileManager.defaultManager removeItemAtPath:path error:nil];
            YTMIActiveStoreQueue = nil;
        });
        if (error) *error = YTMIQueueError(62, @"Music received the audio but the new song is not visible.");
        return NO;
    }

    [NSFileManager.defaultManager removeItemAtURL:audioURL error:nil];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(180 * NSEC_PER_SEC)), dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{ [NSFileManager.defaultManager removeItemAtPath:path error:nil]; YTMIActiveStoreQueue = nil; });
    return YES;
}
@end

