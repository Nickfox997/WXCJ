//
//  WCAILLM.m
//  超时：连接 5s / 总 30s（手动模式；8s 会把正常请求判死）
//  失败：重试 1 次（800ms 退避）→ 仍失败由调用方降级本地模板
//

#import "WCAICommon.h"
#import "WCAILLM.h"
#import "WCAIStore.h"

@interface WCAILLM ()
@property (nonatomic, strong) NSURLSession *session;
@end

@implementation WCAILLM

+ (instancetype)shared {
    static WCAILLM *s; static dispatch_once_t once;
    dispatch_once(&once, ^{
        s = [WCAILLM new];
        // 独立会话：不复用微信的任何 cookie / 凭据 / 缓存，避免与登录态产生关联
        NSURLSessionConfiguration *cfg = [NSURLSessionConfiguration ephemeralSessionConfiguration];
        cfg.timeoutIntervalForRequest  = 8.0;    // 连接/首包
        cfg.timeoutIntervalForResource = 30.0;   // 总时长
        cfg.HTTPShouldSetCookies       = NO;
        cfg.HTTPCookieAcceptPolicy     = NSHTTPCookieAcceptPolicyNever;
        cfg.HTTPCookieStorage          = nil;
        cfg.URLCredentialStorage       = nil;
        cfg.URLCache                   = nil;
        cfg.requestCachePolicy         = NSURLRequestReloadIgnoringLocalCacheData;
        cfg.HTTPAdditionalHeaders = @{
            @"Content-Type": @"application/json",
            // 伪装成常规浏览器 UA，不暴露任何产品/插件特征
            @"User-Agent": @"Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) "
                            @"AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 "
                            @"Mobile/15E148 Safari/604.1"
        };
        s.session = [NSURLSession sessionWithConfiguration:cfg];
    });
    return s;
}

- (NSString *)endpoint {
    NSString *u = [[WCAIStore shared] config:@"api_url"];
    if (u.length == 0) return nil;
    if ([u containsString:@"chat/completions"]) return u;
    if ([u hasSuffix:@"/"]) u = [u substringToIndex:u.length - 1];
    if ([u hasSuffix:@"/v1"]) return [u stringByAppendingString:@"/chat/completions"];
    return [u stringByAppendingString:@"/v1/chat/completions"];
}

- (void)generate:(NSDictionary *)req
      completion:(void (^)(NSDictionary *, NSError *))completion {
    [self attempt:req retries:1 completion:completion];
}

- (void)attempt:(NSDictionary *)req retries:(NSInteger)retries
     completion:(void (^)(NSDictionary *, NSError *))completion {

    NSString *ep = [self endpoint];
    NSString *key = [[WCAIStore shared] config:@"api_key"];
    NSString *model = [[WCAIStore shared] config:@"model"];

    if (ep.length == 0 || key.length == 0) {
        if (completion) completion(nil, [NSError errorWithDomain:@"wcai"
                                                            code:1001
                                                        userInfo:@{NSLocalizedDescriptionKey:
                                                                       @"未配置 API 地址或密钥"}]);
        return;
    }

    NSDictionary *body = @{
        @"model": model.length ? model : @"gpt-4o-mini",
        @"messages": @[ @{ @"role": @"system", @"content": req[@"system"] ?: @"" },
                        @{ @"role": @"user",   @"content": req[@"user"]   ?: @"" } ],
        @"temperature": @0.85,
        @"stream": @NO
    };

    NSMutableURLRequest *r = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:ep]];
    r.HTTPMethod = @"POST";
    [r setValue:[@"Bearer " stringByAppendingString:key] forHTTPHeaderField:@"Authorization"];
    [r setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    r.HTTPBody = [NSJSONSerialization dataWithJSONObject:body options:0 error:nil];

    NSURLSessionDataTask *t = [self.session dataTaskWithRequest:r
                                             completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
        if (err) {
            if (retries > 0) {
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.8 * NSEC_PER_SEC)),
                               dispatch_get_global_queue(0, 0), ^{
                    [self attempt:req retries:retries - 1 completion:completion];
                });
                return;
            }
            if (completion) completion(nil, err);
            return;
        }

        NSError *jerr = nil;
        id json = data.length ? [NSJSONSerialization JSONObjectWithData:data options:0 error:&jerr] : nil;
        NSString *content = nil;
        if ([json isKindOfClass:[NSDictionary class]]) {
            NSArray *choices = json[@"choices"];
            if ([choices isKindOfClass:[NSArray class]] && choices.count) {
                id msg = choices.firstObject[@"message"];
                if ([msg isKindOfClass:[NSDictionary class]]) content = msg[@"content"];
            }
            if (!content.length) {
                // 兼容部分端点的 error 结构
                id e = json[@"error"];
                if ([e isKindOfClass:[NSDictionary class]]) content = e[@"message"];
            }
        }
        if (content.length == 0) {
            if (retries > 0) {
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.8 * NSEC_PER_SEC)),
                               dispatch_get_global_queue(0, 0), ^{
                    [self attempt:req retries:retries - 1 completion:completion];
                });
                return;
            }
            if (completion) completion(nil, [NSError errorWithDomain:@"wcai" code:1002
                                                           userInfo:@{NSLocalizedDescriptionKey:
                                                                          @"响应解析失败"}]);
            return;
        }

        NSDictionary *parsed = [WCAILLM parseContent:content];
        NSArray *replies = parsed[@"replies"];
        if (![replies isKindOfClass:[NSArray class]] || replies.count == 0) {
            if (completion) completion(nil, [NSError errorWithDomain:@"wcai" code:1003
                                                           userInfo:@{NSLocalizedDescriptionKey:
                                                                          @"回复结构不完整"}]);
            return;
        }
        if (completion) completion(parsed, nil);
    }];
    [t resume];
}

