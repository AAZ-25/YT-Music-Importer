#import <UIKit/UIKit.h>
#import <objc/message.h>
#import <objc/runtime.h>
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
static const void *YTMIDownloadsControllerKey = &YTMIDownloadsControllerKey;
static NSString * const YTMIPivotIdentifier = @"FEYTMI_DOWNLOADS";
static const NSInteger YTMIDownloadsIconType = 891;
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

@interface YTMIMatrixSplashViewController : UIViewController
@property (nonatomic, strong) UILabel *terminalLabel;
@property (nonatomic, strong) UIProgressView *progressView;
@property (nonatomic, assign) BOOL animationStarted;
@end

@implementation YTMIMatrixSplashViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.74];

    UIView *card = [UIView new];
    card.translatesAutoresizingMaskIntoConstraints = NO;
    card.backgroundColor = [UIColor colorWithRed:0.015 green:0.035 blue:0.02 alpha:0.98];
    card.layer.cornerRadius = 22.0;
    card.layer.borderWidth = 1.0;
    card.layer.borderColor = [UIColor colorWithRed:0.15 green:1.0 blue:0.42 alpha:0.55].CGColor;
    card.layer.shadowColor = UIColor.blackColor.CGColor;
    card.layer.shadowOpacity = 0.42;
    card.layer.shadowRadius = 24.0;
    card.layer.shadowOffset = CGSizeMake(0, 12);

    UILabel *matrix = [UILabel new];
    matrix.translatesAutoresizingMaskIntoConstraints = NO;
    matrix.text = @"01011001 01010100 01001101 01001001\n00110110 00110010 00110001 00000001\n10100110 01101001 01010100 01001101";
    matrix.numberOfLines = 0;
    matrix.font = [UIFont monospacedSystemFontOfSize:10 weight:UIFontWeightRegular];
    matrix.textColor = [UIColor colorWithRed:0.05 green:0.7 blue:0.25 alpha:0.22];

    UILabel *title = [UILabel new];
    title.translatesAutoresizingMaskIntoConstraints = NO;
    title.text = @"YT MUSIC IMPORTER";
    title.font = [UIFont monospacedSystemFontOfSize:19 weight:UIFontWeightBold];
    title.textColor = [UIColor colorWithRed:0.2 green:1.0 blue:0.45 alpha:1.0];
    title.textAlignment = NSTextAlignmentCenter;

    UILabel *version = [UILabel new];
    version.translatesAutoresizingMaskIntoConstraints = NO;
    version.text = @"v1.0.0-beta.1  ·  LOCAL MODE";
    version.font = [UIFont monospacedSystemFontOfSize:11 weight:UIFontWeightMedium];
    version.textColor = UIColor.secondaryLabelColor;
    version.textAlignment = NSTextAlignmentCenter;

    UILabel *terminal = [UILabel new];
    terminal.translatesAutoresizingMaskIntoConstraints = NO;
    terminal.numberOfLines = 0;
    terminal.font = [UIFont monospacedSystemFontOfSize:12 weight:UIFontWeightMedium];
    terminal.textColor = [UIColor colorWithRed:0.25 green:1.0 blue:0.5 alpha:1.0];
    terminal.text = @"> INITIALIZING LOCAL MODULE_";
    terminal.accessibilityLabel = @"YT Music Importer is starting";
    self.terminalLabel = terminal;

    UIProgressView *progress = [[UIProgressView alloc] initWithProgressViewStyle:UIProgressViewStyleDefault];
    progress.translatesAutoresizingMaskIntoConstraints = NO;
    progress.progressTintColor = [UIColor colorWithRed:0.15 green:1.0 blue:0.42 alpha:1.0];
    progress.trackTintColor = [UIColor colorWithWhite:1.0 alpha:0.10];
    progress.progress = 0.08;
    progress.accessibilityLabel = @"Startup progress";
    self.progressView = progress;

    UILabel *note = [UILabel new];
    note.translatesAutoresizingMaskIntoConstraints = NO;
    note.text = @"Visual startup sequence — no device scan or network activity";
    note.font = [UIFont systemFontOfSize:10 weight:UIFontWeightRegular];
    note.textColor = [UIColor colorWithWhite:0.68 alpha:1.0];
    note.textAlignment = NSTextAlignmentCenter;
    note.numberOfLines = 0;

    [self.view addSubview:card];
    [card addSubview:matrix];
    [card addSubview:title];
    [card addSubview:version];
    [card addSubview:terminal];
    [card addSubview:progress];
    [card addSubview:note];
    NSLayoutConstraint *responsiveWidth = [card.widthAnchor constraintEqualToAnchor:self.view.widthAnchor multiplier:0.88];
    responsiveWidth.priority = UILayoutPriorityDefaultHigh;
    [NSLayoutConstraint activateConstraints:@[
        [card.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [card.centerYAnchor constraintEqualToAnchor:self.view.centerYAnchor],
        [card.leadingAnchor constraintGreaterThanOrEqualToAnchor:self.view.leadingAnchor constant:26],
        [card.trailingAnchor constraintLessThanOrEqualToAnchor:self.view.trailingAnchor constant:-26],
        [card.widthAnchor constraintLessThanOrEqualToConstant:390],
        responsiveWidth,
        [matrix.topAnchor constraintEqualToAnchor:card.topAnchor constant:18],
        [matrix.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:20],
        [matrix.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-20],
        [title.topAnchor constraintEqualToAnchor:matrix.bottomAnchor constant:12],
        [title.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:20],
        [title.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-20],
        [version.topAnchor constraintEqualToAnchor:title.bottomAnchor constant:7],
        [version.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:20],
        [version.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-20],
        [terminal.topAnchor constraintEqualToAnchor:version.bottomAnchor constant:24],
        [terminal.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:22],
        [terminal.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-22],
        [progress.topAnchor constraintEqualToAnchor:terminal.bottomAnchor constant:20],
        [progress.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:22],
        [progress.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-22],
        [note.topAnchor constraintEqualToAnchor:progress.bottomAnchor constant:16],
        [note.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:22],
        [note.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-22],
        [note.bottomAnchor constraintEqualToAnchor:card.bottomAnchor constant:-18]
    ]];
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    if (self.animationStarted) return;
    self.animationStarted = YES;
    NSArray<NSString *> *stages = @[
        @"> INITIALIZING LOCAL MODULE... OK",
        @"> LINKING AUDIO BRIDGE... OK",
        @"> MOUNTING DOWNLOADS... OK",
        @"> UI CHANNEL... READY"
    ];
    NSArray<NSNumber *> *progress = @[@0.24, @0.52, @0.78, @1.0];
    __weak typeof(self) weakSelf = self;
    for (NSUInteger index = 0; index < stages.count; index++) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)((0.28 + (0.44 * index)) * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            YTMIMatrixSplashViewController *strongSelf = weakSelf;
            if (!strongSelf) return;
            strongSelf.terminalLabel.text = [[stages subarrayWithRange:NSMakeRange(0, index + 1)] componentsJoinedByString:@"\n"];
            [strongSelf.progressView setProgress:[(NSNumber *)progress[index] floatValue] animated:YES];
            if (index + 1 == stages.count) {
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.62 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                    [weakSelf dismissViewControllerAnimated:YES completion:nil];
                });
            }
        });
    }
}

