#import <Foundation/Foundation.h>

extern "C" void YTKACEDownloadLog(NSString *identifier, NSString *format, ...) {
    (void)identifier;
    (void)format;
}

extern "C" NSString *YTKACELocalized(NSString *key) {
    return key ?: @"";
}
