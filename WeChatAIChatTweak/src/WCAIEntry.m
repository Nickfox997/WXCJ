//
//  WCAIEntry.m  —  注入入口、hook 挂载、运行时探测
//  全能签环境：无 Substrate/ElleKit，全部走 ObjC runtime，零依赖。
//

#import "WCAICommon.h"
#import "WCAIStore.h"
#import "WCAIInterceptor.h"
#import "WCAIStealth.h"

// ─────────────────────────────────────────────────────────────
#pragma mark - 运行时
// ─────────────────────────────────────────────────────────────

@implementation WCAIRuntime
+ (instancetype)shared {
    static WCAIRuntime *s; static dispatch_once_t once;
    dispatch_once(&once, ^{
        s = [WCAIRuntime new];
        s.bootTime = [NSDate timeIntervalSinceReferenceDate];
        s.diag = [NSMutableArray array];
    });
    return s;
}
- (BOOL)withinSyncWindow {
    return ([NSDate timeIntervalSinceReferenceDate] - self.bootTime) < 60.0;
}
- (void)diagAdd:(NSString *)fmt, ... {
    va_list ap; va_start(ap, fmt);
    NSString *line = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    if (!line) return;
    @synchronized (self) {
        if (!self.diag) self.diag = [NSMutableArray array];
        [self.diag addObject:line];
        while (self.diag.count > 80) [self.diag removeObjectAtIndex:0];
    }
}
- (NSString *)diagText {
    NSMutableString *m = [NSMutableString string];
    [m appendFormat:@"插件 %@\n", WCAI_VERSION_STR];
    [m appendFormat:@"微信 %@\n", self.wxVersion ?: @"?"];
    [m appendFormat:@"本人 %@\n", self.selfWxid.length ? self.selfWxid : @"(未取到)"];
    [m appendFormat:@"hook 命中 %ld / 未命中 %ld\n", (long)self.hookHit, (long)self.hookMiss];
    [m appendString:@"──────────────\n"];
    @synchronized (self) {
        for (NSString *l in self.diag) [m appendFormat:@"%@\n", l];
    }
    if (self.diag.count == 0) [m appendString:@"(无诊断记录)\n"];
    return m;
}
@end

@implementation WCAIDedup {
    NSMutableOrderedSet *_set;
    dispatch_queue_t _q;
}
+ (instancetype)shared {
    static WCAIDedup *s; static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [WCAIDedup new]; });
    return s;
}
- (instancetype)init {
    if ((self = [super init])) {
        _set = [NSMutableOrderedSet orderedSet];
        _q = dispatch_queue_create("wcai.dedup", DISPATCH_QUEUE_SERIAL);
    }
    return self;
}
- (BOOL)markSeen:(NSString *)key {
    if (key.length == 0) return YES;
    __block BOOL first = NO;
    dispatch_sync(_q, ^{
        if ([_set containsObject:key]) { first = NO; }
        else {
            first = YES;
            [_set addObject:key];
            if (_set.count > 512) [_set removeObjectAtIndex:0];
        }
    });
    return first;
}
@end

// ─────────────────────────────────────────────────────────────
#pragma mark - 反射式取值（避免编译期依赖微信私有类）
// ─────────────────────────────────────────────────────────────

static id WCAICall(id obj, NSString *sel, id arg) {
    if (!obj) return nil;
    SEL s = NSSelectorFromString(sel);
    if (![obj respondsToSelector:s]) return nil;
    if (arg) return [obj performSelector:s withObject:arg];
    return [obj performSelector:s];
}

NSString *WCAIResolveSelfWxid(void) {
    @try {
        Class centerCls = objc_getClass(WCAIClsServiceCenter().UTF8String);
        id center = WCAICall((id)centerCls, @"defaultCenter", nil);
        Class accCls = objc_getClass(WCAIClsAccount().UTF8String);
        id account = WCAICall(center, @"getService:", (id)accCls);
        id v = [account valueForKey:@"m_nsUsrName"];
        if ([v isKindOfClass:[NSString class]] && [v length]) return v;
    } @catch (__unused NSException *e) {}
    return nil;
}

