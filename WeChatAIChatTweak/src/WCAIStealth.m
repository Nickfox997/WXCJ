//
//  WCAIStealth.m
//  两层防护：
//   ① 检测对抗 —— 越狱路径过滤、dyld image 隐藏（可选）、检测方法钝化
//   ② 行为风控 —— 限速、重复文本拒绝、崩溃自保护
//
//  刻意不做：反调试、hook 网络/支付/登录。主号构建，稳定性优先。
//

#import "WCAICommon.h"
#import "WCAIStealth.h"
#import "WCAIStore.h"
#import "WCAIObfuscate.h"
#import "WCAIFishhook.h"

#include <string.h>
#include <stdlib.h>
#include <dlfcn.h>

// 可选：GOT patch 隐藏自身 image（默认关，改错会崩微信）
#ifndef WCAI_ENABLE_GOT_PATCH
#define WCAI_ENABLE_GOT_PATCH 0
#endif

#pragma mark - 越狱路径表（分片拼接，避免明文特征）

static NSArray<NSString *> *WCAIJailPaths(void) {
    static NSArray *paths; static dispatch_once_t once;
    dispatch_once(&once, ^{
        paths = @[
            WCAI_JOIN2(@"/Applications/", @"Cydia.app"),
            WCAI_JOIN2(@"/var/lib/", @"dpkg/status"),
            WCAI_JOIN2(@"/bin/", @"bash"),
            WCAI_JOIN2(@"/usr/sbin/", @"sshd"),
            WCAI_JOIN2(@"/etc/", @"apt"),
            WCAI_JOIN2(@"/private/var/lib/", @"apt"),
            WCAI_JOIN2(@"/Library/Mobile", @"Substrate"),
            WCAI_JOIN2(@"/var/lib/", @"cydia"),
            WCAI_JOIN2(@"/usr/libexec/", @"cydia"),
            WCAI_JOIN2(@"/var/", @"jb"),          // roothide / TrollStore
            WCAI_JOIN2(@"/private/preboot/", @"jb"),
            WCAI_JOIN2(@"/usr/lib/lib", @"substrate.dylib"),
            WCAI_JOIN2(@"/usr/lib/lib", @"hooker.dylib"),
            WCAI_JOIN2(@"/usr/lib/lib", @"ellekit.dylib"),
            WCAI_JOIN2(@"/usr/bin/", @"sbreload"),
        ];
    });
    return paths;
}

static BOOL wcai_path_is_suspicious(NSString *path) {
    if (![path isKindOfClass:[NSString class]] || path.length == 0) return NO;

    // 自己的 dylib 本身也要藏
    NSString *selfName = WCAISelfDylibName();
    if (selfName.length && [path containsString:selfName]) return YES;

    for (NSString *p in WCAIJailPaths()) {
        if ([path isEqualToString:p] || [path hasPrefix:p]) return YES;
    }
    return NO;
}

#pragma mark - ① 检测对抗

static BOOL (*g_origFileExists)(id, SEL, NSString *) = NULL;
static BOOL (*g_origFileExistsIsDir)(id, SEL, NSString *, BOOL *) = NULL;

static BOOL wcai_fileExists(id self, SEL _cmd, NSString *path) {
    if (wcai_path_is_suspicious(path)) return NO;
    return g_origFileExists ? g_origFileExists(self, _cmd, path) : NO;
}

static BOOL wcai_fileExistsIsDir(id self, SEL _cmd, NSString *path, BOOL *isDir) {
    if (wcai_path_is_suspicious(path)) {
        if (isDir) *isDir = NO;
        return NO;
    }
    return g_origFileExistsIsDir ? g_origFileExistsIsDir(self, _cmd, path, isDir) : NO;
}

/// dyld image 枚举过滤（仅在开启 GOT patch 时生效）
#if WCAI_ENABLE_GOT_PATCH
static uint32_t (*g_origImageCount)(void) = NULL;
static const char *(*g_origImageName)(uint32_t) = NULL;
static const struct mach_header *(*g_origImageHeader)(uint32_t) = NULL;

