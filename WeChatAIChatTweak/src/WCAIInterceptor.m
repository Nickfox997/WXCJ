//
//  WCAIInterceptor.m
//  三道闸门（历史 / 启动窗口 / 去重）+ 占位符 + 上下文预热 + 编排
//

#import "WCAICommon.h"
#import "WCAIInterceptor.h"
#import "WCAIStore.h"
#import "WCAIPrompt.h"
#import "WCAILLM.h"
#import "WCAIPreviewVC.h"
#import "WCAISettingsVC.h"
#import "WCAIStealth.h"

// 发消息 IMP（由 Entry 保存）
extern void (*g_origSendMsg)(id, SEL, id);

static id WCAIGet(id obj, NSString *key) {
    @try {
        if (!obj) return nil;
        return [obj valueForKey:key];
    } @catch (__unused NSException *e) { return nil; }
}

static NSString *WCAIGetStr(id obj, NSArray<NSString *> *keys) {
    for (NSString *k in keys) {
        id v = WCAIGet(obj, k);
        if ([v isKindOfClass:[NSString class]] && [v length]) return v;
    }
    return nil;
}

static long long WCAIGetLL(id obj, NSArray<NSString *> *keys) {
    for (NSString *k in keys) {
        id v = WCAIGet(obj, k);
        if ([v respondsToSelector:@selector(longLongValue)]) return [v longLongValue];
    }
    return 0;
}

@interface WCAIInterceptor ()
- (void)installFloatBall;
- (void)placeFloatBall;
- (UIWindow *)bestWindow;
- (void)onBallTap;
- (void)onBallPan:(UIPanGestureRecognizer *)g;
- (void)ingestHistoryArray:(NSArray *)arr;
- (BOOL)text:(NSString *)text hitWords:(NSString *)words;
- (UITableViewCell *)aiEntryCellForTable:(UITableView *)tv;
- (UIWindow *)mainWindow;
- (UIViewController *)topVCFrom:(UIViewController *)vc;
- (void)scheduleEntryCheck;
- (void)installTabProbe;
- (void)probeTabPage:(UIViewController *)vc;
- (UITableView *)findTableIn:(UIView *)root;
- (NSString *)dumpTableIn:(UIViewController *)vc;
- (void)rescanCurrentPage;
- (void)showDiagAlert:(NSString *)title;
- (NSString *)dumpSettingCandidates;
- (void)openSettings;
- (void)notify:(NSString *)msg;
@end

@implementation WCAIInterceptor

+ (instancetype)shared {
    static WCAIInterceptor *s; static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [WCAIInterceptor new]; });
    return s;
}

#pragma mark - 占位符

+ (NSString *)placeholderForType:(NSInteger)type content:(NSString *)content {
    switch (type) {
        case WCAIMsgTypeImage:   return @"[发来一张图片]";
        case WCAIMsgTypeVoice:   return @"[发来一段语音]";
        case WCAIMsgTypeVideo:   return @"[发来一段视频]";
        case WCAIMsgTypeSticker: return @"[发来一个表情]";
        case WCAIMsgTypeCard:    return @"[发来一张名片]";
        case WCAIMsgTypeApp: {
            if ([content containsString:@"¥"] || [content containsString:@"转账"])
                return @"[发来一个转账]";
            if ([content containsString:@"红包"]) return @"[发来一个红包]";
            if ([content containsString:@"位置"]) return @"[发来一个位置]";
            return @"[发来一条链接/卡片]";
        }
        case WCAIMsgTypeSystem:  return nil;   // 系统提示不入上下文
        default:                 return [NSString stringWithFormat:@"[非文本消息 type=%ld]", (long)type];
    }
}

#pragma mark - 收消息主流程