#pragma mark - 解析容错链

+ (NSDictionary *)parseContent:(NSString *)col {
    if (col.length == 0) return @{};

    // 1) 直接解析
    NSData *d = [col dataUsingEncoding:NSUTF8StringEncoding];
    id j = [NSJSONSerialization JSONObjectWithData:d options:0 error:nil];
    if ([j isKindOfClass:[NSDictionary class]]) return j;

    // 2) 剥 ```json 围栏
    NSString *s = col;
    NSRange r1 = [s rangeOfString:@"```json"];
    if (r1.location != NSNotFound) s = [s substringFromIndex:NSMaxRange(r1)];
    else {
        NSRange r2 = [s rangeOfString:@"```"];
        if (r2.location != NSNotFound) s = [s substringFromIndex:NSMaxRange(r2)];
    }
    NSRange r3 = [s rangeOfString:@"```"];
    if (r3.location != NSNotFound) s = [s substringToIndex:r3.location];

    j = [NSJSONSerialization JSONObjectWithData:[s dataUsingEncoding:NSUTF8StringEncoding]
                                        options:0 error:nil];
    if ([j isKindOfClass:[NSDictionary class]]) return j;

    // 3) 截首尾大括号
    NSRange b1 = [s rangeOfString:@"{"];
    NSRange b2 = [s rangeOfString:@"}" options:NSBackwardsSearch];
    if (b1.location != NSNotFound && b2.location != NSNotFound && b2.location > b1.location) {
        NSString *sub = [s substringWithRange:NSMakeRange(b1.location, b2.location - b1.location + 1)];
        j = [NSJSONSerialization JSONObjectWithData:[sub dataUsingEncoding:NSUTF8StringEncoding]
                                            options:0 error:nil];
        if ([j isKindOfClass:[NSDictionary class]]) return j;
    }

    // 4) 兜底：正则抓 "text":"..."
    NSMutableArray *replies = [NSMutableArray array];
    NSRegularExpression *re =
        [NSRegularExpression regularExpressionWithPattern:@"\"text\"\\s*:\\s*\"([^\"]+)\""
                                                  options:0 error:nil];
    NSArray *ms = [re matchesInString:col options:0 range:NSMakeRange(0, col.length)];
    NSArray *styles = @[ @"稳妥", @"拉扯", @"简短", @"备用" ];
    for (NSUInteger i = 0; i < ms.count && i < 3; i++) {
        NSTextCheckingResult *m = ms[i];
        NSString *t = [col substringWithRange:[m rangeAtIndex:1]];
        [replies addObject:@{ @"style": styles[MIN(i, styles.count - 1)], @"text": t }];
    }
    if (replies.count) {
        return @{ @"emotion": @"", @"opportunity": @"", @"risk": @"",
                  @"replies": replies, @"hook": @"",
                  @"timing": @{ @"wait_minutes": @0, @"reason": @"" },
                  @"advice": @"send_now" };
    }
    return @{};
}

@end
