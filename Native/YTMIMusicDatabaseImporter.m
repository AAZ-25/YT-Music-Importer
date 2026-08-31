#import "YTMIMusicDatabaseImporter.h"
#import "YTMIConstants.h"
#import <AVFoundation/AVFoundation.h>
#import <CoreFoundation/CoreFoundation.h>
#import <CommonCrypto/CommonDigest.h>
#import <sqlite3.h>
#import <sys/stat.h>

static NSError *YTMIDBError(NSInteger code, NSString *message) {
    return [NSError errorWithDomain:@"com.aaz.ytmusicimporter" code:code userInfo:@{NSLocalizedDescriptionKey:message ?: @"Music import failed."}];
}

static void YTMITrace(NSMutableArray *trace, NSString *stage) {
    if (trace && stage.length) [trace addObject:stage];
}

static NSString *YTMISafeText(id value, NSString *fallback) {
    if (![value isKindOfClass:NSString.class]) return fallback;
    NSString *text = [(NSString *)value stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    return text.length ? text : fallback;
}

static BOOL YTMIExec(sqlite3 *db, NSString *sql) {
    return sqlite3_exec(db, sql.UTF8String, NULL, NULL, NULL) == SQLITE_OK;
}

static BOOL YTMIQuickCheck(sqlite3 *db) {
    sqlite3_stmt *stmt = NULL;
    BOOL ok = NO;
    if (sqlite3_prepare_v2(db, "PRAGMA quick_check", -1, &stmt, NULL) == SQLITE_OK &&
        sqlite3_step(stmt) == SQLITE_ROW) {
        const unsigned char *value = sqlite3_column_text(stmt, 0);
        ok = value && strcmp((const char *)value, "ok") == 0;
    }
    sqlite3_finalize(stmt);
    return ok;
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
    NSDictionary *required = @{
        @"item": @[@"item_pid", @"media_type", @"item_artist_pid", @"album_pid", @"album_artist_pid", @"genre_id", @"base_location_id", @"in_my_library"],
        @"item_extra": @[@"item_pid", @"title", @"location", @"file_size", @"total_time_ms", @"location_kind_id"],
        @"item_playback": @[@"item_pid", @"audio_format", @"bit_rate", @"sample_rate"],
        @"item_stats": @[@"item_pid", @"date_accessed"],
        @"item_store": @[@"item_pid", @"sync_id", @"sync_in_my_library"],
        @"item_search": @[@"item_pid", @"search_title", @"search_album", @"search_artist", @"search_album_artist"],
        @"item_artist": @[@"item_artist_pid", @"item_artist", @"sync_id", @"representative_item_pid"],
        @"album_artist": @[@"album_artist_pid", @"album_artist", @"sync_id", @"representative_item_pid"],
        @"album": @[@"album_pid", @"album", @"album_artist_pid", @"sync_id", @"representative_item_pid"],
        @"genre": @[@"genre_id", @"genre", @"representative_item_pid"],
        @"sort_map": @[@"name", @"name_order", @"name_section"],
        @"base_location": @[@"base_location_id", @"path"]
    };
    for (NSString *table in required) {
        for (NSString *column in required[table]) {
            if (!YTMIHasColumn(db, table, column)) return NO;
        }
    }
    return YES;
}

static NSString *YTMIResolvedMusicDirectory(sqlite3 *db, NSString *dbPath) {
    sqlite3_stmt *stmt = NULL;
    NSString *raw = nil;
    if (sqlite3_prepare_v2(db, "SELECT path FROM base_location WHERE base_location_id=3840 LIMIT 1", -1, &stmt, NULL) == SQLITE_OK &&
        sqlite3_step(stmt) == SQLITE_ROW) {
        const unsigned char *value = sqlite3_column_text(stmt, 0);
        if (value) raw = [NSString stringWithUTF8String:(const char *)value];
    }
    sqlite3_finalize(stmt);
    raw = [raw stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (!raw.length) raw = @"iTunes_Control/Music/F00";
    if (![raw hasPrefix:@"/"]) raw = [@"/" stringByAppendingString:raw];
    if (![raw isEqualToString:@"/iTunes_Control"] && ![raw hasPrefix:@"/iTunes_Control/"]) {
        raw = [@"/iTunes_Control" stringByAppendingString:raw];
    }
    if (![raw hasPrefix:@"/iTunes_Control/Music/"]) return nil;
    NSRange control = [dbPath rangeOfString:@"/iTunes_Control/"];
    if (control.location == NSNotFound) return nil;
    NSString *mediaRoot = [dbPath substringToIndex:control.location];
    return [mediaRoot stringByAppendingString:raw];
}

static long long YTMIRandomPID(void) {
    uint64_t value = ((uint64_t)arc4random() << 32) | arc4random();
    value &= 0x7fffffffffffffffULL;
    return (long long)(value ?: 1);
}

static int YTMISectionForName(NSString *name) {
    if (!name.length) return 26;
    unichar c = [[name uppercaseString] characterAtIndex:0];
    return c >= 'A' && c <= 'Z' ? (int)(c - 'A') : 26;
}

static BOOL YTMIBindText(sqlite3_stmt *stmt, int index, NSString *text) {
    return sqlite3_bind_text(stmt, index, text.UTF8String, -1, SQLITE_TRANSIENT) == SQLITE_OK;
}

static long long YTMIEntityPID(sqlite3 *db, NSString *table, NSString *pidColumn, NSString *nameColumn, NSString *name) {
    NSString *sql = [NSString stringWithFormat:@"SELECT %@ FROM %@ WHERE %@=? LIMIT 1", pidColumn, table, nameColumn];
    sqlite3_stmt *stmt = NULL;
    long long pid = 0;
    if (sqlite3_prepare_v2(db, sql.UTF8String, -1, &stmt, NULL) == SQLITE_OK) {
        YTMIBindText(stmt, 1, name);
        if (sqlite3_step(stmt) == SQLITE_ROW) pid = sqlite3_column_int64(stmt, 0);
    }
    sqlite3_finalize(stmt);
    return pid;
}

static BOOL YTMISortInfo(sqlite3 *db, NSString *name, long long *orderOut, int *sectionOut) {
    sqlite3_stmt *stmt = NULL;
    long long order = 0;
    int section = YTMISectionForName(name);
    if (sqlite3_prepare_v2(db, "SELECT name_order,name_section FROM sort_map WHERE name=? LIMIT 1", -1, &stmt, NULL) == SQLITE_OK) {
        YTMIBindText(stmt, 1, name);
        if (sqlite3_step(stmt) == SQLITE_ROW) {
            order = sqlite3_column_int64(stmt, 0);
            section = sqlite3_column_int(stmt, 1);
        }
    }
    sqlite3_finalize(stmt);
    if (!order) {
        if (sqlite3_prepare_v2(db, "SELECT COALESCE(MAX(name_order),0)+1 FROM sort_map", -1, &stmt, NULL) != SQLITE_OK) return NO;
        if (sqlite3_step(stmt) == SQLITE_ROW) order = sqlite3_column_int64(stmt, 0);
        sqlite3_finalize(stmt);
        if (!order) return NO;
        if (sqlite3_prepare_v2(db, "INSERT OR IGNORE INTO sort_map(name,name_order,name_section,sort_key) VALUES(?,?,?,X'')", -1, &stmt, NULL) != SQLITE_OK) return NO;
        YTMIBindText(stmt, 1, name);
        sqlite3_bind_int64(stmt, 2, order);
        sqlite3_bind_int(stmt, 3, section);
        BOOL ok = sqlite3_step(stmt) == SQLITE_DONE;
        sqlite3_finalize(stmt);
        if (!ok) return NO;
    }
    if (orderOut) *orderOut = order;
    if (sectionOut) *sectionOut = section;
    return YES;
}

static BOOL YTMIInsertArtist(sqlite3 *db, long long pid, NSString *name, long long itemPID) {
    sqlite3_stmt *stmt = NULL;
    const char *sql = "INSERT INTO item_artist(item_artist_pid,item_artist,sort_item_artist,series_name,grouping_key,sync_id,keep_local,representative_item_pid) VALUES(?,?,?,'',X'',?,1,?)";
    if (sqlite3_prepare_v2(db, sql, -1, &stmt, NULL) != SQLITE_OK) return NO;
    sqlite3_bind_int64(stmt, 1, pid); YTMIBindText(stmt, 2, name); YTMIBindText(stmt, 3, name);
    sqlite3_bind_int64(stmt, 4, YTMIRandomPID()); sqlite3_bind_int64(stmt, 5, itemPID);
    BOOL ok = sqlite3_step(stmt) == SQLITE_DONE; sqlite3_finalize(stmt); return ok;
}

static BOOL YTMIInsertAlbumArtist(sqlite3 *db, long long pid, NSString *name, long long itemPID, long long sortOrder, int section) {
    sqlite3_stmt *stmt = NULL;
    BOOL hasSort = YTMIHasColumn(db, @"album_artist", @"sort_order");
    BOOL hasNameOrder = YTMIHasColumn(db, @"album_artist", @"name_order");
    NSString *sql;
    if (hasSort && hasNameOrder) sql = @"INSERT INTO album_artist(album_artist_pid,album_artist,sort_album_artist,grouping_key,sync_id,keep_local,representative_item_pid,sort_order,sort_order_section,name_order) VALUES(?,?,?,X'',?,1,?,?,?,?)";
    else if (hasSort) sql = @"INSERT INTO album_artist(album_artist_pid,album_artist,sort_album_artist,grouping_key,sync_id,keep_local,representative_item_pid,sort_order,sort_order_section) VALUES(?,?,?,X'',?,1,?,?,?)";
    else sql = @"INSERT INTO album_artist(album_artist_pid,album_artist,sort_album_artist,grouping_key,sync_id,keep_local,representative_item_pid) VALUES(?,?,?,X'',?,1,?)";
    if (sqlite3_prepare_v2(db, sql.UTF8String, -1, &stmt, NULL) != SQLITE_OK) return NO;
    sqlite3_bind_int64(stmt, 1, pid); YTMIBindText(stmt, 2, name); YTMIBindText(stmt, 3, name);
    sqlite3_bind_int64(stmt, 4, YTMIRandomPID()); sqlite3_bind_int64(stmt, 5, itemPID);
    if (hasSort) { sqlite3_bind_int64(stmt, 6, sortOrder); sqlite3_bind_int(stmt, 7, section); if (hasNameOrder) sqlite3_bind_int64(stmt, 8, sortOrder); }
    BOOL ok = sqlite3_step(stmt) == SQLITE_DONE; sqlite3_finalize(stmt); return ok;
}

static BOOL YTMIInsertAlbum(sqlite3 *db, long long pid, NSString *name, long long albumArtistPID, long long itemPID) {
    sqlite3_stmt *stmt = NULL;
    const char *sql = "INSERT INTO album(album_pid,album,sort_album,album_artist_pid,grouping_key,album_year,keep_local,sync_id,representative_item_pid) VALUES(?,?,?, ?,X'',0,1,?,?)";
    if (sqlite3_prepare_v2(db, sql, -1, &stmt, NULL) != SQLITE_OK) return NO;
    sqlite3_bind_int64(stmt, 1, pid); YTMIBindText(stmt, 2, name); YTMIBindText(stmt, 3, name);
    sqlite3_bind_int64(stmt, 4, albumArtistPID); sqlite3_bind_int64(stmt, 5, YTMIRandomPID()); sqlite3_bind_int64(stmt, 6, itemPID);
    BOOL ok = sqlite3_step(stmt) == SQLITE_DONE; sqlite3_finalize(stmt); return ok;
}

static BOOL YTMIInsertGenre(sqlite3 *db, long long pid, NSString *name, long long itemPID) {
    sqlite3_stmt *stmt = NULL;
    if (sqlite3_prepare_v2(db, "INSERT INTO genre(genre_id,genre,grouping_key,representative_item_pid) VALUES(?,?,X'',?)", -1, &stmt, NULL) != SQLITE_OK) return NO;
    sqlite3_bind_int64(stmt, 1, pid); YTMIBindText(stmt, 2, name); sqlite3_bind_int64(stmt, 3, itemPID);
    BOOL ok = sqlite3_step(stmt) == SQLITE_DONE; sqlite3_finalize(stmt); return ok;
}

static BOOL YTMIInsertCompleteItem(sqlite3 *db, long long itemPID, NSString *title, NSString *artist, NSString *album, NSString *genre, NSString *filename, long long fileSize, long long durationMs, long long now) {
    long long titleOrder=0, artistOrder=0, albumOrder=0, genreOrder=0;
    int titleSection=26, artistSection=26, albumSection=26, genreSection=26;
    if (!YTMISortInfo(db,title,&titleOrder,&titleSection) || !YTMISortInfo(db,artist,&artistOrder,&artistSection) ||
        !YTMISortInfo(db,album,&albumOrder,&albumSection) || !YTMISortInfo(db,genre,&genreOrder,&genreSection)) return NO;

    long long artistPID = YTMIEntityPID(db,@"item_artist",@"item_artist_pid",@"item_artist",artist);
    if (!artistPID) { artistPID=YTMIRandomPID(); if (!YTMIInsertArtist(db,artistPID,artist,itemPID)) return NO; }
    long long albumArtistPID = YTMIEntityPID(db,@"album_artist",@"album_artist_pid",@"album_artist",artist);
    if (!albumArtistPID) { albumArtistPID=YTMIRandomPID(); if (!YTMIInsertAlbumArtist(db,albumArtistPID,artist,itemPID,artistOrder,artistSection)) return NO; }
    long long albumPID = YTMIEntityPID(db,@"album",@"album_pid",@"album",album);
    if (!albumPID) { albumPID=YTMIRandomPID(); if (!YTMIInsertAlbum(db,albumPID,album,albumArtistPID,itemPID)) return NO; }
    long long genrePID = YTMIEntityPID(db,@"genre",@"genre_id",@"genre",genre);
    if (!genrePID) { genrePID=YTMIRandomPID(); if (!YTMIInsertGenre(db,genrePID,genre,itemPID)) return NO; }

    sqlite3_stmt *stmt=NULL;
    const char *itemSQL =
    "INSERT INTO item(item_pid,media_type,title_order,title_order_section,item_artist_pid,item_artist_order,item_artist_order_section,series_name_order,series_name_order_section,album_pid,album_order,album_order_section,album_artist_pid,album_artist_order,album_artist_order_section,composer_pid,composer_order,composer_order_section,genre_id,genre_order,genre_order_section,disc_number,track_number,episode_sort_id,base_location_id,remote_location_id,exclude_from_shuffle,keep_local,keep_local_status,keep_local_status_reason,keep_local_constraints,in_my_library,is_compilation,date_added,show_composer,is_music_show,date_downloaded,download_source_container_pid) VALUES(?,8,?,?,?,?,?,0,26,?,?,?,?,?,?,0,0,26,?,?,?,1,1,1,3840,0,0,1,2,0,0,1,0,?,0,0,?,0)";
    if(sqlite3_prepare_v2(db,itemSQL,-1,&stmt,NULL)!=SQLITE_OK)return NO;
    int i=1; sqlite3_bind_int64(stmt,i++,itemPID); sqlite3_bind_int64(stmt,i++,titleOrder); sqlite3_bind_int(stmt,i++,titleSection);
    sqlite3_bind_int64(stmt,i++,artistPID); sqlite3_bind_int64(stmt,i++,artistOrder); sqlite3_bind_int(stmt,i++,artistSection);
    sqlite3_bind_int64(stmt,i++,albumPID); sqlite3_bind_int64(stmt,i++,albumOrder); sqlite3_bind_int(stmt,i++,albumSection);
    sqlite3_bind_int64(stmt,i++,albumArtistPID); sqlite3_bind_int64(stmt,i++,artistOrder); sqlite3_bind_int(stmt,i++,artistSection);
    sqlite3_bind_int64(stmt,i++,genrePID); sqlite3_bind_int64(stmt,i++,genreOrder); sqlite3_bind_int(stmt,i++,genreSection);
    sqlite3_bind_int64(stmt,i++,now); sqlite3_bind_int64(stmt,i++,now);
    BOOL ok=sqlite3_step(stmt)==SQLITE_DONE; sqlite3_finalize(stmt); if(!ok)return NO;

    const char *extraSQL="INSERT INTO item_extra(item_pid,title,sort_title,disc_count,track_count,total_time_ms,year,location,file_size,integrity,is_audible_audio_book,date_modified,media_kind,content_rating,content_rating_level,is_user_disabled,bpm,genius_id,location_kind_id,copyright) VALUES(?,?,?,1,1,?,0,?,?,X'',0,?,1,0,0,0,0,0,42,'')";
    if(sqlite3_prepare_v2(db,extraSQL,-1,&stmt,NULL)!=SQLITE_OK)return NO;
    sqlite3_bind_int64(stmt,1,itemPID);YTMIBindText(stmt,2,title);YTMIBindText(stmt,3,title);sqlite3_bind_int64(stmt,4,durationMs);YTMIBindText(stmt,5,filename);sqlite3_bind_int64(stmt,6,fileSize);sqlite3_bind_int64(stmt,7,now);
    ok=sqlite3_step(stmt)==SQLITE_DONE;sqlite3_finalize(stmt);if(!ok)return NO;

    if(sqlite3_prepare_v2(db,"INSERT INTO item_playback(item_pid,audio_format,bit_rate,codec_type,codec_subtype,data_kind,duration,has_video,relative_volume,sample_rate) VALUES(?,1633772320,256,0,0,0,0,0,0,44100.0)",-1,&stmt,NULL)!=SQLITE_OK)return NO;
    sqlite3_bind_int64(stmt,1,itemPID);ok=sqlite3_step(stmt)==SQLITE_DONE;sqlite3_finalize(stmt);if(!ok)return NO;
    if(sqlite3_prepare_v2(db,"INSERT INTO item_stats(item_pid,date_accessed) VALUES(?,?)",-1,&stmt,NULL)!=SQLITE_OK)return NO;
    sqlite3_bind_int64(stmt,1,itemPID);sqlite3_bind_int64(stmt,2,now);ok=sqlite3_step(stmt)==SQLITE_DONE;sqlite3_finalize(stmt);if(!ok)return NO;
    if(sqlite3_prepare_v2(db,"INSERT INTO item_store(item_pid,sync_id,sync_in_my_library,is_subscription,store_saga_id,cloud_status,cloud_asset_available,cloud_in_my_library,playback_endpoint_type,cloud_playback_endpoint_type) VALUES(?,?,1,0,0,0,0,0,0,0)",-1,&stmt,NULL)!=SQLITE_OK)return NO;
    sqlite3_bind_int64(stmt,1,itemPID);sqlite3_bind_int64(stmt,2,YTMIRandomPID());ok=sqlite3_step(stmt)==SQLITE_DONE;sqlite3_finalize(stmt);if(!ok)return NO;
    if(sqlite3_prepare_v2(db,"INSERT INTO item_search(item_pid,search_title,search_album,search_artist,search_composer,search_album_artist) VALUES(?,?,?,?,0,?)",-1,&stmt,NULL)!=SQLITE_OK)return NO;
    sqlite3_bind_int64(stmt,1,itemPID);sqlite3_bind_int64(stmt,2,titleOrder);sqlite3_bind_int64(stmt,3,albumOrder);sqlite3_bind_int64(stmt,4,artistOrder);sqlite3_bind_int64(stmt,5,artistOrder);ok=sqlite3_step(stmt)==SQLITE_DONE;sqlite3_finalize(stmt);if(!ok)return NO;
    if(YTMIHasColumn(db,@"item_video",@"item_pid")) { if(sqlite3_prepare_v2(db,"INSERT OR REPLACE INTO item_video(item_pid,hls_asset_traits) VALUES(?,0)",-1,&stmt,NULL)==SQLITE_OK){sqlite3_bind_int64(stmt,1,itemPID);ok=sqlite3_step(stmt)==SQLITE_DONE;sqlite3_finalize(stmt);if(!ok)return NO;} }
    if(YTMIHasColumn(db,@"chapter",@"item_pid")) { if(sqlite3_prepare_v2(db,"INSERT OR REPLACE INTO chapter(item_pid) VALUES(?)",-1,&stmt,NULL)==SQLITE_OK){sqlite3_bind_int64(stmt,1,itemPID);ok=sqlite3_step(stmt)==SQLITE_DONE;sqlite3_finalize(stmt);if(!ok)return NO;} }
    return YES;
}

static BOOL YTMICopyDatabase(sqlite3 *source, NSString *destination) {
    sqlite3 *target=NULL;
    if(sqlite3_open_v2(destination.UTF8String,&target,SQLITE_OPEN_READWRITE|SQLITE_OPEN_CREATE,NULL)!=SQLITE_OK){if(target)sqlite3_close(target);return NO;}
    sqlite3_backup *backup=sqlite3_backup_init(target,"main",source,"main");
    if(!backup){sqlite3_close(target);return NO;}
    int step=sqlite3_backup_step(backup,-1);int finish=sqlite3_backup_finish(backup);
    BOOL ok=step==SQLITE_DONE&&finish==SQLITE_OK&&YTMIQuickCheck(target);
    sqlite3_close(target);return ok;
}

static void YTMINotifyMusicLibrary(void) {
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(), CFSTR("com.apple.itunes-mobdev.syncDidFinish"), NULL, NULL, true);
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(), CFSTR("com.apple.mobileipod.librarychanged"), NULL, NULL, true);
}

