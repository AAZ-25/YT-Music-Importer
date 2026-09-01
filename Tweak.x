#import <UIKit/UIKit.h>
#import <objc/message.h>
#import <YouTubeHeader/YTPlayerViewController.h>
#import <YouTubeHeader/YTMainAppControlsOverlayView.h>
#import <YouTubeHeader/YTInlinePlayerBarContainerView.h>
#import "../YTVideoOverlay/Header.h"
#import "../YTVideoOverlay/Init.x"
#import "Shared/YTMIConstants.h"
#import "Native/YTMINativeStreamResolver.h"
#import "Native/YTMIMusicImporter.h"
#import "Native/YTMISABRBridge.h"

#define YTMIOverlayKey @"YTMusicImporter"

static __weak YTPlayerViewController *YTMIActivePlayer = nil;
static BOOL YTMIBetaNoticePresentationInFlight = NO;
static BOOL YTMILoggingEnabled(void) {
    return YES;
}

static NSString *YTMILogPath(void) {
    NSString *directory = [NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES).firstObject stringByAppendingPathComponent:@"YTMusicImporter"];
    [NSFileManager.defaultManager createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions:@0700} error:nil];
    return [directory stringByAppendingPathComponent:@"debug.log"];
}

static void YTMILogStage(NSString *message) {
    if (!YTMILoggingEnabled() || !message.length) return;
    NSString *line = [NSString stringWithFormat:@"[%@] %@\n", NSDate.date, message];
    NSData *data = [line dataUsingEncoding:NSUTF8StringEncoding];
    NSString *path = YTMILogPath();
    if (![NSFileManager.defaultManager fileExistsAtPath:path]) {
        [data writeToFile:path atomically:YES];
        return;
    }
    NSFileHandle *handle = [NSFileHandle fileHandleForWritingAtPath:path];
    [handle seekToEndOfFile];
    [handle writeData:data];
    [handle closeFile];
}

static NSString *YTMICleanText(id value, NSUInteger maxLength) {
    if (![value isKindOfClass:NSString.class]) return @"";
    NSString *text = [(NSString *)value stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (text.length > maxLength) text = [text substringToIndex:maxLength];
    return text;
}

static UIViewController *YTMIVisibleController(UIViewController *controller) {
    if (!controller) return nil;
    UIViewController *presented = controller.presentedViewController;
    if (presented && !presented.isBeingDismissed) return YTMIVisibleController(presented);
    if ([controller isKindOfClass:UINavigationController.class]) return YTMIVisibleController(((UINavigationController *)controller).visibleViewController);
    if ([controller isKindOfClass:UITabBarController.class]) return YTMIVisibleController(((UITabBarController *)controller).selectedViewController);
    return controller;
}

static UIViewController *YTMIFallbackPresenter(void) {
    UIWindow *window = nil;
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (scene.activationState != UISceneActivationStateForegroundActive || ![scene isKindOfClass:UIWindowScene.class]) continue;
        for (UIWindow *candidate in ((UIWindowScene *)scene).windows) {
            if (candidate.isKeyWindow) { window = candidate; break; }
        }
        if (window) break;
    }
    return YTMIVisibleController(window.rootViewController);
}

static void YTMIShowMessage(YTPlayerViewController *player, NSString *message) {
    if (!message.length) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        UIViewController *base = player ?: YTMIActivePlayer ?: YTMIFallbackPresenter();
        UIViewController *visible = YTMIVisibleController(base);
        if ([visible isKindOfClass:UIAlertController.class]) {
            UIAlertController *existing = (UIAlertController *)visible;
            if ([existing.title isEqualToString:@"YT Music Importer"]) {
                existing.message = message;
                return;
            }
        }
        UIViewController *presenter = visible ?: YTMIFallbackPresenter();
        if (!presenter) return;
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"YT Music Importer" message:message preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
        if (presenter.presentedViewController && !presenter.presentedViewController.isBeingDismissed) {
            [presenter dismissViewControllerAnimated:NO completion:^{
                UIViewController *fresh = YTMIFallbackPresenter() ?: player;
                [fresh presentViewController:alert animated:YES completion:nil];
            }];
        } else {
            [presenter presentViewController:alert animated:YES completion:nil];
        }
    });
}