- (void)handleWrap:(id)wrap {
    if (!wrap) return;

    WCAIStore *store = [WCAIStore shared];
    WCAIRuntime *rt = [WCAIRuntime shared];

    // ── 基础字段 ──
    NSString *from = WCAIGetStr(wrap, @[ @"m_nsFromUsr", @"fromUsr" ]);
    NSString *to   = WCAIGetStr(wrap, @[ @"m_nsToUsr", @"toUsr" ]);
    NSString *body = WCAIGetStr(wrap, @[ @"m_nsContent", @"content" ]);
    long long type = WCAIGetLL(wrap, @[ @"m_uiMessageType", @"messageType" ]);
    long long ctime = WCAIGetLL(wrap, @[ @"m_uiCreateTime", @"createTime" ]);
    long long localId = WCAIGetLL(wrap, @[ @"m_uiMesLocalID", @"mesLocalID", @"m_uiMesSvrID" ]);

    if (from.length == 0) return;

    BOOL isSelf = (rt.selfWxid.length && [from isEqualToString:rt.selfWxid]);
    NSString *peer = isSelf ? (to ?: @"") : from;
    if (peer.length == 0) return;

    // ── 闸门 0：群聊直接忽略 ──
    if ([peer hasSuffix:@"@chatroom"] || [from hasSuffix:@"@chatroom"]) return;

    // ── 闸门 1：历史消息（离线补收 / 回放）──
    NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
    if (ctime > 0 && (now - (NSTimeInterval)ctime) > 120) return;

    // ── 闸门 2：进程启动 60s 内的同步窗口 ──
    if ([rt withinSyncWindow]) return;

    // ── 闸门 3：去重 ──
    NSString *dedupKey = [NSString stringWithFormat:@"%@|%lld|%lld", peer, localId, ctime];
    if (![[WCAIDedup shared] markSeen:dedupKey]) return;

    // ── 全局开关 ──
    if ([store configInt:@"global_enable" default:1] == 0) return;

    // ── 记流水（非文本也记占位，保证上下文不断）──
    NSString *text = body;
    BOOL isText = ((WCAIMsgType)type == WCAIMsgTypeText);
    if (!isText) {
        text = [WCAIInterceptor placeholderForType:(WCAIMsgType)type content:body];
        if (!text) return;
    }
    [store appendChat:peer self:isSelf text:text
                 type:isText ? @"文本" : @"其他"
                   ts:(ctime > 0 ? (NSTimeInterval)ctime : now)];

    // 我方消息只记流水（供语气卡统计），不触发生成
    if (isSelf) return;
    // 非文本不触发生成
    if (!isText) return;

    // ── 联系人档案（不存在则自动建档，默认 L1 开启）──
    WCAIContact *c = [store contact:peer];
    if (c.nick.length == 0) { [store saveContact:c]; }
    if (c.enable == 0) return;

    // ── 免打扰（正确处理跨零点）──
    NSInteger qs = [store configInt:@"quiet_start" default:-1];
    NSInteger qe = [store configInt:@"quiet_end"   default:-1];
    if (qs >= 0 && qe >= 0 && WCAIInQuietHours(qs, qe)) {
        WCAITrace(@"quiet", @"%@ 处于免打扰时段，跳过生成", peer);
        return;
    }

    // ── 敏感词拦截：对方消息命中则不生成 ──
    NSString *banWords = [store config:@"ban_words"];
    if (banWords.length && [self text:body hitWords:banWords]) {
        WCAITrace(@"ban", @"命中敏感词，放弃生成");
        return;
    }

    // ── 组装上下文 ──
    NSInteger limit = c.maxShort > 0 ? c.maxShort : 12;
    NSArray *chats = [store recentChats:peer limit:limit];
    NSArray *mems  = [store activeMemories:peer];

    NSDictionary *req = [WCAIPrompt buildForContact:c chats:chats
                                          memories:mems latest:body];
    WCAITrace(@"gen", @"触发生成 peer=%@ L=%@ 上下文%lu条",
              peer, c.flirtLevel, (unsigned long)chats.count);

    [[WCAILLM shared] generate:req completion:^(NSDictionary *result, NSError *err) {
        if (err || !result) {
            WCAITrace(@"llm_fail", @"%@", err.localizedDescription ?: @"empty");
            result = [WCAIPrompt fallbackResultForLevel:c.flirtLevel latest:body];
        }
        NSMutableDictionary *payload = [result mutableCopy];
        payload[@"origin"] = body;
        payload[@"req"] = req;                    // 供弹窗「重新生成」复用
        payload[@"flirt_level"] = c.flirtLevel;
        payload[@"stage"] = c.stage;
        payload[@"memories"] = mems;
        payload[@"degraded"] = @(err != nil);

        WCAIOnMain(^{
            [[WCAIPreviewVC shared] showPayload:payload wxid:peer];
        });
    }];
}

