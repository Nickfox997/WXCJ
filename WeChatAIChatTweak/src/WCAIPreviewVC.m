//
//  WCAIPreviewVC.m
//  要点：独立 UIWindow 保住生命周期；三条备选就地编辑；发送前二次确认；
//        时机建议与「这条先别回」直接展示。
//

#import "WCAICommon.h"
#import "WCAIPreviewVC.h"
#import "WCAIStore.h"
#import "WCAIInterceptor.h"
#import "WCAILLM.h"
#import "WCAIPrompt.h"

@interface WCAIPreviewVC () <UIScrollViewDelegate>
@property (nonatomic, strong) UIWindow *win;
@property (nonatomic, strong) UIView *card;
@property (nonatomic, strong) UIScrollView *scroll;
@property (nonatomic, strong) NSMutableArray<UITextView *> *editors;
@property (nonatomic, copy)   NSString *wxid;
@property (nonatomic, strong) NSDictionary *payload;

- (void)dismiss:(BOOL)animated;
- (void)buildWindow;
- (void)buildCard;
- (void)buildButtons:(CGFloat)cardH cardW:(CGFloat)cardW;
- (UILabel *)addLabel:(NSString *)text size:(CGFloat)size
                color:(UIColor *)color bold:(BOOL)bold
              yCursor:(CGFloat *)y width:(CGFloat)w;
- (void)onButton:(UIButton *)b;
- (void)onBackdrop:(UITapGestureRecognizer *)g;
- (void)regenerate;
- (void)collectWord;
- (void)confirmSend;
@end

@implementation WCAIPreviewVC

+ (instancetype)shared {
    static WCAIPreviewVC *s; static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [WCAIPreviewVC new]; });
    return s;
}

- (instancetype)init {
    if ((self = [super init])) { self.editors = [NSMutableArray array]; }
    return self;
}

#pragma mark - 展示

- (void)showPayload:(NSDictionary *)payload wxid:(NSString *)wxid {
    self.payload = payload;
    self.wxid = wxid;

    WCAIOnMain(^{
        [self dismiss:NO];
        [self buildWindow];
        [self buildCard];
    });
}

- (void)buildWindow {
    UIWindow *w = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
    w.windowLevel = UIWindowLevelAlert + 100;
    w.backgroundColor = [UIColor colorWithWhite:0 alpha:0.45];
    w.rootViewController = [UIViewController new];
    self.win = w;
    w.hidden = NO;

    UITapGestureRecognizer *tap =
        [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(onBackdrop:)];
    [w addGestureRecognizer:tap];
}

- (void)onBackdrop:(UITapGestureRecognizer *)g {
    CGPoint p = [g locationInView:self.win];
    if (!CGRectContainsPoint(self.card.frame, p)) [self dismiss:YES];
}

#pragma mark - 卡片

- (UILabel *)addLabel:(NSString *)text size:(CGFloat)size
                color:(UIColor *)color bold:(BOOL)bold
              yCursor:(CGFloat *)y width:(CGFloat)w {
    UILabel *l = [UILabel new];
    l.numberOfLines = 0;
    l.font = bold ? [UIFont boldSystemFontOfSize:size] : [UIFont systemFontOfSize:size];
    l.textColor = color;
    l.text = text;
    CGSize sz = [l sizeThatFits:CGSizeMake(w, CGFLOAT_MAX)];
    l.frame = CGRectMake(16, *y, w, sz.height);
    [self.scroll addSubview:l];
    *y += sz.height + 8;
    return l;
}

