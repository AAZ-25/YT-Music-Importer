#import "YTMISABRBridge.h"
#import "../Shared/YTMIConstants.h"
#import <AVFoundation/AVFoundation.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import "SABRDownloader.h"
#import "StreamResolver.h"

static IMP YTMIOriginalMakePlayerRequest = NULL;
static IMP YTMIOriginalMakePlaybackRequest = NULL;
static IMP YTMIOriginalMakePrefetchPlayerRequest = NULL;
static IMP YTMIOriginalOnesieRequest = NULL;
static IMP YTMIOriginalOnesieRequestAsync = NULL;
static IMP YTMIOriginalOnesieRequestCompletion = NULL;
static IMP YTMIOriginalHAMBuildURLRequest = NULL;
static IMP YTMIOriginalMintWithVideoID = NULL;
static IMP YTMIOriginalSetPoToken = NULL;

static NSMutableDictionary<NSString *, NSArray *> *YTMIPlayerRequests;
static NSMutableSet<NSString *> *YTMINativeSessions;
static NSMutableDictionary<NSString *, id> *YTMIActiveTasks;
static NSString *YTMILastVideoID;
static NSInteger YTMIHookAttempts = 0;
static void (^YTMISABRLogger)(NSString *stage);

static void YTMIEnsureStores(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        YTMIPlayerRequests = [NSMutableDictionary dictionary];
        YTMINativeSessions = [NSMutableSet set];
        YTMIActiveTasks = [NSMutableDictionary dictionary];
    });
}

static void YTMISABRLog(NSString *stage) {
    if (stage.length == 0) return;
    void (^logger)(NSString *) = YTMISABRLogger;
    if (logger) logger(stage);
}

void YTMISetSABRLogger(void (^logger)(NSString *stage)) {
    YTMISABRLogger = [logger copy];
}

NSString *YTKACELocalized(NSString *key) {
    return key ?: @"";
}

void YTKACEDownloadLog(NSString *identifier, NSString *format, ...) {
    (void)identifier;
    (void)format;
}

NSString *YTKACEDownloadLogContents(void) {
    return @"";
}

void YTKACEClearDownloadLog(void) {
}

static id YTMIObject(id object, NSArray<NSString *> *keys) {
    if (!object) return nil;
    for (NSString *key in keys) {
        SEL selector = NSSelectorFromString(key);
        if ([object respondsToSelector:selector]) {
            id value = ((id (*)(id, SEL))objc_msgSend)(object, selector);
            if (value) return value;
        }
        @try {
            id value = [object valueForKey:key];
            if (value) return value;
        } @catch (__unused NSException *exception) {
        }
    }
    return nil;
}

static id YTMICopyObject(id object) {
    if ([object respondsToSelector:@selector(copyWithZone:)]) return [object copy];
    return object;
}

static NSString *YTMIRequestVideoID(id request) {
    id value = YTMIObject(request, @[@"videoId", @"videoID", @"videoIdString"]);
    return [value isKindOfClass:NSString.class] ? value : nil;
}

static NSURLRequest *YTMIURLRequestFromObject(id object) {
    if ([object isKindOfClass:NSURLRequest.class]) return object;
    SEL builder = NSSelectorFromString(@"buildURLRequest");
    if ([object respondsToSelector:builder]) {
        id value = ((id (*)(id, SEL))objc_msgSend)(object, builder);
        if ([value isKindOfClass:NSURLRequest.class]) return value;
    }
    return nil;
}

static BOOL YTMIInstallHook(NSString *className, NSString *selectorName, IMP replacement, IMP *original) {
    Class cls = NSClassFromString(className);
    if (!cls) return NO;
    SEL selector = NSSelectorFromString(selectorName);
    Method method = class_getInstanceMethod(cls, selector);
    if (!method) return NO;
    IMP current = method_getImplementation(method);
    if (current == replacement) return YES;
    if (original && *original == NULL) *original = current;
    method_setImplementation(method, replacement);
    return YES;
}

static void YTMICaptureService(id service, id request) {
    NSString *videoID = YTMIRequestVideoID(request);
    if (videoID.length == 0) return;
    YTMIEnsureStores();
    YTMILastVideoID = [videoID copy];
    YTKACESABRSetCurrentVideoID(videoID);
    @synchronized (YTMIPlayerRequests) {
        YTMIPlayerRequests[videoID] = @[service, YTMICopyObject(request) ?: request];
    }
}