static void YTMIScheduleBetaNotice(YTPlayerViewController *player) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.6 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        NSString *key = @"YTMusicImporterBeta53NoticeShown";
        NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
        if ([defaults boolForKey:key] || YTMIBetaNoticePresentationInFlight) return;
        UIViewController *presenter = YTMIVisibleController(player ?: YTMIActivePlayer ?: YTMIFallbackPresenter());
        if (!presenter || [presenter isKindOfClass:UIAlertController.class] || presenter.presentedViewController || presenter.isBeingDismissed) {
            YTMIScheduleBetaNotice(player ?: YTMIActivePlayer);
            return;
        }
        UIAlertController *notice = [UIAlertController alertControllerWithTitle:@"YT Music Importer" message:@"Test build — Beta 53. Diagnostic logging is always on; no private song, path, account, or device data is written." preferredStyle:UIAlertControllerStyleAlert];
        [notice addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
        YTMIBetaNoticePresentationInFlight = YES;
        [presenter presentViewController:notice animated:YES completion:^{
            BOOL shown = notice.presentingViewController != nil;
            if (shown) [defaults setBool:YES forKey:key];
            YTMIBetaNoticePresentationInFlight = NO;
            if (!shown) YTMIScheduleBetaNotice(player ?: YTMIActivePlayer);
        }];
    });
}

static NSString *YTMILibraryRoot(void) {
    NSString *base = NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES).firstObject;
    if (!base.length) return nil;
    NSString *root = [base stringByAppendingPathComponent:@"YTMusicImporter/Downloads"];
    [NSFileManager.defaultManager createDirectoryAtPath:root withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions:@0700} error:nil];
    return root;
}

static NSString *YTMILibraryIndexPath(void) {
    NSString *root = YTMILibraryRoot();
    return root.length ? [root stringByAppendingPathComponent:@"library.plist"] : nil;
}

static NSMutableArray<NSDictionary *> *YTMILoadLibrary(void) {
    NSArray *items = [NSArray arrayWithContentsOfFile:YTMILibraryIndexPath() ?: @""];
    return items ? [items mutableCopy] : [NSMutableArray array];
}

static void YTMISaveLibrary(NSArray *items) {
    NSString *path = YTMILibraryIndexPath();
    if (path.length) [items writeToFile:path atomically:YES];
}

static NSDictionary *YTMISaveDownloadedAudio(NSURL *audioURL, NSDictionary *metadata, NSError **error) {
    if (!audioURL.isFileURL || ![NSFileManager.defaultManager fileExistsAtPath:audioURL.path]) return nil;
    NSString *root = YTMILibraryRoot();
    if (!root.length) return nil;
    NSString *identifier = NSUUID.UUID.UUIDString;
    NSString *fileName = [identifier stringByAppendingString:@".m4a"];
    NSString *destination = [root stringByAppendingPathComponent:fileName];
    if (![NSFileManager.defaultManager copyItemAtPath:audioURL.path toPath:destination error:error]) return nil;
    NSString *title = YTMICleanText(metadata[YTMIJobTitleKey], 180);
    NSString *artist = YTMICleanText(metadata[YTMIJobArtistKey], 120);
    NSDictionary *item = @{
        @"id":identifier,
        @"file":fileName,
        @"title":title.length ? title : @"YouTube Audio",
        @"artist":artist.length ? artist : @"Unknown Artist",
        @"album":YTMICleanText(metadata[YTMIJobAlbumKey], 120),
        @"date":NSDate.date
    };
    NSMutableArray *items = YTMILoadLibrary();
    [items insertObject:item atIndex:0];
    YTMISaveLibrary(items);
    return item;
}

static NSURL *YTMIURLForLibraryItem(NSDictionary *item) {
    NSString *file = [item[@"file"] isKindOfClass:NSString.class] ? item[@"file"] : nil;
    NSString *root = YTMILibraryRoot();
    if (!file.length || !root.length) return nil;
    NSString *path = [root stringByAppendingPathComponent:file];
    return [NSFileManager.defaultManager fileExistsAtPath:path] ? [NSURL fileURLWithPath:path] : nil;
}

static NSDictionary *YTMIMetadataForLibraryItem(NSDictionary *item) {
    return @{
        YTMIJobTitleKey:[item[@"title"] isKindOfClass:NSString.class] ? item[@"title"] : @"YouTube Audio",
        YTMIJobArtistKey:[item[@"artist"] isKindOfClass:NSString.class] ? item[@"artist"] : @"Unknown Artist",
        YTMIJobAlbumKey:[item[@"album"] isKindOfClass:NSString.class] ? item[@"album"] : @""
    };
}