@end

static void YTMIScheduleStartupSplash(YTPlayerViewController *player) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.6 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        NSString *key = @"YTMusicImporterV1Beta1SplashShown";
        NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
        if ([defaults boolForKey:key] || YTMIBetaNoticePresentationInFlight) return;
        UIViewController *presenter = YTMIVisibleController(player ?: YTMIActivePlayer ?: YTMIFallbackPresenter());
        if (!presenter || [presenter isKindOfClass:UIAlertController.class] || presenter.presentedViewController || presenter.isBeingDismissed) {
            YTMIScheduleStartupSplash(player ?: YTMIActivePlayer);
            return;
        }
        YTMIMatrixSplashViewController *notice = [YTMIMatrixSplashViewController new];
        notice.modalPresentationStyle = UIModalPresentationOverFullScreen;
        notice.modalTransitionStyle = UIModalTransitionStyleCrossDissolve;
        YTMIBetaNoticePresentationInFlight = YES;
        [presenter presentViewController:notice animated:YES completion:^{
            BOOL shown = notice.presentingViewController != nil;
            if (shown) [defaults setBool:YES forKey:key];
            YTMIBetaNoticePresentationInFlight = NO;
            if (!shown) YTMIScheduleStartupSplash(player ?: YTMIActivePlayer);
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
    NSString *importID = [NSString stringWithFormat:@"V1B1-%@", [rawID substringToIndex:8]];
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

static BOOL YTMIDeleteLibraryItem(NSDictionary *item, NSError **error) {
    NSString *identifier = [item[@"id"] isKindOfClass:NSString.class] ? item[@"id"] : @"";
    NSString *fileName = [item[@"file"] isKindOfClass:NSString.class] ? item[@"file"] : @"";
    NSString *expectedName = identifier.length ? [identifier stringByAppendingString:@".m4a"] : @"";
    if (!identifier.length || ![fileName isEqualToString:expectedName] || ![fileName.lastPathComponent isEqualToString:fileName]) {
        if (error) *error = [NSError errorWithDomain:@"com.aaz.ytmusicimporter.ui" code:1 userInfo:nil];
        return NO;
    }
    NSString *root = YTMILibraryRoot();
    if (!root.length) return NO;
    NSString *path = [root stringByAppendingPathComponent:fileName];
    NSFileManager *fm = NSFileManager.defaultManager;
    NSMutableArray *items = YTMILoadLibrary();
    NSIndexSet *matches = [items indexesOfObjectsPassingTest:^BOOL(NSDictionary *candidate, NSUInteger idx, BOOL *stop) {
        (void)idx;
        (void)stop;
        return [candidate[@"id"] isKindOfClass:NSString.class] && [candidate[@"id"] isEqualToString:identifier];
    }];
    if (!matches.count && ![fm fileExistsAtPath:path]) return YES;
    NSString *stagedPath = nil;
    if ([fm fileExistsAtPath:path]) {
        stagedPath = [root stringByAppendingPathComponent:[NSString stringWithFormat:@".delete-%@.tmp", NSUUID.UUID.UUIDString]];
        if (![fm moveItemAtPath:path toPath:stagedPath error:error]) return NO;
    }
    [items removeObjectsAtIndexes:matches];
    NSString *indexPath = YTMILibraryIndexPath();
    if (!indexPath.length || ![items writeToFile:indexPath atomically:YES]) {
        if (stagedPath.length) [fm moveItemAtPath:stagedPath toPath:path error:nil];
        if (error && !*error) *error = [NSError errorWithDomain:@"com.aaz.ytmusicimporter.ui" code:2 userInfo:nil];
        return NO;
    }
    if (stagedPath.length) [fm removeItemAtPath:stagedPath error:nil];
    return YES;
}

@interface YTMIDownloadsViewController : UITableViewController
@property (nonatomic, weak) YTPlayerViewController *player;
@property (nonatomic, copy) NSArray<NSDictionary *> *items;
- (instancetype)initWithPlayer:(YTPlayerViewController *)player;
- (void)reloadLibraryAnimated:(BOOL)animated;
@end

@implementation YTMIDownloadsViewController

- (instancetype)initWithPlayer:(YTPlayerViewController *)player {
    self = [super initWithStyle:UITableViewStyleInsetGrouped];
    if (self) _player = player;
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Downloads";
    self.view.backgroundColor = UIColor.systemBackgroundColor;
    self.tableView.backgroundColor = UIColor.systemGroupedBackgroundColor;
    self.tableView.rowHeight = 72.0;
    self.tableView.separatorInset = UIEdgeInsetsMake(0, 66, 0, 16);
    self.navigationController.navigationBar.prefersLargeTitles = YES;
    self.navigationItem.largeTitleDisplayMode = UINavigationItemLargeTitleDisplayModeAlways;
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"arrow.clockwise"] style:UIBarButtonItemStylePlain target:self action:@selector(ytmi_refresh)];
    UIRefreshControl *refresh = [UIRefreshControl new];
    [refresh addTarget:self action:@selector(ytmi_pullToRefresh:) forControlEvents:UIControlEventValueChanged];
    self.refreshControl = refresh;
    [self reloadLibraryAnimated:NO];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self reloadLibraryAnimated:NO];
}

