#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface YTMINativeStreamResolver : NSObject
+ (nullable NSURL *)bestAudioURLFromPlayerResponse:(id)playerResponse;
+ (nullable NSString *)titleFromPlayerResponse:(id)playerResponse;
+ (nullable NSString *)authorFromPlayerResponse:(id)playerResponse;
@end

NS_ASSUME_NONNULL_END