@implementation YTMIMusicDatabaseImporter
- (BOOL)importAudioAtURL:(NSURL *)audioURL metadata:(NSDictionary *)metadata trace:(NSMutableArray *)trace error:(NSError **)error {
    NSFileManager *fm=NSFileManager.defaultManager;
    if(!audioURL.isFileURL||![fm fileExistsAtPath:audioURL.path]){YTMITrace(trace,@"db.source.missing");if(error)*error=YTMIDBError(19,@"The prepared audio file is unavailable.");return NO;}
    YTMITrace(trace,@"db.source.present");
    NSString *dbPath=@"/var/mobile/Media/iTunes_Control/iTunes/MediaLibrary.sqlitedb";
    if(![fm fileExistsAtPath:dbPath])dbPath=@"/private/var/mobile/Media/iTunes_Control/iTunes/MediaLibrary.sqlitedb";
    if(![fm fileExistsAtPath:dbPath]){YTMITrace(trace,@"db.library.missing");if(error)*error=YTMIDBError(70,@"The local Music database is unavailable.");return NO;}
    YTMITrace(trace,@"db.library.present");

    NSString *dbDir=dbPath.stringByDeletingLastPathComponent;
    sqlite3 *live=NULL;
    if(sqlite3_open_v2(dbPath.UTF8String,&live,SQLITE_OPEN_READONLY|SQLITE_OPEN_FULLMUTEX,NULL)!=SQLITE_OK){
        if(live)sqlite3_close(live);
        YTMITrace(trace,@"db.open.failed");
        if(error)*error=YTMIDBError(73,@"The Music database could not be opened safely.");
        return NO;
    }
    YTMITrace(trace,@"db.open.complete");
    NSString *musicDir=YTMIResolvedMusicDirectory(live,dbPath);
    if(!musicDir.length||![fm createDirectoryAtPath:musicDir withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions:@0755} error:nil]){
        sqlite3_close(live);
        YTMITrace(trace,@"db.location.failed");
        if(error)*error=YTMIDBError(71,@"The Music media folder could not be resolved safely.");
        return NO;
    }
    YTMITrace(trace,@"db.location.resolved");

    NSString *token=[NSUUID.UUID.UUIDString stringByReplacingOccurrencesOfString:@"-" withString:@""].lowercaseString;
    NSString *filename=[token stringByAppendingPathExtension:@"m4a"];
    NSString *destination=[musicDir stringByAppendingPathComponent:filename];
    if(![fm copyItemAtPath:audioURL.path toPath:destination error:nil]){
        sqlite3_close(live);
        YTMITrace(trace,@"db.payload.copy-failed");
        if(error)*error=YTMIDBError(72,@"The audio could not be copied into Music storage.");
        return NO;
    }
    YTMITrace(trace,@"db.payload.copied");
    chmod(destination.fileSystemRepresentation,0644);

    NSDictionary *attrs=[fm attributesOfItemAtPath:destination error:nil];
    long long fileSize=[attrs[NSFileSize] longLongValue];
    AVURLAsset *asset=[AVURLAsset URLAssetWithURL:[NSURL fileURLWithPath:destination] options:nil];
    double seconds=CMTimeGetSeconds(asset.duration);
    BOOL hasAudio=[asset tracksWithMediaType:AVMediaTypeAudio].count>0;
    if(fileSize<=0||!hasAudio||!isfinite(seconds)||seconds<=0.25){
        sqlite3_close(live);
        [fm removeItemAtPath:destination error:nil];
        YTMITrace(trace,@"db.payload.precheck-failed");
        if(error)*error=YTMIDBError(80,@"The prepared audio is not a playable Music file.");
        return NO;
    }
    YTMITrace(trace,@"db.payload.precheck-valid");
    long long durationMs=(long long)(seconds*1000.0),now=(long long)NSDate.date.timeIntervalSince1970,itemPID=YTMIRandomPID();
    NSString *title=YTMISafeText(metadata[YTMIJobTitleKey],@"YouTube Audio");
    NSString *artist=YTMISafeText(metadata[YTMIJobArtistKey],@"YouTube");
    NSString *album=YTMISafeText(metadata[YTMIJobAlbumKey],@"YT Music Importer");
    NSString *genre=@"YouTube";

    NSString *workDir=@"/var/mobile/Media/YTMusicImporter/Database";
    [fm createDirectoryAtPath:workDir withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions:@0700} error:nil];
    NSString *stage=[dbDir stringByAppendingPathComponent:@".ytmi-stage.sqlite"];
    NSString *backup=[workDir stringByAppendingPathComponent:@"MediaLibrary-before-import.sqlite"];
    [fm removeItemAtPath:stage error:nil];[fm removeItemAtPath:backup error:nil];

    BOOL copied=YTMICopyDatabase(live,stage)&&YTMICopyDatabase(live,backup);sqlite3_close(live);
    if(!copied){YTMITrace(trace,@"db.snapshot.failed");[fm removeItemAtPath:stage error:nil];[fm removeItemAtPath:destination error:nil];if(error)*error=YTMIDBError(75,@"A protected database snapshot could not be created.");return NO;}
    YTMITrace(trace,@"db.snapshot.complete");
    chmod(backup.fileSystemRepresentation,0600);

    sqlite3 *db=NULL;
    if(sqlite3_open_v2(stage.UTF8String,&db,SQLITE_OPEN_READWRITE|SQLITE_OPEN_FULLMUTEX,NULL)!=SQLITE_OK){YTMITrace(trace,@"db.stage.open-failed");if(db)sqlite3_close(db);[fm removeItemAtPath:stage error:nil];[fm removeItemAtPath:destination error:nil];if(error)*error=YTMIDBError(73,@"The staged Music database could not be opened.");return NO;}
    sqlite3_busy_timeout(db,8000);
    BOOL ok=YTMIValidateSchema(db)&&YTMIQuickCheck(db);
    YTMITrace(trace,ok?@"db.schema.valid":@"db.schema.invalid");
    if(ok)ok=YTMIExec(db,@"BEGIN IMMEDIATE");
    if(ok)ok=YTMIExec(db,@"INSERT OR IGNORE INTO base_location(base_location_id,path) VALUES(3840,'iTunes_Control/Music/F00')");
    if(ok)ok=YTMIInsertCompleteItem(db,itemPID,title,artist,album,genre,filename,fileSize,durationMs,now);
    if(ok)ok=YTMIExec(db,@"COMMIT");else YTMIExec(db,@"ROLLBACK");
    if(ok)YTMITrace(trace,@"db.transaction.committed");
    if(ok)YTMIExec(db,@"PRAGMA wal_checkpoint(TRUNCATE)");
    if(ok)YTMIExec(db,@"PRAGMA journal_mode=DELETE");
    if(ok)ok=YTMIQuickCheck(db);
    sqlite3_close(db);
    if(!ok){YTMITrace(trace,@"db.transaction.failed");[fm removeItemAtPath:stage error:nil];[fm removeItemAtPath:destination error:nil];if(error)*error=YTMIDBError(76,@"The complete Music database transaction was rejected.");return NO;}
    YTMITrace(trace,@"db.stage.integrity-valid");

    NSDictionary *dbAttrs=[fm attributesOfItemAtPath:dbPath error:nil];
    [fm removeItemAtPath:[dbPath stringByAppendingString:@"-wal"] error:nil];
    [fm removeItemAtPath:[dbPath stringByAppendingString:@"-shm"] error:nil];
    NSURL *dbURL=[NSURL fileURLWithPath:dbPath],*stageURL=[NSURL fileURLWithPath:stage];
    NSURL *resultURL=nil;
    BOOL replaced=[fm replaceItemAtURL:dbURL withItemAtURL:stageURL backupItemName:nil options:0 resultingItemURL:&resultURL error:nil];
    if(!replaced){
        YTMITrace(trace,@"db.replacement.failed");
        [fm removeItemAtPath:stage error:nil];[fm removeItemAtPath:destination error:nil];
        if(error)*error=YTMIDBError(78,@"The protected Music database replacement failed.");return NO;
    }
    YTMITrace(trace,@"db.replacement.complete");
    if(dbAttrs)[fm setAttributes:dbAttrs ofItemAtPath:dbPath error:nil];

    sqlite3 *verify=NULL;BOOL verified=sqlite3_open_v2(dbPath.UTF8String,&verify,SQLITE_OPEN_READONLY,NULL)==SQLITE_OK;
    sqlite3_stmt *stmt=NULL;if(verified&&sqlite3_prepare_v2(verify,"SELECT item_extra.title,item_artist.item_artist,album.album FROM item JOIN item_extra USING(item_pid) JOIN item_store USING(item_pid) JOIN item_search USING(item_pid) JOIN item_artist ON item.item_artist_pid=item_artist.item_artist_pid JOIN album ON item.album_pid=album.album_pid WHERE item.item_pid=? AND item_extra.location=?",-1,&stmt,NULL)==SQLITE_OK){sqlite3_bind_int64(stmt,1,itemPID);YTMIBindText(stmt,2,filename);if(sqlite3_step(stmt)==SQLITE_ROW){NSString *storedTitle=sqlite3_column_text(stmt,0)?[NSString stringWithUTF8String:(const char *)sqlite3_column_text(stmt,0)]:@"";NSString *storedArtist=sqlite3_column_text(stmt,1)?[NSString stringWithUTF8String:(const char *)sqlite3_column_text(stmt,1)]:@"";NSString *storedAlbum=sqlite3_column_text(stmt,2)?[NSString stringWithUTF8String:(const char *)sqlite3_column_text(stmt,2)]:@"";verified=[storedTitle isEqualToString:title]&&[storedArtist isEqualToString:artist]&&[storedAlbum isEqualToString:album];YTMITrace(trace,[storedTitle isEqualToString:title]?@"db.metadata.title-match":@"db.metadata.title-mismatch");YTMITrace(trace,[storedArtist isEqualToString:artist]?@"db.metadata.artist-match":@"db.metadata.artist-mismatch");YTMITrace(trace,[storedAlbum isEqualToString:album]?@"db.metadata.album-match":@"db.metadata.album-mismatch");}else verified=NO;}else verified=NO;
    sqlite3_finalize(stmt);if(verify)sqlite3_close(verify);
    if(!verified){YTMITrace(trace,@"db.record.verify-failed");if(error)*error=YTMIDBError(79,@"The replaced Music database could not verify the local record.");return NO;}
    YTMITrace(trace,@"db.record.verified");

    NSDictionary *postAttrs=[fm attributesOfItemAtPath:destination error:nil];
    AVURLAsset *postAsset=[AVURLAsset URLAssetWithURL:[NSURL fileURLWithPath:destination] options:nil];
    BOOL postPayload=[postAttrs[NSFileSize] longLongValue]>0&&[fm isReadableFileAtPath:destination]&&[postAsset tracksWithMediaType:AVMediaTypeAudio].count>0&&CMTimeGetSeconds(postAsset.duration)>0.25;
    if(!postPayload){YTMITrace(trace,@"db.payload.postcheck-failed");if(error)*error=YTMIDBError(81,@"The Music payload did not survive the database replacement.");return NO;}
    YTMITrace(trace,@"db.payload.postcheck-valid");

    YTMINotifyMusicLibrary();
    YTMITrace(trace,@"db.refresh.sent");
    return YES;
}
@end