- (BOOL)text:(NSString *)text hitWords:(NSString *)words {
    NSArray *list = [words componentsSeparatedByString:@","];
    for (NSString *w in list) {
        NSString *t = [w stringByTrimmingCharactersInSet:
                       [NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (t.length && [text rangeOfString:t].location != NSNotFound) return YES;
    }
    return NO;
}

#pragma mark - 手动发送（唯一出口）

- (void)sendText:(NSString *)text toWxid:(NSString *)wxid {
    if (text.length == 0 || wxid.length == 0) return;

    // 行为风控第一道：节奏限速 + 复读检测（比任何技术对抗都更能保号）
    NSString *why = nil;
    if (![WCAIRateLimiter canSendTo:wxid text:text reason:&why]) {
        WCAITrace(@"rate", @"拦截发送：%@", why ?: @"限速");
        [self notify:why ?: @"发送太频繁"];
        return;
    }

    // 敏感词二次校验（发送前）
    NSString *banWords = [[WCAIStore shared] config:@"ban_words"];
    for (NSString *w in [banWords componentsSeparatedByString:@","]) {
        NSString *t = [w stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        if (t.length && [text rangeOfString:t].location != NSNotFound) {
            WCAITrace(@"ban_send", @"发送前命中敏感词，已阻止");
            return;
        }
    }

    @try {
        Class wrapCls = objc_getClass("CMessageWrap");
        if (!wrapCls) { WCAITrace(@"send_fail", @"CMessageWrap 缺失"); return; }

        id wrap = [[wrapCls alloc] init];
        @try {
            [wrap setValue:@(WCAIMsgTypeText) forKey:@"m_uiMessageType"];
            [wrap setValue:text forKey:@"m_nsContent"];
            [wrap setValue:wxid forKey:@"m_nsToUsr"];
            [wrap setValue:[WCAIRuntime shared].selfWxid ?: @"" forKey:@"m_nsFromUsr"];
            [wrap setValue:@([[NSDate date] timeIntervalSince1970]) forKey:@"m_uiCreateTime"];
        } @catch (__unused NSException *e) {}

        Class mgrCls = objc_getClass("CMessageMgr");
        id center = nil;
        @try {
            id sc = objc_getClass("MMServiceCenter");
            center = [sc performSelector:NSSelectorFromString(@"defaultCenter")];
        } @catch (__unused NSException *e) {}
        id mgr = center ? [center performSelector:NSSelectorFromString(@"getService:")
                                       withObject:mgrCls] : nil;

        BOOL ok = NO;
        for (NSString *sn in WCAISelSendMsg()) {
            SEL s = NSSelectorFromString(sn);
            if (mgr && [mgr respondsToSelector:s]) {
                [mgr performSelector:s withObject:wrap];
                ok = YES;
                break;
            }
        }
        [[WCAIStore shared] logRun:@{ @"wxid": wxid, @"origin_text": @"(manual)",
                                      @"ai_reply": text, @"mode": @"manual",
                                      @"send_status": ok ? @"sent" : @"send_fail",
                                      @"risk_flag": @"" }];
        if (ok) [WCAIRateLimiter noteSent:wxid text:text];
    } @catch (NSException *e) {
        WCAITrace(@"send_exception", @"%@", e.reason);
    }
}

- (void)notify:(NSString *)msg {
    WCAIOnMain(^{
        UIWindow *key = nil;
        for (UIWindow *w in UIApplication.sharedApplication.windows) {
            if (w.isKeyWindow) { key = w; break; }
        }
        if (!key) key = UIApplication.sharedApplication.windows.firstObject;
        if (!key) return;
        UIAlertController *ac = [UIAlertController
            alertControllerWithTitle:@"发送已拦截" message:msg
                      preferredStyle:UIAlertControllerStyleAlert];
        [ac addAction:[UIAlertAction actionWithTitle:@"好"
                                               style:UIAlertActionStyleDefault handler:nil]];
        [key.rootViewController presentViewController:ac animated:YES completion:nil];
    });
}

#pragma mark - 历史预热

- (void)installHistoryHook {
    // 1) hook 历史消息加载方法：把微信返回的消息数组抄一份进库
    for (NSString *cn in WCAIClsMessageMgr()) {
        Class c = objc_getClass(cn.UTF8String);
        if (!c) continue;
        for (NSString *sn in WCAISelHistoryLoad()) {
            SEL s = NSSelectorFromString(sn);
            Method m = class_getInstanceMethod(c, s);
            if (!m) continue;

            typedef id (*HistIMP)(id, SEL, id);
            static HistIMP origHist = NULL;
            origHist = (HistIMP)method_getImplementation(m);

            IMP newImp = imp_implementationWithBlock(^id(id self_, id arg) {
                id ret = origHist ? origHist(self_, s, arg) : nil;
                @try {
                    if ([ret isKindOfClass:[NSArray class]]) {
                        [[WCAIInterceptor shared] ingestHistoryArray:(NSArray *)ret];
                    }
                } @catch (__unused NSException *e) {}
                return ret;
            });
            method_setImplementation(m, newImp);
            WCAITrace(@"hook", @"历史加载命中 %s %s", class_getName(c), sel_getName(s));
            return;   // 命中一个即可
        }
    }
    WCAITrace(@"hook", @"历史加载未命中，预热降级（靠首次进入会话补）");
}

/// 把微信历史消息数组抄进 chat_log（去重靠 内容+时间 哈希）
- (void)ingestHistoryArray:(NSArray *)arr {
    if (arr.count == 0) return;
    WCAIStore *store = [WCAIStore shared];
    WCAIRuntime *rt = [WCAIRuntime shared];
    NSInteger added = 0;

    for (id w in arr) {
        @autoreleasepool {
            NSString *from = WCAIGetStr(w, @[ @"m_nsFromUsr" ]);
            NSString *to   = WCAIGetStr(w, @[ @"m_nsToUsr" ]);
            NSString *body = WCAIGetStr(w, @[ @"m_nsContent" ]);
            long long type = WCAIGetLL(w, @[ @"m_uiMessageType" ]);
            long long ctime = WCAIGetLL(w, @[ @"m_uiCreateTime" ]);
            long long lid = WCAIGetLL(w, @[ @"m_uiMesLocalID" ]);

            BOOL isSelf = (rt.selfWxid.length && [from isEqualToString:rt.selfWxid]);
            NSString *peer = isSelf ? to : from;
            if (peer.length == 0 || [peer hasSuffix:@"@chatroom"]) continue;
            if ([peer isEqualToString:rt.selfWxid]) continue;

            NSString *text = body;
            if ((WCAIMsgType)type != WCAIMsgTypeText) {
                text = [WCAIInterceptor placeholderForType:(WCAIMsgType)type content:body];
                if (!text) continue;
            }
            if (text.length == 0) continue;

            NSString *key = [NSString stringWithFormat:@"H|%@|%lld|%lld|%lu",
                             peer, lid, ctime, (unsigned long)text.hash];
            if (![[WCAIDedup shared] markSeen:key]) continue;

            [store appendChat:peer self:isSelf text:text
                         type:((WCAIMsgType)type == WCAIMsgTypeText) ? @"文本" : @"其他"
                           ts:(ctime > 0 ? (NSTimeInterval)ctime : [[NSDate date] timeIntervalSince1970])];
            added++;
            if (added >= 60) break;   // 一次最多补 60 条
        }
    }
    if (added) WCAITrace(@"preheat", @"预热补入 %ld 条历史", (long)added);
}

#pragma mark - 设置页原生入口（hook 数据源，遵循微信列表渲染逻辑）

static NSMutableSet<NSString *> *g_hookedSettingCls = nil;

// 插入点：微信设置页里「关于微信」所在位置（运行时探测，不猜 section 序号）
static NSInteger gInsSection = -1;
static NSInteger gInsRow     = -1;
static BOOL      gProbed     = NO;
static BOOL      gReloading  = NO;
static BOOL      gPromptedSetting = NO;   // 设置页结构提示只弹一次
static BOOL      gPromptedMe      = NO;   // 「我」页结构提示只弹一次

static BOOL WCAIIsOurRow(NSInteger s, NSInteger r) {
    return (gProbed && s == gInsSection && r == gInsRow);
}

/// 界面 index 映射回微信自己的 index（插了一行，后面的都要减一）
static NSIndexPath *WCAIOrigIndexPath(NSIndexPath *ip) {
    if (!gProbed || ip.section != gInsSection) return ip;
    if (ip.row <= gInsRow) return ip;
    return [NSIndexPath indexPathForRow:(ip.row - 1) inSection:ip.section];
}

/// 安全 hook：方法若继承自父类，先在子类里补一份再改，
/// 否则 method_setImplementation 会改到父类，波及所有子类。
static BOOL WCAIHookMethod(Class c, SEL sel, IMP newImp, IMP *outOrig) {
    Method m = class_getInstanceMethod(c, sel);
    if (!m) return NO;
    IMP orig = method_getImplementation(m);
    if (class_addMethod(c, sel, orig, method_getTypeEncoding(m))) {
        m = class_getInstanceMethod(c, sel);
        if (!m) return NO;
    }
    if (outOrig) *outOrig = orig;
    method_setImplementation(m, newImp);
    return YES;
}

/// VC 嗅探：微信 UI 类懒加载，启动 2s 时设置页类可能还没注册。
/// 记录真实类名+标题，并在看到设置页时触发一次重试。
- (void)installVCProbe {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        Class nav = [UINavigationController class];
        SEL sel = @selector(pushViewController:animated:);
        Method m = class_getInstanceMethod(nav, sel);
        if (!m) return;
        typedef void (*PushIMP)(id, SEL, UIViewController *, BOOL);
        PushIMP orig = (PushIMP)method_getImplementation(m);
        IMP newImp = imp_implementationWithBlock(^(id self_, UIViewController *vc, BOOL animated) {
            if (orig) orig(self_, sel, vc, animated);
            @try {
                NSString *cn = NSStringFromClass([vc class]);
                NSString *t  = vc.title;
                [[WCAIRuntime shared] diagAdd:@"[VC] %@ | %@", cn, t.length ? t : @"(无标题)"];
                if ([cn isEqualToString:@"WXSettingViewController"] ||
                    [t isEqualToString:@"设置"] || [t isEqualToString:@"Settings"]) {
                    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)),
                                   dispatch_get_main_queue(), ^{
                        [[WCAIInterceptor shared] installSettingsEntry];
                    });
                }
            } @catch (__unused NSException *e) {}
        });
        method_setImplementation(m, newImp);
        WCAITrace(@"hook", @"VC 嗅探已安装");
    });
}

