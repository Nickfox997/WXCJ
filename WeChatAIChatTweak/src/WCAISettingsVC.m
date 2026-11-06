//
//  WCAISettingsVC.m
//  主号构建：界面里不存在任何「全自动」入口，只有一行灰字说明。
//

#import "WCAICommon.h"
#import "WCAISettingsVC.h"
#import "WCAIStore.h"
#import "WCAIPrompt.h"
#import "WCAIInterceptor.h"

#pragma mark - 主设置页

@interface WCAISettingsVC () <UITableViewDataSource, UITableViewDelegate>
@property (nonatomic, strong) UITableView *table;
@property (nonatomic, strong) NSArray<NSArray<NSString *> *> *sections;
@end

@implementation WCAISettingsVC

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"AI 助手";
    self.view.backgroundColor = [UIColor groupTableViewBackgroundColor];

    self.sections = @[
        @[ @"总开关" ],
        @[ @"API 地址", @"API 密钥", @"模型" ],
        @[ @"免打扰开始(时)", @"免打扰结束(时)", @"敏感词" ],
        @[ @"联系人档案", @"立即备份数据" ],
        @[ @"运行状态", @"清空运行日志" ]
    ];

    self.table = [[UITableView alloc] initWithFrame:self.view.bounds style:UITableViewStyleGrouped];
    self.table.dataSource = self;
    self.table.delegate = self;
    self.table.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self.view addSubview:self.table];

    self.navigationItem.rightBarButtonItem =
        [[UIBarButtonItem alloc] initWithTitle:@"关闭" style:UIBarButtonItemStyleDone
                                        target:self action:@selector(close)];
}

- (void)close {
    [self.navigationController dismissViewControllerAnimated:YES completion:nil];
}

#pragma mark - 数据源

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tv { return self.sections.count; }
- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s {
    return self.sections[s].count;
}
- (NSString *)tableView:(UITableView *)tv titleForHeaderInSection:(NSInteger)s {
    NSArray *titles = @[ @"开关", @"大模型接口", @"过滤", @"数据", @"调试" ];
    return s < titles.count ? titles[s] : @"";
}
- (NSString *)tableView:(UITableView *)tv titleForFooterInSection:(NSInteger)s {
    if (s == 0) return @"当前构建禁用全自动（主号安全构建）：进程内不存在自动发送路径。";
    return nil;
}

- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    static NSString *cid = @"wcai.cell";
    UITableViewCell *c = [tv dequeueReusableCellWithIdentifier:cid];
    if (!c) c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1
                                          reuseIdentifier:cid];

    WCAIStore *st = [WCAIStore shared];
    NSString *title = self.sections[ip.section][ip.row];
    c.textLabel.text = title;
    c.accessoryView = nil;
    c.accessoryType = UITableViewCellAccessoryNone;

    if (ip.section == 0) {
        UISwitch *sw = [[UISwitch alloc] init];
        sw.on = [st configInt:@"global_enable" default:1] == 1;
        [sw addTarget:self action:@selector(toggleGlobal:) forControlEvents:UIControlEventValueChanged];
        c.accessoryView = sw;
    } else if (ip.section == 1) {
        NSString *key = @[ @"api_url", @"api_key", @"model" ][ip.row];
        NSString *v = [st config:key];
        if ([key isEqualToString:@"api_key"] && v.length) {
            c.detailTextLabel.text = @"已配置";
        } else {
            c.detailTextLabel.text = v.length ? v : @"未设置";
        }
        c.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    } else if (ip.section == 2) {
        if (ip.row < 2) {
            NSString *key = ip.row == 0 ? @"quiet_start" : @"quiet_end";
            NSInteger v = [st configInt:key default:-1];
            c.detailTextLabel.text = v < 0 ? @"关闭" : [NSString stringWithFormat:@"%ld 点", (long)v];
        } else {
            NSString *v = [st config:@"ban_words"];
            c.detailTextLabel.text = v.length ? [NSString stringWithFormat:@"%lu 个",
                                                  (unsigned long)[v componentsSeparatedByString:@","].count]
                                              : @"未设置";
        }
        c.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    } else if (ip.section == 3) {
        if (ip.row == 0) {
            c.detailTextLabel.text = [NSString stringWithFormat:@"%lu 人",
                                      (unsigned long)[[WCAIStore shared] allContacts].count];
        }
        c.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    } else {
        if (ip.row == 0) {
            WCAIRuntime *rt = [WCAIRuntime shared];
            c.detailTextLabel.text = [NSString stringWithFormat:@"wx%@ / hook %ld·%ld",
                                      rt.wxVersion ?: @"?", (long)rt.hookHit, (long)rt.hookMiss];
            c.detailTextLabel.font = [UIFont systemFontOfSize:11];
        }
        c.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    }
    return c;
}