NSString *WCAIResolveWxVersion(void) {
    @try {
        NSDictionary *info = [[NSBundle mainBundle] infoDictionary];
        NSString *v = info[@"CFBundleShortVersionString"];
        if (v.length) return v;
    } @catch (__unused NSException *e) {}
    return @"unknown";
}

BOOL WCAIInQuietHours(NSInteger start, NSInteger end) {
    if (start == end) return NO;
    NSInteger h = [[NSCalendar currentCalendar] component:NSCalendarUnitHour
                                                 fromDate:[NSDate date]];
    if (start < end) return (h >= start && h < end);
    return (h >= start || h < end);   // 跨零点：23→8
}

void WCAIOnMain(void (^blk)(void)) {
    if (!blk) return;
    if ([NSThread isMainThread]) blk();
    else dispatch_async(dispatch_get_main_queue(), blk);
}

void WCAITrace(NSString *tag, NSString *fmt, ...) {
    va_list ap; va_start(ap, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    [[WCAIStore shared] logRun:@{ @"wxid": @"-", @"origin_text": msg ?: @"",
                                  @"ai_reply": @"", @"mode": @"trace",
                                  @"send_status": tag ?: @"", @"risk_flag": @"" }];
}

// ─────────────────────────────────────────────────────────────
#pragma mark - Hook 工具：零依赖 IMP 替换
// ─────────────────────────────────────────────────────────────

/// 在多个候选类上依次尝试，返回命中的 Method（找不到返回 NULL）
static Method WCAIFindMethod(NSArray<NSString *> *clsNames,
                             NSArray<NSString *> *sels,
                             Class *outCls, SEL *outSel) {
    for (NSString *cn in clsNames) {
        Class c = objc_getClass(cn.UTF8String);
        if (!c) continue;
        for (NSString *sn in sels) {
            SEL s = NSSelectorFromString(sn);
            // 实例方法优先
            Method m = class_getInstanceMethod(c, s);
            if (!m) m = class_getClassMethod(c, s);   // 少数版本是类方法
            if (m) {
                if (outCls) *outCls = c;
                if (outSel) *outSel = s;
                return m;
            }
        }
    }
    return NULL;
}

// 原始 IMP（hook 前保存）
static void (*g_origOnAddMsg3)(id, SEL, id, id) = NULL;   // 收消息
static void (*g_origSendMsg)(id, SEL, id) = NULL;         // 发消息

static void wcai_onAddMsg(id self, SEL _cmd, id a, id wrap) {
    // 先让微信跑完原始逻辑，绝不阻塞主流程
    if (g_origOnAddMsg3) g_origOnAddMsg3(self, _cmd, a, wrap);
    @try {
        [[WCAIInterceptor shared] handleWrap:wrap];
    } @catch (NSException *e) {
        WCAITrace(@"exception", @"OnAddMsg: %@", e.reason);
    }
}

static void wcai_sendMsg(id self, SEL _cmd, id arg) {
    @try {
        NSString *to  = [arg valueForKey:@"m_nsToUsr"];
        NSString *txt = [arg valueForKey:@"m_nsContent"];
        if (to.length && txt.length) {
            [[WCAIStore shared] appendChat:to self:YES text:txt type:@"文本"
                                        ts:[[NSDate date] timeIntervalSince1970]];
        }
    } @catch (__unused NSException *e) {}
    if (g_origSendMsg) g_origSendMsg(self, _cmd, arg);
}

// ─────────────────────────────────────────────────────────────
#pragma mark - 挂载（带重试：注入早期类可能未加载）
// ─────────────────────────────────────────────────────────────

static int g_retry = 0;

static void wcai_installHooks(void) {
    WCAIRuntime *rt = [WCAIRuntime shared];

    // 1) 收消息
    if (!g_origOnAddMsg3) {
        Class c = Nil; SEL s = NULL;
        Method m = WCAIFindMethod(WCAIClsMessageMgr(), WCAISelOnAddMsg(), &c, &s);
        if (m) {
            g_origOnAddMsg3 = (void (*)(id, SEL, id, id))method_getImplementation(m);
            method_setImplementation(m, (IMP)wcai_onAddMsg);
            rt.hookHit++;
            [rt diagAdd:@"[OK] 收消息 %s %s", class_getName(c), sel_getName(s)];
            WCAITrace(@"hook", @"OnAddMsg 命中 %s %s", class_getName(c), sel_getName(s));
        } else {
            rt.hookMiss++;
            [rt diagAdd:@"[X] 收消息全未命中  类[%@]  选择器[%@]",
                [WCAIClsMessageMgr() componentsJoinedByString:@","],
                [WCAISelOnAddMsg() componentsJoinedByString:@","]];
        }
    }

    // 2) 发消息
    if (!g_origSendMsg) {
        Class c = Nil; SEL s = NULL;
        Method m = WCAIFindMethod(WCAIClsMessageMgr(), WCAISelSendMsg(), &c, &s);
        if (m) {
            g_origSendMsg = (void (*)(id, SEL, id))method_getImplementation(m);
            method_setImplementation(m, (IMP)wcai_sendMsg);
            rt.hookHit++;
            [rt diagAdd:@"[OK] 发消息 %s %s", class_getName(c), sel_getName(s)];
            WCAITrace(@"hook", @"SendMsg 命中 %s %s", class_getName(c), sel_getName(s));
        } else {
            rt.hookMiss++;
            [rt diagAdd:@"[X] 发消息全未命中  类[%@]  选择器[%@]",
                [WCAIClsMessageMgr() componentsJoinedByString:@","],
                [WCAISelSendMsg() componentsJoinedByString:@","]];
        }
    }

    // 3) 历史预热
    [[WCAIInterceptor shared] installHistoryHook];

    // 4) 设置页入口
    [[WCAIInterceptor shared] installSettingsEntry];

    rt.hooked = (g_origOnAddMsg3 != NULL);
    rt.selfWxid = WCAIResolveSelfWxid() ?: @"";
    rt.wxVersion = WCAIResolveWxVersion();
    WCAITrace(@"boot", @"v%@ wx=%@ self=%@ hit=%ld miss=%ld",
              WCAI_VERSION_STR, rt.wxVersion, rt.selfWxid,
              (long)rt.hookHit, (long)rt.hookMiss);
    [rt diagAdd:@"启动 v%@  wx=%@  self=%@  命中%ld 未命中%ld",
        WCAI_VERSION_STR, rt.wxVersion ?: @"?", rt.selfWxid.length ? rt.selfWxid : @"(空)",
        (long)rt.hookHit, (long)rt.hookMiss];

    // 未全部命中则重试（最多 3 次，间隔 1s）
    if ((!g_origOnAddMsg3 || !g_origSendMsg) && g_retry < 3) {
        g_retry++;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ wcai_installHooks(); });
    }
}