/// Tab 嗅探：捕获「我」页面切换。设置页若始终插不进去，入口就改挂「我」页面——
/// 那里就几个固定项，结构比设置页简单得多。
- (void)installTabProbe {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        Class tabCls = [UITabBarController class];
        SEL s1 = @selector(setSelectedViewController:);
        __block IMP o1 = NULL;
        WCAIHookMethod(tabCls, s1,
            imp_implementationWithBlock(^(id self_, UIViewController *vc) {
                typedef void (*F)(id, SEL, UIViewController *);
                if (o1) ((F)o1)(self_, s1, vc);
                @try { [[WCAIInterceptor shared] probeTabPage:vc]; }
                @catch (__unused NSException *e) {}
            }), &o1);
        WCAITrace(@"hook", @"Tab 嗅探已安装");
    });
}

- (void)probeTabPage:(UIViewController *)vc {
    if (![vc isKindOfClass:[UIViewController class]]) return;
    NSString *cn = NSStringFromClass([vc class]);
    NSString *t  = vc.title;
    [[WCAIRuntime shared] diagAdd:@"[TAB] %@ | %@", cn, t.length ? t : @"(无标题)"];
    // 只记录，不弹窗（入口已改走悬浮球）
}

- (void)installSettingsEntry {
    if (!g_hookedSettingCls) g_hookedSettingCls = [NSMutableSet set];
    [self installVCProbe];
    [self installTabProbe];

    BOOL any = NO;
    // 用固定候选表。动态扫描全类 + 批量 hook 在微信里容易碰到不该碰的类，
    // 是 v7/v8 不稳定的嫌疑之一，先退回安全做法。
    for (NSString *cn in WCAIClsSettingVC()) {
        if ([g_hookedSettingCls containsObject:cn]) { any = YES; continue; }
        Class c = objc_getClass(cn.UTF8String);
        if (!c) continue;

        // ① 行数：插入点所在 section 多一行
        SEL s1 = @selector(tableView:numberOfRowsInSection:);
        __block IMP o1 = NULL;
        BOOL h1 = WCAIHookMethod(c, s1,
            imp_implementationWithBlock(^NSInteger(id self_, UITableView *tv, NSInteger section) {
                typedef NSInteger (*F)(id, SEL, UITableView *, NSInteger);
                NSInteger n = o1 ? ((F)o1)(self_, s1, tv, section) : 0;
                if (gProbed && section == gInsSection) return n + 1;
                return n;
            }), &o1);

        // ② cell：插入点返回我们的 cell，其余映射回原始 index
        SEL s2 = @selector(tableView:cellForRowAtIndexPath:);
        __block IMP o2 = NULL;
        BOOL h2 = WCAIHookMethod(c, s2,
            imp_implementationWithBlock(^UITableViewCell *(id self_, UITableView *tv, NSIndexPath *ip) {
                typedef UITableViewCell *(*F)(id, SEL, UITableView *, NSIndexPath *);
                if (WCAIIsOurRow(ip.section, ip.row))
                    return [[WCAIInterceptor shared] aiEntryCellForTable:tv];
                NSIndexPath *o = WCAIOrigIndexPath(ip);
                UITableViewCell *cell = o2 ? ((F)o2)(self_, s2, tv, o) : nil;
                // 探测插入点：cellForRow 一定会被调用，比 willDisplayCell 更可靠
                if (!gProbed && cell.textLabel.text.length) {
                    NSString *t = cell.textLabel.text;
                    if ([t containsString:@"关于微信"] || [t isEqualToString:@"关于"]) {
                        gInsSection = ip.section;
                        gInsRow     = ip.row;
                        gProbed     = YES;
                        [[WCAIRuntime shared] diagAdd:@"[OK] 插入点(cell 探测) section=%ld row=%ld",
                            (long)ip.section, (long)ip.row];
                        if (!gReloading) {
                            gReloading = YES;
                            dispatch_async(dispatch_get_main_queue(), ^{
                                gReloading = NO;
                                [tv reloadData];
                            });
                        }
                    }
                }
                return cell;
            }), &o2);

        // ③ 点击：我们的行打开面板，其余透传（index 要映射回去）
        SEL s3 = @selector(tableView:didSelectRowAtIndexPath:);
        __block IMP o3 = NULL;
        BOOL h3 = WCAIHookMethod(c, s3,
            imp_implementationWithBlock(^(id self_, UITableView *tv, NSIndexPath *ip) {
                typedef void (*F)(id, SEL, UITableView *, NSIndexPath *);
                if (WCAIIsOurRow(ip.section, ip.row)) {
                    [tv deselectRowAtIndexPath:ip animated:YES];
                    [[WCAIInterceptor shared] openSettings];
                    return;
                }
                if (o3) ((F)o3)(self_, s3, tv, WCAIOrigIndexPath(ip));
            }), &o3);

        // ④ 显示时探测「关于微信」真实位置，然后 reload 让插入生效
        SEL s4 = @selector(tableView:willDisplayCell:forRowAtIndexPath:);
        __block IMP o4 = NULL;
        BOOL h4 = WCAIHookMethod(c, s4,
            imp_implementationWithBlock(^(id self_, UITableView *tv, UITableViewCell *cell, NSIndexPath *ip) {
                typedef void (*F)(id, SEL, UITableView *, UITableViewCell *, NSIndexPath *);
                if (o4) ((F)o4)(self_, s4, tv, cell, ip);
                if (gProbed) return;
                @try {
                    NSString *t = cell.textLabel.text;
                    if (t.length && [t containsString:@"关于微信"]) {
                        gInsSection = ip.section;
                        gInsRow     = ip.row;
                        gProbed     = YES;
                        [[WCAIRuntime shared] diagAdd:@"[OK] 设置页插入点 section=%ld row=%ld",
                            (long)ip.section, (long)ip.row];
                        if (!gReloading) {
                            gReloading = YES;
                            dispatch_async(dispatch_get_main_queue(), ^{
                                gReloading = NO;
                                [tv reloadData];
                            });
                        }
                    }
                } @catch (__unused NSException *e) {}
            }), &o4);

        if (!(h1 && h2)) continue;    // 数据源没挂上，换下一个候选类
        [g_hookedSettingCls addObject:cn];
        any = YES;
        WCAITrace(@"hook", @"设置页数据源挂载 %s rows:%d cell:%d select:%d display:%d",
                  class_getName(c), h1, h2, h3, h4);
        [[WCAIRuntime shared] diagAdd:@"[OK] 设置页 %s rows:%d cell:%d select:%d display:%d",
            class_getName(c), h1, h2, h3, h4];
    }

    if (!any) {
        WCAITrace(@"hook", @"设置页类尚未加载（懒加载），等待重试");
        [[WCAIRuntime shared] diagAdd:@"[..] 设置页类未加载，等待重试"];
    }

    // 首次调用时排一次自检：8 秒后若一个类都没 hook 到，弹窗给排查线索
    [self scheduleEntryCheck];
}

