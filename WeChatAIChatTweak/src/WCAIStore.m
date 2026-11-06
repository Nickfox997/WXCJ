//
//  WCAIStore.m
//  并发策略：所有读写走唯一串行队列，杜绝多线程读写崩溃（不用自造锁）。
//

#import "WCAICommon.h"
#import "WCAIStore.h"

@implementation WCAIContact
- (instancetype)init {
    if ((self = [super init])) {
        _enable = 1; _flirtLevel = @"L1"; _stage = @"初识";
        _maxShort = 12; _isTest = 0;
        _myPrompt = @""; _herPrompt = @""; _flavorCard = @""; _nick = @"";
    }
    return self;
}
@end

@implementation WCAIStore {
    sqlite3 *_db;
    dispatch_queue_t _q;
    NSString *_path;
    NSInteger _rowSinceBackup;
}

+ (instancetype)shared {
    static WCAIStore *s; static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [WCAIStore new]; });
    return s;
}

- (instancetype)init {
    if ((self = [super init])) {
        _q = dispatch_queue_create("wcai.store", DISPATCH_QUEUE_SERIAL);
    }
    return self;
}

#pragma mark - 打开与建表

- (NSString *)dbPath { return _path; }

- (BOOL)openDefault {
    NSString *base = [NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory,
                                                          NSUserDomainMask, YES) firstObject];
    NSString *dir = [base stringByAppendingPathComponent:@"WCAI"];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir
                              withIntermediateDirectories:YES attributes:nil error:nil];
    return [self openAt:[dir stringByAppendingPathComponent:@"wcai.db"]];
}

- (BOOL)openAt:(NSString *)path {
    __block BOOL ok = NO;
    dispatch_sync(_q, ^{
        if (self->_db) return;
        self->_path = path;
        if (sqlite3_open(path.UTF8String, &self->_db) != SQLITE_OK) {
            self->_db = NULL; return;
        }
        sqlite3_busy_timeout(self->_db, 3000);
        char *err = NULL;
        const char *sql =
        "PRAGMA journal_mode=WAL;"
        "PRAGMA synchronous=NORMAL;"

        "CREATE TABLE IF NOT EXISTS contact("
        " wxid TEXT PRIMARY KEY, nick TEXT, enable INTEGER DEFAULT 1,"
        " flirt_level TEXT DEFAULT 'L1', relation_stage TEXT DEFAULT '初识',"
        " my_prompt TEXT, her_prompt TEXT, flavor_card TEXT,"
        " max_short_context INTEGER DEFAULT 12, is_test INTEGER DEFAULT 0,"
        " create_ts INTEGER);"

        "CREATE TABLE IF NOT EXISTS chat_log("
        " id INTEGER PRIMARY KEY AUTOINCREMENT, wxid TEXT NOT NULL,"
        " is_self INTEGER NOT NULL, content TEXT, msg_type TEXT DEFAULT '文本', ts INTEGER NOT NULL);"
        "CREATE INDEX IF NOT EXISTS idx_chat_wxid_ts ON chat_log(wxid, ts DESC);"
        "CREATE INDEX IF NOT EXISTS idx_chat_ts ON chat_log(ts);"

        "CREATE TABLE IF NOT EXISTS long_memory("
        " id INTEGER PRIMARY KEY AUTOINCREMENT, wxid TEXT NOT NULL, memo_type TEXT,"
        " content TEXT, source TEXT DEFAULT 'auto', weight INTEGER DEFAULT 3,"
        " valid INTEGER DEFAULT 1, create_ts INTEGER);"
        "CREATE INDEX IF NOT EXISTS idx_mem_wxid ON long_memory(wxid, valid, weight DESC);"

        "CREATE TABLE IF NOT EXISTS memory_pending("
        " id INTEGER PRIMARY KEY AUTOINCREMENT, wxid TEXT, memo_type TEXT, content TEXT,"
        " weight INTEGER DEFAULT 3, conflict_with INTEGER DEFAULT 0, create_ts INTEGER);"

        // 注意：主号构建下 config 表刻意不含 run_mode / auto_* 任何列
        "CREATE TABLE IF NOT EXISTS config(k TEXT PRIMARY KEY, v TEXT);"

        "CREATE TABLE IF NOT EXISTS word_collection("
        " id INTEGER PRIMARY KEY AUTOINCREMENT, wxid TEXT, content TEXT, tag TEXT, ts INTEGER);"

        "CREATE TABLE IF NOT EXISTS run_log("
        " id INTEGER PRIMARY KEY AUTOINCREMENT, wxid TEXT, origin_text TEXT, ai_reply TEXT,"
        " mode TEXT, send_status TEXT, risk_flag TEXT, ts INTEGER);"
        "CREATE INDEX IF NOT EXISTS idx_runlog_ts ON run_log(ts DESC);"

        "CREATE TABLE IF NOT EXISTS schema_ver(v INTEGER);";

        if (sqlite3_exec(self->_db, sql, NULL, NULL, &err) == SQLITE_OK) ok = YES;
        else WCAILog(@"建表失败: %s", err ?: "?");
        if (err) sqlite3_free(err);
    });
    return ok;
}