static NSString *YTMIImportFailureMessage(NSError *error) {
    if ([error.domain isEqualToString:@"com.aaz.ytmusicimporter"] && error.code > 0) return [NSString stringWithFormat:@"Import failed in Music (code %ld). The downloaded file is still in Downloads.", (long)error.code];
    return @"Import failed while adding the audio to Music. The downloaded file is still in Downloads.";
}

static void YTMIImportLibraryItem(NSDictionary *item, YTPlayerViewController *player) {
    NSURL *audioURL = YTMIURLForLibraryItem(item);
    if (!audioURL) { YTMIShowMessage(player, @"The downloaded audio file is unavailable."); return; }
    NSString *rawID = [[[[NSUUID UUID] UUIDString] stringByReplacingOccurrencesOfString:@"-" withString:@""] uppercaseString];
    NSString *importID = [NSString stringWithFormat:@"B53-%@", [rawID substringToIndex:8]];
    YTMIShowMessage(player, [NSString stringWithFormat:@"%@ started. Progress will be shown inside Music.", importID]);
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSMutableDictionary *metadata = [YTMIMetadataForLibraryItem(item) mutableCopy];
        NSString *title = YTMICleanText([metadata objectForKey:YTMIJobTitleKey], 180);
        [metadata setObject:[NSString stringWithFormat:@"%@ [%@]", title.length ? title : @"YouTube Audio", importID] forKey:YTMIJobTitleKey];
        [metadata setObject:importID forKey:YTMIJobImportIDKey];
        YTMIPrepareAudioForMusic(audioURL, metadata, ^(NSURL *preparedURL, NSError *prepareError) {
            if (!preparedURL) {
                (void)prepareError;
                YTMILogStage(@"Music import code=80");
                YTMIShowMessage(player, YTMIImportFailureMessage([NSError errorWithDomain:@"com.aaz.ytmusicimporter" code:80 userInfo:nil]));
                return;
            }
            NSError *error = nil;
            YTMIMusicImporter *importer = [YTMIMusicImporter new];
            BOOL imported = [importer importAudioAtURL:preparedURL metadata:metadata error:&error];
            NSDictionary *diagnostics = importer.lastDiagnostics;
            [NSFileManager.defaultManager removeItemAtURL:preparedURL error:nil];
            id traceObject = [diagnostics objectForKey:@"trace"];
            NSString *lastStage = @"no-stage";
            if ([traceObject isKindOfClass:[NSArray class]]) {
                id candidate = [traceObject lastObject];
                if ([candidate isKindOfClass:[NSString class]]) lastStage = candidate;
                NSString *joined = [traceObject componentsJoinedByString:@" > "];
                if (joined.length) YTMILogStage([NSString stringWithFormat:@"%@ %@", importID, joined]);
            }
            NSInteger resultCode = imported ? 0 : ([error.domain isEqualToString:@"com.aaz.ytmusicimporter"] ? error.code : 42);
            YTMILogStage([NSString stringWithFormat:@"%@ result.%@", importID, imported ? @"accepted" : @"failed"]);
            NSString *resultMessage = imported ? [NSString stringWithFormat:@"%@ completed through %@. Music created a playable local record; open Music and test playback.", importID, lastStage] : [NSString stringWithFormat:@"%@ failed (code %ld). Last stage: %@. The source remains in Downloads.", importID, (long)resultCode, lastStage];
            YTMIShowMessage(player, resultMessage);
        });
    });
}

static void YTMIPresentLibrary(YTPlayerViewController *player);

