//
//  WCAIStealth.h  —  防检测 / 防封
//

#ifndef WCAI_STEALTH_H
#define WCAI_STEALTH_H

#import <Foundation/Foundation.h>

/// 必须在 constructor 里最先调用（早于任何微信代码）
void WCAIInstallStealth(void);

@interface WCAIRateLimiter : NSObject
+ (instancetype)shared;
/// 行为层风控：同一联系人限速 + 重复文本拒绝
+ (BOOL)canSendTo:(NSString *)wxid text:(NSString *)text reason:(NSString **)reason;
+ (void)noteSent:(NSString *)wxid text:(NSString *)text;
@end

/// 连续/早期崩溃自保护：本次启动若检测到上次非正常退出，则自动静默
BOOL WCAIShouldRunSilently(void);
void WCAIMarkBootOK(void);

#endif