#pragma mark - 基础执行

- (void)exec:(void (^)(sqlite3 *db))blk {
    if (!blk) return;
    dispatch_sync(_q, ^{ if (self->_db) blk(self->_db); });
}

static NSString *WCAICol(sqlite3_stmt *st, int i) {
    const unsigned char *t = sqlite3_column_text(st, i);
    return t ? [NSString stringWithUTF8String:(const char *)t] : @"";
}

#pragma mark - 聊天流水

- (void)appendChat:(NSString *)wxid self:(BOOL)isSelf
              text:(NSString *)text type:(NSString *)type ts:(NSTimeInterval)ts {
    if (wxid.length == 0 || text == nil) return;
    [self exec:^(sqlite3 *db) {
        sqlite3_stmt *st = NULL;
        const char *sql = "INSERT INTO chat_log(wxid,is_self,content,msg_type,ts) VALUES(?,?,?,?,?)";
        if (sqlite3_prepare_v2(db, sql, -1, &st, NULL) == SQLITE_OK) {
            sqlite3_bind_text(st, 1, wxid.UTF8String, -1, SQLITE_TRANSIENT);
            sqlite3_bind_int(st, 2, isSelf ? 1 : 0);
            sqlite3_bind_text(st, 3, text.UTF8String, -1, SQLITE_TRANSIENT);
            sqlite3_bind_text(st, 4, (type ?: @"文本").UTF8String, -1, SQLITE_TRANSIENT);
            sqlite3_bind_int64(st, 5, (sqlite3_int64)ts);
            sqlite3_step(st);
            sqlite3_finalize(st);
        }
        // run_log 保留上限：2 万行裁剪 5000
        self->_rowSinceBackup++;
        if (self->_rowSinceBackup >= 200) {
            self->_rowSinceBackup = 0;
            sqlite3_exec(db, "DELETE FROM run_log WHERE id <= (SELECT MAX(id)-20000 FROM run_log);",
                         NULL, NULL, NULL);
            dispatch_async(dispatch_get_global_queue(0, 0), ^{ [self writeBackupSnapshot]; });
        }
    }];
}

- (NSInteger)chatCount:(NSString *)wxid {
    __block NSInteger n = 0;
    [self exec:^(sqlite3 *db) {
        sqlite3_stmt *st = NULL;
        if (sqlite3_prepare_v2(db, "SELECT COUNT(1) FROM chat_log WHERE wxid=?", -1, &st, NULL) == SQLITE_OK) {
            sqlite3_bind_text(st, 1, wxid.UTF8String, -1, SQLITE_TRANSIENT);
            if (sqlite3_step(st) == SQLITE_ROW) n = sqlite3_column_int(st, 0);
            sqlite3_finalize(st);
        }
    }];
    return n;
}

- (BOOL)hasChatHistory:(NSString *)wxid { return [self chatCount:wxid] > 0; }

- (NSArray<NSDictionary *> *)recentChats:(NSString *)wxid limit:(NSInteger)limit {
    NSMutableArray *out = [NSMutableArray array];
    [self exec:^(sqlite3 *db) {
        sqlite3_stmt *st = NULL;
        const char *sql = "SELECT is_self,content,msg_type,ts FROM chat_log "
                          "WHERE wxid=? ORDER BY ts DESC, id DESC LIMIT ?";
        if (sqlite3_prepare_v2(db, sql, -1, &st, NULL) == SQLITE_OK) {
            sqlite3_bind_text(st, 1, wxid.UTF8String, -1, SQLITE_TRANSIENT);
            sqlite3_bind_int(st, 2, (int)limit);
            while (sqlite3_step(st) == SQLITE_ROW) {
                [out addObject:@{ @"is_self": @(sqlite3_column_int(st, 0)),
                                  @"content": WCAICol(st, 1),
                                  @"msg_type": WCAICol(st, 2),
                                  @"ts": @(sqlite3_column_int64(st, 3)) }];
            }
            sqlite3_finalize(st);
        }
    }];
    return [[out reverseObjectEnumerator] allObjects];   // 时间正序
}

