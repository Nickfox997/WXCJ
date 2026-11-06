//
//  WCAIStore.h  —  本地持久层（sqlite3 + 串行队列，零第三方依赖）
//

#import <Foundation/Foundation.h>
#import <sqlite3.h>

@interface WCAIContact : NSObject
@property (nonatomic, copy)   NSString *wxid;
@property (nonatomic, copy)   NSString *nick;
@property (nonatomic, assign) NSInteger enable;        // 0/1
@property (nonatomic, copy)   NSString *flirtLevel;    // L0/L1/L2/L3
@property (nonatomic, copy)   NSString *stage;         // 初识/暧昧/好友/恋人
@property (nonatomic, copy)   NSString *myPrompt;
@property (nonatomic, copy)   NSString *herPrompt;
@property (nonatomic, copy)   NSString *flavorCard;    // 我的语气卡（自动统计+可手改）
@property (nonatomic, assign) NSInteger maxShort;      // 默认 12
@property (nonatomic, assign) NSInteger isTest;        // 仅测试联系人（主号构建恒为 0）
@end

@interface WCAIStore : NSObject

+ (instancetype)shared;
- (BOOL)openDefault;                       // Library/Application Support/WCAI/wcai.db
- (BOOL)openAt:(NSString *)path;

#pragma mark 聊天流水
- (void)appendChat:(NSString *)wxid self:(BOOL)isSelf
              text:(NSString *)text type:(NSString *)type
                ts:(NSTimeInterval)ts;
- (NSInteger)chatCount:(NSString *)wxid;
- (BOOL)hasChatHistory:(NSString *)wxid;
- (NSArray<NSDictionary *> *)recentChats:(NSString *)wxid limit:(NSInteger)limit;

#pragma mark 联系人
- (WCAIContact *)contact:(NSString *)wxid;          // 不存在返回默认 L1 档案
- (NSArray<WCAIContact *> *)allContacts;
- (void)saveContact:(WCAIContact *)c;

#pragma mark 记忆
- (NSArray<NSDictionary *> *)activeMemories:(NSString *)wxid;
- (void)addPending:(NSString *)wxid type:(NSString *)type
           content:(NSString *)content weight:(NSInteger)w;

#pragma mark 配置
- (NSString *)config:(NSString *)key;
- (void)setConfig:(NSString *)key value:(NSString *)v;
- (NSInteger)configInt:(NSString *)key default:(NSInteger)dv;

#pragma mark 日志 / 备份
- (void)logRun:(NSDictionary *)d;
- (NSString *)writeBackupSnapshot;                  // 返回备份文件路径
- (NSString *)dbPath;

/// 串行队列内执行裸 SQL（内部用；需要直接操作连接时用）
- (void)exec:(void (^)(sqlite3 *db))blk;

@end
