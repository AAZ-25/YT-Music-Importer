#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef void (^YTMISABRProgress)(double progress);
typedef void (^YTMISABRCompletion)(NSURL * _Nullable audioURL, NSError * _Nullable error);

#ifdef __cplusplus
extern "C" {
#endif

FOUNDATION_EXPORT void YTMIInstallSABRCapture(void);
FOUNDATION_EXPORT void YTMISetSABRLogger(void (^ _Nullable logger)(NSString *stage));
FOUNDATION_EXPORT void YTMIPrepareAudioForMusic(NSURL *inputURL,
                                                    NSDictionary *metadata,
                                                    YTMISABRCompletion completion);
FOUNDATION_EXPORT void YTMIStartSABRAudioDownload(id playerResponse,
                                                   NSString *videoID,
                                                   YTMISABRProgress _Nullable progress,
                                                   YTMISABRCompletion completion);

#ifdef __cplusplus
}
#endif

NS_ASSUME_NONNULL_END
