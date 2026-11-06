//
//  WCAISettingsVC.h  —  微信内自建设置（不走 PreferenceBundle）
//

#import <UIKit/UIKit.h>

@interface WCAISettingsVC : UIViewController
@end

@interface WCAIContactListVC : UITableViewController
@end

@interface WCAIContactEditVC : UIViewController
- (instancetype)initWithWxid:(NSString *)wxid;
@end
