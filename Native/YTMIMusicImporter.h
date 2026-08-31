#import <Foundation/Foundation.h>

@interface YTMIMusicImporter : NSObject
@property (nonatomic, copy, readonly) NSDictionary *lastDiagnostics;
- (BOOL)importAudioAtURL:(NSURL *)audioURL metadata:(NSDictionary *)metadata error:(NSError **)error;
@end
