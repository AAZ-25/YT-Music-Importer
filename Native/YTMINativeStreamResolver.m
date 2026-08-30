#import "YTMINativeStreamResolver.h"
#import <objc/message.h>

static id YTMIObject(id receiver, NSArray<NSString *> *names) {
    if (!receiver) return nil;
    for (NSString *name in names) {
        SEL selector = NSSelectorFromString(name);
        if ([receiver respondsToSelector:selector]) {
            id value = ((id (*)(id, SEL))objc_msgSend)(receiver, selector);
            if (value) return value;
        }
    }
    return nil;
}

static id YTMIFind(id object, NSString *target, NSHashTable *visited, NSUInteger depth) {
    if (!object || depth > 8 || [visited containsObject:object]) return nil;
    [visited addObject:object];
    id direct = YTMIObject(object, @[target]);
    if (direct) return direct;
    for (NSString *name in @[@"playerData", @"contentPlayerResponse", @"playerResponse", @"playbackData", @"video", @"response", @"shortsPlayerData"]) {
        id found = YTMIFind(YTMIObject(object, @[name]), target, visited, depth + 1);
        if (found) return found;
    }
    return nil;
}

static id YTMINested(id object, NSString *target) {
    return YTMIFind(object, target, [NSHashTable hashTableWithOptions:NSPointerFunctionsObjectPointerPersonality], 0);
}

static NSArray *YTMIArray(id receiver, NSArray<NSString *> *names) {
    id value = YTMIObject(receiver, names);
    return [value isKindOfClass:NSArray.class] ? value : @[];
}

static NSString *YTMIString(id value) {
    if ([value isKindOfClass:NSString.class]) return value;
    id nested = YTMIObject(value, @[@"text", @"string", @"simpleText"]);
    return [nested isKindOfClass:NSString.class] ? nested : nil;
}

@implementation YTMINativeStreamResolver
+ (NSURL *)bestAudioURLFromPlayerResponse:(id)playerResponse {
    id playerData = YTMINested(playerResponse, @"playerData") ?: playerResponse;
    id streamingData = YTMIObject(playerResponse, @[@"streamingData"]) ?: YTMIObject(playerData, @[@"streamingData"]);
    if (!streamingData) return nil;
    id best = nil;
    NSInteger bestBitrate = -1;
    NSArray *formats = [YTMIArray(streamingData, @[@"adaptiveFormatsArray", @"adaptiveFormats"]) arrayByAddingObjectsFromArray:YTMIArray(streamingData, @[@"formatsArray", @"formats"])];
    for (id format in formats) {
        NSString *mime = YTMIObject(format, @[@"mimeType"]);
        if (![mime isKindOfClass:NSString.class] || ![mime hasPrefix:@"audio/mp4"]) continue;
        id rawURL = YTMIObject(format, @[@"URL", @"url"]);
        NSURL *url = [rawURL isKindOfClass:NSURL.class] ? rawURL : ([rawURL isKindOfClass:NSString.class] ? [NSURL URLWithString:rawURL] : nil);
        if (!url || ![url.scheme.lowercaseString hasPrefix:@"http"]) continue;
        NSInteger bitrate = 0;
        id rawBitrate = YTMIObject(format, @[@"bitrate"]);
        if ([rawBitrate respondsToSelector:@selector(integerValue)]) bitrate = [rawBitrate integerValue];
        if (!best || bitrate > bestBitrate) { best = url; bestBitrate = bitrate; }
    }
    return best;
}

+ (NSString *)titleFromPlayerResponse:(id)playerResponse {
    id details = YTMINested(playerResponse, @"videoDetails") ?: YTMINested(playerResponse, @"playerData");
    return YTMIString(YTMIObject(details, @[@"title", @"videoTitle", @"headline"]));
}

+ (NSString *)authorFromPlayerResponse:(id)playerResponse {
    id details = YTMINested(playerResponse, @"videoDetails") ?: YTMINested(playerResponse, @"playerData");
    return YTMIString(YTMIObject(details, @[@"author", @"channelTitle", @"ownerChannelName"]));
}
@end
