// ============================================================================
//  GaodeClean 0.9.125（A6）—— 内置设置面板
//
//  打开方式：在高德地图主界面**双指长按任意位置**。
//    · 不用 PreferenceLoader —— 那需要私有框架 Preferences.framework 的头文件，
//      而 iPhoneOS SDK 里没有（只有 .tbd），theos 的 vendor/include 也不带，
//      为了一个设置面板去引第三方头文件不值得。
//    · 也不用进「设置」App —— 少一层跳转，双指长按是老大指定的入口。
//
//  技术选择：
//    · 纯 UIKit（UITableView + UISwitch），零私有 API，零额外依赖。
//    · 面板是独立 UIWindow（windowLevel = UIWindowLevelAlert + 1），
//      不挂在 App 的视图树里 —— 避免被 App 的布局/隐藏逻辑波及。
//    · 手势挂在 App 的 key window 上，`numberOfTouchesRequired = 2`，
//      与高德的单指手势天然不冲突；长按 0.6 秒判定成功。
//
//  数据：NSUserDefaults(suiteName: com.jibamao.gaodeclean)，与 GCPrefBool 同一域名。
// ============================================================================

#import <UIKit/UIKit.h>
#import <objc/runtime.h>

#pragma mark - 数据模型

// 设置项定义：key 必须与 GaodeClean.m 里的 GC_PREF_* 常量逐字一致
typedef struct {
    const char *group;      // 分组标题（NULL = 沿用上一组）
    const char *key;        // NSUserDefaults 键
    const char *title;      // 中文标题
    const char *note;       // 副标题（NULL = 无）
} GCSettingItem;

static GCSettingItem kGCSettingItems[] = {
    { "广告与横幅", "hideTopBanner",  "移除顶部横幅与运营通知条", "「请查收：【…】」这类" },
    { NULL,         "hideSplashAd",   "移除开屏广告",             NULL },
    { "视觉清理",   "hideFog",        "移除白雾与上拉闪白",       NULL },
    { NULL,         "hideBlur",       "移除顶部模糊带",           NULL },
    { NULL,         "hideTabBarHint", "移除底栏「上拉发现」引导",  NULL },
    { "布局调整",   "alignWidgets",   "控件归位",                 "定位/路线胶囊、连接车机" },
    { NULL,         "narrowBar",      "底栏胶囊缩窄",             NULL },
    { NULL,         "darkenWidgets",  "深色模式统一压白",         NULL },
};
static const int kGCSettingCount = (int)(sizeof(kGCSettingItems) / sizeof(kGCSettingItems[0]));

// 编译期校验：数组长度必须与 GaodeClean.m 里的开关数一致（8 个）。
//   改键名/加减开关时，两边只要有一边忘了改，这里直接编译失败 ——
//   比「上机发现某个开关没反应」便宜得多。
_Static_assert(sizeof(kGCSettingItems) / sizeof(kGCSettingItems[0]) == 8,
               "设置项数量必须与 GaodeClean.m 的 GC_PREF_* 常量一一对应（当前 8 个）");

static NSString *const kGCPanelDomain = @"com.jibamao.gaodeclean";
// 与 GaodeClean.m 的 kGCVersion 同步（门禁会比对体内版本串，这里只是显示用）
static NSString *const kGCPanelVersion = @"0.9.125";

// ★0.9.125（A7）：给面板窗口打「自己人」标记。
//   插件有多处会遍历 GCAllWindows() 做全窗扫描（白雾、白蒙版、缩窄描边、广告窗），
//   面板若被扫进去：轻则每拍浪费时间，重则被当成「半透明白雾」直接隐藏掉。
//   用关联对象打标，GaodeClean.m 侧用同一套键判断并跳过。
static char GCPanelWindowKey;
BOOL GCPanelIsOwnWindow(UIWindow *w) {
    if (!w) return NO;
    return objc_getAssociatedObject(w, &GCPanelWindowKey) != nil;
}

// UIApplication.windows 在 iOS 15 起弃用，但本项目要同时兼容 iOS 15 以下与多场景，
// 且这只是「取一个可挂手势的窗口」，用任何等价入口都可以。
// 统一封装在这里集中 suppress 警告，保持全文件 0 警告基线（与 GaodeClean.m 的
// GCAllWindows 同一处理方式）。
static NSArray<UIWindow *> *GCFPanelAllWindows(void) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    return UIApplication.sharedApplication.windows;
#pragma clang diagnostic pop
}