static void YTMIMarkNativeRequest(NSURLRequest *request) {
    if (!request) return;
    YTKACESABRSetNativeRequest(request);
    NSString *videoID = YTKACESABRCurrentVideoIDValue() ?: YTMILastVideoID;
    if (videoID.length != 0) {
        YTMIEnsureStores();
        @synchronized (YTMINativeSessions) {
            [YTMINativeSessions addObject:videoID];
        }
    }
}

static void YTMIMakePlayerRequest(id receiver, SEL selector, id request, id responseBlock, id errorBlock) {
    YTMICaptureService(receiver, request);
    if (YTMIOriginalMakePlayerRequest) {
        ((void (*)(id, SEL, id, id, id))YTMIOriginalMakePlayerRequest)(receiver, selector, request, responseBlock, errorBlock);
    }
}

static id YTMIMakePlaybackRequest(id receiver, SEL selector, id request, id responseBlock, id errorBlock) {
    YTMICaptureService(receiver, YTMIObject(request, @[@"protoRequest", @"playerRequest"]) ?: request);
    return YTMIOriginalMakePlaybackRequest
        ? ((id (*)(id, SEL, id, id, id))YTMIOriginalMakePlaybackRequest)(receiver, selector, request, responseBlock, errorBlock)
        : nil;
}

static void YTMIMakePrefetchPlayerRequest(id receiver, SEL selector, id request, id responseBlock, id errorBlock) {
    YTMICaptureService(receiver, request);
    if (YTMIOriginalMakePrefetchPlayerRequest) {
        ((void (*)(id, SEL, id, id, id))YTMIOriginalMakePrefetchPlayerRequest)(receiver, selector, request, responseBlock, errorBlock);
    }
}

static id YTMIOnesieRequest(id receiver,
                            SEL selector,
                            id playerRequest,
                            id dataLoader,
                            id context,
                            id cryptor,
                            NSInteger requestNumber,
                            NSError **error) {
    NSString *videoID = YTMIRequestVideoID(playerRequest);
    if (videoID.length) {
        YTMILastVideoID = [videoID copy];
        YTKACESABRSetCurrentVideoID(videoID);
    }
    id result = YTMIOriginalOnesieRequest
        ? ((id (*)(id, SEL, id, id, id, id, NSInteger, NSError **))YTMIOriginalOnesieRequest)(receiver, selector, playerRequest, dataLoader, context, cryptor, requestNumber, error)
        : nil;
    YTMIMarkNativeRequest(YTMIURLRequestFromObject(result));
    return result;
}

static void YTMIOnesieRequestAsync(id receiver,
                                   SEL selector,
                                   id playerRequest,
                                   id authorization,
                                   id dataLoader,
                                   id context,
                                   id cryptor,
                                   NSInteger requestNumber,
                                   void (^completion)(id, NSError *)) {
    NSString *videoID = YTMIRequestVideoID(playerRequest);
    if (videoID.length) {
        YTMILastVideoID = [videoID copy];
        YTKACESABRSetCurrentVideoID(videoID);
    }
    void (^wrapped)(id, NSError *) = ^(id result, NSError *error) {
        YTMIMarkNativeRequest(YTMIURLRequestFromObject(result));
        if (completion) completion(result, error);
    };
    if (YTMIOriginalOnesieRequestAsync) {
        ((void (*)(id, SEL, id, id, id, id, id, NSInteger, id))YTMIOriginalOnesieRequestAsync)(receiver, selector, playerRequest, authorization, dataLoader, context, cryptor, requestNumber, wrapped);
    }
}

static void YTMIOnesieRequestCompletion(id receiver, SEL selector, id request, id error) {
    YTMIMarkNativeRequest(YTMIURLRequestFromObject(request));
    if (YTMIOriginalOnesieRequestCompletion) {
        ((void (*)(id, SEL, id, id))YTMIOriginalOnesieRequestCompletion)(receiver, selector, request, error);
    }
}

static id YTMIHAMBuildURLRequest(id receiver, SEL selector) {
    id result = YTMIOriginalHAMBuildURLRequest
        ? ((id (*)(id, SEL))YTMIOriginalHAMBuildURLRequest)(receiver, selector)
        : nil;
    if (![result isKindOfClass:NSURLRequest.class]) return result;
    NSURLRequest *request = result;
    NSString *host = request.URL.host.lowercaseString;
    if (![host containsString:@"googlevideo.com"] ||
        ![request.HTTPMethod.uppercaseString isEqualToString:@"POST"]) return result;

    NSData *body = nil;
    SEL bodySelector = NSSelectorFromString(@"HTTPBody");
    if ([receiver respondsToSelector:bodySelector]) {
        id value = ((id (*)(id, SEL))objc_msgSend)(receiver, bodySelector);
        if ([value isKindOfClass:NSData.class]) body = value;
    }
    NSMutableURLRequest *nativeRequest = [request mutableCopy];
    if (body.length != 0) {
        nativeRequest.HTTPBody = body;
        [nativeRequest setValue:nil forHTTPHeaderField:@"Content-Encoding"];
    }
    YTMIMarkNativeRequest(nativeRequest);
    return result;
}

