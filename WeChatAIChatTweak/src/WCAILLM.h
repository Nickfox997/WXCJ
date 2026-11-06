//
//  WCAILLM.h  —  LLM 客户端（异步 + 超时 + 重试 + JSON 容错链）
//

#import <Foundation/Foundation.h>

@interface WCAILLM : NSObject

+ (instancetype)shared;

/// req: @{ @"system": ..., @"user": ... }
/// completion 返回已解析的结果字典（emotion/opportunity/risk/replies/hook/timing/advice）
/// 失败时 result 为 nil，err 非空 —— 调用方自行走降级模板
- (void)generate:(NSDictionary *)req
      completion:(void (^)(NSDictionary *result, NSError *err))completion;

/// JSON 容错链：直接解析 → 剥 ```json 围栏 → 截首尾大括号 → 抓 replies 文本
+ (NSDictionary *)parseContent:(NSString *)content;

@end