/// 原生样式的「AI 助手」cell：自适配深色模式，右侧 disclosure 箭头
- (UITableViewCell *)aiEntryCellForTable:(UITableView *)tv {
    static NSString *cid = @"wcai.entry.native";
    UITableViewCell *cell = [tv dequeueReusableCellWithIdentifier:cid];
    if (cell) return cell;

    cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:cid];
    cell.textLabel.text = @"AI 助手";
    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    cell.textLabel.font = [UIFont systemFontOfSize:17];

    if (@available(iOS 13.0, *)) {
        UIImageSymbolConfiguration *conf =
            [UIImageSymbolConfiguration configurationWithPointSize:19
                                                            weight:UIImageSymbolWeightMedium];
        UIImage *img = [UIImage systemImageNamed:@"lightbulb.fill" withConfiguration:conf];
        cell.imageView.image = [img imageWithTintColor:[UIColor systemOrangeColor]
                                         renderingMode:UIImageRenderingModeAlwaysOriginal];
        cell.backgroundColor = [UIColor secondarySystemGroupedBackgroundColor];
        cell.textLabel.textColor = [UIColor labelColor];
    } else {
        cell.backgroundColor = [UIColor whiteColor];
        cell.textLabel.textColor = [UIColor blackColor];
    }
    return cell;
}

