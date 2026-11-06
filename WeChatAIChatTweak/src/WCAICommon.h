//
//  WCAICommon.h  —  Hook 映射表 / 全局状态 / 日志
//  纪律：所有微信类名与选择器只能出现在本文件。微信升版只改这里。
//

#ifndef WCAI_COMMON_H
#define WCAI_COMMON_H

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>

// ── 构建开关 ───────────────────────────────────────────────
#define WCAI_VERSION_STR        @"0.1.0"
#ifndef WCAI_DISABLE_AUTO
#define WCAI_DISABLE_AUTO       1
#endif

// ── 日志 ───────────────────────────────────────────────────
#ifdef DEBUG
#define WCAILog(fmt, ...) NSLog(@"[WCAI] " fmt, ##__VA_ARGS__)
#else
#define WCAILog(fmt, ...) ((void)0)
#endif
// 落库级日志（永远生效，用户可在面板看）
void WCAITrace(NSString *tag, NSString *fmt, ...);

// ── Hook 映射表（多候选，运行时按顺序探测）─────────────────
static inline NSArray<NSString *> *WCAIClsMessageMgr(void) {
    return @[ @"CMessageMgr", @"MessageMgr", @"MMMsgMgr" ];
}
// 收消息（第一候选命中率最高）
static inline NSArray<NSString *> *WCAISelOnAddMsg(void) {
    return @[ @"AsyncOnAddMsg:MsgWrap:",
              @"OnAddMsg:MsgWrap:",
              @"AsyncOnAddMsg:MsgWrap:FromPush:" ];
}
// 发消息
static inline NSArray<NSString *> *WCAISelSendMsg(void) {
    return @[ @"AsyncSendTextMsg:",
              @"AsyncSendMsg:",
              @"SendMsg:" ];
}
// 历史消息加载（预热用；命中任一即可）
static inline NSArray<NSString *> *WCAISelHistoryLoad(void) {
    return @[ @"getMessagesFromLocalDB:",
              @"GetAllMessageBySession:",
              @"getMessages:",
              @"loadMessages:" ];
}
// 设置页 VC（微信各版本差异很大；命中任一即可，另有标题嗅探兜底）
static inline NSArray<NSString *> *WCAIClsSettingVC(void) {
    return @[ @"NewSettingViewController",
              @"MMSettingViewController",
              @"MMSettingsViewController",
              @"WCSettingsViewController",
              @"WXSettingViewController",
              @"SettingsViewController",
              @"SettingViewController",
              @"WCSettingViewController",
              @"MMMoreViewController",
              @"NewMoreViewController" ];
}
// 本人 wxid 读取链
static inline NSString *WCAIClsServiceCenter(void) { return @"MMServiceCenter"; }
static inline NSString *WCAIClsAccount(void)       { return @"WCAccount"; }

// ── 消息类型（微信 CMessageWrap.m_uiMessageType）────────────
typedef NS_ENUM(NSInteger, WCAIMsgType) {
    WCAIMsgTypeText   = 1,
    WCAIMsgTypeImage  = 3,
    WCAIMsgTypeVoice  = 34,
    WCAIMsgTypeCard   = 42,
    WCAIMsgTypeVideo  = 43,
    WCAIMsgTypeSticker= 47,
    WCAIMsgTypeApp    = 49,
    WCAIMsgTypeSystem = 10000,
};

// ── 运行时全局 ─────────────────────────────────────────────
@interface WCAIRuntime : NSObject
@property (nonatomic, copy)   NSString *selfWxid;
@property (nonatomic, copy)   NSString *wxVersion;      // 回填显示
@property (nonatomic, assign) NSTimeInterval bootTime;
@property (nonatomic, assign) NSInteger hookHit, hookMiss;
@property (nonatomic, assign) BOOL hooked;
// 自检诊断（注入后用于定位 hook 点是否命中，非越狱环境看不到 NSLog）
@property (nonatomic, strong) NSMutableArray<NSString *> *diag;
+ (instancetype)shared;
- (BOOL)withinSyncWindow;                                // 启动 60s 内 = YES
- (void)diagAdd:(NSString *)fmt, ... NS_FORMAT_FUNCTION(1,2);
- (NSString *)diagText;                                  // 汇总文本，供一键复制
@end

// wxid 去重（LRU，容量 512）
@interface WCAIDedup : NSObject
+ (instancetype)shared;
- (BOOL)markSeen:(NSString *)key;    // 首次 YES，重复 NO
@end

// 读取本人 wxid（进程内，无版本依赖）
NSString *WCAIResolveSelfWxid(void);
// 读取微信版本号
NSString *WCAIResolveWxVersion(void);
// 免打扰判断（正确处理跨零点）
BOOL WCAIInQuietHours(NSInteger startHour, NSInteger endHour);
// 主线程安全执行
void WCAIOnMain(void (^blk)(void));

#endif