#pragma mark - 交互

- (void)toggleGlobal:(UISwitch *)sw {
    [[WCAIStore shared] setConfig:@"global_enable" value:sw.on ? @"1" : @"0"];
    WCAITrace(@"config", @"global_enable=%d", sw.on);
}

- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tv deselectRowAtIndexPath:ip animated:YES];
    WCAIStore *st = [WCAIStore shared];

    if (ip.section == 1) {
        NSString *key = @[ @"api_url", @"api_key", @"model" ][ip.row];
        NSString *cur = [st config:key];
        [self askText:key current:cur secure:(ip.row == 1) done:^(NSString *v) {
            [st setConfig:key value:v];
            [tv reloadData];
        }];
    } else if (ip.section == 2) {
        if (ip.row < 2) {
            NSString *key = ip.row == 0 ? @"quiet_start" : @"quiet_end";
            [self askText:key current:[st config:key] secure:NO done:^(NSString *v) {
                [st setConfig:key value:v];
                [tv reloadData];
            }];
        } else {
            [self askText:@"敏感词（逗号分隔）" current:[st config:@"ban_words"] secure:NO
                     done:^(NSString *v) {
                [st setConfig:@"ban_words" value:v];
                [tv reloadData];
            }];
        }
    } else if (ip.section == 3) {
        if (ip.row == 0) {
            [self.navigationController pushViewController:[WCAIContactListVC new] animated:YES];
        } else {
            NSString *path = [st writeBackupSnapshot];
            UIAlertController *ac = [UIAlertController
                alertControllerWithTitle:@"备份完成" message:path ?: @"失败"
                          preferredStyle:UIAlertControllerStyleAlert];
            [ac addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault
                                                 handler:nil]];
            [self presentViewController:ac animated:YES completion:nil];
        }
    } else {
        if (ip.row == 1) {
            [st exec:^(sqlite3 *db) {
                sqlite3_exec(db, "DELETE FROM run_log;", NULL, NULL, NULL);
            }];
            [tv reloadData];
        }
    }
}

- (void)askText:(NSString *)title current:(NSString *)cur
         secure:(BOOL)secure done:(void (^)(NSString *))done {
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:title
                                                               message:nil
                                                        preferredStyle:UIAlertControllerStyleAlert];
    [ac addTextFieldWithConfigurationHandler:^(UITextField *tf) {
        tf.text = cur;
        tf.secureTextEntry = secure;
        tf.autocapitalizationType = UITextAutocapitalizationTypeNone;
    }];
    [ac addAction:[UIAlertAction actionWithTitle:@"保存" style:UIAlertActionStyleDefault
                                        handler:^(UIAlertAction *a) {
        done(ac.textFields.firstObject.text ?: @"");
    }]];
    [ac addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:ac animated:YES completion:nil];
}

@end

#pragma mark - 联系人列表

@implementation WCAIContactListVC

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"联系人档案";
    self.navigationItem.rightBarButtonItem =
        [[UIBarButtonItem alloc] initWithTitle:@"新增" style:UIBarButtonItemStylePlain
                                        target:self action:@selector(addNew)];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self.tableView reloadData];
}