static id YTMIMintWithVideoID(id receiver, SEL selector, id videoID) {
    if ([videoID isKindOfClass:NSString.class]) {
        YTMILastVideoID = [videoID copy];
        YTKACESABRSetCurrentVideoID(videoID);
    }
    id result = YTMIOriginalMintWithVideoID
        ? ((id (*)(id, SEL, id))YTMIOriginalMintWithVideoID)(receiver, selector, videoID)
        : nil;
    YTKACESABRSetPoToken(result);
    return result;
}

static void YTMISetPoToken(id receiver, SEL selector, id token) {
    if (YTMIOriginalSetPoToken) {
        ((void (*)(id, SEL, id))YTMIOriginalSetPoToken)(receiver, selector, token);
    }
    YTKACESABRSetPoToken(token);
}

static void YTMIInstallSABRHooksAttempt(void) {
    BOOL player = YTMIInstallHook(@"YTPlayerService",
                                  @"makePlayerRequest:responseBlock:errorBlock:",
                                  (IMP)YTMIMakePlayerRequest,
                                  &YTMIOriginalMakePlayerRequest);
    BOOL playback = YTMIInstallHook(@"YTPlayerService",
                                    @"makePlaybackRequest:responseBlock:errorBlock:",
                                    (IMP)YTMIMakePlaybackRequest,
                                    &YTMIOriginalMakePlaybackRequest);
    BOOL prefetch = YTMIInstallHook(@"YTPlayerService",
                                    @"makePrefetchPlayerRequest:responseBlock:errorBlock:",
                                    (IMP)YTMIMakePrefetchPlayerRequest,
                                    &YTMIOriginalMakePrefetchPlayerRequest);
    BOOL onesie = YTMIInstallHook(@"MLOnesieRequestFactory",
                                  @"onesieRequestForPlayerRequest:dataLoader:context:cryptor:requestNumber:error:",
                                  (IMP)YTMIOnesieRequest,
                                  &YTMIOriginalOnesieRequest);
    BOOL async = YTMIInstallHook(@"MLOnesieRequestFactory",
                                 @"onesieRequestForPlayerRequest:authorization:dataLoader:context:cryptor:requestNumber:completionHandler:",
                                 (IMP)YTMIOnesieRequestAsync,
                                 &YTMIOriginalOnesieRequestAsync);
    BOOL completion = YTMIInstallHook(@"MLOnesieUMPFetcherTask",
                                      @"onRequestFactoryCompletionWithRequest:error:",
                                      (IMP)YTMIOnesieRequestCompletion,
                                      &YTMIOriginalOnesieRequestCompletion);
    BOOL ham = YTMIInstallHook(@"HAMDataLoadRequest",
                               @"buildURLRequest",
                               (IMP)YTMIHAMBuildURLRequest,
                               &YTMIOriginalHAMBuildURLRequest);
    YTMIInstallHook(@"YTProofOfOriginTokenManager",
                    @"mintWithVideoID:",
                    (IMP)YTMIMintWithVideoID,
                    &YTMIOriginalMintWithVideoID);
    YTMIInstallHook(@"YTIServiceIntegrityDimensions",
                    @"setPoToken:",
                    (IMP)YTMISetPoToken,
                    &YTMIOriginalSetPoToken);

    if (player && playback && prefetch && (onesie || async || completion || ham)) {
        YTMISABRLog(@"Playback session capture ready");
        return;
    }
    if (++YTMIHookAttempts < 30) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), dispatch_get_main_queue(), ^{
            YTMIInstallSABRHooksAttempt();
        });
    } else {
        YTMISABRLog(@"Playback session capture unavailable");
    }
}

void YTMIInstallSABRCapture(void) {
    YTMIEnsureStores();
    dispatch_async(dispatch_get_main_queue(), ^{
        YTMIInstallSABRHooksAttempt();
    });
}