// ─────────────────────────────────────────────────────────────
#pragma mark - 入口
// ─────────────────────────────────────────────────────────────

__attribute__((constructor))
static void wcai_entry(void) {
    @autoreleasepool {
        // ① 隐蔽层必须最先装（越狱检测多在启动早期调用）
        WCAIInstallStealth();

        // ② 崩溃自保护：上次启动没跑满 10s 就退 → 本次静默，避免连环崩
        BOOL silent = WCAIShouldRunSilently();
        WCAIMarkBootOK();
        if (silent) {
            // 静默不是「消失」：仍然挂球，让你能确认插件确实被加载了，
            // 同时能看到「因为上次异常退出所以本次静默」这个状态。
            [[WCAIRuntime shared] diagAdd:@"上次启动异常退出 → 本次静默模式（未装 hook）"];
            [[WCAIInterceptor shared] installFloatBall];
            return;
        }

        [WCAIRuntime shared].bootTime = [NSDate timeIntervalSinceReferenceDate];
        [[WCAIStore shared] openDefault];

        // 延迟 2s：等微信 ServiceCenter 初始化完成，避免早期取不到类
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            wcai_installHooks();
        });

        // 回前台时刷新 selfWxid（换号场景）
        [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidBecomeActiveNotification
                                                          object:nil queue:[NSOperationQueue mainQueue]
                                                      usingBlock:^(NSNotification *n) {
            WCAIRuntime *r = [WCAIRuntime shared];
            NSString *now = WCAIResolveSelfWxid();
            if (now.length && ![now isEqualToString:r.selfWxid]) {
                r.selfWxid = now;
                WCAITrace(@"account", @"selfWxid 变更 → %@", now);
            }
        }];
    }
}