- (UIWindow *)mainWindow {
    @try {
        UIWindow *kw = nil;
        if (@available(iOS 13.0, *)) {
            for (UIScene *sc in UIApplication.sharedApplication.connectedScenes) {
                if (![sc isKindOfClass:[UIWindowScene class]]) continue;
                for (UIWindow *w in ((UIWindowScene *)sc).windows) {
                    if (w.isKeyWindow) { kw = w; break; }
                }
                if (kw) break;
            }
        }
        if (!kw) kw = UIApplication.sharedApplication.keyWindow;
        if (!kw) kw = UIApplication.sharedApplication.windows.firstObject;
        return kw;
    } @catch (__unused NSException *e) { return nil; }
}

- (UIViewController *)topVCFrom:(UIViewController *)vc {
    while (vc.presentedViewController) vc = vc.presentedViewController;
    if ([vc isKindOfClass:[UINavigationController class]])
        vc = [(UINavigationController *)vc topViewController];
    else if ([vc isKindOfClass:[UITabBarController class]])
        vc = [(UITabBarController *)vc selectedViewController];
    return vc;
}

#pragma mark - 悬浮球（独立 UIWindow）

static const NSInteger kWCAIBallTag = 0x5743414A;

- (void)installFloatBall {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        WCAIOnMain(^{
            [self placeFloatBall];
            // keyWindow 随页面切换会变，定时补挂（已存在则只提到最上层）
            [NSTimer scheduledTimerWithTimeInterval:2.0 repeats:YES block:^(NSTimer *t) {
                [self placeFloatBall];
            }];
        });
    });
}