- (void)buildCard {
    CGRect scr = [UIScreen mainScreen].bounds;
    CGFloat cardW = scr.size.width - 24;
    CGFloat cardH = MIN(scr.size.height - 96, 620);
    self.card = [[UIView alloc] initWithFrame:
                 CGRectMake(12, (scr.size.height - cardH) / 2, cardW, cardH)];
    self.card.backgroundColor = [UIColor whiteColor];
    self.card.layer.cornerRadius = 14;
    self.card.clipsToBounds = YES;
    [self.win addSubview:self.card];

    UIScrollView *sv = [[UIScrollView alloc] initWithFrame:
                        CGRectMake(0, 0, cardW, cardH - 56)];
    sv.delegate = self;
    [self.card addSubview:sv];
    self.scroll = sv;

    CGFloat y = 14;
    CGFloat w = cardW - 32;
    NSDictionary *p = self.payload;
    NSString *lv = p[@"flirt_level"] ?: @"L1";

    // 标题：撩度 + 阶段 + 降级标记
    NSString *title = [NSString stringWithFormat:@"%@ · %@", lv, p[@"stage"] ?: @""];
    if ([p[@"degraded"] boolValue]) title = [title stringByAppendingString:@" · 降级模板"];
    UIColor *titleColor = [lv isEqualToString:@"L3"] ? [UIColor systemRedColor]
                                                     : [UIColor darkGrayColor];
    [self addLabel:title size:13 color:titleColor bold:YES yCursor:&y width:w];

    // 对方原文
    [self addLabel:[NSString stringWithFormat:@"她说：%@", p[@"origin"] ?: @""]
             size:15 color:[UIColor blackColor] bold:NO yCursor:&y width:w];

    // 情绪 / 机会 / 风险
    NSString *meta = [NSString stringWithFormat:@"情绪：%@\n撩机会：%@\n风险：%@",
                      p[@"emotion"] ?: @"-", p[@"opportunity"] ?: @"-", p[@"risk"] ?: @"-"];
    [self addLabel:meta size:13 color:[UIColor darkGrayColor] bold:NO yCursor:&y width:w];

    // 时机建议（核心差异化）
    NSDictionary *timing = p[@"timing"];
    NSInteger wait = [timing[@"wait_minutes"] integerValue];
    NSString *advice = p[@"advice"] ?: @"send_now";
    NSString *timingText;
    if ([advice isEqualToString:@"skip"]) {
        timingText = [NSString stringWithFormat:@"⏸ 这条建议先别回（%@）", timing[@"reason"] ?: @""];
    } else if (wait > 0) {
        timingText = [NSString stringWithFormat:@"⏱ 建议 %ld 分钟后回（%@）",
                      (long)wait, timing[@"reason"] ?: @""];
    } else {
        timingText = @"⏱ 可以现在回";
    }
    UILabel *tl = [self addLabel:timingText size:13
                           color:[UIColor systemOrangeColor] bold:YES
                         yCursor:&y width:w];
    tl.backgroundColor = [UIColor colorWithRed:1 green:0.95 blue:0.85 alpha:1];

    // 记忆引用提示
    NSArray *mems = p[@"memories"];
    if ([mems isKindOfClass:[NSArray class]] && mems.count) {
        NSMutableArray *strs = [NSMutableArray array];
        for (NSDictionary *m in [mems subarrayWithRange:NSMakeRange(0, MIN((NSUInteger)3, mems.count))]) {
            [strs addObject:[NSString stringWithFormat:@"·%@", m[@"content"] ?: @""]];
        }
        [self addLabel:[NSString stringWithFormat:@"引用记忆：\n%@", [strs componentsJoinedByString:@"\n"]]
                 size:12 color:[UIColor grayColor] bold:NO yCursor:&y width:w];
    }

    // 三条备选（可编辑）
    NSArray *replies = p[@"replies"];
    [self.editors removeAllObjects];
    if ([replies isKindOfClass:[NSArray class]]) {
        for (NSDictionary *r in replies) {
            NSString *style = r[@"style"] ?: @"备选";
            [self addLabel:[NSString stringWithFormat:@"【%@】可点开直接改", style]
                     size:12 color:[UIColor grayColor] bold:YES yCursor:&y width:w];

            UITextView *tv = [[UITextView alloc] initWithFrame:CGRectMake(16, y, w, 64)];
            tv.font = [UIFont systemFontOfSize:15];
            tv.text = r[@"text"] ?: @"";
            tv.layer.borderColor = [UIColor colorWithWhite:0.85 alpha:1].CGColor;
            tv.layer.borderWidth = 1;
            tv.layer.cornerRadius = 8;
            tv.textContainerInset = UIEdgeInsetsMake(8, 8, 8, 8);
            [self.scroll addSubview:tv];
            [self.editors addObject:tv];
            y += 64 + 12;
        }
    }

    // 解析 + 钩子
    if ([p[@"hook"] length]) {
        [self addLabel:[NSString stringWithFormat:@"接续钩子：%@", p[@"hook"]]
                 size:13 color:[UIColor darkGrayColor] bold:NO yCursor:&y width:w];
    }
    // 按钮要用的空间
    y += 8;
    sv.contentSize = CGSizeMake(cardW, y);

    [self buildButtons:cardH cardW:cardW];
}