static void YTMIPresentLibraryItem(NSDictionary *item, YTPlayerViewController *player) {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIViewController *presenter = YTMIFallbackPresenter() ?: player;
        if (!presenter) return;
        NSString *title = [item[@"title"] isKindOfClass:NSString.class] ? item[@"title"] : @"Downloaded Audio";
        NSString *artist = [item[@"artist"] isKindOfClass:NSString.class] ? item[@"artist"] : @"";
        UIAlertController *menu = [UIAlertController alertControllerWithTitle:title message:artist preferredStyle:UIAlertControllerStyleActionSheet];
        [menu addAction:[UIAlertAction actionWithTitle:@"Import to Music" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) { YTMIImportLibraryItem(item, player); }]];
        [menu addAction:[UIAlertAction actionWithTitle:@"Share Audio" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
            NSURL *url = YTMIURLForLibraryItem(item);
            if (!url) { YTMIShowMessage(player, @"The downloaded audio file is unavailable."); return; }
            UIViewController *host = YTMIFallbackPresenter() ?: player;
            UIActivityViewController *share = [[UIActivityViewController alloc] initWithActivityItems:@[url] applicationActivities:nil];
            share.popoverPresentationController.sourceView = host.view;
            share.popoverPresentationController.sourceRect = host.view.bounds;
            [host presentViewController:share animated:YES completion:nil];
        }]];
        [menu addAction:[UIAlertAction actionWithTitle:@"Delete Download" style:UIAlertActionStyleDestructive handler:^(__unused UIAlertAction *action) {
            NSURL *url = YTMIURLForLibraryItem(item);
            if (url) [NSFileManager.defaultManager removeItemAtURL:url error:nil];
            NSString *identifier = [item[@"id"] isKindOfClass:NSString.class] ? item[@"id"] : @"";
            NSMutableArray *items = YTMILoadLibrary();
            NSIndexSet *matches = [items indexesOfObjectsPassingTest:^BOOL(NSDictionary *obj, NSUInteger idx, BOOL *stop) {
                (void)idx;
                (void)stop;
                return identifier.length && [obj[@"id"] isEqual:identifier];
            }];
            [items removeObjectsAtIndexes:matches];
            YTMISaveLibrary(items);
            YTMIPresentLibrary(player);
        }]];
        [menu addAction:[UIAlertAction actionWithTitle:@"Back" style:UIAlertActionStyleCancel handler:^(__unused UIAlertAction *action) { YTMIPresentLibrary(player); }]];
        menu.popoverPresentationController.sourceView = presenter.view;
        menu.popoverPresentationController.sourceRect = presenter.view.bounds;
        [presenter presentViewController:menu animated:YES completion:nil];
    });
}

static void YTMIPresentLibrary(YTPlayerViewController *player) {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIViewController *presenter = YTMIFallbackPresenter() ?: player;
        if (!presenter) return;
        NSMutableArray<NSDictionary *> *items = YTMILoadLibrary();
        UIAlertController *library = [UIAlertController alertControllerWithTitle:@"Downloads" message:items.count ? @"Saved audio stays here until you delete it." : @"No downloaded audio yet." preferredStyle:UIAlertControllerStyleActionSheet];
        NSUInteger count = MIN(items.count, 15);
        for (NSUInteger i = 0; i < count; i++) {
            NSDictionary *item = items[i];
            NSString *title = [item[@"title"] isKindOfClass:NSString.class] ? item[@"title"] : @"Downloaded Audio";
            NSString *artist = [item[@"artist"] isKindOfClass:NSString.class] ? item[@"artist"] : @"";
            NSString *label = artist.length ? [NSString stringWithFormat:@"%@ — %@", title, artist] : title;
            [library addAction:[UIAlertAction actionWithTitle:label style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) { YTMIPresentLibraryItem(item, player); }]];
        }
        [library addAction:[UIAlertAction actionWithTitle:@"Close" style:UIAlertActionStyleCancel handler:nil]];
        library.popoverPresentationController.sourceView = presenter.view;
        library.popoverPresentationController.sourceRect = presenter.view.bounds;
        [presenter presentViewController:library animated:YES completion:nil];
    });
}

static id YTMIPlayerResponse(YTPlayerViewController *player) {
    for (NSString *name in @[@"contentPlayerResponse", @"playerResponse", @"playerData"]) {
        SEL selector = NSSelectorFromString(name);
        if ([player respondsToSelector:selector]) {
            id value = ((id (*)(id, SEL))objc_msgSend)(player, selector);
            if (value) return value;
        }
    }
    return nil;
}