- (UIWindow *)bestWindow {
    @try {
        UIWindow *kw = UIApplication.sharedApplication.keyWindow;
        if (kw && !kw.hidden) return kw;
        for (UIWindow *w in UIApplication.sharedApplication.windows) {
            if (w.isKeyWindow && !w.hidden) return w;
        }
        for (UIWindow *w in UIApplication.sharedApplication.windows) {
            if (!w.hidden && w.alpha > 0.01) return w;
        }
        return nil;
    } @catch (__unused NSException *e) { return nil; }
}

- (void)placeFloatBall {
    @try {
        UIWindow *win = [self bestWindow];
        if (!win) return;

        UIView *old = [win viewWithTag:kWCAIBallTag];
        if (old) {
            if (old.superview != win) [win addSubview:old];
            [win bringSubviewToFront:old];
            return;
        }

        UIButton *ball = [UIButton buttonWithType:UIButtonTypeCustom];
        ball.tag = kWCAIBallTag;
        ball.frame = CGRectMake(12, 170, 52, 52);
        ball.backgroundColor = [UIColor colorWithWhite:0.10 alpha:0.82];
        ball.layer.cornerRadius = 26;
        ball.layer.borderWidth = 1.0;
        ball.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.25].CGColor;
        ball.titleLabel.font = [UIFont boldSystemFontOfSize:15];
        [ball setTitle:@"AI" forState:UIControlStateNormal];
        [ball setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];

        // 点击走 tap 手势：pan 手势会让 button 的 touchUpInside 失效
        [ball addGestureRecognizer:[[UITapGestureRecognizer alloc]
                                    initWithTarget:self action:@selector(onBallTap)]];
        [ball addGestureRecognizer:[[UIPanGestureRecognizer alloc]
                                    initWithTarget:self action:@selector(onBallPan:)]];

        [win addSubview:ball];
        WCAITrace(@"ui", @"悬浮球已挂载");
    } @catch (__unused NSException *e) {}
}

- (void)onBallTap {
    WCAITrace(@"ui", @"球被点击");
    [self openSettings];
}

- (void)onBallPan:(UIPanGestureRecognizer *)g {
    UIView *v = g.view;
    UIView *sp = v.superview;
    if (!sp) return;
    CGPoint t = [g translationInView:sp];
    CGPoint c = v.center;
    c.x += t.x;
    c.y += t.y;
    CGFloat half = v.bounds.size.width / 2.0;
    c.x = MAX(half + 4, MIN(c.x, sp.bounds.size.width  - half - 4));
    c.y = MAX(half + 4, MIN(c.y, sp.bounds.size.height - half - 4));
    v.center = c;
    [g setTranslation:CGPointZero inView:sp];
}

- (void)openSettings {
    WCAIOnMain(^{
        UIWindow *win = [self mainWindow];
        if (!win) return;
        UIViewController *top = [self topVCFrom:win.rootViewController];
        if (!top) return;
        UINavigationController *nav = [[UINavigationController alloc]
                                       initWithRootViewController:[WCAISettingsVC new]];
        nav.modalPresentationStyle = UIModalPresentationFullScreen;
        [top presentViewController:nav animated:YES completion:nil];
    });
}

#pragma mark - 入口失败自检

/// 首启 8 秒后检查：如果一个设置页类都没 hook 到，说明入口无处可挂，
/// 此时没有任何 UI 可以让用户看到诊断（入口挂了就进不去面板）。
/// 所以主动弹一次窗，把候选类清单给出来。
- (void)scheduleEntryCheck {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(8.0 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            if (g_hookedSettingCls.count > 0) {
                [[WCAIRuntime shared] diagAdd:@"[OK] 设置页已 hook %lu 个类",
                    (unsigned long)g_hookedSettingCls.count];
                return;
            }
            [self showDiagAlert:@"设置页 hook 全部失败"];
        });
    });
}