- (void)ytmi_refresh {
    [self reloadLibraryAnimated:YES];
}

- (void)ytmi_pullToRefresh:(UIRefreshControl *)refresh {
    [self reloadLibraryAnimated:YES];
    [refresh endRefreshing];
}

- (UIView *)ytmi_emptyView {
    UIView *container = [[UIView alloc] initWithFrame:self.tableView.bounds];
    UIImageView *icon = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"tray"]];
    icon.translatesAutoresizingMaskIntoConstraints = NO;
    icon.tintColor = UIColor.secondaryLabelColor;
    icon.preferredSymbolConfiguration = [UIImageSymbolConfiguration configurationWithPointSize:34 weight:UIImageSymbolWeightRegular];
    UILabel *title = [UILabel new];
    title.translatesAutoresizingMaskIntoConstraints = NO;
    title.text = @"No Downloads Yet";
    title.font = [UIFont preferredFontForTextStyle:UIFontTextStyleHeadline];
    title.textColor = UIColor.labelColor;
    UILabel *subtitle = [UILabel new];
    subtitle.translatesAutoresizingMaskIntoConstraints = NO;
    subtitle.text = @"Download audio from a playing video, then manage it here.";
    subtitle.font = [UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline];
    subtitle.textColor = UIColor.secondaryLabelColor;
    subtitle.numberOfLines = 0;
    subtitle.textAlignment = NSTextAlignmentCenter;
    [container addSubview:icon];
    [container addSubview:title];
    [container addSubview:subtitle];
    [NSLayoutConstraint activateConstraints:@[
        [icon.centerXAnchor constraintEqualToAnchor:container.centerXAnchor],
        [icon.centerYAnchor constraintEqualToAnchor:container.centerYAnchor constant:-54],
        [icon.widthAnchor constraintEqualToConstant:42],
        [icon.heightAnchor constraintEqualToConstant:42],
        [title.topAnchor constraintEqualToAnchor:icon.bottomAnchor constant:16],
        [title.centerXAnchor constraintEqualToAnchor:container.centerXAnchor],
        [subtitle.topAnchor constraintEqualToAnchor:title.bottomAnchor constant:8],
        [subtitle.leadingAnchor constraintEqualToAnchor:container.leadingAnchor constant:42],
        [subtitle.trailingAnchor constraintEqualToAnchor:container.trailingAnchor constant:-42]
    ]];
    return container;
}