static NSDictionary *YTMIMetadataFromForm(UIAlertController *form, id response) {
    NSString *title = YTMICleanText(form.textFields[0].text, 180);
    NSString *artist = YTMICleanText(form.textFields[1].text, 120);
    NSString *album = YTMICleanText(form.textFields[2].text, 120);
    if (!title.length) title = [YTMINativeStreamResolver titleFromPlayerResponse:response] ?: @"YouTube Audio";
    if (!artist.length) artist = [YTMINativeStreamResolver authorFromPlayerResponse:response] ?: @"Unknown Artist";
    return @{YTMIJobTitleKey:title, YTMIJobArtistKey:artist, YTMIJobAlbumKey:album.length ? album : @"YT Music Importer"};
}

static void YTMIStoreCompletedDownload(NSURL *audioURL, NSDictionary *metadata, YTPlayerViewController *player) {
    NSError *error = nil;
    NSDictionary *item = YTMISaveDownloadedAudio(audioURL, metadata, &error);
    [NSFileManager.defaultManager removeItemAtURL:audioURL error:nil];
    if (!item) {
        YTMILogStage(@"Download library save failed");
        YTMIShowMessage(player, @"The audio downloaded, but it could not be saved to Downloads.");
        return;
    }
    YTMILogStage(@"Audio saved to Downloads");
    YTMIShowMessage(player, @"Audio saved to Downloads. Open Downloads from the importer menu to import it to Music, share it, or delete it.");
}

static void YTMIDownloadDirectAudio(NSURL *audioURL, NSDictionary *metadata, YTPlayerViewController *player) {
    YTMILogStage(@"Direct audio download started");
    NSURLSessionDownloadTask *task = [[NSURLSession sharedSession] downloadTaskWithURL:audioURL completionHandler:^(NSURL *location, NSURLResponse *responseObject, NSError *downloadError) {
        (void)responseObject;
        NSError *error = downloadError;
        NSURL *tempURL = nil;
        if (location && !error) {
            NSString *tempName = [NSString stringWithFormat:@"ytmi-%@.m4a", NSUUID.UUID.UUIDString];
            tempURL = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:tempName]];
            [NSFileManager.defaultManager removeItemAtURL:tempURL error:nil];
            if (![NSFileManager.defaultManager moveItemAtURL:location toURL:tempURL error:&error]) tempURL = nil;
        }
        if (!tempURL) {
            YTMILogStage(@"Direct audio download failed");
            YTMIShowMessage(player, @"Download failed while preparing the audio.");
            return;
        }
        YTMIPrepareAudioForMusic(tempURL, metadata, ^(NSURL *preparedURL, NSError *prepareError) {
            [NSFileManager.defaultManager removeItemAtURL:tempURL error:nil];
            if (!preparedURL) {
                (void)prepareError;
                YTMILogStage(@"Direct audio finalization failed");
                YTMIShowMessage(player, @"The downloaded audio could not be finalized for Music.");
                return;
            }
            YTMIStoreCompletedDownload(preparedURL, metadata, player);
        });
    }];
    [task resume];
}

static void YTMISubmitDownload(YTPlayerViewController *player, UIAlertController *form) {
    YTMILogStage(@"Download started");
    NSString *videoID = YTMICleanText(player.currentVideoID, 32);
    if (!videoID.length || player.isPlayingAd) {
        YTMILogStage(@"Download unavailable");
        YTMIShowMessage(player, @"Start the video briefly, then try again.");
        return;
    }
    id response = YTMIPlayerResponse(player);
    if (!response) {
        YTMILogStage(@"Player response unavailable");
        YTMIShowMessage(player, @"The current video is not ready yet. Play it briefly and try again.");
        return;
    }
    NSDictionary *metadata = YTMIMetadataFromForm(form, response);
    NSURL *audioURL = [YTMINativeStreamResolver bestAudioURLFromPlayerResponse:response];
    YTMIShowMessage(player, @"Audio download started. You can keep using YouTube.");
    if (audioURL) {
        YTMIDownloadDirectAudio(audioURL, metadata, player);
        return;
    }
    YTMILogStage(@"Using current playback session");
    YTMIStartSABRAudioDownload(response, videoID, nil, ^(NSURL *downloadedAudio, NSError *error) {
        (void)error;
        if (!downloadedAudio) {
            YTMILogStage(@"Playback session download failed");
            YTMIShowMessage(player, @"Download failed while preparing the audio stream.");
            return;
        }
        YTMIStoreCompletedDownload(downloadedAudio, metadata, player);
    });
}

