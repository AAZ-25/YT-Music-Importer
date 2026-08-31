#import <Foundation/Foundation.h>

@interface YTMIMusicDatabaseImporter : NSObject
- (BOOL)importAudioAtURL:(NSURL *)audioURL metadata:(NSDictionary *)metadata trace:(NSMutableArray *)trace error:(NSError **)error;
@end