#pragma mark - 联系人

- (WCAIContact *)contact:(NSString *)wxid {
    __block WCAIContact *c = nil;
    [self exec:^(sqlite3 *db) {
        sqlite3_stmt *st = NULL;
        const char *sql = "SELECT wxid,nick,enable,flirt_level,relation_stage,"
                          "my_prompt,her_prompt,flavor_card,max_short_context,is_test "
                          "FROM contact WHERE wxid=?";
        if (sqlite3_prepare_v2(db, sql, -1, &st, NULL) == SQLITE_OK) {
            sqlite3_bind_text(st, 1, wxid.UTF8String, -1, SQLITE_TRANSIENT);
            if (sqlite3_step(st) == SQLITE_ROW) {
                c = [WCAIContact new];
                c.wxid = WCAICol(st, 0); c.nick = WCAICol(st, 1);
                c.enable = sqlite3_column_int(st, 2);
                c.flirtLevel = WCAICol(st, 3); c.stage = WCAICol(st, 4);
                c.myPrompt = WCAICol(st, 5); c.herPrompt = WCAICol(st, 6);
                c.flavorCard = WCAICol(st, 7);
                c.maxShort = sqlite3_column_int(st, 8);
                c.isTest = sqlite3_column_int(st, 9);
            }
            sqlite3_finalize(st);
        }
    }];
    if (!c) {
        c = [WCAIContact new];
        c.wxid = wxid ?: @"";
    }
    return c;
}

- (NSArray<WCAIContact *> *)allContacts {
    NSMutableArray *out = [NSMutableArray array];
    [self exec:^(sqlite3 *db) {
        sqlite3_stmt *st = NULL;
        if (sqlite3_prepare_v2(db, "SELECT wxid FROM contact ORDER BY create_ts DESC", -1, &st, NULL) == SQLITE_OK) {
            while (sqlite3_step(st) == SQLITE_ROW) {
                NSString *wxid = WCAICol(st, 0);
                if (wxid.length) [out addObject:wxid];
            }
            sqlite3_finalize(st);
        }
    }];
    NSMutableArray *res = [NSMutableArray array];
    for (NSString *w in out) [res addObject:[self contact:w]];
    return res;
}

- (void)saveContact:(WCAIContact *)c {
    if (c.wxid.length == 0) return;
    [self exec:^(sqlite3 *db) {
        sqlite3_stmt *st = NULL;
        const char *sql =
            "INSERT INTO contact(wxid,nick,enable,flirt_level,relation_stage,my_prompt,"
            "her_prompt,flavor_card,max_short_context,is_test,create_ts) "
            "VALUES(?,?,?,?,?,?,?,?,?,?,?) "
            "ON CONFLICT(wxid) DO UPDATE SET nick=excluded.nick,enable=excluded.enable,"
            "flirt_level=excluded.flirt_level,relation_stage=excluded.relation_stage,"
            "my_prompt=excluded.my_prompt,her_prompt=excluded.her_prompt,"
            "flavor_card=excluded.flavor_card,max_short_context=excluded.max_short_context,"
            "is_test=excluded.is_test";
        if (sqlite3_prepare_v2(db, sql, -1, &st, NULL) == SQLITE_OK) {
            sqlite3_bind_text(st, 1, c.wxid.UTF8String, -1, SQLITE_TRANSIENT);
            sqlite3_bind_text(st, 2, (c.nick ?: @"").UTF8String, -1, SQLITE_TRANSIENT);
            sqlite3_bind_int(st, 3, (int)c.enable);
            sqlite3_bind_text(st, 4, (c.flirtLevel ?: @"L1").UTF8String, -1, SQLITE_TRANSIENT);
            sqlite3_bind_text(st, 5, (c.stage ?: @"初识").UTF8String, -1, SQLITE_TRANSIENT);
            sqlite3_bind_text(st, 6, (c.myPrompt ?: @"").UTF8String, -1, SQLITE_TRANSIENT);
            sqlite3_bind_text(st, 7, (c.herPrompt ?: @"").UTF8String, -1, SQLITE_TRANSIENT);
            sqlite3_bind_text(st, 8, (c.flavorCard ?: @"").UTF8String, -1, SQLITE_TRANSIENT);
            sqlite3_bind_int(st, 9, (int)(c.maxShort > 0 ? c.maxShort : 12));
            sqlite3_bind_int(st, 10, 0);   // 主号构建：is_test 恒 0
            sqlite3_bind_int64(st, 11, (sqlite3_int64)[[NSDate date] timeIntervalSince1970]);
            sqlite3_step(st);
            sqlite3_finalize(st);
        }
    }];
}

