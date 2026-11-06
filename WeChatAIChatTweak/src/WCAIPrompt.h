//
//  WCAIPrompt.h  —  Prompt 组装（固定顺序 + 防注入分隔 + 语气卡 + 时机建议）
//

#import <Foundation/Foundation.h>
#import "WCAIStore.h"

@interface WCAIPrompt : NSObject

/// 返回 @{ @"system": ..., @"user": ... }
+ (NSDictionary *)buildForContact:(WCAIContact *)c
                            chats:(NSArray<NSDictionary *> *)chats
                         memories:(NSArray<NSDictionary *> *)mems
                           latest:(NSString *)latest;

/// LLM 全失败时的本地降级结果（保证弹窗永不空窗）
+ (NSDictionary *)fallbackResultForLevel:(NSString *)level latest:(NSString *)latest;

/// 从我方历史消息统计"语气卡"（防 AI 味）
+ (NSString *)flavorCardFromChats:(NSArray<NSDictionary *> *)chats;

@end
