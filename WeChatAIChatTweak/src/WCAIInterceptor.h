//
//  WCAIInterceptor.h  —  消息编排：三道闸门 → 上下文 → Prompt → 弹窗
//

#import <Foundation/Foundation.h>

@interface WCAIInterceptor : NSObject

+ (instancetype)shared;

/// 收消息总入口（由 hook 调用，任何异常都被吞掉，绝不影响微信）
- (void)handleWrap:(id)wrap;

/// 挂历史加载 hook（聊天界面打开时预热 chat_log）
- (void)installHistoryHook;

/// 挂设置页入口
- (void)installSettingsEntry;

/// 悬浮球入口（不依赖微信类名；同时是「dylib 是否加载」的可视信号）
- (void)installFloatBall;

/// 用户确认后发送（手动模式唯一发出口）
- (void)sendText:(NSString *)text toWxid:(NSString *)wxid;

/// 占位符映射：非文本消息也要进上下文
+ (NSString *)placeholderForType:(NSInteger)type content:(NSString *)content;

@end