// 做法：命中自己的索引时返回下一个非自身 image（近似过滤，不做重排）
static uint32_t wcai_imageCount(void) {
    return g_origImageCount ? g_origImageCount() - 1 : 0;
}
static const char *wcai_imageName(uint32_t idx) {
    NSString *hint = WCAISelfImageHint();
    uint32_t n = g_origImageCount ? g_origImageCount() : 0;
    uint32_t real = idx;
    for (uint32_t i = 0; i < n; i++) {
        const char *nm = g_origImageName ? g_origImageName(i) : NULL;
        if (!nm) continue;
        if ([hint length] && strstr(nm, hint.UTF8String)) { continue; }  // 跳过自己
        if (real == idx) return nm;
        real++;
    }
    return "";
}
#endif

/// 钝化微信自身的越狱/注入检测方法（返回 BOOL、无额外参数的那些）
static void wcai_neutralize_checks(void) {
    static const char *kKeywords[] = {
        "jailbreak", "jailbroken", "isjb", "isjailbreak", "cydia", "substrate",
        "ishacked", "hackeddevice", "detecttweak", "detectinject", "checksandboxbreach",
        "isrooted", "fakesignature"
    };
    const size_t nk = sizeof(kKeywords) / sizeof(kKeywords[0]);

    unsigned int count = 0;
    Class *classes = objc_copyClassList(&count);
    if (!classes) return;
    int neutralized = 0;

    for (unsigned int i = 0; i < count; i++) {
        Class c = classes[i];
        const char *cn = class_getName(c);
        if (!cn) continue;
        // 只碰腾讯/微信命名空间，避免误伤系统类
        if (!(strncmp(cn, "WX", 2) == 0 || strncmp(cn, "WC", 2) == 0 ||
              strncmp(cn, "MM", 2) == 0 || strncmp(cn, "WAService", 9) == 0 ||
              strncmp(cn, "Tencent", 7) == 0 || strncmp(cn, "Miu", 3) == 0)) continue;

        unsigned int mc = 0;
        Method *methods = class_copyMethodList(c, &mc);
        if (!methods) continue;

        for (unsigned int j = 0; j < mc; j++) {
            SEL sel = method_getName(methods[j]);
            const char *sn = sel_getName(sel);
            if (!sn) continue;

            BOOL hit = NO;
            for (size_t k = 0; k < nk; k++) {
                if (strcasestr(sn, kKeywords[k])) { hit = YES; break; }
            }
            if (!hit) continue;

            const char *types = method_getTypeEncoding(methods[j]);
            if (!types) continue;
            if (types[0] != 'c' && types[0] != 'B') continue;      // 只处理返回 BOOL
            if (method_getNumberOfArguments(methods[j]) != 2) continue;  // 无额外参数

            IMP imp = imp_implementationWithBlock(^BOOL(id s){ return NO; });
            method_setImplementation(methods[j], imp);
            neutralized++;
        }
        free(methods);
    }
    free(classes);
    if (neutralized) WCAITrace(@"stealth", @"钝化检测方法 %d 个", neutralized);
}

void WCAIInstallStealth(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        // 越狱路径过滤（最先做 —— 大多数检测在启动早期就会调用它）
        @try {
            Class fm = [NSFileManager class];
            Method m1 = class_getInstanceMethod(fm, @selector(fileExistsAtPath:));
            if (m1) {
                g_origFileExists = (void *)method_getImplementation(m1);
                method_setImplementation(m1, (IMP)wcai_fileExists);
            }
            Method m2 = class_getInstanceMethod(fm, @selector(fileExistsAtPath:isDirectory:));
            if (m2) {
                g_origFileExistsIsDir = (void *)method_getImplementation(m2);
                method_setImplementation(m2, (IMP)wcai_fileExistsIsDir);
            }
        } @catch (__unused NSException *e) {}

#if WCAI_ENABLE_GOT_PATCH
        // 可选：隐藏 dyld image（高风险，默认关）
        void *o = NULL;
        wcai_rebind_symbol("_dyld_image_count", (void *)wcai_imageCount, &o);
        g_origImageCount = o;
        o = NULL;
        wcai_rebind_symbol("_dyld_get_image_name", (void *)wcai_imageName, &o);
        g_origImageName = o;
#endif

        // 检测方法钝化放到后台：要遍历上万个类，别拖慢启动
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)),
                       dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            @try { wcai_neutralize_checks(); }
            @catch (__unused NSException *e) {}
        });
    });
}