static NSUserDefaults *GCPanelDefaults(void) {
    static NSUserDefaults *d;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        d = [[NSUserDefaults alloc] initWithSuiteName:kGCPanelDomain];
        if (!d) d = NSUserDefaults.standardUserDefaults;
    });
    return d;
}

#pragma mark - 面板

@interface GCSettingPanel : NSObject
<UITableViewDataSource, UITableViewDelegate>
@property (nonatomic, strong) UIWindow *window;
@property (nonatomic, strong) UITableView *table;
- (void)handleLongPress:(UILongPressGestureRecognizer *)g;
@end

@implementation GCSettingPanel

+ (instancetype)shared {
    static GCSettingPanel *s;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [GCSettingPanel new]; });
    return s;
}

- (void)show {
    if (self.window && self.window.hidden == NO) return;

    UIWindowScene *scene = nil;
    for (UIWindow *w in GCFPanelAllWindows()) {
        if (w.windowScene) { scene = w.windowScene; break; }
    }
    UIWindow *win = scene ? [[UIWindow alloc] initWithWindowScene:scene]
                          : [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    win.windowLevel = UIWindowLevelAlert + 1;
    win.backgroundColor = UIColor.clearColor;
    // 打「自己人」标记 —— 插件的全窗扫描据此跳过本窗口（见 GCPanelIsOwnWindow 注释）
    objc_setAssociatedObject(win, &GCPanelWindowKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    UIViewController *vc = [UIViewController new];
    vc.view.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.55];

    // 点击遮罩关闭（只认遮罩本身，不吞表格的点击）
    UIControl *mask = [[UIControl alloc] initWithFrame:vc.view.bounds];
    mask.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [mask addTarget:self action:@selector(dismiss) forControlEvents:UIControlEventTouchUpInside];
    [vc.view addSubview:mask];

    // 卡片
    CGFloat W = MIN(360, UIScreen.mainScreen.bounds.size.width - 40);
    CGFloat H = MIN(UIScreen.mainScreen.bounds.size.height * 0.72,
                    64.0 + kGCSettingCount * 62.0 + 96.0);
    UIView *card = [[UIView alloc] initWithFrame:CGRectMake(0, 0, W, H)];
    card.center = CGPointMake(UIScreen.mainScreen.bounds.size.width / 2,
                              UIScreen.mainScreen.bounds.size.height / 2);
    card.autoresizingMask = UIViewAutoresizingFlexibleTopMargin | UIViewAutoresizingFlexibleBottomMargin
                          | UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleRightMargin;
    card.backgroundColor = [UIColor secondarySystemBackgroundColor];
    card.layer.cornerRadius = 16;
    card.layer.masksToBounds = YES;
    [vc.view addSubview:card];

    // 标题
    UILabel *title = [[UILabel alloc] initWithFrame:CGRectMake(20, 18, W - 40, 24)];
    title.text = @"GaodeClean 设置";
    title.font = [UIFont boldSystemFontOfSize:18];
    [card addSubview:title];

    UILabel *sub = [[UILabel alloc] initWithFrame:CGRectMake(20, 42, W - 40, 16)];
    sub.text = kGCPanelVersion;
    sub.font = [UIFont systemFontOfSize:12];
    sub.textColor = [UIColor secondaryLabelColor];
    [card addSubview:sub];

    // 表格
    UITableView *tb = [[UITableView alloc] initWithFrame:CGRectMake(0, 64, W, H - 64 - 72)
                                                   style:UITableViewStyleInsetGrouped];
    tb.dataSource = self;
    tb.delegate = self;
    tb.backgroundColor = UIColor.clearColor;
    tb.separatorInset = UIEdgeInsetsMake(0, 16, 0, 16);
    [tb registerClass:UITableViewCell.class forCellReuseIdentifier:@"cell"];
    [card addSubview:tb];
    self.table = tb;

    // 底部按钮
    UIButton *done = [UIButton buttonWithType:UIButtonTypeSystem];
    done.frame = CGRectMake(20, H - 56, W - 40, 40);
    done.backgroundColor = [UIColor systemBlueColor];
    done.layer.cornerRadius = 10;
    [done setTitle:@"完成" forState:UIControlStateNormal];
    [done setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    done.titleLabel.font = [UIFont boldSystemFontOfSize:16];
    [done addTarget:self action:@selector(dismiss) forControlEvents:UIControlEventTouchUpInside];
    [card addSubview:done];

    win.rootViewController = vc;
    win.hidden = NO;
    self.window = win;

    // 出现动画
    card.transform = CGAffineTransformMakeScale(0.92, 0.92);
    card.alpha = 0;
    [UIView animateWithDuration:0.18 animations:^{
        card.transform = CGAffineTransformIdentity;
        card.alpha = 1;
    }];
}

- (void)dismiss {
    UIWindow *w = self.window;
    self.window = nil;
    self.table = nil;
    [UIView animateWithDuration:0.14 animations:^{
        w.alpha = 0;
    } completion:^(__unused BOOL done) {
        w.hidden = YES;
        w.rootViewController = nil;
    }];
}

// 双指长按。只在 Began 触发一次（否则按住不放会反复触发）。
- (void)handleLongPress:(UILongPressGestureRecognizer *)g {
    if (g.state != UIGestureRecognizerStateBegan) return;
    [self show];
}

#pragma mark - 表格

- (NSInteger)numberOfSectionsInTableView:(__unused UITableView *)tv { return 1; }

- (NSInteger)tableView:(__unused UITableView *)tv numberOfRowsInSection:(__unused NSInteger)s {
    return kGCSettingCount;
}

- (NSString *)tableView:(__unused UITableView *)tv titleForHeaderInSection:(__unused NSInteger)s {
    return @"开关默认全部关闭；改完需完全退出高德再进";
}

- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    UITableViewCell *c = [tv dequeueReusableCellWithIdentifier:@"cell" forIndexPath:ip];
    if (ip.row < 0 || ip.row >= kGCSettingCount) return c;

    const GCSettingItem *it = &kGCSettingItems[ip.row];
    UIListContentConfiguration *cfg = [UIListContentConfiguration subtitleCellConfiguration];
    cfg.text = @(it->title);
    if (it->note) cfg.secondaryText = @(it->note);
    cfg.secondaryTextProperties.color = [UIColor secondaryLabelColor];
    c.contentConfiguration = cfg;

    UISwitch *sw = [[UISwitch alloc] init];
    sw.on = [GCPanelDefaults() boolForKey:@(it->key)];
    sw.tag = ip.row;
    [sw addTarget:self action:@selector(toggle:) forControlEvents:UIControlEventValueChanged];
    c.accessoryView = sw;
    c.selectionStyle = UITableViewCellSelectionStyleNone;
    return c;
}

- (void)toggle:(UISwitch *)sw {
    if (sw.tag < 0 || sw.tag >= kGCSettingCount) return;
    const GCSettingItem *it = &kGCSettingItems[sw.tag];
    [GCPanelDefaults() setBool:sw.on forKey:@(it->key)];
    [GCPanelDefaults() synchronize];
}

- (void)tableView:(__unused UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tv deselectRowAtIndexPath:ip animated:YES];
}