- (void)showDiagAlert:(NSString *)title {
    WCAIOnMain(^{
        UIWindow *win = [self mainWindow];
        UIViewController *top = win ? [self topVCFrom:win.rootViewController] : nil;
        if (!top) return;

        NSString *msg = title ?: @"";
        if (msg.length > 1200) msg = [[msg substringToIndex:1200] stringByAppendingString:@"…"];

        [[WCAIRuntime shared] diagAdd:@"%@", msg];

        UIAlertController *ac = [UIAlertController
            alertControllerWithTitle:@"AI 插件自检"
                             message:msg
                      preferredStyle:UIAlertControllerStyleAlert];
        __weak UIAlertController *wac = ac;
        [ac addAction:[UIAlertAction actionWithTitle:@"重新扫描" style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction *a) {
            [wac dismissViewControllerAnimated:YES completion:nil];
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.8 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                [[WCAIInterceptor shared] rescanCurrentPage];
            });
        }]];
        [ac addAction:[UIAlertAction actionWithTitle:@"复制全部" style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction *a) {
            [UIPasteboard generalPasteboard].string = [[WCAIRuntime shared] diagText];
        }]];
        [ac addAction:[UIAlertAction actionWithTitle:@"关闭"
                                               style:UIAlertActionStyleCancel handler:nil]];
        [top presentViewController:ac animated:YES completion:nil];
    });
}

/// 在视图树里找第一个 UITableView
- (UITableView *)findTableIn:(UIView *)root {
    if (!root) return nil;
    NSMutableArray *stack = [NSMutableArray arrayWithObject:root];
    while (stack.count) {
        UIView *v = stack.lastObject;
        [stack removeLastObject];
        if ([v isKindOfClass:[UITableView class]]) return (UITableView *)v;
        for (UIView *s in v.subviews) [stack addObject:s];
    }
    return nil;
}

/// dump 页面列表结构：section/row 数 + 当前可见行文本
- (NSString *)dumpTableIn:(UIViewController *)vc {
    NSMutableString *m = [NSMutableString string];
    [m appendFormat:@"VC: %@\n", NSStringFromClass([vc class])];
    if (![vc isKindOfClass:[UIViewController class]]) { [m appendString:@"(不是 VC)\n"]; return m; }
    UITableView *tv = [self findTableIn:vc.view];
    if (!tv) { [m appendString:@"(视图树里没有 UITableView)\n"]; return m; }

    NSInteger secs = [tv numberOfSections];
    [m appendFormat:@"sections=%ld\n", (long)secs];
    for (NSInteger s = 0; s < secs; s++) {
        NSInteger rows = [tv numberOfRowsInSection:s];
        [m appendFormat:@"  s%ld rows=%ld", (long)s, (long)rows];
        for (UITableViewCell *c in tv.visibleCells) {
            NSIndexPath *ip = [tv indexPathForCell:c];
            if (ip.section != s) continue;
            NSString *t = c.textLabel.text;
            if (t.length) [m appendFormat:@" [r%ld %@]", (long)ip.row, t];
        }
        [m appendString:@"\n"];
    }
    return m;
}

/// 重新扫描当前最顶层页面（「重新扫描」按钮用）
- (void)rescanCurrentPage {
    UIWindow *win = [self mainWindow];
    UIViewController *top = win ? [self topVCFrom:win.rootViewController] : nil;
    if (!top) return;
    NSString *dump = [self dumpTableIn:top];
    [self showDiagAlert:[NSString stringWithFormat:@"当前页面结构：\n%@", dump]];
}

- (NSString *)dumpSettingCandidates {
    NSMutableString *m = [NSMutableString string];
    unsigned int count = 0;
    Class *classes = objc_copyClassList(&count);
    if (classes) {
        for (unsigned int i = 0; i < count; i++) {
            Class c = classes[i];
            const char *n = class_getName(c);
            if (!n) continue;
            NSString *cn = [NSString stringWithUTF8String:n];
            if ([cn rangeOfString:@"Setting"].location == NSNotFound &&
                [cn rangeOfString:@"More"].location    == NSNotFound) continue;
            BOOL rows = class_getInstanceMethod(c, @selector(tableView:numberOfRowsInSection:)) != NULL;
            BOOL cell = class_getInstanceMethod(c, @selector(tableView:cellForRowAtIndexPath:)) != NULL;
            Class sup = class_getSuperclass(c);
            [m appendFormat:@"%@ (%s) rows:%d cell:%d\n", cn,
                sup ? class_getName(sup) : "nil", rows, cell];
        }
        free(classes);
    }
    if (m.length == 0) [m appendString:@"（一个都没找到）"];
    return m;
}

@end