#pragma mark - 记忆

- (NSArray<NSDictionary *> *)activeMemories:(NSString *)wxid {
    NSMutableArray *out = [NSMutableArray array];
    [self exec:^(sqlite3 *db) {
        sqlite3_stmt *st = NULL;
        const char *sql = "SELECT memo_type,content,weight FROM long_memory "
                          "WHERE wxid=? AND valid=1 ORDER BY weight DESC, id DESC LIMIT 30";
        if (sqlite3_prepare_v2(db, sql, -1, &st, NULL) == SQLITE_OK) {
            sqlite3_bind_text(st, 1, wxid.UTF8String, -1, SQLITE_TRANSIENT);
            while (sqlite3_step(st) == SQLITE_ROW) {
                [out addObject:@{ @"type": WCAICol(st, 0),
                                  @"content": WCAICol(st, 1),
                                  @"weight": @(sqlite3_column_int(st, 2)) }];
            }
            sqlite3_finalize(st);
        }
    }];
    return out;
}

- (void)addPending:(NSString *)wxid type:(NSString *)type
           content:(NSString *)content weight:(NSInteger)w {
    if (content.length == 0) return;
    [self exec:^(sqlite3 *db) {
        sqlite3_stmt *st = NULL;
        const char *sql = "INSERT INTO memory_pending(wxid,memo_type,content,weight,create_ts)"
                          " VALUES(?,?,?,?,?)";
        if (sqlite3_prepare_v2(db, sql, -1, &st, NULL) == SQLITE_OK) {
            sqlite3_bind_text(st, 1, wxid.UTF8String, -1, SQLITE_TRANSIENT);
            sqlite3_bind_text(st, 2, (type ?: @"个人信息").UTF8String, -1, SQLITE_TRANSIENT);
            sqlite3_bind_text(st, 3, content.UTF8String, -1, SQLITE_TRANSIENT);
            sqlite3_bind_int(st, 4, (int)(w > 0 ? w : 3));
            sqlite3_bind_int64(st, 5, (sqlite3_int64)[[NSDate date] timeIntervalSince1970]);
            sqlite3_step(st);
            sqlite3_finalize(st);
        }
    }];
}

#pragma mark - 配置

- (NSString *)config:(NSString *)key {
    __block NSString *v = nil;
    [self exec:^(sqlite3 *db) {
        sqlite3_stmt *st = NULL;
        if (sqlite3_prepare_v2(db, "SELECT v FROM config WHERE k=?", -1, &st, NULL) == SQLITE_OK) {
            sqlite3_bind_text(st, 1, key.UTF8String, -1, SQLITE_TRANSIENT);
            if (sqlite3_step(st) == SQLITE_ROW) v = WCAICol(st, 0);
            sqlite3_finalize(st);
        }
    }];
    return v;
}

- (void)setConfig:(NSString *)key value:(NSString *)v {
    if (key.length == 0) return;
    [self exec:^(sqlite3 *db) {
        sqlite3_stmt *st = NULL;
        const char *sql = "INSERT INTO config(k,v) VALUES(?,?) "
                          "ON CONFLICT(k) DO UPDATE SET v=excluded.v";
        if (sqlite3_prepare_v2(db, sql, -1, &st, NULL) == SQLITE_OK) {
            sqlite3_bind_text(st, 1, key.UTF8String, -1, SQLITE_TRANSIENT);
            sqlite3_bind_text(st, 2, (v ?: @"").UTF8String, -1, SQLITE_TRANSIENT);
            sqlite3_step(st);
            sqlite3_finalize(st);
        }
    }];
}

- (NSInteger)configInt:(NSString *)key default:(NSInteger)dv {
    NSString *v = [self config:key];
    return v.length ? v.integerValue : dv;
}

#pragma mark - 日志

