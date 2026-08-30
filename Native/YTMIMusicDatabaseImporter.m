#import "YTMIMusicDatabaseImporter.h"
#import "YTMIConstants.h"
#import <AVFoundation/AVFoundation.h>
#import <CoreFoundation/CoreFoundation.h>
#import <dlfcn.h>
#import <math.h>
#import <objc/message.h>
#import <sqlite3.h>
#import <sys/stat.h>

static NSError *YTMIDBError(NSInteger code, NSString *message) {
    return [NSError errorWithDomain:@"com.aaz.ytmusicimporter"
                               code:code
                           userInfo:@{NSLocalizedDescriptionKey:message ?: @"Music database import failed."}];
}

static NSString *YTMISafeText(id value, NSString *fallback) {
    if (![value isKindOfClass:NSString.class]) return fallback;
    NSString *text = [(NSString *)value stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    return text.length ? text : fallback;
}

static BOOL YTMIExec(sqlite3 *db, const char *sql) {
    return sqlite3_exec(db, sql, NULL, NULL, NULL) == SQLITE_OK;
}

static BOOL YTMIHasColumn(sqlite3 *db, NSString *table, NSString *column) {
    NSString *sql = [NSString stringWithFormat:@"PRAGMA table_info(%@)", table];
    sqlite3_stmt *stmt = NULL;
    if (sqlite3_prepare_v2(db, sql.UTF8String, -1, &stmt, NULL) != SQLITE_OK) return NO;
    BOOL found = NO;
    while (sqlite3_step(stmt) == SQLITE_ROW) {
        const unsigned char *name = sqlite3_column_text(stmt, 1);
        if (name && [column isEqualToString:[NSString stringWithUTF8String:(const char *)name]]) {
            found = YES;
            break;
        }
    }
    sqlite3_finalize(stmt);
    return found;
}

static BOOL YTMIValidateSchema(sqlite3 *db) {
    NSDictionary<NSString *, NSArray<NSString *> *> *required = @{
        @"item":@[@"item_pid", @"media_type", @"base_location_id", @"in_my_library", @"date_added"],
        @"item_extra":@[@"item_pid", @"title", @"location", @"file_size", @"total_time_ms", @"media_kind", @"location_kind_id"],
        @"item_playback":@[@"item_pid", @"audio_format", @"bit_rate", @"sample_rate"],
        @"item_stats":@[@"item_pid", @"date_accessed"],
        @"item_store":@[@"item_pid", @"sync_id", @"sync_in_my_library"],
        @"base_location":@[@"base_location_id", @"path"]
    };
    for (NSString *table in required) {
        for (NSString *column in required[table]) {
            if (!YTMIHasColumn(db, table, column)) return NO;
        }
    }
    return YES;
}

static BOOL YTMICreateBackup(sqlite3 *source, NSString *path) {
    sqlite3 *backupDB = NULL;
    if (sqlite3_open_v2(path.UTF8String, &backupDB, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, NULL) != SQLITE_OK) {
        if (backupDB) sqlite3_close(backupDB);
        return NO;
    }
    sqlite3_backup *backup = sqlite3_backup_init(backupDB, "main", source, "main");
    if (!backup) {
        sqlite3_close(backupDB);
        return NO;
    }
    int step = sqlite3_backup_step(backup, -1);
    int finish = sqlite3_backup_finish(backup);
    BOOL ok = (step == SQLITE_DONE && finish == SQLITE_OK);
    if (ok) ok = YTMIExec(backupDB, "PRAGMA quick_check");
    sqlite3_close(backupDB);
    return ok;
}

static long long YTMIRandomPID(void) {
    uint64_t upper = (uint64_t)arc4random();
    uint64_t lower = (uint64_t)arc4random();
    return (long long)(((upper << 32) | lower) & 0x7fffffffffffffffULL) ?: 1;
}

static NSUInteger YTMIVisibleSongCount(void) {
    dlopen("/System/Library/Frameworks/MediaPlayer.framework/MediaPlayer", RTLD_LAZY | RTLD_LOCAL);
    Class queryClass = NSClassFromString(@"MPMediaQuery");
    SEL songsSEL = NSSelectorFromString(@"songsQuery");
    if (!queryClass || ![queryClass respondsToSelector:songsSEL]) return NSNotFound;
    id query = ((id (*)(id, SEL))objc_msgSend)(queryClass, songsSEL);
    SEL itemsSEL = NSSelectorFromString(@"items");
    id items = query && [query respondsToSelector:itemsSEL] ? ((id (*)(id, SEL))objc_msgSend)(query, itemsSEL) : nil;
    return [items respondsToSelector:@selector(count)] ? [items count] : NSNotFound;
}

static void YTMINotifyMusicLibrary(void) {
    dlopen("/System/Library/PrivateFrameworks/MusicLibrary.framework/MusicLibrary", RTLD_LAZY | RTLD_LOCAL);
    Class libraryClass = NSClassFromString(@"ML3MusicLibrary");
    SEL sharedSEL = NSSelectorFromString(@"sharedLibrary");
    id library = libraryClass && [libraryClass respondsToSelector:sharedSEL] ? ((id (*)(id, SEL))objc_msgSend)(libraryClass, sharedSEL) : nil;
    for (NSString *name in @[@"notifyEntitiesAddedOrRemoved", @"notifyContentsDidChange", @"notifyLibraryImportDidFinish"]) {
        SEL selector = NSSelectorFromString(name);
        if (library && [library respondsToSelector:selector]) ((void (*)(id, SEL))objc_msgSend)(library, selector);
    }
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(), CFSTR("com.apple.itunes-mobdev.syncDidFinish"), NULL, NULL, true);
}