- (void)reloadLibraryAnimated:(BOOL)animated {
    self.items = [YTMILoadLibrary() copy];
    self.tableView.backgroundView = self.items.count ? nil : [self ytmi_emptyView];
    void (^updates)(void) = ^{ [self.tableView reloadData]; };
    if (animated) [UIView transitionWithView:self.tableView duration:0.22 options:UIViewAnimationOptionTransitionCrossDissolve | UIViewAnimationOptionAllowAnimatedContent animations:updates completion:nil];
    else updates();
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    (void)tableView;
    return self.items.count ? 1 : 0;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    (void)tableView;
    (void)section;
    return (NSInteger)self.items.count;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    (void)tableView;
    (void)section;
    return [NSString stringWithFormat:@"%lu SAVED %@", (unsigned long)self.items.count, self.items.count == 1 ? @"TRACK" : @"TRACKS"];
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    (void)tableView;
    (void)section;
    return @"Saved audio remains here until you confirm deletion. Importing or deleting this copy does not remove an existing song from Music.";
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    static NSString *reuse = @"YTMIDownloadCell";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:reuse];
    if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:reuse];
    NSDictionary *item = self.items[(NSUInteger)indexPath.row];
    cell.textLabel.text = [item[@"title"] isKindOfClass:NSString.class] ? item[@"title"] : @"Downloaded Audio";
    NSString *artist = [item[@"artist"] isKindOfClass:NSString.class] ? item[@"artist"] : @"Unknown Artist";
    NSString *album = [item[@"album"] isKindOfClass:NSString.class] ? item[@"album"] : @"";
    cell.detailTextLabel.text = album.length ? [NSString stringWithFormat:@"%@  ·  %@", artist, album] : artist;
    cell.textLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
    cell.detailTextLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleCaption1];
    cell.detailTextLabel.textColor = UIColor.secondaryLabelColor;
    cell.imageView.image = [UIImage systemImageNamed:@"music.note"];
    cell.imageView.tintColor = UIColor.systemRedColor;
    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    cell.selectionStyle = UITableViewCellSelectionStyleDefault;
    return cell;
}