#pragma mark - ② 行为风控

@implementation WCAIRateLimiter {
    NSMutableDictionary<NSString *, NSMutableArray<NSNumber *> *> *_sentAt;
    NSMutableDictionary<NSString *, NSMutableArray<NSString *> *> *_recentText;
    dispatch_queue_t _q;
}

+ (instancetype)shared {
    static WCAIRateLimiter *s; static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [WCAIRateLimiter new]; });
    return s;
}

- (instancetype)init {
    if ((self = [super init])) {
        _sentAt = [NSMutableDictionary dictionary];
        _recentText = [NSMutableDictionary dictionary];
        _q = dispatch_queue_create("wcai.rate", DISPATCH_QUEUE_SERIAL);
    }
    return self;
}

+ (BOOL)canSendTo:(NSString *)wxid text:(NSString *)text reason:(NSString **)reason {
    __block BOOL ok = YES;
    __block NSString *why = nil;
    WCAIRateLimiter *me = [self shared];
    NSTimeInterval now = [[NSDate date] timeIntervalSince1970];

    dispatch_sync(me->_q, ^{
        NSMutableArray<NSNumber *> *arr = me->_sentAt[wxid];
        if (!arr) { arr = [NSMutableArray array]; me->_sentAt[wxid] = arr; }

        // 清理 60s 外的记录
        NSMutableArray *keep = [NSMutableArray array];
        for (NSNumber *t in arr) {
            if (now - t.doubleValue < 60.0) [keep addObject:t];
        }
        me->_sentAt[wxid] = keep;

        // 规则 1：10 秒内最多 1 条
        if (keep.count && now - keep.lastObject.doubleValue < 10.0) {
            ok = NO;
            why = @"10 秒内已发过一条，等会儿再发";
        }
        // 规则 2：60 秒内最多 3 条
        if (ok && keep.count >= 3) {
            ok = NO;
            why = @"1 分钟内已经发了 3 条，节奏太密了";
        }
        // 规则 3：与最近 3 条完全相同 → 像复读
        if (ok && text.length) {
            NSMutableArray<NSString *> *recent = me->_recentText[wxid];
            for (NSString *t in recent) {
                if ([t isEqualToString:text]) {
                    ok = NO;
                    why = @"和刚才发过的一模一样，改一句再发";
                    break;
                }
            }
        }
    });

    if (reason) *reason = why;
    return ok;
}

+ (void)noteSent:(NSString *)wxid text:(NSString *)text {
    if (wxid.length == 0) return;
    WCAIRateLimiter *me = [self shared];
    NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
    dispatch_async(me->_q, ^{
        NSMutableArray<NSNumber *> *arr = me->_sentAt[wxid];
        if (!arr) { arr = [NSMutableArray array]; me->_sentAt[wxid] = arr; }
        [arr addObject:@(now)];

        NSMutableArray<NSString *> *recent = me->_recentText[wxid];
        if (!recent) { recent = [NSMutableArray array]; me->_recentText[wxid] = recent; }
        if (text.length) {
            [recent addObject:text];
            while (recent.count > 3) [recent removeObjectAtIndex:0];
        }
    });
}

@end

#pragma mark - 崩溃自保护

BOOL WCAIShouldRunSilently(void) {
    return [[NSUserDefaults standardUserDefaults] boolForKey:@"wc_boot_pending"];
}

void WCAIMarkBootOK(void) {
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    [d setBool:YES forKey:@"wc_boot_pending"];
    [d synchronize];
    // 10 秒后仍活着 → 认定本次启动成功
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(10.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        NSUserDefaults *d2 = [NSUserDefaults standardUserDefaults];
        [d2 setBool:NO forKey:@"wc_boot_pending"];
        [d2 synchronize];
    });
}