- (void)addNew {
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"新增联系人"
                                                               message:@"输入 wxid"
                                                        preferredStyle:UIAlertControllerStyleAlert];
    [ac addTextFieldWithConfigurationHandler:nil];
    [ac addAction:[UIAlertAction actionWithTitle:@"确定" style:UIAlertActionStyleDefault
                                        handler:^(UIAlertAction *a) {
        NSString *w = ac.textFields.firstObject.text;
        if (!w.length) return;
        [[WCAIStore shared] saveContact:[[WCAIStore shared] contact:w]];
        [self.tableView reloadData];
    }]];
    [ac addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:ac animated:YES completion:nil];
}

- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s {
    return [[WCAIStore shared] allContacts].count;
}

- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    static NSString *cid = @"wcai.contact";
    UITableViewCell *c = [tv dequeueReusableCellWithIdentifier:cid];
    if (!c) c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle
                                          reuseIdentifier:cid];
    NSArray *all = [[WCAIStore shared] allContacts];
    if (ip.row < all.count) {
        WCAIContact *ct = all[ip.row];
        c.textLabel.text = ct.nick.length ? ct.nick : ct.wxid;
        c.detailTextLabel.text = [NSString stringWithFormat:@"%@ · %@ · %@",
                                  ct.flirtLevel, ct.stage, ct.enable ? @"开启" : @"关闭"];
    }
    c.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    return c;
}

- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tv deselectRowAtIndexPath:ip animated:YES];
    NSArray *all = [[WCAIStore shared] allContacts];
    if (ip.row < all.count) {
        WCAIContact *ct = all[ip.row];
        [self.navigationController pushViewController:
            [[WCAIContactEditVC alloc] initWithWxid:ct.wxid] animated:YES];
    }
}

@end

#pragma mark - 联系人编辑

@interface WCAIContactEditVC ()
@property (nonatomic, copy) NSString *wxid;
@property (nonatomic, strong) WCAIContact *contact;
@end

@implementation WCAIContactEditVC