- (void)ytmi_shareItem:(NSDictionary *)item sourceView:(UIView *)sourceView {
    NSURL *url = YTMIURLForLibraryItem(item);
    if (!url) { YTMIShowMessage(self.player, @"The downloaded audio file is unavailable."); return; }
    UIActivityViewController *share = [[UIActivityViewController alloc] initWithActivityItems:@[url] applicationActivities:nil];
    share.popoverPresentationController.sourceView = sourceView ?: self.view;
    share.popoverPresentationController.sourceRect = sourceView ? sourceView.bounds : self.view.bounds;
    [self presentViewController:share animated:YES completion:nil];
}

- (void)ytmi_confirmDeleteItem:(NSDictionary *)item {
    NSString *title = [item[@"title"] isKindOfClass:NSString.class] ? item[@"title"] : @"this download";
    NSString *message = [NSString stringWithFormat:@"Delete “%@” from YouTube Downloads?\n\nThis does not remove an existing imported song from Music.", title];
    UIAlertController *confirm = [UIAlertController alertControllerWithTitle:@"Delete Download?" message:message preferredStyle:UIAlertControllerStyleAlert];
    [confirm addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    __weak typeof(self) weakSelf = self;
    [confirm addAction:[UIAlertAction actionWithTitle:@"Delete" style:UIAlertActionStyleDestructive handler:^(__unused UIAlertAction *action) {
        NSError *error = nil;
        if (!YTMIDeleteLibraryItem(item, &error)) {
            (void)error;
            YTMIShowMessage(weakSelf.player, @"The download could not be deleted. Nothing else was removed.");
            return;
        }
        YTMILogStage(@"Download deleted after confirmation");
        [weakSelf reloadLibraryAnimated:YES];
    }]];
    [self presentViewController:confirm animated:YES completion:nil];
}

- (UISwipeActionsConfiguration *)tableView:(UITableView *)tableView trailingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath {
    (void)tableView;
    if ((NSUInteger)indexPath.row >= self.items.count) return nil;
    NSDictionary *item = self.items[(NSUInteger)indexPath.row];
    __weak typeof(self) weakSelf = self;
    UIContextualAction *deleteAction = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleDestructive title:@"Delete" handler:^(__unused UIContextualAction *action, __unused UIView *sourceView, void (^completionHandler)(BOOL)) {
        completionHandler(NO);
        dispatch_async(dispatch_get_main_queue(), ^{ [weakSelf ytmi_confirmDeleteItem:item]; });
    }];
    deleteAction.image = [UIImage systemImageNamed:@"trash"];
    UISwipeActionsConfiguration *configuration = [UISwipeActionsConfiguration configurationWithActions:@[deleteAction]];
    configuration.performsFirstActionWithFullSwipe = NO;
    return configuration;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if ((NSUInteger)indexPath.row >= self.items.count) return;
    NSDictionary *item = self.items[(NSUInteger)indexPath.row];
    UITableViewCell *cell = [tableView cellForRowAtIndexPath:indexPath];
    NSString *title = [item[@"title"] isKindOfClass:NSString.class] ? item[@"title"] : @"Downloaded Audio";
    NSString *artist = [item[@"artist"] isKindOfClass:NSString.class] ? item[@"artist"] : @"";
    UIAlertController *menu = [UIAlertController alertControllerWithTitle:title message:artist preferredStyle:UIAlertControllerStyleActionSheet];
    __weak typeof(self) weakSelf = self;
    [menu addAction:[UIAlertAction actionWithTitle:@"Import to Music" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) { YTMIImportLibraryItem(item, weakSelf.player ?: YTMIActivePlayer); }]];
    [menu addAction:[UIAlertAction actionWithTitle:@"Share Audio" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
        dispatch_async(dispatch_get_main_queue(), ^{ [weakSelf ytmi_shareItem:item sourceView:cell]; });
    }]];
    [menu addAction:[UIAlertAction actionWithTitle:@"Delete Download…" style:UIAlertActionStyleDestructive handler:^(__unused UIAlertAction *action) {
        dispatch_async(dispatch_get_main_queue(), ^{ [weakSelf ytmi_confirmDeleteItem:item]; });
    }]];
    [menu addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    menu.popoverPresentationController.sourceView = cell ?: self.view;
    menu.popoverPresentationController.sourceRect = cell ? cell.bounds : self.view.bounds;
    [self presentViewController:menu animated:YES completion:nil];
}

