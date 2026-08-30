#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <dlfcn.h>

static id YTMIMediaFolderPathCompatibility(id self, SEL _cmd) {
    (void)self;
    (void)_cmd;
    NSArray<NSString *> *candidates = @[
        @"/var/mobile/Media/iTunes_Control/Music",
        @"/private/var/mobile/Media/iTunes_Control/Music"
    ];
    NSFileManager *fm = NSFileManager.defaultManager;
    for (NSString *path in candidates) {
        BOOL isDirectory = NO;
        if ([fm fileExistsAtPath:path isDirectory:&isDirectory] && isDirectory) return path;
    }
    return nil;
}

@interface YTMIMusicLibraryCompatibilityBootstrap : NSObject
@end

@implementation YTMIMusicLibraryCompatibilityBootstrap
+ (void)load {
    void *framework = dlopen("/System/Library/PrivateFrameworks/MusicLibrary.framework/MusicLibrary", RTLD_LAZY | RTLD_LOCAL);
    if (!framework) return;
    Class libraryClass = NSClassFromString(@"ML3MusicLibrary");
    SEL selector = NSSelectorFromString(@"mediaFolderPath");
    if (libraryClass && ![libraryClass instancesRespondToSelector:selector]) {
        class_addMethod(libraryClass, selector, (IMP)YTMIMediaFolderPathCompatibility, "@@:");
    }
}
@end
