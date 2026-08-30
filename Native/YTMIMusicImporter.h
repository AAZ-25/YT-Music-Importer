#import <Foundation/Foundation.h>

@interface YTMIMusicImporter : NSObject
- (BOOL)importAudioAtURL:(NSURL *)audioURL metadata:(NSDictionary *)metadata error:(NSError **)error;
@end