- (void)buildButtons:(CGFloat)cardH cardW:(CGFloat)cardW {
    UIView *bar = [[UIView alloc] initWithFrame:CGRectMake(0, cardH - 56, cardW, 56)];
    bar.backgroundColor = [UIColor colorWithWhite:0.96 alpha:1];
    [self.card addSubview:bar];

    NSArray *titles = @[ @"取消", @"重新生成", @"收藏", @"发送" ];
    CGFloat bw = cardW / 4.0;
    for (NSInteger i = 0; i < titles.count; i++) {
        UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
        b.frame = CGRectMake(bw * i, 0, bw, 56);
        [b setTitle:titles[i] forState:UIControlStateNormal];
        b.tag = i;
        b.titleLabel.font = [UIFont systemFontOfSize:(i == 3 ? 16 : 14)];
        if (i == 3) [b setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
        [b addTarget:self action:@selector(onButton:) forControlEvents:UIControlEventTouchUpInside];
        [bar addSubview:b];
    }
    // 发送键高亮
    UIView *sendBg = [[UIView alloc] initWithFrame:CGRectMake(cardW * 3 / 4 + 6, 8, cardW / 4 - 12, 40)];
    sendBg.backgroundColor = [UIColor systemGreenColor];
    sendBg.layer.cornerRadius = 8;
    sendBg.userInteractionEnabled = NO;
    [bar insertSubview:sendBg atIndex:0];
}

#pragma mark - 交互

- (void)onButton:(UIButton *)b {
    switch (b.tag) {
        case 0: [self dismiss:YES]; break;
        case 1: [self regenerate];  break;
        case 2: [self collectWord]; break;
        case 3: [self confirmSend]; break;
    }
}

- (void)regenerate {
    NSDictionary *req = self.payload[@"req"];
    if (![req isKindOfClass:[NSDictionary class]]) return;
    [self dismiss:NO];
    [[WCAILLM shared] generate:req completion:^(NSDictionary *result, NSError *err) {
        NSMutableDictionary *p = [(result ?: [WCAIPrompt fallbackResultForLevel:self.payload[@"flirt_level"]
                                                                         latest:self.payload[@"origin"] ?: @""]) mutableCopy];
        p[@"origin"] = self.payload[@"origin"];
        p[@"flirt_level"] = self.payload[@"flirt_level"];
        p[@"stage"] = self.payload[@"stage"];
        p[@"memories"] = self.payload[@"memories"];
        p[@"req"] = req;
        p[@"degraded"] = @(err != nil);
        WCAIOnMain(^{ [self showPayload:p wxid:self.wxid]; });
    }];
}

- (void)collectWord {
    // 收藏当前第一条（或已编辑的）话术
    NSString *t = self.editors.count ? self.editors.firstObject.text : @"";
    if (t.length) {
        [[WCAIStore shared] setConfig:@"_last_fav" value:t];
        WCAITrace(@"fav", @"收藏话术 %lu 字", (unsigned long)t.length);
    }
}

- (void)confirmSend {
    // 取第一条非空（优先用户改过的）
    NSString *picked = nil;
    for (UITextView *tv in self.editors) {
        if (tv.text.length) { picked = tv.text; break; }
    }
    if (!picked.length) return;

    UIAlertController *ac =
        [UIAlertController alertControllerWithTitle:@"确认发送？"
                                            message:picked
                                     preferredStyle:UIAlertControllerStyleAlert];
    [ac addAction:[UIAlertAction actionWithTitle:@"发送" style:UIAlertActionStyleDefault
                                        handler:^(UIAlertAction *a) {
        [[WCAIInterceptor shared] sendText:picked toWxid:self.wxid];
        [self dismiss:YES];
    }]];
    [ac addAction:[UIAlertAction actionWithTitle:@"再改改" style:UIAlertActionStyleCancel handler:nil]];

    [self.win.rootViewController presentViewController:ac animated:YES completion:nil];
}

- (void)dismiss:(BOOL)animated {
    UIWindow *w = self.win;
    self.win = nil;
    self.card = nil;
    [self.editors removeAllObjects];
    if (!w) return;
    if (animated) {
        [UIView animateWithDuration:0.15 animations:^{ w.alpha = 0; }
                         completion:^(BOOL f) { w.hidden = YES; w.rootViewController = nil; }];
    } else {
        w.hidden = YES;
        w.rootViewController = nil;
    }
}

@end