- (instancetype)initWithWxid:(NSString *)wxid {
    if ((self = [super init])) { _wxid = [wxid copy]; }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = self.wxid;
    self.view.backgroundColor = [UIColor groupTableViewBackgroundColor];
    self.contact = [[WCAIStore shared] contact:self.wxid];

    UIScrollView *sv = [[UIScrollView alloc] initWithFrame:self.view.bounds];
    sv.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self.view addSubview:sv];

    CGFloat y = 20, w = self.view.bounds.size.width - 32;
    NSArray *labels = @[ @"昵称", @"我的人设", @"她的人设", @"我的语气卡" ];
    NSArray *keys = @[ @"nick", @"myPrompt", @"herPrompt", @"flavorCard" ];

    for (NSUInteger i = 0; i < labels.count; i++) {
        UILabel *l = [UILabel new];
        l.font = [UIFont systemFontOfSize:12];
        l.textColor = [UIColor grayColor];
        l.text = labels[i];
        l.frame = CGRectMake(16, y, w, 16);
        [sv addSubview:l];
        y += 18;

        UITextView *tv = [[UITextView alloc] initWithFrame:CGRectMake(16, y, w, i == 0 ? 36 : 72)];
        tv.font = [UIFont systemFontOfSize:14];
        tv.text = [self.contact valueForKey:keys[i]] ?: @"";
        tv.tag = 100 + i;
        tv.layer.borderWidth = 1;
        tv.layer.borderColor = [UIColor colorWithWhite:0.88 alpha:1].CGColor;
        tv.layer.cornerRadius = 8;
        [sv addSubview:tv];
        y += tv.bounds.size.height + 14;
    }

    // 撩度选择
    UILabel *lvLabel = [UILabel new];
    lvLabel.font = [UIFont systemFontOfSize:12];
    lvLabel.textColor = [UIColor grayColor];
    lvLabel.text = @"撩动等级";
    lvLabel.frame = CGRectMake(16, y, w, 16);
    [sv addSubview:lvLabel];
    y += 20;

    UISegmentedControl *seg = [[UISegmentedControl alloc] initWithItems:@[ @"L0", @"L1", @"L2", @"L3" ]];
    seg.frame = CGRectMake(16, y, w, 32);
    NSArray *levels = @[ @"L0", @"L1", @"L2", @"L3" ];
    seg.selectedSegmentIndex = [levels indexOfObject:self.contact.flirtLevel];
    if (seg.selectedSegmentIndex == NSNotFound) seg.selectedSegmentIndex = 1;
    seg.tag = 200;
    [sv addSubview:seg];
    y += 44;

    // 关系阶段
    UILabel *stLabel = [UILabel new];
    stLabel.font = [UIFont systemFontOfSize:12];
    stLabel.textColor = [UIColor grayColor];
    stLabel.text = @"关系阶段";
    stLabel.frame = CGRectMake(16, y, w, 16);
    [sv addSubview:stLabel];
    y += 20;

    UISegmentedControl *seg2 = [[UISegmentedControl alloc] initWithItems:@[ @"初识", @"暧昧", @"好友", @"恋人" ]];
    seg2.frame = CGRectMake(16, y, w, 32);
    NSArray *stages = @[ @"初识", @"暧昧", @"好友", @"恋人" ];
    seg2.selectedSegmentIndex = [stages indexOfObject:self.contact.stage];
    if (seg2.selectedSegmentIndex == NSNotFound) seg2.selectedSegmentIndex = 0;
    seg2.tag = 201;
    [sv addSubview:seg2];
    y += 44;

    // 开关 + 保存
    UISwitch *sw = [[UISwitch alloc] init];
    sw.on = self.contact.enable == 1;
    sw.frame = CGRectMake(16, y, 51, 31);
    sw.tag = 202;
    [sv addSubview:sw];

    UIButton *save = [UIButton buttonWithType:UIButtonTypeSystem];
    save.frame = CGRectMake(w - 100, y, 100, 36);
    [save setTitle:@"保存" forState:UIControlStateNormal];
    [save addTarget:self action:@selector(save) forControlEvents:UIControlEventTouchUpInside];
    [sv addSubview:save];

    UIButton *stats = [UIButton buttonWithType:UIButtonTypeSystem];
    stats.frame = CGRectMake(16, y + 44, 200, 32);
    [stats setTitle:@"生成语气卡（读我方历史）" forState:UIControlStateNormal];
    stats.titleLabel.font = [UIFont systemFontOfSize:13];
    [stats addTarget:self action:@selector(regenFlavor) forControlEvents:UIControlEventTouchUpInside];
    [sv addSubview:stats];

    y += 90;
    sv.contentSize = CGSizeMake(self.view.bounds.size.width, y);
}

- (void)regenFlavor {
    NSArray *chats = [[WCAIStore shared] recentChats:self.wxid limit:200];
    NSString *card = [WCAIPrompt flavorCardFromChats:chats];
    UITextView *tv = [self.view viewWithTag:103];
    if (card.length && tv) tv.text = card;
}

- (void)save {
    self.contact.nick       = [(UITextView *)[self.view viewWithTag:100] text];
    self.contact.myPrompt   = [(UITextView *)[self.view viewWithTag:101] text];
    self.contact.herPrompt  = [(UITextView *)[self.view viewWithTag:102] text];
    self.contact.flavorCard = [(UITextView *)[self.view viewWithTag:103] text];

    UISegmentedControl *seg  = (UISegmentedControl *)[self.view viewWithTag:200];
    UISegmentedControl *seg2 = (UISegmentedControl *)[self.view viewWithTag:201];
    UISwitch *sw = (UISwitch *)[self.view viewWithTag:202];

    self.contact.flirtLevel = @[ @"L0", @"L1", @"L2", @"L3" ][seg.selectedSegmentIndex];
    self.contact.stage      = @[ @"初识", @"暧昧", @"好友", @"恋人" ][seg2.selectedSegmentIndex];
    self.contact.enable     = sw.on ? 1 : 0;

    [[WCAIStore shared] saveContact:self.contact];
    [self.navigationController popViewControllerAnimated:YES];
}

@end