static BOOL YTMIInsertItem(sqlite3 *db, long long pid, NSString *title, NSString *filename,
                           long long fileSize, long long durationMs, long long now) {
    const char *itemSQL =
        "INSERT INTO item (item_pid,media_type,title_order,title_order_section,"
        "item_artist_pid,item_artist_order,item_artist_order_section,series_name_order,series_name_order_section,"
        "album_pid,album_order,album_order_section,album_artist_pid,album_artist_order,album_artist_order_section,"
        "composer_pid,composer_order,composer_order_section,genre_id,genre_order,genre_order_section,"
        "disc_number,track_number,episode_sort_id,base_location_id,remote_location_id,"
        "exclude_from_shuffle,keep_local,keep_local_status,keep_local_status_reason,keep_local_constraints,"
        "in_my_library,is_compilation,date_added,show_composer,is_music_show,date_downloaded,download_source_container_pid)"
        " VALUES (?,8,0,26,0,0,26,0,26,0,0,26,0,0,26,0,0,26,0,0,26,1,1,1,3840,0,0,1,2,0,0,1,0,?,0,0,?,0)";
    sqlite3_stmt *stmt = NULL;
    if (sqlite3_prepare_v2(db, itemSQL, -1, &stmt, NULL) != SQLITE_OK) return NO;
    sqlite3_bind_int64(stmt, 1, pid);
    sqlite3_bind_int64(stmt, 2, now);
    sqlite3_bind_int64(stmt, 3, now);
    BOOL ok = sqlite3_step(stmt) == SQLITE_DONE;
    sqlite3_finalize(stmt);
    if (!ok) return NO;
    stmt = NULL;
    const char *extraSQL =
        "INSERT INTO item_extra (item_pid,title,sort_title,disc_count,track_count,total_time_ms,year,"
        "location,file_size,integrity,is_audible_audio_book,date_modified,media_kind,content_rating,"
        "content_rating_level,is_user_disabled,bpm,genius_id,location_kind_id,copyright)"
        " VALUES (?,?,?,1,1,?,0,?,?,X'',0,?,1,0,0,0,0,0,42,'')";
    if (sqlite3_prepare_v2(db, extraSQL, -1, &stmt, NULL) != SQLITE_OK) return NO;
    sqlite3_bind_int64(stmt, 1, pid);
    sqlite3_bind_text(stmt, 2, title.UTF8String, -1, SQLITE_TRANSIENT);
    sqlite3_bind_text(stmt, 3, title.UTF8String, -1, SQLITE_TRANSIENT);
    sqlite3_bind_int64(stmt, 4, durationMs);
    sqlite3_bind_text(stmt, 5, filename.UTF8String, -1, SQLITE_TRANSIENT);
    sqlite3_bind_int64(stmt, 6, fileSize);
    sqlite3_bind_int64(stmt, 7, now);
    ok = sqlite3_step(stmt) == SQLITE_DONE;
    sqlite3_finalize(stmt);
    if (!ok) return NO;
    stmt = NULL;
    const char *playbackSQL =
        "INSERT INTO item_playback (item_pid,audio_format,bit_rate,codec_type,codec_subtype,data_kind,"
        "duration,has_video,relative_volume,sample_rate) VALUES (?,1633772320,256,0,0,0,0,0,0,44100.0)";
    if (sqlite3_prepare_v2(db, playbackSQL, -1, &stmt, NULL) != SQLITE_OK) return NO;
    sqlite3_bind_int64(stmt, 1, pid);
    ok = sqlite3_step(stmt) == SQLITE_DONE;
    sqlite3_finalize(stmt);
    if (!ok) return NO;
    stmt = NULL;
    if (sqlite3_prepare_v2(db, "INSERT INTO item_stats (item_pid,date_accessed) VALUES (?,?)", -1, &stmt, NULL) != SQLITE_OK) return NO;
    sqlite3_bind_int64(stmt, 1, pid);
    sqlite3_bind_int64(stmt, 2, now);
    ok = sqlite3_step(stmt) == SQLITE_DONE;
    sqlite3_finalize(stmt);
    if (!ok) return NO;
    stmt = NULL;
    if (sqlite3_prepare_v2(db, "INSERT INTO item_store (item_pid,sync_id,sync_in_my_library) VALUES (?,?,1)", -1, &stmt, NULL) != SQLITE_OK) return NO;
    sqlite3_bind_int64(stmt, 1, pid);
    sqlite3_bind_int64(stmt, 2, YTMIRandomPID());
    ok = sqlite3_step(stmt) == SQLITE_DONE;
    sqlite3_finalize(stmt);
    return ok;
}

