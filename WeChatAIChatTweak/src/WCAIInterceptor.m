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
- (void)ingestHistoryArray:(NSArray *)arr;
- (BOOL)text:(NSString *)text hitWords:(NSString *)words;
- (void)attachEntryButton:(id)vc;
- (void)installFloatBall;
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

#pragma mark - 设置入口（微信内自建，不改微信数据源）

- (void)installSettingsEntry {
    // 在设置页 viewWillAppear 时贴一个入口按钮：零侵入，不碰 tableView 结构
    for (NSString *cn in WCAIClsSettingVC()) {
        Class c = objc_getClass(cn.UTF8String);
        if (!c) continue;
        SEL s = NSSelectorFromString(@"viewWillAppear:");
        Method m = class_getInstanceMethod(c, s);
        if (!m) continue;

        typedef void (*AppearIMP)(id, SEL, BOOL);
        static AppearIMP origAppear = NULL;
        origAppear = (AppearIMP)method_getImplementation(m);

        IMP newImp = imp_implementationWithBlock(^(id self_, BOOL animated) {
            if (origAppear) origAppear(self_, s, animated);
            @try { [[WCAIInterceptor shared] attachEntryButton:self_]; }
            @catch (__unused NSException *e) {}
        });
        method_setImplementation(m, newImp);
        WCAITrace(@"hook", @"设置入口命中 %s", class_getName(c));
        return;
    }
    WCAITrace(@"hook", @"设置入口未命中，改用悬浮球入口");
    [self installFloatBall];
}

- (void)attachEntryButton:(id)vc {
    if (![vc isKindOfClass:[UIViewController class]]) return;
    UIViewController *v = (UIViewController *)vc;
    UIView *root = v.view;
    if (!root) return;
    if ([root viewWithTag:0x57434149]) return;   // 已加过

    UIButton *btn = [UIButton buttonWithType:UIButtonTypeSystem];
    btn.tag = 0x57434149;
    btn.frame = CGRectMake(root.bounds.size.width - 76, root.bounds.size.height - 96, 60, 34);
    btn.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleTopMargin;
    [btn setTitle:@"AI" forState:UIControlStateNormal];
    btn.titleLabel.font = [UIFont boldSystemFontOfSize:15];
    btn.backgroundColor = [UIColor colorWithWhite:0.2 alpha:0.85];
    [btn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    btn.layer.cornerRadius = 17;
    [btn addTarget:self action:@selector(openSettings) forControlEvents:UIControlEventTouchUpInside];
    [root addSubview:btn];
}

- (void)openSettings {
    WCAIOnMain(^{
        UIWindow *win = UIApplication.sharedApplication.keyWindow;
        if (!win) win = UIApplication.sharedApplication.windows.firstObject;
        UINavigationController *nav = [[UINavigationController alloc]
                                       initWithRootViewController:[WCAISettingsVC new]];
        [win.rootViewController presentViewController:nav animated:YES completion:nil];
    });
}

- (void)installFloatBall {
    // 极简兜底：无设置页 hook 时，在首次生成弹窗里提供入口
    WCAITrace(@"hook", @"使用弹窗内设置入口作为兜底");
}

@end