BOOL YTKACEHasNativeOnesieSession(NSString *videoID) {
    if (videoID.length == 0) return NO;
    YTMIEnsureStores();
    @synchronized (YTMINativeSessions) {
        return [YTMINativeSessions containsObject:videoID];
    }
}

void YTKACEPreparePlayerWithRoute(NSString *videoID,
                                  BOOL forcePlayerRoute,
                                  YTKACEPlayerReloadCompletion completion) {
    (void)forcePlayerRoute;
    YTMIEnsureStores();
    NSArray *pair = nil;
    @synchronized (YTMIPlayerRequests) {
        pair = [YTMIPlayerRequests[videoID] copy];
    }
    id service = pair.count > 0 ? pair[0] : nil;
    id request = pair.count > 1 ? pair[1] : nil;
    if (!service || !request || !YTMIOriginalMakePlayerRequest) {
        NSError *error = [NSError errorWithDomain:@"YTMIPlaybackSession"
                                             code:1
                                         userInfo:@{NSLocalizedDescriptionKey: @"The current YouTube playback session is not ready."}];
        if (completion) completion(nil, error);
        return;
    }

    YTKACESABRSetCurrentVideoID(videoID);
    dispatch_async(dispatch_get_main_queue(), ^{
        void (^response)(id, id) = ^(id playerResponse, __unused id cacheContext) {
            if (completion) completion(playerResponse, nil);
        };
        void (^failure)(NSError *) = ^(NSError *error) {
            if (completion) completion(nil, error);
        };
        ((void (*)(id, SEL, id, id, id))YTMIOriginalMakePlayerRequest)(
            service,
            NSSelectorFromString(@"makePlayerRequest:responseBlock:errorBlock:"),
            YTMICopyObject(request),
            response,
            failure);
    });
}

void YTKACEPreparePlayer(NSString *videoID, YTKACEPlayerReloadCompletion completion) {
    YTKACEPreparePlayerWithRoute(videoID, NO, completion);
}

void YTKACEReloadPlayer(NSString *videoID, NSString *token, YTKACEPlayerReloadCompletion completion) {
    (void)token;
    YTKACEPreparePlayer(videoID, completion);
}

void YTKACEBuildNativeOnesieRequest(NSString *videoID, YTKACENativeRequestCompletion completion) {
    (void)videoID;
    if (completion) {
        completion(nil, NSNotFound,
                   [NSError errorWithDomain:@"YTMIPlaybackSession"
                                      code:2
                                  userInfo:@{NSLocalizedDescriptionKey: @"A replay request is not required for this build."}]);
    }
}

static YTKACEStreamOption *YTMIBestAudioOption(id response) {
    NSArray<YTKACEStreamOption *> *options = [YTKACEStreamResolver audioOptionsFromPlayerResponse:response];
    YTKACEStreamOption *best = nil;
    for (YTKACEStreamOption *option in options) {
        if (!best || option.isDefaultAudio || option.bitrate > best.bitrate) best = option;
        if (option.isDefaultAudio && best.isDefaultAudio && option.bitrate > best.bitrate) best = option;
    }
    return best;
}