@implementation YTMIMusicDatabaseImporter

- (BOOL)importAudioAtURL:(NSURL *)audioURL metadata:(NSDictionary *)metadata error:(NSError **)error {
    if (!audioURL.isFileURL || ![NSFileManager.defaultManager fileExistsAtPath:audioURL.path]) {
        if (error) *error = YTMIDBError(19, @"The prepared audio file is unavailable.");
        return NO;
    }
    NSFileManager *fm = NSFileManager.defaultManager;
    NSString *databasePath = @"/var/mobile/Media/iTunes_Control/iTunes/MediaLibrary.sqlitedb";
    if (![fm fileExistsAtPath:databasePath]) databasePath = @"/private/var/mobile/Media/iTunes_Control/iTunes/MediaLibrary.sqlitedb";
    if (![fm fileExistsAtPath:databasePath]) {
        if (error) *error = YTMIDBError(70, @"The local Music database is unavailable.");
        return NO;
    }
    NSString *musicDir = [databasePath hasPrefix:@"/private"] ? @"/private/var/mobile/Media/iTunes_Control/Music/F00" : @"/var/mobile/Media/iTunes_Control/Music/F00";
    if (![fm createDirectoryAtPath:musicDir withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions:@0755} error:nil]) {
        if (error) *error = YTMIDBError(71, @"The local Music media folder could not be prepared.");
        return NO;
    }
    NSString *filename = [NSString stringWithFormat:@"%@.m4a", [[NSUUID.UUID.UUIDString stringByReplacingOccurrencesOfString:@"-" withString:@""] lowercaseString]];
    NSString *destination = [musicDir stringByAppendingPathComponent:filename];
    if (![fm copyItemAtPath:audioURL.path toPath:destination error:nil]) {
        if (error) *error = YTMIDBError(72, @"The audio could not be copied into local Music storage.");
        return NO;
    }
    chmod(destination.fileSystemRepresentation, 0644);

    sqlite3 *db = NULL;
    if (sqlite3_open_v2(databasePath.UTF8String, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, NULL) != SQLITE_OK) {
        if (db) sqlite3_close(db);
        [fm removeItemAtPath:destination error:nil];
        if (error) *error = YTMIDBError(73, @"The local Music database could not be opened.");
        return NO;
    }
    sqlite3_busy_timeout(db, 8000);
    if (!YTMIValidateSchema(db)) {
        sqlite3_close(db);
        [fm removeItemAtPath:destination error:nil];
        if (error) *error = YTMIDBError(74, @"This Music database schema is not supported safely.");
        return NO;
    }

    NSString *backupDir = @"/var/mobile/Media/YTMusicImporter/Backups";
    [fm createDirectoryAtPath:backupDir withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions:@0700} error:nil];
    NSString *backupPath = [backupDir stringByAppendingPathComponent:@"MediaLibrary-before-import.sqlite"];
    [fm removeItemAtPath:backupPath error:nil];
    if (!YTMICreateBackup(db, backupPath)) {
        sqlite3_close(db);
        [fm removeItemAtPath:destination error:nil];
        if (error) *error = YTMIDBError(75, @"A safe local Music database backup could not be created.");
        return NO;
    }
    chmod(backupPath.fileSystemRepresentation, 0600);

    NSDictionary *attrs = [fm attributesOfItemAtPath:destination error:nil];
    long long fileSize = [attrs[NSFileSize] longLongValue];
    AVURLAsset *asset = [AVURLAsset URLAssetWithURL:[NSURL fileURLWithPath:destination] options:nil];
    double seconds = CMTimeGetSeconds(asset.duration);
    if (!isfinite(seconds) || seconds < 0) seconds = 0;
    long long durationMs = (long long)(seconds * 1000.0);
    long long now = (long long)NSDate.date.timeIntervalSince1970;
    long long pid = YTMIRandomPID();
    NSString *title = YTMISafeText(metadata[YTMIJobTitleKey], @"YouTube Audio");
    NSUInteger visibleBefore = YTMIVisibleSongCount();

    BOOL ok = YTMIExec(db, "BEGIN IMMEDIATE");
    if (ok) ok = YTMIExec(db, "INSERT OR IGNORE INTO base_location (base_location_id,path) VALUES (3840,'iTunes_Control/Music/F00')");
    if (ok) ok = YTMIInsertItem(db, pid, title, filename, fileSize, durationMs, now);
    if (ok) ok = YTMIExec(db, "COMMIT");
    else YTMIExec(db, "ROLLBACK");
    sqlite3_close(db);
    if (!ok) {
        [fm removeItemAtPath:destination error:nil];
        if (error) *error = YTMIDBError(76, @"The Music database transaction was rejected and rolled back.");
        return NO;
    }

    YTMINotifyMusicLibrary();
    BOOL visible = NO;
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:15.0];
    while (deadline.timeIntervalSinceNow > 0) {
        NSUInteger visibleAfter = YTMIVisibleSongCount();
        if (visibleBefore != NSNotFound && visibleAfter != NSNotFound && visibleAfter > visibleBefore) {
            visible = YES;
            break;
        }
        [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.5]];
    }
    if (!visible) {
        if (error) *error = YTMIDBError(77, @"The local record was committed but Music has not refreshed it yet.");
        return NO;
    }
    return YES;
}

@end