static void YTMIPresentImport(YTPlayerViewController *player) {
    if (!player) return;
    UIAlertController *form = [UIAlertController alertControllerWithTitle:@"YT Music Importer — Beta 53 Test" message:@"Diagnostic logging is always on. Every import gets a random Import ID. The log contains fixed stage names only, without song names, paths, account, or device data." preferredStyle:UIAlertControllerStyleAlert];
    [form addTextFieldWithConfigurationHandler:^(UITextField *field) { field.placeholder = @"Title"; }];
    [form addTextFieldWithConfigurationHandler:^(UITextField *field) { field.placeholder = @"Artist"; }];
    [form addTextFieldWithConfigurationHandler:^(UITextField *field) { field.placeholder = @"Album (optional)"; }];
    [form addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [form addAction:[UIAlertAction actionWithTitle:@"Downloads" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) { YTMIPresentLibrary(player); }]];
    [form addAction:[UIAlertAction actionWithTitle:@"Diagnostic Log: Always On" style:UIAlertActionStyleDefault handler:nil]];
    [form addAction:[UIAlertAction actionWithTitle:@"Share Debug Log" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
        NSString *path = YTMILogPath();
        if (![NSFileManager.defaultManager fileExistsAtPath:path]) { YTMIShowMessage(player, @"No debug log is available yet."); return; }
        UIActivityViewController *share = [[UIActivityViewController alloc] initWithActivityItems:@[[NSURL fileURLWithPath:path]] applicationActivities:nil];
        share.popoverPresentationController.sourceView = player.view;
        share.popoverPresentationController.sourceRect = player.view.bounds;
        [player presentViewController:share animated:YES completion:nil];
    }]];
    [form addAction:[UIAlertAction actionWithTitle:@"Download" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) { YTMISubmitDownload(player, form); }]];
    [player presentViewController:form animated:YES completion:nil];
}

@interface YTMainAppControlsOverlayView (YTMusicImporter)
- (void)ytmi_buttonPressed:(id)sender;
@end
@interface YTInlinePlayerBarContainerView (YTMusicImporter)
- (void)ytmi_buttonPressed:(id)sender;
@end

%group Player
%hook YTPlayerViewController
- (void)viewDidAppear:(BOOL)animated {
    %orig;
    YTMIActivePlayer = self;
    YTMIScheduleBetaNotice(self);
}
%end
%end

%group TopButton
%hook YTMainAppControlsOverlayView
- (UIImage *)buttonImage:(NSString *)tweakID {
    if ([tweakID isEqualToString:YTMIOverlayKey]) return [UIImage systemImageNamed:@"tray.full"] ?: [UIImage systemImageNamed:@"arrow.down.circle"];
    return %orig;
}
%new(v@:@)
- (void)ytmi_buttonPressed:(id)sender {
    (void)sender;
    YTMIPresentImport(YTMIActivePlayer);
}
%end
%end

%group BottomButton
%hook YTInlinePlayerBarContainerView
- (UIImage *)buttonImage:(NSString *)tweakID {
    if ([tweakID isEqualToString:YTMIOverlayKey]) return [UIImage systemImageNamed:@"tray.full"] ?: [UIImage systemImageNamed:@"arrow.down.circle"];
    return %orig;
}
%new(v@:@)
- (void)ytmi_buttonPressed:(id)sender {
    (void)sender;
    YTMIPresentImport(YTMIActivePlayer);
}
%end
%end

%ctor {
    NSString *enabledKey = [NSString stringWithFormat:@"YTVideoOverlay-%@-Enabled", YTMIOverlayKey];
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    if ([defaults objectForKey:enabledKey] == nil) [defaults setBool:YES forKey:enabledKey];
    if (![defaults boolForKey:@"YTMusicImporterBeta53LogInitialized"]) {
        [NSFileManager.defaultManager removeItemAtPath:YTMILogPath() error:nil];
        [defaults setBool:YES forKey:@"YTMusicImporterBeta53LogInitialized"];
    }
    YTMILogStage(@"build.beta53.loaded");
    YTMISetSABRLogger(^(NSString *stage) { YTMILogStage(stage); });
    YTMIInstallSABRCapture();
    initYTVideoOverlay(YTMIOverlayKey, @{AccessibilityLabelKey:@"YT Music Importer", SelectorKey:@"ytmi_buttonPressed:"});
    %init(Player);
    %init(TopButton);
    %init(BottomButton);
}