- (void)logRun:(NSDictionary *)d {
    [self exec:^(sqlite3 *db) {
        sqlite3_stmt *st = NULL;
        const char *sql = "INSERT INTO run_log(wxid,origin_text,ai_reply,mode,send_status,"
                          "risk_flag,ts) VALUES(?,?,?,?,?,?,?)";
        if (sqlite3_prepare_v2(db, sql, -1, &st, NULL) == SQLITE_OK) {
            sqlite3_bind_text(st, 1, [(d[@"wxid"] ?: @"-") UTF8String], -1, SQLITE_TRANSIENT);
            sqlite3_bind_text(st, 2, [(d[@"origin_text"] ?: @"") UTF8String], -1, SQLITE_TRANSIENT);
            sqlite3_bind_text(st, 3, [(d[@"ai_reply"] ?: @"") UTF8String], -1, SQLITE_TRANSIENT);
            sqlite3_bind_text(st, 4, [(d[@"mode"] ?: @"") UTF8String], -1, SQLITE_TRANSIENT);
            sqlite3_bind_text(st, 5, [(d[@"send_status"] ?: @"") UTF8String], -1, SQLITE_TRANSIENT);
            sqlite3_bind_text(st, 6, [(d[@"risk_flag"] ?: @"") UTF8String], -1, SQLITE_TRANSIENT);
            sqlite3_bind_int64(st, 7, (sqlite3_int64)[[NSDate date] timeIntervalSince1970]);
            sqlite3_step(st);
            sqlite3_finalize(st);
        }
    }];
}

#pragma mark - 备份（证书 7 天重签的数据保险）

- (NSString *)writeBackupSnapshot {
    NSMutableDictionary *dump = [NSMutableDictionary dictionary];
    NSArray *tables = @[ @"contact", @"chat_log", @"long_memory",
                         @"memory_pending", @"config", @"word_collection" ];
    for (NSString *t in tables) {
        NSMutableArray *rows = [NSMutableArray array];
        [self exec:^(sqlite3 *db) {
            NSString *q = [NSString stringWithFormat:@"SELECT * FROM %@", t];
            sqlite3_stmt *st = NULL;
            if (sqlite3_prepare_v2(db, q.UTF8String, -1, &st, NULL) != SQLITE_OK) return;
            int n = sqlite3_column_count(st);
            while (sqlite3_step(st) == SQLITE_ROW) {
                NSMutableDictionary *row = [NSMutableDictionary dictionary];
                for (int i = 0; i < n; i++) {
                    NSString *k = [NSString stringWithUTF8String:sqlite3_column_name(st, i)];
                    int ty = sqlite3_column_type(st, i);
                    if (ty == SQLITE_INTEGER) row[k] = @(sqlite3_column_int64(st, i));
                    else if (ty == SQLITE_NULL) row[k] = [NSNull null];
                    else row[k] = WCAICol(st, i);
                }
                [rows addObject:row];
            }
            sqlite3_finalize(st);
        }];
        dump[t] = rows;
    }
    dump[@"_meta"] = @{ @"version": WCAI_VERSION_STR,
                        @"ts": @([[NSDate date] timeIntervalSince1970]) };

    NSData *data = [NSJSONSerialization dataWithJSONObject:dump
                                                   options:NSJSONWritingPrettyPrinted
                                                     error:nil];
    if (!data) return nil;

    NSString *docs = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory,
                                                          NSUserDomainMask, YES) firstObject];
    NSString *dir = [docs stringByAppendingPathComponent:@"WCAI_Backup"];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir
                              withIntermediateDirectories:YES attributes:nil error:nil];

    NSDateFormatter *df = [NSDateFormatter new];
    df.dateFormat = @"yyyyMMdd_HHmmss";
    NSString *file = [dir stringByAppendingPathComponent:
                      [NSString stringWithFormat:@"backup_%@.json", [df stringFromDate:[NSDate date]]]];
    [data writeToFile:file atomically:YES];

    // 只保留最近 7 份
    NSArray *files = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:dir error:nil];
    NSArray *sorted = [files sortedArrayUsingSelector:@selector(compare:)];
    if (sorted.count > 7) {
        for (NSUInteger i = 0; i < sorted.count - 7; i++) {
            [[NSFileManager defaultManager] removeItemAtPath:
                [dir stringByAppendingPathComponent:sorted[i]] error:nil];
        }
    }
    return file;
}

@end