void YTMIPrepareAudioForMusic(NSURL *inputURL, NSDictionary *metadata, YTMISABRCompletion completion) {
    NSString *name = [NSString stringWithFormat:@"ytmi-%@.m4a", NSUUID.UUID.UUIDString];
    NSURL *outputURL = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:name]];
    [NSFileManager.defaultManager removeItemAtURL:outputURL error:nil];

    AVURLAsset *asset = [AVURLAsset URLAssetWithURL:inputURL options:nil];
    AVAssetExportSession *exporter = [[AVAssetExportSession alloc] initWithAsset:asset
                                                                     presetName:AVAssetExportPresetPassthrough];
    if (!exporter) {
        completion(nil, [NSError errorWithDomain:@"YTMIAudio" code:3
                                        userInfo:@{NSLocalizedDescriptionKey: @"The downloaded audio could not be prepared for Music."}]);
        return;
    }
    NSArray<AVFileType> *types = exporter.supportedFileTypes;
    AVFileType type = [types containsObject:AVFileTypeAppleM4A] ? AVFileTypeAppleM4A :
                      ([types containsObject:AVFileTypeMPEG4] ? AVFileTypeMPEG4 : nil);
    if (!type) {
        completion(nil, [NSError errorWithDomain:@"YTMIAudio" code:4
                                        userInfo:@{NSLocalizedDescriptionKey: @"The downloaded audio format is not supported by Music."}]);
        return;
    }
    exporter.outputURL = outputURL;
    exporter.outputFileType = type;
    exporter.shouldOptimizeForNetworkUse = NO;
    NSMutableArray<AVMetadataItem *> *embedded = [NSMutableArray array];
    NSDictionary *keys = @{
        YTMIJobTitleKey: AVMetadataCommonKeyTitle,
        YTMIJobArtistKey: AVMetadataCommonKeyArtist,
        YTMIJobAlbumKey: AVMetadataCommonKeyAlbumName
    };
    for (NSString *sourceKey in keys) {
        NSString *value = [metadata[sourceKey] isKindOfClass:NSString.class] ? metadata[sourceKey] : nil;
        value = [value stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if (!value.length) continue;
        AVMutableMetadataItem *item = [AVMutableMetadataItem metadataItem];
        item.keySpace = AVMetadataKeySpaceCommon;
        item.key = keys[sourceKey];
        item.value = value;
        [embedded addObject:item];
    }
    exporter.metadata = embedded;
    [exporter exportAsynchronouslyWithCompletionHandler:^{
        NSError *error = exporter.error;
        if (exporter.status == AVAssetExportSessionStatusCompleted) {
            completion(outputURL, nil);
        } else {
            [NSFileManager.defaultManager removeItemAtURL:outputURL error:nil];
            completion(nil, error ?: [NSError errorWithDomain:@"YTMIAudio" code:5
                                                     userInfo:@{NSLocalizedDescriptionKey: @"The downloaded audio could not be finalized."}]);
        }
    }];
}

void YTMIStartSABRAudioDownload(id playerResponse,
                                NSString *videoID,
                                YTMISABRProgress progress,
                                YTMISABRCompletion completion) {
    if (!playerResponse || videoID.length == 0) {
        completion(nil, [NSError errorWithDomain:@"YTMIPlaybackSession" code:6
                                        userInfo:@{NSLocalizedDescriptionKey: @"No active video session is available."}]);
        return;
    }

    YTKACEStreamOption *audio = YTMIBestAudioOption(playerResponse);
    YTKACEStreamOption *video = [YTKACEStreamResolver videoOptionsFromPlayerResponse:playerResponse].firstObject;
    if (!audio || !video) {
        completion(nil, [NSError errorWithDomain:@"YTMIPlaybackSession" code:7
                                        userInfo:@{NSLocalizedDescriptionKey: @"YouTube did not expose compatible media formats for this video."}]);
        return;
    }

    YTKACESABRSetCurrentVideoID(videoID);
    NSString *identifier = NSUUID.UUID.UUIDString;
    YTMISABRLog(@"Segmented audio download started");
    YTKACESABRTask *task = [YTKACESABRDownloader downloadPlayerResponse:playerResponse
                                                            videoOption:video
                                                            audioOption:audio
                                                              audioOnly:YES
                                                                videoID:videoID
                                                             identifier:identifier
                                                               progress:^(double audioProgress,
                                                                          double videoProgress,
                                                                          int64_t audioBytes,
                                                                          int64_t videoBytes,
                                                                          NSInteger mediaPhase) {
        (void)videoProgress;
        (void)audioBytes;
        (void)videoBytes;
        (void)mediaPhase;
        if (progress) progress(MIN(MAX(audioProgress, 0.0), 1.0));
    }
                                                             completion:^(NSURL *videoURL, NSURL *audioURL, NSError *error) {
        if (videoURL) [NSFileManager.defaultManager removeItemAtURL:videoURL error:nil];
        @synchronized (YTMIActiveTasks) {
            [YTMIActiveTasks removeObjectForKey:identifier];
        }
        if (error || !audioURL) {
            YTMISABRLog(@"Segmented audio download failed");
            completion(nil, error ?: [NSError errorWithDomain:@"YTMIAudio" code:8
                                                     userInfo:@{NSLocalizedDescriptionKey: @"The audio download did not complete."}]);
            return;
        }
        YTMIPrepareAudioForMusic(audioURL, @{}, ^(NSURL *finalURL, NSError *remuxError) {
            [NSFileManager.defaultManager removeItemAtURL:audioURL error:nil];
            if (finalURL) YTMISABRLog(@"Audio download completed");
            else YTMISABRLog(@"Audio finalization failed");
            completion(finalURL, remuxError);
        });
    }];

    if (task) {
        YTMIEnsureStores();
        @synchronized (YTMIActiveTasks) {
            YTMIActiveTasks[identifier] = task;
        }
    }
}
