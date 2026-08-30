#import <Foundation/Foundation.h>

@interface YTMIMusicDatabaseImporter : NSObject
- (BOOL)importAudioAtURL:(NSURL *)audioURL metadata:(NSDictionary *)metadata error:(NSError **)error;
@end