@end

static void YTMIPresentLibrary(YTPlayerViewController *player) {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIViewController *presenter = YTMIVisibleController(YTMIFallbackPresenter() ?: player);
        if (!presenter) return;
        YTMIDownloadsViewController *downloads = [[YTMIDownloadsViewController alloc] initWithPlayer:player ?: YTMIActivePlayer];
        UINavigationController *navigation = [[UINavigationController alloc] initWithRootViewController:downloads];
        navigation.modalPresentationStyle = UIModalPresentationPageSheet;
        [presenter presentViewController:navigation animated:YES completion:nil];
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
    YTMIShowMessage(player, @"Audio saved. Open the Downloads tab to import it to Music, share it, or delete it.");
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
    UIAlertController *form = [UIAlertController alertControllerWithTitle:@"YT Music Importer — 1.0 Beta 1" message:@"Every import gets a random Import ID. Diagnostics contain fixed stage names only and do not include song, account, or device data." preferredStyle:UIAlertControllerStyleAlert];
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

@interface YTPivotBarView : UIView
@end

static id YTMIRuntimeValue(id receiver, NSString *selectorName) {
    SEL selector = NSSelectorFromString(selectorName);
    return receiver && [receiver respondsToSelector:selector]
        ? ((id (*)(id, SEL))objc_msgSend)(receiver, selector)
        : nil;
}

static void YTMISetRuntimeValue(id receiver, NSString *selectorName, id value) {
    SEL selector = NSSelectorFromString(selectorName);
    if (receiver && [receiver respondsToSelector:selector]) {
        ((void (*)(id, SEL, id))objc_msgSend)(receiver, selector, value);
    }
}

static NSString *YTMIPivotItemIdentifier(id item, NSUInteger depth) {
    if (!item || depth > 4) return nil;
    for (NSString *name in @[@"pivotIdentifier", @"tabIdentifier", @"browseId"]) {
        id value = YTMIRuntimeValue(item, name);
        if ([value isKindOfClass:NSString.class] && [value length]) return value;
    }
    for (NSString *name in @[@"pivotBarItemRenderer", @"pivotBarIconOnlyItemRenderer", @"renderer", @"navigationEndpoint", @"endpoint", @"browseEndpoint"]) {
        id nested = YTMIRuntimeValue(item, name);
        NSString *identifier = nested != item ? YTMIPivotItemIdentifier(nested, depth + 1) : nil;
        if (identifier.length) return identifier;
    }
    return nil;
}

static id YTMIMakeDownloadsPivotItem(void) {
    Class rendererClass = NSClassFromString(@"YTIPivotBarRenderer");
    SEL factory = NSSelectorFromString(@"pivotSupportedRenderersWithBrowseId:title:iconType:");
    if (rendererClass && [rendererClass respondsToSelector:factory]) {
        id renderer = ((id (*)(id, SEL, id, id, NSInteger))objc_msgSend)(rendererClass, factory, YTMIPivotIdentifier, @"Downloads", YTMIDownloadsIconType);
        id item = YTMIRuntimeValue(renderer, @"pivotBarItemRenderer");
        YTMISetRuntimeValue(item, @"setPivotIdentifier:", YTMIPivotIdentifier);
        if (renderer) return renderer;
    }
    id browseEndpoint = [[NSClassFromString(@"YTIBrowseEndpoint") alloc] init];
    id command = [[NSClassFromString(@"YTICommand") alloc] init];
    id itemRenderer = [[NSClassFromString(@"YTIPivotBarItemRenderer") alloc] init];
    id supportedRenderer = [[NSClassFromString(@"YTIPivotBarSupportedRenderers") alloc] init];
    Class formattedClass = NSClassFromString(@"YTIFormattedString");
    SEL formattedFactory = NSSelectorFromString(@"formattedStringWithString:");
    if (!browseEndpoint || !command || !itemRenderer || !supportedRenderer ||
        !formattedClass || ![formattedClass respondsToSelector:formattedFactory]) return nil;
    YTMISetRuntimeValue(browseEndpoint, @"setBrowseId:", YTMIPivotIdentifier);
    YTMISetRuntimeValue(command, @"setBrowseEndpoint:", browseEndpoint);
    YTMISetRuntimeValue(itemRenderer, @"setPivotIdentifier:", YTMIPivotIdentifier);
    YTMISetRuntimeValue(itemRenderer, @"setNavigationEndpoint:", command);
    id title = ((id (*)(id, SEL, id))objc_msgSend)(formattedClass, formattedFactory, @"Downloads");
    YTMISetRuntimeValue(itemRenderer, @"setTitle:", title);
    id icon = [[NSClassFromString(@"YTIIcon") alloc] init];
    SEL setIconType = NSSelectorFromString(@"setIconType:");
    if ([icon respondsToSelector:setIconType]) {
        ((void (*)(id, SEL, NSInteger))objc_msgSend)(icon, setIconType, YTMIDownloadsIconType);
        YTMISetRuntimeValue(itemRenderer, @"setIcon:", icon);
    }
    YTMISetRuntimeValue(supportedRenderer, @"setPivotBarItemRenderer:", itemRenderer);
    return supportedRenderer;
}

static NSArray *YTMIPivotItems(id renderer, NSString **setterName) {
    NSArray<NSString *> *getters = @[@"itemsArray", @"items", @"pivotBarItemsArray", @"pivotBarItems"];
    NSArray<NSString *> *setters = @[@"setItemsArray:", @"setItems:", @"setPivotBarItemsArray:", @"setPivotBarItems:"];
    for (NSUInteger index = 0; index < getters.count; index++) {
        id value = YTMIRuntimeValue(renderer, getters[index]);
        if ([value isKindOfClass:NSArray.class]) {
            if (setterName) *setterName = setters[index];
            return value;
        }
    }
    return nil;
}

static void YTMIInstallDownloadsPivotItem(id renderer) {
    if (!renderer) return;
    NSString *setterName = nil;
    NSArray *items = YTMIPivotItems(renderer, &setterName);
    if (!items) return;
    NSMutableArray *updated = [NSMutableArray arrayWithCapacity:items.count + 1];
    BOOL found = NO;
    for (id item in items) {
        BOOL isDownloads = [[YTMIPivotItemIdentifier(item, 0) lowercaseString] isEqualToString:YTMIPivotIdentifier.lowercaseString];
        if (!isDownloads || !found) [updated addObject:item];
        found = found || isDownloads;
    }
    if (!found) {
        id downloads = YTMIMakeDownloadsPivotItem();
        if (!downloads) return;
        [updated addObject:downloads];
        YTMILogStage(@"ui.downloads-tab.installed");
    }
    if ([items isKindOfClass:NSMutableArray.class]) {
        [(NSMutableArray *)items setArray:updated];
    } else {
        YTMISetRuntimeValue(renderer, setterName, updated);
    }
}

static NSString *YTMIBrowseIdentifier(id controller) {
    id endpoint = YTMIRuntimeValue(controller, @"navigationEndpoint") ?: YTMIRuntimeValue(controller, @"navEndpoint");
    if (!endpoint) {
        @try { endpoint = [controller valueForKey:@"_navEndpoint"]; }
        @catch (__unused NSException *exception) {}
    }
    id browse = YTMIRuntimeValue(endpoint, @"browseEndpoint") ?: endpoint;
    id identifier = YTMIRuntimeValue(browse, @"browseId");
    return [identifier isKindOfClass:NSString.class] ? identifier : nil;
}

static void YTMIAttachDownloadsPage(id controller) {
    if (![controller isKindOfClass:UIViewController.class]) return;
    UIViewController *viewController = (UIViewController *)controller;
    if (![[YTMIBrowseIdentifier(viewController) lowercaseString] isEqualToString:YTMIPivotIdentifier.lowercaseString] ||
        objc_getAssociatedObject(viewController, YTMIDownloadsControllerKey)) return;
    YTMIDownloadsViewController *downloads = [[YTMIDownloadsViewController alloc] initWithPlayer:YTMIActivePlayer];
    UINavigationController *navigation = [[UINavigationController alloc] initWithRootViewController:downloads];
    [viewController addChildViewController:navigation];
    navigation.view.frame = viewController.view.bounds;
    navigation.view.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    navigation.view.alpha = 0.0;
    [viewController.view addSubview:navigation.view];
    [navigation didMoveToParentViewController:viewController];
    objc_setAssociatedObject(viewController, YTMIDownloadsControllerKey, navigation, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [UIView animateWithDuration:0.18 delay:0 options:UIViewAnimationOptionCurveEaseOut | UIViewAnimationOptionBeginFromCurrentState animations:^{
        navigation.view.alpha = 1.0;
    } completion:nil];
    UISelectionFeedbackGenerator *feedback = [UISelectionFeedbackGenerator new];
    [feedback selectionChanged];
    YTMILogStage(@"ui.downloads-tab.opened");
}

static void YTMITryAttachDownloadsPage(id controller) {
    YTMIAttachDownloadsPage(controller);
    if (!objc_getAssociatedObject(controller, YTMIDownloadsControllerKey)) {
        dispatch_async(dispatch_get_main_queue(), ^{ YTMIAttachDownloadsPage(controller); });
    }
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
    YTMIScheduleStartupSplash(self);
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

%group DownloadsTab
%hook YTPivotBarView
- (void)setRenderer:(id)renderer {
    YTMIInstallDownloadsPivotItem(renderer);
    %orig(renderer);
}
%end

%hook YTAppViewController
- (void)viewDidLoad {
    %orig;
    YTMITryAttachDownloadsPage(self);
}
- (void)viewDidAppear:(BOOL)animated {
    %orig(animated);
    YTMITryAttachDownloadsPage(self);
}
%end

%hook YTBrowseViewController
- (void)viewDidLoad {
    %orig;
    YTMITryAttachDownloadsPage(self);
}
- (void)viewDidAppear:(BOOL)animated {
    %orig(animated);
    YTMITryAttachDownloadsPage(self);
}
%end

%hook YTBrowseResponseViewController
- (void)viewDidLoad {
    %orig;
    YTMITryAttachDownloadsPage(self);
}
- (void)viewDidAppear:(BOOL)animated {
    %orig(animated);
    YTMITryAttachDownloadsPage(self);
}
%end

%hook YTWrapperFlatViewController
- (void)viewDidLoad {
    %orig;
    YTMITryAttachDownloadsPage(self);
}
- (void)viewDidAppear:(BOOL)animated {
    %orig(animated);
    YTMITryAttachDownloadsPage(self);
}
%end
%end

%ctor {
    NSString *enabledKey = [NSString stringWithFormat:@"YTVideoOverlay-%@-Enabled", YTMIOverlayKey];
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    if ([defaults objectForKey:enabledKey] == nil) [defaults setBool:YES forKey:enabledKey];
    if (![defaults boolForKey:@"YTMusicImporterV1Beta1LogInitialized"]) {
        [NSFileManager.defaultManager removeItemAtPath:YTMILogPath() error:nil];
        [defaults setBool:YES forKey:@"YTMusicImporterV1Beta1LogInitialized"];
    }
    YTMILogStage(@"build.v1-beta1.loaded");
    YTMISetSABRLogger(^(NSString *stage) { YTMILogStage(stage); });
    YTMIInstallSABRCapture();
    initYTVideoOverlay(YTMIOverlayKey, @{AccessibilityLabelKey:@"YT Music Importer", SelectorKey:@"ytmi_buttonPressed:"});
    %init(Player);
    %init(TopButton);
    %init(BottomButton);
    %init(DownloadsTab);
}
