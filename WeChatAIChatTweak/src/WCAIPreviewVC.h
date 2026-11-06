//
//  WCAIPreviewVC.h  —  手动预览弹窗（独立 UIWindow，不依赖微信视图层级）
//

#import <Foundation/Foundation.h>

@interface WCAIPreviewVC : NSObject

+ (instancetype)shared;

/// payload: emotion/opportunity/risk/replies/hook/timing/advice/origin/
///          flirt_level/stage/memories/degraded/req
- (void)showPayload:(NSDictionary *)payload wxid:(NSString *)wxid;

@end