@end

#pragma mark - 手势

// 双指长按打开设置。挂 key window，与高德的单指手势天然不冲突。
//
// ★幂等按「窗口实例」判，不是按「装过一次」判：
//   冷启动早期 key window 可能还没建好；之后 App 也可能换窗口（切页/重建）。
//   若只用一个 BOOL，第一次挂到旧窗口上就再不重试 —— 用户双指长按永远没反应。
//   这里记住「已挂过的窗口」，窗口变了就补挂一次。
void GCInstallSettingGesture(void) {
    static __weak UIWindow *hooked;

    UIWindow *anchor = nil;
    for (UIWindow *w in GCFPanelAllWindows()) {
        if (w.isKeyWindow && !w.hidden && w.bounds.size.width >= 200) { anchor = w; break; }
    }
    if (!anchor) {
        // 没有 key window 时退回「最大的非隐藏窗口」，总比不挂强
        CGFloat best = 0;
        for (UIWindow *w in GCFPanelAllWindows()) {
            if (w.hidden || w.bounds.size.width < 200) continue;
            CGFloat a = w.bounds.size.width * w.bounds.size.height;
            if (a > best) { best = a; anchor = w; }
        }
    }
    if (!anchor) return;
    if (hooked == anchor) return;          // 这个窗口已经挂过

    UILongPressGestureRecognizer *g =
        [[UILongPressGestureRecognizer alloc] initWithTarget:[GCSettingPanel shared]
                                                      action:@selector(handleLongPress:)];
    g.numberOfTouchesRequired = 2;
    g.minimumPressDuration = 0.6;
    g.cancelsTouchesInView = NO;
    g.delaysTouchesEnded = NO;
    // 不设 delegate：让它与 App 自己的手势并存，避免「识别成功就吞掉触摸」
    [anchor addGestureRecognizer:g];
    hooked = anchor;
}
