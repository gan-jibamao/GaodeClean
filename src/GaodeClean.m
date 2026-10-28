#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import "GCCGeometry.h"

// ===== 屏幕日志面板（仅 GCC_DEVICE_TEST 编译）=====
// 为什么需要它：iOS 上普通用户拿不到 NSLog 输出（要去 Xcode / Console.app），
// 前几轮让用户"发日志"实际都拿不到。改成直接把诊断信息画在屏幕上，截图就行。
// 面板常驻在最上层窗口，不拦截触摸（userInteractionEnabled=NO）。
#ifdef GCC_DEVICE_TEST

#import <UIKit/UIKit.h>

static void GCProbeWhiteFog(const char *tag);

@interface GCHUDView : UIView
@property(nonatomic, strong) NSMutableArray<NSString *> *lines;
@property(nonatomic, strong) UILabel *label;
@property(nonatomic, strong) UIButton *fogButton;
@end

static GCHUDView *GCHUD;

@implementation GCHUDView

+ (instancetype)shared {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        GCHUD = [[GCHUDView alloc] initWithFrame:CGRectZero];
        GCHUD.lines = [NSMutableArray array];
        GCHUD.userInteractionEnabled = YES;
        GCHUD.backgroundColor = [UIColor colorWithWhite:0 alpha:0.72];
        GCHUD.layer.cornerRadius = 8;
        GCHUD.layer.masksToBounds = YES;

        UILabel *l = [UILabel new];
        l.numberOfLines = 0;
        l.font = [UIFont monospacedSystemFontOfSize:10 weight:UIFontWeightRegular];
        l.textColor = UIColor.whiteColor;
        l.userInteractionEnabled = NO;
        GCHUD.label = l;
        [GCHUD addSubview:l];

        // N1: 「查白雾」按钮 —— 用户看到白雾的瞬间点它，立刻全窗扫描报真身。
        // 面板整体 userInteractionEnabled 已改为 YES，但 hitTest 做了穿透：
        // 只有按钮可点，面板其余区域触摸照常穿到地图。
        UIButton *fb = [UIButton buttonWithType:UIButtonTypeSystem];
        [fb setTitle:@"查白雾" forState:UIControlStateNormal];
        fb.titleLabel.font = [UIFont boldSystemFontOfSize:11];
        [fb setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
        fb.backgroundColor = [UIColor colorWithWhite:1 alpha:0.22];
        fb.layer.cornerRadius = 4;
        fb.userInteractionEnabled = YES;
        [fb addTarget:GCHUD action:@selector(fogTap) forControlEvents:UIControlEventTouchUpInside];
        GCHUD.fogButton = fb;
        [GCHUD addSubview:fb];
    });
    return GCHUD;
}

+ (void)log:(NSString *)fmt, ... {
    va_list ap;
    va_start(ap, fmt);
    NSString *s = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    NSLog(@"[GaodeClean] %@", s);
    dispatch_async(dispatch_get_main_queue(), ^{
        GCHUDView *hud = [GCHUDView shared];
        NSDateFormatter *df = [NSDateFormatter new];
        df.dateFormat = @"HH:mm:ss";
        [hud.lines addObject:[NSString stringWithFormat:@"%@ %@", [df stringFromDate:[NSDate date]], s]];
        while (hud.lines.count > 16) [hud.lines removeObjectAtIndex:0];
        [hud refresh];
    });
}

- (void)refresh {
    UIWindow *win = nil;
    for (UIScene *sc in UIApplication.sharedApplication.connectedScenes) {
        if (![sc isKindOfClass:UIWindowScene.class]) continue;
        for (UIWindow *w in ((UIWindowScene *)sc).windows) {
            if (w.isKeyWindow) { win = w; break; }
        }
        if (win) break;
    }
    if (!win) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
        win = UIApplication.sharedApplication.windows.firstObject;
#pragma clang diagnostic pop
    }
    if (!win) return;
    if (self.superview != win) {
        [win addSubview:self];
        [win bringSubviewToFront:self];
    }
    CGFloat W = win.bounds.size.width;
    CGFloat pad = 6;
    CGFloat w = MIN(W - 16, 370);
    CGSize fit = [self.label sizeThatFits:CGSizeMake(w - pad * 2, CGFLOAT_MAX)];
    self.frame = CGRectMake(8, 60, w, fit.height + pad * 2);
    self.label.frame = CGRectMake(pad, pad, w - pad * 2, fit.height);
    self.label.text = [self.lines componentsJoinedByString:@"\n"];
    self.fogButton.frame = CGRectMake(w - 76, 4, 68, 22);
    [win bringSubviewToFront:self];
}

// 只有按钮可点，面板本体触摸穿透（否则会挡住底下地图）
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *v = [super hitTest:point withEvent:event];
    return (v && v != self) ? v : nil;
}

- (void)fogTap {
    // GCLog 宏在此处尚未定义（定义顺序在文件更靠后），直接走 log: 方法
    [GCHUDView log:@"[FOG] —— 手动触发 ——"];
    GCProbeWhiteFog("manual");
}

@end

// 让宏可以像 NSLog 一样用
#define GCLog(fmt, ...) [GCHUDView log:fmt, ##__VA_ARGS__]

#else  // !GCC_DEVICE_TEST —— 正式包里 GCLog 是空操作

#define GCLog(fmt, ...) do { } while (0)

#endif



// This tweak changes UI only. No network interception or modification of the IPA.
static char TextKey, StateKey, LimitKey, ForcedKindKey, ForcedPathKey, SearchDotKey, HandlerKey;
static NSHashTable<UIView *> *Pages;
static NSHashTable *NearbyControllers;
static NSHashTable *TabControllers;
static NSHashTable *HomeHandlers;
static BOOL LayingOutHome;
static BOOL Scheduled, Applying, Cleaning;
static void UpdateMask(UIView *page);
static void Schedule(void);
static void LayoutMinimalHome(id handler);

// ===== 0.4.10 三圆钮几何 =====
// 三槽位统一定义：槽0=导航 槽1=搜索(屏幕正中) 槽2=我的。
// 所有元素一律从槽位取坐标，禁止各自"居中/左右摆"两套坐标系并存
// （0.4.9 的偏左+重叠就是这样来的）。
#define GC_DOT 52.0             // 圆钮直径
#define GC_GAP 8.0              // 相邻圆心距 - 直径
#define GC_BOTTOM_INSET 60.0    // 底栏原始高度，圆心 y = 屏高 - 该值 - GC_DOT/2 - 4
#define GC_PITCH (GC_DOT + GC_GAP)

static void GCDotDress(UIView *v, BOOL hideText);
static void GCDressSearchDot(UIView *bar);
static void GCHideBarPlatter(UIView *bar);

@class GCCState;
@interface GCCLimit : NSObject
@property(nonatomic, weak) GCCState *owner;
@property(nonatomic) CGFloat bottom;
@property(nonatomic) CGSize requestedSize;
@property(nonatomic) BOOL requestedBounces;
@end
@implementation GCCLimit
@end

// Explore and Mine are opaque pages. Their removed area must consume touches,
// rather than exposing the shared map behind the page as the home sheet does.
@interface GCCBlankArea : UIView
@end
@implementation GCCBlankArea
- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.opaque = YES;
        self.multipleTouchEnabled = YES;
        self.accessibilityElementsHidden = YES;
        self.layer.zPosition = 100000;
        [self addGestureRecognizer:[[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(absorb:)]];
        [self addGestureRecognizer:[[UIPinchGestureRecognizer alloc] initWithTarget:self action:@selector(absorb:)]];
    }
    return self;
}
- (void)absorb:(__unused UIGestureRecognizer *)gesture {}
@end

@interface GCCState : NSObject
@property(nonatomic, copy) NSString *path;
@property(nonatomic, strong) NSHashTable<UIScrollView *> *scrolls;
@property(nonatomic, weak) UIView *reference;
@property(nonatomic) CGPoint boundaryPoint;
@property(nonatomic, strong) CAShapeLayer *clip;
@property(nonatomic, strong) CALayer *previousMask;
@property(nonatomic, strong) GCCBlankArea *blankArea;
@property(nonatomic, weak) UIView *page;
@property(nonatomic) CGFloat width;
@property(nonatomic) BOOL matched;
@property(nonatomic) BOOL reportedMatch;
@property(nonatomic) BOOL reportedMiss;
@property(nonatomic) NSUInteger attempts;
@end
@implementation GCCState
- (instancetype)init {
    if ((self = [super init])) _scrolls = [NSHashTable weakObjectsHashTable];
    return self;
}
@end

// Only invoke verified object-returning, zero-argument getters. Never guess ivar layouts.
static id ObjectGetter(id obj, NSString *name) {
    SEL sel = NSSelectorFromString(name);
    if (!obj || ![obj respondsToSelector:sel]) return nil;
    NSMethodSignature *sig = [obj methodSignatureForSelector:sel];
    if (sig.numberOfArguments != 2 || sig.methodReturnType[0] != '@') return nil;
    return ((id (*)(id, SEL))objc_msgSend)(obj, sel);
}

static NSString *PagePath(UIView *page) {
    id path = ObjectGetter(page, @"pagePath");
    return [path isKindOfClass:NSString.class] ? path : @"";
}

static NSInteger PageKind(NSString *path) {
    // Exact page allowlist: other pages in these bundles remain untouched.
    NSString *p = [[path componentsSeparatedByString:@"?"] firstObject];
    if ([p containsString:@"QuickServiceRedesign"]) return 1;
    if ([p containsString:@"BizNearbyIndex"]) return 2;
    if ([p containsString:@"ExplorePage"]) return 2;
    // P2: 17.02.2 可能改了 bundle 目录/文件名，hasSuffix 精确匹配会静默失配
    //（Kind()==0 → Capture 直接 return，整页零裁剪且无日志）。
    // 放宽成「包含 MinePage」，仍只认我的页，不会误伤其它页面。
    if ([p containsString:@"MinePage"]) return 3;
    return 0;
}

static NSInteger Kind(UIView *page) {
    NSString *path = PagePath(page);
    NSInteger explicitKind = PageKind(path);
    if (explicitKind) return explicitKind;
    NSString *initialPath = objc_getAssociatedObject(page, &ForcedPathKey);
    return [path isEqualToString:initialPath] ? [objc_getAssociatedObject(page, &ForcedKindKey) integerValue] : 0;
}

static void RegisterNearby(id controller) {
    UIView *view = ObjectGetter(controller, @"ajxView") ?: ObjectGetter(controller, @"view");
    if (![view isKindOfClass:UIView.class]) return;
    NSString *initial = objc_getAssociatedObject(view, &ForcedPathKey);
    if (!initial.length) objc_setAssociatedObject(view, &ForcedPathKey, PagePath(view), OBJC_ASSOCIATION_COPY_NONATOMIC);
    objc_setAssociatedObject(view, &ForcedKindKey, @2, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [Pages addObject:view];
}

static void Restore(GCCState *state) {
    for (UIScrollView *scroll in state.scrolls) {
        GCCLimit *limit = objc_getAssociatedObject(scroll, &LimitKey);
        if (limit.owner != state) continue;
        objc_setAssociatedObject(scroll, &LimitKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        scroll.contentSize = limit.requestedSize;
        scroll.bounces = limit.requestedBounces;
    }
    [state.scrolls removeAllObjects];
    if (state.page.layer.mask == state.clip) {
        state.clip.mask = nil;
        state.page.layer.mask = state.previousMask;
    }
    state.clip = nil;
    [state.blankArea removeFromSuperview];
    state.blankArea = nil;
    state.previousMask = nil;
    state.reference = nil;
    state.matched = NO;
}

static BOOL Visible(UIView *v) {
    if (!v.window) return NO;
    for (UIView *p = v; p; p = p.superview) if (p.hidden || p.alpha < 0.01) return NO;
    return YES;
}

static NSString *NodeText(UIView *v) {
    NSMutableString *s = [NSMutableString string];
    if ([v isKindOfClass:UILabel.class]) [s appendString:((UILabel *)v).text ?: @""];
    // AJX uses custom CoreText labels, not just UIKit UILabel.
    if ([NSStringFromClass(v.class) hasPrefix:@"AJX"]) {
        for (NSString *getter in @[@"attributedString", @"attributedText", @"text"]) {
            id value = ObjectGetter(v, getter);
            if ([value isKindOfClass:NSAttributedString.class]) value = [value string];
            if ([value isKindOfClass:NSString.class] && [value length] < 160) [s appendFormat:@" %@", value];
        }
    }
    NSString *label = v.accessibilityLabel;
    if (label.length < 160) [s appendFormat:@" %@", label ?: @""];
    NSString *meta = objc_getAssociatedObject(v, &TextKey);
    if (meta) [s appendFormat:@" %@", meta];
    return s;
}

static NSArray<UIView *> *Flatten(UIView *root) {
    if (!root) return @[];
    NSMutableArray *out = [NSMutableArray arrayWithObject:root];
    for (NSUInteger i = 0; i < out.count; i++) {
        UIView *v = out[i];
        if (out.count + v.subviews.count > 2000) return nil; // Fail open on unexpected trees.
        [out addObjectsFromArray:v.subviews];
    }
    return out;
}

static BOOL HasTerm(NSString *text, NSArray<NSString *> *terms) {
    for (NSString *term in terms) if ([text containsString:term]) return YES;
    return NO;
}

static void UpdateMask(UIView *page) {
    GCCState *state = objc_getAssociatedObject(page, &StateKey);
    if (!state.matched || !state.reference || !page.window) return;
    CGPoint edge = [state.reference convertPoint:state.boundaryPoint toView:page];
    CGFloat height = MAX(0, MIN(page.bounds.size.height, edge.y - page.bounds.origin.y));
    if (!isfinite(height)) return;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    if (Kind(page) == 2 || Kind(page) == 3) {
        if (page.layer.mask == state.clip && state.clip) {
            state.clip.mask = nil;
            page.layer.mask = state.previousMask;
        }
        state.clip = nil;
        state.previousMask = nil;
        if (!state.blankArea) state.blankArea = [[GCCBlankArea alloc] initWithFrame:CGRectZero];
        if (state.blankArea.superview != page) [page addSubview:state.blankArea];
        UIColor *background = page.backgroundColor;
        CGFloat alpha = 0;
        if (!background || ![background getRed:NULL green:NULL blue:NULL alpha:&alpha] || alpha < 0.99)
            background = UIColor.systemBackgroundColor;
        state.blankArea.backgroundColor = background;
        state.blankArea.frame = CGRectMake(page.bounds.origin.x, page.bounds.origin.y + height,
                                            page.bounds.size.width, MAX(0, page.bounds.size.height - height));
        [page bringSubviewToFront:state.blankArea];
        [CATransaction commit];
        return;
    }
    if (!state.clip) {
        state.clip = [CAShapeLayer layer];
        state.clip.fillColor = UIColor.blackColor.CGColor;
    }
    if (page.layer.mask != state.clip) {
        state.previousMask = page.layer.mask;
        page.layer.mask = nil;
        state.clip.mask = state.previousMask;
        page.layer.mask = state.clip;
    }
    state.clip.frame = page.bounds;
    state.clip.path = [UIBezierPath bezierPathWithRect:CGRectMake(0, 0, page.bounds.size.width, height)].CGPath;
    [CATransaction commit];
}

static void UpdateMasks(void) {
    if (Applying || !NSThread.isMainThread) return;
    for (UIView *page in Pages.allObjects) UpdateMask(page);
}

static BOOL VerticalContainer(UIScrollView *s, UIView *root) {
    // Do not disable the horizontal category / service carousels.
    if (s.bounds.size.height < 120 || s.bounds.size.width < root.bounds.size.width * 0.65) return NO;
    if (s.contentSize.width > s.bounds.size.width + 20 && s.contentSize.height <= s.bounds.size.height + 10) return NO;
    return YES;
}

static void ApplyLimits(GCCState *state) {
    if (Applying || !state.matched || !state.reference) return;
    Applying = YES;
    for (UIScrollView *scroll in state.scrolls) {
        GCCLimit *limit = objc_getAssociatedObject(scroll, &LimitKey);
        if (limit.owner != state) continue;
        CGPoint edge = [state.reference convertPoint:state.boundaryPoint toView:scroll];
        if (!isfinite(edge.y) || edge.y <= 0) continue;
        limit.bottom = edge.y;
        scroll.bounces = NO;
        CGSize size = limit.requestedSize;
        size.height = MIN(size.height, limit.bottom);
        if (!CGSizeEqualToSize(scroll.contentSize, size)) scroll.contentSize = size;
        UIEdgeInsets inset = scroll.adjustedContentInset;
        CGPoint offset = scroll.contentOffset;
        offset.y = GCCClampOffset(offset.y, size.height, scroll.bounds.size.height, inset.top, inset.bottom);
        if (!CGPointEqualToPoint(offset, scroll.contentOffset)) [scroll setContentOffset:offset animated:NO];
    }
    Applying = NO;
    UpdateMask(state.page);
}

static void BindBoundary(UIView *page, UIView *anchor, UIView *peer, CGFloat boundary, GCCState *state) {
    // Persist the boundary in content coordinates, not screen coordinates. Cell reuse no
    // longer removes the boundary, and scrolling cannot move new cards into the visible area.
    UIView *reference = page;
    for (UIView *v = anchor.superview; v; v = v.superview) {
        if ([v isKindOfClass:UIScrollView.class] && [peer isDescendantOfView:v] && VerticalContainer((id)v, page)) {
            reference = v;
            break;
        }
        if (v == page) break;
    }
    state.reference = reference;
    state.boundaryPoint = [page convertPoint:CGPointMake(0, boundary) toView:reference];
    state.matched = YES;
    state.width = page.bounds.size.width;
    NSUInteger beyondPage = 0;
    BOOL passedPage = NO;
    for (UIView *v = anchor.superview; v && ![v isKindOfClass:UIWindow.class]; v = v.superview) {
        if (v == page) passedPage = YES;
        if (passedPage && ++beyondPage > 5) break;
        if (![v isKindOfClass:UIScrollView.class] || ![peer isDescendantOfView:v] || !VerticalContainer((id)v, page)) continue;
        UIScrollView *scroll = (id)v;
        GCCLimit *limit = objc_getAssociatedObject(scroll, &LimitKey);
        if (limit && limit.owner != state) continue;
        if (!limit) {
            limit = [GCCLimit new];
            limit.owner = state;
            limit.requestedSize = scroll.contentSize;
            limit.requestedBounces = scroll.bounces;
            objc_setAssociatedObject(scroll, &LimitKey, limit, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        [state.scrolls addObject:scroll];
    }
    ApplyLimits(state);
}

// 0.4.10 D2: 诊断落盘只存在于开发构建。正式包不往 App 沙盒写页面树
// （class/frame 属于内部结构信息，且会额外产生磁盘写入）。
#if GCC_DEVICE_TEST
static void SaveDiagnostics(UIView *page, GCCState *state, NSArray<UIView *> *nodes) {
    // No arbitrary label text, addresses, account details or network payloads are exported.
    static NSMutableDictionary *records;
    if (!records) records = [NSMutableDictionary dictionary];
    NSMutableArray *tree = [NSMutableArray array];
    NSArray *known = @[@"常去地点", @"回家", @"去单位", @"编辑", @"停车", @"美食", @"酒店", @"旅游", @"加油", @"家人地图", @"地图共建", @"车辆服务", @"高德运动", @"店铺入驻"];
    for (UIView *v in nodes) {
        NSMutableArray *matches = [NSMutableArray array];
        NSString *text = NodeText(v);
        for (NSString *word in known) if ([text containsString:word]) [matches addObject:word];
        if (tree.count > 250 && !matches.count) continue;
        NSMutableDictionary *node = [@{@"class": NSStringFromClass(v.class), @"frame": NSStringFromCGRect([v convertRect:v.bounds toView:page]), @"markers": matches} mutableCopy];
        if ([v isKindOfClass:UIScrollView.class]) node[@"contentSize"] = NSStringFromCGSize(((UIScrollView *)v).contentSize);
        [tree addObject:node];
    }
    records[[NSString stringWithFormat:@"%ld", (long)Kind(page)]] = @{
        @"rootClass": NSStringFromClass(page.class), @"page": [PagePath(page) componentsSeparatedByString:@"?"].firstObject ?: @"",
        @"matched": @(state.matched), @"scrollContainers": @(state.scrolls.count),
        @"opaqueBlankArea": @(state.blankArea != nil && state.blankArea.superview == page),
        @"blankAreaFrame": NSStringFromCGRect(state.blankArea.frame), @"tree": tree};
    NSData *data = [NSJSONSerialization dataWithJSONObject:@{@"version": @"0.3.1", @"pages": records} options:NSJSONWritingPrettyPrinted error:nil];
    NSURL *documents = [NSFileManager.defaultManager URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask].firstObject;
    if (data && documents) [data writeToURL:[documents URLByAppendingPathComponent:@"GaodeClean-diagnostics.json"] options:NSDataWritingAtomic error:nil];
}
#else
static void SaveDiagnostics(__unused UIView *page, __unused GCCState *state, __unused NSArray<UIView *> *nodes) {}
#endif

static void CleanPage(UIView *page) {
    NSString *path = PagePath(page);
    GCCState *state = objc_getAssociatedObject(page, &StateKey);
    if (!state) {
        state = [GCCState new];
        state.page = page;
        objc_setAssociatedObject(page, &StateKey, state, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    if (![state.path isEqualToString:path]) {
        Restore(state);
        state.path = path;
        state.reportedMatch = state.reportedMiss = NO;
        state.attempts = 0;
    }
    NSInteger kind = Kind(page);
    if (!kind) { Restore(state); return; }
    if (!page.window) return;
    if (kind == 1) {
        // Search is native and lives outside the AJX quick-service page.
        // Keep no quick-service rows, including the shortcuts formerly used as anchors.
        state.reference = page;
        state.boundaryPoint = page.bounds.origin;
        state.matched = YES;
        UpdateMask(page);
        return;
    }
    if (state.matched && fabs(state.width - page.bounds.size.width) > 1) Restore(state);
    NSArray<UIView *> *nodes = Flatten(page);
    if (!nodes) { ApplyLimits(state); return; }
    state.attempts++;
    NSArray *primary = kind == 1 ? @[@"常去地点"] : kind == 2 ? @[@"停车", @"美食", @"酒店", @"加油", @"旅游"] : @[@"家人地图", @"地图共建"];
    NSArray *secondary = kind == 1 ? @[@"回家", @"去单位", @"编辑"] : kind == 2 ? @[@"美食", @"酒店", @"加油", @"旅游"] : @[@"车辆服务", @"高德运动", @"店铺入驻"];
    UIView *anchor = nil, *peer = nil;
    CGFloat boundary = 0;
    if (kind == 3) {
        // P3: 高度上限 200→320（17.02.2 卡片可能变高），并加两级兜底：
        //   ① 原判据：宽≥75%页、高 70~320 的祖先卡片
        //   ② 兜底：往上最多 6 层，取第一个「宽度接近整页」的祖先，用它底边
        // 两轮都失败才放弃（日志会报 [MINE] anchor=未命中）。
        UIView *footNode = nil;
        for (UIView *node in nodes) {
            if (!Visible(node)) continue;
            if (![NodeText(node) containsString:@"足迹"]) continue;
            if (node.bounds.size.height > 120) continue;
            footNode = node;
            int depth = 0;
            for (UIView *card = node.superview; card && card != page && depth < 8; card = card.superview, depth++) {
                CGRect rect = [card convertRect:card.bounds toView:page];
                if (rect.size.width >= page.bounds.size.width * 0.75 &&
                    rect.size.height >= 60 && rect.size.height <= 320) {
                    anchor = peer = node;
                    boundary = CGRectGetMaxY(rect) + 8;
                    break;
                }
            }
            if (anchor) break;
            // ② 兜底：足迹节点上方 6 层内第一个接近整页宽的祖先
            depth = 0;
            for (UIView *card = node.superview; card && card != page && depth < 6; card = card.superview, depth++) {
                CGRect rect = [card convertRect:card.bounds toView:page];
                if (rect.size.width >= page.bounds.size.width * 0.9 && rect.size.height > 40) {
                    anchor = peer = node;
                    boundary = CGRectGetMaxY(rect) + 8;
                    break;
                }
            }
            if (anchor) break;
        }
        if (!anchor && footNode) {
            // ③ 最后兜底：用足迹节点自身底边 + 28（历史 0.3.0 的经验值）
            CGRect nr = [footNode convertRect:footNode.bounds toView:page];
            anchor = peer = footNode;
            boundary = CGRectGetMaxY(nr) + 28;
            GCLog(@"[MINE] 用足迹节点自身兜底 boundary=%.1f", boundary);
        }
    }
    // Two separate labels on the same row must agree; avoid matching recommendation copy.
    for (UIView *a in kind == 3 ? @[] : nodes) {
        if (!Visible(a) || CGRectGetHeight(a.bounds) > 100 || CGRectGetHeight(a.bounds) <= 0) continue;
        if (!HasTerm(NodeText(a), primary)) continue;
        CGRect ar = [a convertRect:a.bounds toView:page];
        for (UIView *b in nodes) {
            if (a == b || !Visible(b) || CGRectGetHeight(b.bounds) > 100 || CGRectGetHeight(b.bounds) <= 0) continue;
            CGRect br = [b convertRect:b.bounds toView:page];
            if (fabs(CGRectGetMidY(ar) - CGRectGetMidY(br)) > 18) continue;
            if (fabs(CGRectGetMidX(ar) - CGRectGetMidX(br)) < 25) continue;
            if (!HasTerm(NodeText(b), secondary)) continue;
            anchor = a;
            peer = b;
            boundary = MAX(CGRectGetMaxY(ar), CGRectGetMaxY(br)) + (kind == 3 ? 28 : 18);
            break;
        }
        if (anchor) break;
    }
    if (!anchor) {
        // Reuse only a previously measured boundary for the same viewport width.
        // Covering the entire pending page would blank the account header during loading.
        if (kind == 3 && !state.matched) {
            NSDictionary *cached = [NSUserDefaults.standardUserDefaults dictionaryForKey:@"GaodeClean.MineBoundary.17.00.2"];
            if (!cached) {
                NSString *dir = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
                NSData *data = [NSData dataWithContentsOfFile:[dir stringByAppendingPathComponent:@"GaodeClean-diagnostics.json"]];
                NSDictionary *report = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
                NSDictionary *mine = report[@"pages"][@"3"];
                if ([@[@"0.3.0", @"0.3.1"] containsObject:report[@"version"] ?: @""] && [mine[@"matched"] boolValue]) {
                    CGRect blank = CGRectFromString(mine[@"blankAreaFrame"] ?: @"");
                    if (blank.origin.y > 100) cached = @{@"width":@(blank.size.width), @"bottom":@(blank.origin.y)};
                }
            }
            CGFloat bottom = [cached[@"bottom"] doubleValue];
            if (fabs([cached[@"width"] doubleValue] - page.bounds.size.width) < 1 && bottom > 100 && bottom < page.bounds.size.height) {
                state.reference = page;
                state.boundaryPoint = CGPointMake(0, page.bounds.origin.y + bottom);
                state.matched = YES;
                state.width = page.bounds.size.width;
                UpdateMask(page);
            }
        }
        // A recycled/offscreen anchor does not mean that the recommendation boundary vanished.
        ApplyLimits(state);
        if (!state.reportedMiss) {
            GCLog(@"[MINE] kind=%ld anchor=未命中 attempts=%lu（本页内容不会被裁剪）",
                  (long)kind, (unsigned long)state.attempts);
            state.reportedMiss = YES;
        }
        if (state.attempts == 10) SaveDiagnostics(page, state, nodes);
        return;
    }
    if (kind == 2) {
        // On-device ExplorePage has a separate recommendation list directly below
        // the horizontal categories. Align the blank area to its top, not into its first card.
        CGFloat rowBottom = MAX(CGRectGetMaxY([anchor convertRect:anchor.bounds toView:page]),
                                CGRectGetMaxY([peer convertRect:peer.bounds toView:page]));
        for (UIView *v in nodes) {
            if (![v isKindOfClass:UIScrollView.class] || [anchor isDescendantOfView:v]) continue;
            CGRect r = [v convertRect:v.bounds toView:page];
            if (r.size.width >= page.bounds.size.width * 0.8 && r.size.height > 150 &&
                r.origin.y >= rowBottom && r.origin.y <= boundary) boundary = r.origin.y;
        }
    }
    if (kind == 3 && !(boundary > 100 && boundary < page.bounds.size.height)) {
        GCLog(@"[MINE] kind=3 boundary 越界 %.1f (pageH=%.0f)，跳过缓存", boundary, page.bounds.size.height);
    }
    if (kind == 3 && boundary > 100 && boundary < page.bounds.size.height) {
        NSDictionary *cached = [NSUserDefaults.standardUserDefaults dictionaryForKey:@"GaodeClean.MineBoundary.17.00.2"];
        if (fabs([cached[@"bottom"] doubleValue] - boundary) > 0.5 || fabs([cached[@"width"] doubleValue] - page.bounds.size.width) > 0.5)
            [NSUserDefaults.standardUserDefaults setObject:@{@"width":@(page.bounds.size.width), @"bottom":@(boundary)} forKey:@"GaodeClean.MineBoundary.17.00.2"];
    }
    BindBoundary(page, anchor, peer, boundary, state);
    if (!state.reportedMatch) {
        GCLog(@"[MINE] kind=%ld anchor=命中 boundary=%.1f scrolls=%lu pageH=%.0f",
              (long)kind, boundary, (unsigned long)state.scrolls.count, page.bounds.size.height);
        state.reportedMatch = YES;
        SaveDiagnostics(page, state, nodes);
    }
}

#if GCC_DEVICE_TEST
// Built only for this SSH regression session; absent from the delivery package.
static void RunDeviceCheck(void) {
    NSString *dir = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    NSString *request = [dir stringByAppendingPathComponent:@"GaodeClean-test-request"];
    NSString *pageName = [[NSString stringWithContentsOfFile:request encoding:NSUTF8StringEncoding error:nil]
                         stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (!pageName) return;
    [NSFileManager.defaultManager removeItemAtPath:request error:nil];
    NSInteger index = [pageName isEqual:@"mine"] ? 1 : ([@[@"home", @"search"] containsObject:pageName] ? 0 : -1);
    if (index < 0) return;
    for (id tabs in TabControllers.allObjects) {
        id params = ObjectGetter(tabs, @"viewControlParams");
        UIView *view = ObjectGetter(tabs, @"view");
        if (![params isKindOfClass:NSArray.class] || [params count] < 2 || !view.window) continue;
        NSMutableArray *tabNames = [NSMutableArray array];
        for (NSUInteger i = 0; i < [params count]; i++) {
            id item = params[i];
            NSString *className = ObjectGetter(item, @"className");
            [tabNames addObject:className ?: @"dynamic"];
            if ([pageName isEqual:@"mine"] && [className isEqual:@"WINMineViewControl"]) index = i;
        }
        SEL select = NSSelectorFromString(@"selectIndex:data:");
        if (![tabs respondsToSelector:select]) continue;
        if (![pageName isEqual:@"search"]) ((void (*)(id, SEL, NSInteger, id))objc_msgSend)(tabs, select, index, nil);
        if ([pageName isEqual:@"search"]) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 500 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
                for (id handler in HomeHandlers.allObjects) {
                    UIView *bar = ObjectGetter(handler, @"searchBar");
                    SEL tap = NSSelectorFromString(@"onTapBackgound:");
                    if (bar.window && !bar.hidden && [bar respondsToSelector:tap]) {
                        ((void (*)(id, SEL, id))objc_msgSend)(bar, tap, nil);
                        break;
                    }
                }
            });
        }
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
            NSMutableArray *results = [NSMutableArray array];
            UIWindow *window = view.window;
            NSMutableArray *widgets = [NSMutableArray array];
            UIView *actualTab = ObjectGetter(tabs, @"tabBar");
            if (actualTab) [widgets addObject:@{@"class":@"diagnostic-tab", @"hidden":@(actualTab.hidden), @"alpha":@(actualTab.alpha), @"parent":NSStringFromClass(actualTab.superview.class) ?: @"nil", @"window":@(actualTab.window != nil), @"frame":NSStringFromCGRect(actualTab.frame)}];
            for (UIView *v in Flatten(window)) {
                NSString *cls = NSStringFromClass(v.class);
                if ([cls containsString:@"Widget"] || [cls containsString:@"Combined"] || [cls containsString:@"SearchBar"] || [cls containsString:@"TabBar"]) {
                    NSMutableDictionary *entry = [@{@"class":cls, @"frame":NSStringFromCGRect([v convertRect:v.bounds toView:window]), @"hidden":@(v.hidden)} mutableCopy];
                    for (NSString *key in @[@"getItemTag", @"iconImageName", @"accessibilityLabel"] ) {
                        id value = ObjectGetter(v, key);
                        if ([value isKindOfClass:NSString.class]) entry[key] = value;
                    }
                    [widgets addObject:entry];
                }
            }
            for (UIView *page in Pages.allObjects) {
                if (!Visible(page)) continue;
                CleanPage(page);
                GCCState *state = objc_getAssociatedObject(page, &StateKey);
                GCCBlankArea *blank = state.blankArea;
                if (!blank || !Visible(blank) || CGRectIsEmpty(blank.bounds)) continue;
                CGPoint point = [blank convertPoint:CGPointMake(CGRectGetMidX(blank.bounds), CGRectGetMidY(blank.bounds)) toView:window];
                UIView *hit = [window hitTest:point withEvent:nil];
                [results addObject:@{@"kind": @(Kind(page)), @"frame": NSStringFromCGRect(blank.frame),
                                     @"hitClass": hit ? NSStringFromClass(hit.class) : @"nil", @"opaque": @(blank.opaque),
                                     @"gestures": @(blank.gestureRecognizers.count)}];
            }
            NSData *json = [NSJSONSerialization dataWithJSONObject:@{@"page":pageName, @"checks":results, @"widgets":widgets, @"tabs":tabNames} options:NSJSONWritingPrettyPrinted error:nil];
            [json writeToFile:[dir stringByAppendingPathComponent:[NSString stringWithFormat:@"GaodeClean-check-%@.json",pageName]] atomically:YES];
            if (window) {
                UIGraphicsBeginImageContextWithOptions(window.bounds.size, NO, 1);
                [window drawViewHierarchyInRect:window.bounds afterScreenUpdates:YES];
                UIImage *image = UIGraphicsGetImageFromCurrentImageContext();
                UIGraphicsEndImageContext();
                [UIImagePNGRepresentation(image) writeToFile:[dir stringByAppendingPathComponent:[NSString stringWithFormat:@"GaodeClean-check-%@.png",pageName]] atomically:YES];
            }
        });
        break;
    }
}
#endif

// ===== L1: 首页遮罩常驻压制 =====
//
// 用户反馈（2026-10-28）：已经在首页时再点首页圆钮，屏幕出现一层白雾。
//
// 根因：高德首页的 slidableView（可滑动面板）上方有一层 maskView 半透明遮罩，
// 面板被我们 hidden 之后，遮罩被 App 在 tab 重选流程里重新显示出来 ——
// 因为面板没了，这层遮罩就孤零零地铺在屏幕上，看起来就是"白雾"。
// 原来的压制只写在 LayoutMinimalHome 里，而它只在 layoutBottomSearchBar /
// viewDidLayoutSubviews 两个钩子触发；再点一次首页走的是 App 自己的 tab
// 重选路径，不经过这两个钩子，所以压制失效。
//
// 修法：独立成 GCSuppressHomeMask，挂在 100ms 的 Schedule() 循环里常驻执行，
// 用 hidden 判定做幂等（已经压制过就直接返回，不重复写、不抖动）。
static void GCSuppressHomeMask(id handler) {
    if (!handler) return;
    UIView *sheet = ObjectGetter(handler, @"slidableView");
    if (![sheet isKindOfClass:UIView.class]) return;
    // 只有首页才压（其它页的原生遮罩是正常 UI，不能动）
    id tabs = ObjectGetter(handler, @"tabBarControl");
    id selected = ObjectGetter(tabs, @"selectedViewControl");
    if (![NSStringFromClass([selected class]) isEqualToString:@"WINAmapHomeControl"]) return;

    BOOL changed = NO;
    if (!sheet.hidden) { sheet.hidden = YES; changed = YES; }

    // 首选：调 App 自己的开关。17.00.2 类转储确认 GDAmapHomeHandler 有
    // setSlidableViewBottomMaskEnable: —— 这是原生控制底部遮罩的入口，
    // 比硬压 hidden 更彻底（App 内部状态也一致，不会被后续布局再打开）。
    // 只调一次（100ms 循环里反复调会让 App 内部状态抖动）
    static char MaskFlagKey;
    if (!objc_getAssociatedObject(handler, &MaskFlagKey)) {
        SEL maskEnable = NSSelectorFromString(@"setSlidableViewBottomMaskEnable:");
        if ([handler respondsToSelector:maskEnable]) {
            ((void (*)(id, SEL, BOOL))objc_msgSend)(handler, maskEnable, NO);
            objc_setAssociatedObject(handler, &MaskFlagKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            GCLog(@"[MASK] setSlidableViewBottomMaskEnable:NO 已下发");
        }
    }

    UIView *mask = ObjectGetter(handler, @"maskView");
    if ([mask isKindOfClass:UIView.class] && (!mask.hidden || mask.alpha > 0.01)) {
        mask.hidden = YES;
        mask.alpha = 0.0;
        changed = YES;
    }
    CALayer *bottomMask = ObjectGetter(handler, @"bottomMaskLayer");
    if ([bottomMask isKindOfClass:CALayer.class] && !bottomMask.hidden) {
        bottomMask.hidden = YES;
        changed = YES;
    }
    // 也压一层：有些版本遮罩是 handler 上的独立 UIView 属性
    for (NSString *name in @[@"shadowView", @"dimmingView", @"overlayView", @"maskContainerView"]) {
        UIView *v = ObjectGetter(handler, name);
        if ([v isKindOfClass:UIView.class] && !v.hidden) { v.hidden = YES; changed = YES; }
    }
    if (changed) {
        GCLog(@"[MASK] 重新压制 mask sheet=%d mask=%d bottom=%d",
              sheet.hidden, mask ? mask.hidden : -1, bottomMask ? bottomMask.hidden : -1);
    }
}

// ===== M3: 大面积近白覆盖层兜底 =====
//
// 白雾真身还没确认（M0 取证中）。这层是保险：扫全窗口，凡「覆盖 >= 55% 屏幕、
// 可见、背景近白、且不是页面根视图」的层，压到 alpha=0。
// 只处理超大面积，正常卡片/导航栏不会被误伤。
// 白名单：WINTabBar 及其子树（我们的圆钮）、UIWindow、以及 searchBar 本身。
static void GCKillWhiteOverlay(UIView *bar) {
    UIWindow *win = bar.window;
    if (!win) return;
    CGFloat area = win.bounds.size.width * win.bounds.size.height;
    if (area <= 0) return;
    NSMutableArray<UIView *> *stack = [NSMutableArray arrayWithObject:win];
    NSUInteger guard = 0;
    int killed = 0;
    while (stack.count && guard++ < 3000) {
        UIView *v = stack.lastObject;
        [stack removeLastObject];
        for (UIView *sub in v.subviews) [stack addObject:sub];
        if (v == win || v.hidden || v.alpha < 0.05) continue;
        if (v == bar || [v isDescendantOfView:bar]) continue;          // 我们的底栏
        if ([v isKindOfClass:UIScrollView.class]) continue;            // 页面滚动容器
        if ([v isKindOfClass:UINavigationBar.class] || [v isKindOfClass:UITabBar.class]) continue;
        CGRect r = [v convertRect:v.bounds toView:win];
        if (!isfinite(r.size.width) || !isfinite(r.size.height)) continue;
        if (r.size.width * r.size.height < area * 0.60) continue;
        // 页面根视图（占满全屏、cover 整个 VC）是正常背景，不压
        if (r.size.width >= win.bounds.size.width * 0.98 && r.size.height >= win.bounds.size.height * 0.98) continue;
        CGFloat rr = 0, gg = 0, bb = 0, aa = 0;
        BOOL whiteish = NO;
        if ([v.backgroundColor getRed:&rr green:&gg blue:&bb alpha:&aa] && aa > 0.02)
            whiteish = (rr > 0.85 && gg > 0.85 && bb > 0.85);
        if (!whiteish) continue;
        v.alpha = 0.0;
        killed++;
        if (killed <= 6)
            GCLog(@"[MASK] 压掉大白层 %@ {%.0f,%.0f,%.0f,%.0f}",
                  NSStringFromClass([v class]), r.origin.x, r.origin.y, r.size.width, r.size.height);
    }
    if (killed) GCLog(@"[MASK] 本轮压掉 %d 层", killed);
}

static void Schedule(void) {
    if (![NSThread isMainThread] || Scheduled) return;
    Scheduled = YES;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 100 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
        Scheduled = NO;
        if (UIApplication.sharedApplication.applicationState != UIApplicationStateActive) return;
        for (id tabs in TabControllers.allObjects) {
            id selected = ObjectGetter(tabs, @"selectedViewControl");
            id params = ObjectGetter(tabs, @"viewControlParams");
            if ([params isKindOfClass:NSArray.class]) for (id item in params) {
                if (selected && ObjectGetter(item, @"viewControl") == selected) {
                    id title = ObjectGetter(item, @"title");
                    id label = ObjectGetter(item, @"accessibilityLabel");
                    if ([@[@"探索", @"附近"] containsObject:title ?: @""] || [@[@"探索", @"附近"] containsObject:label ?: @""]) {
                        [NearbyControllers addObject:selected];
                    }
                }
            }
        }
        for (id controller in NearbyControllers.allObjects) RegisterNearby(controller);
        for (UIView *page in Pages.allObjects) CleanPage(page);
        for (id handler in HomeHandlers.allObjects) {
            LayoutMinimalHome(handler);
            // L1: 遮罩常驻压制（再点首页时 App 会重新显示 maskView）
            GCSuppressHomeMask(handler);
        }
        // M3: 大面积白层兜底 —— 只在首页执行。
        // 0.4.21 的隐患（本轮拆除）：原来无条件每 100ms 扫全窗，
        // 而「我的」页本身就是大面积白底，会被误压成透明。
        {
            BOOL onHome = NO;
            for (id tabs in TabControllers.allObjects) {
                id sv = ObjectGetter(tabs, @"selectedViewControl");
                if ([NSStringFromClass([sv class]) isEqualToString:@"WINAmapHomeControl"]) { onHome = YES; break; }
            }
            if (onHome) {
                for (id tabs in TabControllers.allObjects) {
                    UIView *tb = ObjectGetter(tabs, @"tabBar");
                    if ([tb isKindOfClass:UIView.class]) { GCKillWhiteOverlay(tb); break; }
                }
            }
        }
#if GCC_DEVICE_TEST
        RunDeviceCheck();
#endif
    });
}

static void Capture(id element) {
    if (![NSThread isMainThread]) return;
    id render = ObjectGetter(element, @"rootRender") ?: ObjectGetter(element, @"render");
    UIView *page = ObjectGetter(render, @"ajx3View");
    if (![page isKindOfClass:UIView.class]) return;
    // P1: 取证 —— 每个 AJX 页面只报一次真实 pagePath 和识别结果。
    // 之前 Kind()==0 时这里直接 return，整页静默跳过、一行日志都没有，
    // 所以"我的页突然不裁剪"完全无从观察。现在把它摊开。
    {
        static char PathLogKey;
        if (!objc_getAssociatedObject(page, &PathLogKey)) {
            objc_setAssociatedObject(page, &PathLogKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
#if GCC_DEVICE_TEST
            NSString *raw = PagePath(page);
            NSString *tail = raw.length > 90 ? [raw substringFromIndex:raw.length - 90] : raw;
            GCLog(@"[PATH] kind=%ld path=%@", (long)PageKind(raw), tail.length ? tail : @"(空)");
#endif
        }
    }
    if (!Kind(page)) return;
    [Pages addObject:page];
    UIView *view = ObjectGetter(element, @"view");
    if ([view isKindOfClass:UIView.class]) {
        id model = ObjectGetter(element, @"propertyModel");
        id attrs = ObjectGetter(model, @"attributeProps");
        NSMutableString *text = [NSMutableString string];
        if ([attrs isKindOfClass:NSDictionary.class]) {
            for (NSString *key in @[@"text", @"title", @"content", @"value", @"accessibilityLabel", @"aria-label"]) {
                id value = attrs[key];
                if ([value isKindOfClass:NSString.class] && [value length] < 160)
                    [text appendFormat:@" %@", value];
            }
        }
        objc_setAssociatedObject(view, &TextKey, text, OBJC_ASSOCIATION_COPY_NONATOMIC);
    }
    if (Kind(page) == 3 && !Cleaning) { Cleaning = YES; CleanPage(page); Cleaning = NO; }
    Schedule();
}

// Install on a class's own method table, preserving inherited implementations.
// 0.4.10: 原实现缺 nil 守卫 —— class_addMethod 失败且方法不存在时
// class_getInstanceMethod 返回 NULL，method_setImplementation(NULL,...) 必崩。
static void Replace(Class cls, SEL sel, IMP replacement, const char *types) {
    if (!cls || !sel || !replacement) return;
    if (class_addMethod(cls, sel, replacement, types)) return;
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) {
        NSLog(@"[GaodeClean] skip missing %@", NSStringFromSelector(sel));
        return;
    }
    method_setImplementation(m, replacement);
}

static void HookVoid(NSString *name, NSString *methodName, void (^after)(id)) {
    Class cls = NSClassFromString(name);
    SEL sel = NSSelectorFromString(methodName);
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) return;
    NSMethodSignature *s = [NSMethodSignature signatureWithObjCTypes:method_getTypeEncoding(m)];
    if (s.numberOfArguments != 2 || s.methodReturnType[0] != 'v') return;
    IMP original = method_getImplementation(m);
    IMP imp = imp_implementationWithBlock(^(id self) {
        ((void (*)(id, SEL))original)(self, sel);
        after(self);
    });
    Replace(cls, sel, imp, method_getTypeEncoding(m));
}

static CGPoint LimitedOffset(UIScrollView *scroll, CGPoint point) {
    GCCLimit *limit = objc_getAssociatedObject(scroll, &LimitKey);
    if (limit.owner && limit.bottom > 0) {
        UIEdgeInsets inset = scroll.adjustedContentInset;
        point.y = GCCClampOffset(point.y, MIN(limit.requestedSize.height, limit.bottom), scroll.bounds.size.height, inset.top, inset.bottom);
    }
    return point;
}

static void InstallScrollHooks(void) {
    Class cls = UIScrollView.class;
    SEL sizeSEL = @selector(setContentSize:);
    Method sizeMethod = class_getInstanceMethod(cls, sizeSEL);
    IMP sizeOriginal = method_getImplementation(sizeMethod);
    Replace(cls, sizeSEL, imp_implementationWithBlock(^(UIScrollView *self, CGSize size) {
        GCCLimit *limit = objc_getAssociatedObject(self, &LimitKey);
        if (limit.owner && limit.bottom > 0) {
            if (!Applying) limit.requestedSize = size;
            size.height = MIN(size.height, limit.bottom);
        }
        ((void (*)(id, SEL, CGSize))sizeOriginal)(self, sizeSEL, size);
    }), method_getTypeEncoding(sizeMethod));

    SEL boundsSEL = @selector(setBounds:);
    Method boundsMethod = class_getInstanceMethod(cls, boundsSEL);
    IMP boundsOriginal = method_getImplementation(boundsMethod);
    Replace(cls, boundsSEL, imp_implementationWithBlock(^(UIScrollView *self, CGRect rect) {
        GCCLimit *limit = objc_getAssociatedObject(self, &LimitKey);
        if (limit.owner && limit.bottom > 0) {
            UIEdgeInsets inset = self.adjustedContentInset;
            rect.origin.y = GCCClampOffset(rect.origin.y, MIN(limit.requestedSize.height, limit.bottom), rect.size.height, inset.top, inset.bottom);
        }
        ((void (*)(id, SEL, CGRect))boundsOriginal)(self, boundsSEL, rect);
        if (limit.owner) UpdateMasks();
    }), method_getTypeEncoding(boundsMethod));

    SEL offsetSEL = @selector(setContentOffset:);
    Method offsetMethod = class_getInstanceMethod(cls, offsetSEL);
    IMP offsetOriginal = method_getImplementation(offsetMethod);
    Replace(cls, offsetSEL, imp_implementationWithBlock(^(UIScrollView *self, CGPoint point) {
        ((void (*)(id, SEL, CGPoint))offsetOriginal)(self, offsetSEL, LimitedOffset(self, point));
        if (objc_getAssociatedObject(self, &LimitKey)) UpdateMasks();
    }), method_getTypeEncoding(offsetMethod));

    SEL animatedSEL = @selector(setContentOffset:animated:);
    Method animatedMethod = class_getInstanceMethod(cls, animatedSEL);
    IMP animatedOriginal = method_getImplementation(animatedMethod);
    Replace(cls, animatedSEL, imp_implementationWithBlock(^(UIScrollView *self, CGPoint point, BOOL animated) {
        ((void (*)(id, SEL, CGPoint, BOOL))animatedOriginal)(self, animatedSEL, LimitedOffset(self, point), animated);
        if (objc_getAssociatedObject(self, &LimitKey)) UpdateMasks();
    }), method_getTypeEncoding(animatedMethod));

    SEL bounceSEL = @selector(setBounces:);
    Method bounceMethod = class_getInstanceMethod(cls, bounceSEL);
    IMP bounceOriginal = method_getImplementation(bounceMethod);
    Replace(cls, bounceSEL, imp_implementationWithBlock(^(UIScrollView *self, BOOL value) {
        GCCLimit *limit = objc_getAssociatedObject(self, &LimitKey);
        if (limit.owner) {
            if (!Applying) limit.requestedBounces = value;
            value = NO;
        }
        ((void (*)(id, SEL, BOOL))bounceOriginal)(self, bounceSEL, value);
    }), method_getTypeEncoding(bounceMethod));
}

// ===== H 组：底栏圆钮只认圆内点击 =====
//
// 迭代记录（三轮才定案，写清楚避免重走）：
//   v1(0.4.10) 只调 item.bounds/center → 视觉变了，但点击范围还是原 84x54。
//   v2(0.4.13) 只钩 WINTabBarItem.hitTest: → 仍然能点圆外切换。
//
// v2 失败的根本原因（用户 2026-10-28 反馈："点首页圆钮左边还是能切换"）：
//   点圆外空白时，WINTabBar.hitTest: 在自己的 bounds 内直接返回 self，
//   App 内部按坐标算"最近 item"就切页 —— 这条路径根本不进子视图的 hitTest:，
//   所以只钩子视图永远无效。
//
// v3 正确做法：把网关提到 WINTabBar 这一层。接到点后先判断
//   「是否落在三个圆心的 52pt 圆内」，不在圆内就 return nil（穿透到地图）。
// 命中槽位号：-1 = 不在任何圆内；0 = 左(首页)；1 = 中(搜索)；2 = 右(我的)
//
// 真机实测（2026-10-28 17:11 面板日志）定的两个数：
//   ① 热区半径 52/2=26 太大 —— 用户"点首页钮左边"也落在圆内，
//      所以缩到 GC_DOT_HIT 直径 30pt（半径 15），只认图标附近。
//   ② 点中间搜索钮命中的是 WINTabBar（x=197.3 正好是中间槽），
//      说明底栏盖在搜索钮上方。中间槽必须 return nil 让触摸穿到搜索钮，
//      否则底栏会把它吃掉 —— 这就是"点搜索钮没任何反应"的原因。
#define GC_DOT_HIT 30.0

static NSInteger GCTabDotSlot(UIView *bar, CGPoint point) {
    if (![bar isKindOfClass:UIView.class]) return -1;
    UIWindow *win = bar.window;
    CGFloat W = win ? win.bounds.size.width : bar.bounds.size.width;
    if (!isfinite(W) || W < 200) W = bar.bounds.size.width;
    CGFloat midY = bar.bounds.size.height / 2.0;
    CGFloat cx[3] = { W / 2.0 - GC_PITCH, W / 2.0, W / 2.0 + GC_PITCH };
    CGFloat r = GC_DOT_HIT / 2.0 + 1.0;      // 1pt 容差，防亚像素抖动
    CGFloat r2 = r * r;
    for (int i = 0; i < 3; i++) {
        CGFloat dx = point.x - cx[i];
        CGFloat dy = point.y - midY;
        if (isfinite(dx) && isfinite(dy) && dx * dx + dy * dy <= r2) return i;
    }
    return -1;
}

static void InstallTabDotHitTest(void) {
    // ① WINTabBar 层网关（关键）
    Class barCls = NSClassFromString(@"WINTabBar");
    if (barCls) {
        SEL sel = @selector(hitTest:withEvent:);
        Method m = class_getInstanceMethod(barCls, sel);
        if (m) {
            IMP original = method_getImplementation(m);
            Replace(barCls, sel, imp_implementationWithBlock(^UIView *(UIView *self, CGPoint point, UIEvent *event) {
                UIView *hit = ((UIView *(*)(id, SEL, CGPoint, id))original)(self, sel, point, event);
                if (!hit) return nil;
                // 只拦「落在本底栏上」的命中；点到别处（比如外部控件）不干预
                if (hit != self && ![hit isDescendantOfView:self]) return hit;
                NSInteger slot = GCTabDotSlot(self, point);
                // ★ 中间槽(搜索)必须穿透：底栏盖在搜索钮上方，放行会被它吃掉
                if (slot != 0 && slot != 2) {
                    GCLog(@"[HIT] bar (%.1f,%.1f) slot=%ld -> 穿透", point.x, point.y, (long)slot);
                    return nil;
                }
                GCLog(@"[HIT] bar (%.1f,%.1f) slot=%ld hit=%@ -> PASS",
                      point.x, point.y, (long)slot, NSStringFromClass(hit.class));
                return hit;
            }), method_getTypeEncoding(m));
            GCLog(@"[INIT] WINTabBar 网关已装");
        }
    } else {
        GCLog(@"[INIT] ！！WINTabBar 不存在");
    }

    // ② WINTabBarItem 层双保险（有些路径会直接命中子视图）
    Class cls = NSClassFromString(@"WINTabBarItem");
    if (!cls) {
        GCLog(@"[INIT] ！！WINTabBarItem 不存在");
        return;
    }
    SEL sel = @selector(hitTest:withEvent:);
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) return;
    IMP original = method_getImplementation(m);
    Replace(cls, sel, imp_implementationWithBlock(^UIView *(UIView *self, CGPoint point, UIEvent *event) {
        UIView *hit = ((UIView *(*)(id, SEL, CGPoint, id))original)(self, sel, point, event);
        if (!hit) return nil;
        // 换算到所在 WINTabBar 的坐标系再判断圆内
        UIView *ancestor = self.superview;
        while (ancestor && ![NSStringFromClass(ancestor.class) isEqualToString:@"WINTabBar"]) ancestor = ancestor.superview;
        if (!ancestor) return hit;
        CGPoint p = [self convertPoint:point toView:ancestor];
        NSInteger slot = GCTabDotSlot(ancestor, p);
        // 中间槽不属于任何 tab item；其余槽外一律穿透
        if (slot != 0 && slot != 2) return nil;
        GCLog(@"[HIT] item p=(%.1f,%.1f) slot=%ld -> PASS", p.x, p.y, (long)slot);
        return hit;
    }), method_getTypeEncoding(m));
    GCLog(@"[INIT] WINTabBarItem 热区已装");
}

static void HookHitTest(Class cls) {
    // 0.4.10: 调用点在 Initialize() 里传 NSClassFromString(@"AJX3View")，
    // 该类比名在 17.02.2 上可能不存在；原代码直接下探 class_getInstanceMethod(nil,...)。
    if (!cls) {
        NSLog(@"[GaodeClean] hitTest hook skipped: class nil");
        return;
    }
    SEL sel = @selector(hitTest:withEvent:);
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) return;
    IMP original = method_getImplementation(m);
    Replace(cls, sel, imp_implementationWithBlock(^UIView *(UIView *self, CGPoint point, UIEvent *event) {
        GCCState *state = objc_getAssociatedObject(self, &StateKey);
        if (state.matched && state.reference) {
            CGFloat edge = [state.reference convertPoint:state.boundaryPoint toView:self].y;
            if (point.y >= edge) {
                // Home intentionally reveals the map. Explore/Mine must remain opaque
                // and must not return nil (which falls through to the underlying map).
                if ((Kind(self) == 2 || Kind(self) == 3) && CGRectContainsPoint(self.bounds, point)) {
                    UpdateMask(self);
                    return state.blankArea;
                }
                return nil;
            }
        }
        return ((UIView *(*)(id, SEL, CGPoint, id))original)(self, sel, point, event);
    }), method_getTypeEncoding(m));
}

static BOOL IsStreetRank(UIView *view) {
    NSMutableString *identity = [NSMutableString string];
    for (NSString *getter in @[@"getItemTag", @"iconImageName", @"accessibilityLabel"]) {
        id value = ObjectGetter(view, getter);
        if ([value isKindOfClass:NSString.class]) [identity appendFormat:@" %@", value];
    }
    NSString *lower = identity.lowercaseString;
    return [ObjectGetter(view, @"getItemTag") isEqual:@"template_rank"] || [identity containsString:@"扫街榜"] || [lower containsString:@"saojie"] || [lower containsString:@"streetrank"];
}

// ===== 0.4.10 B5: 搜索钮点击转发 =====
// 0.3.5 真机验证：17.00.2 的 WINQuickSearchBarV2 点击走 clickAction block，
// 不是 target/action。内部视图被我们隐藏后原生手势也可能失效，所以自己兜一层。
// UIGestureRecognizer 的 target/action 是私有属性，必须 KVC 取。
static UIView *GCLiveSearchBar;
static void GCFireSearchFallback(UIView *bar);
static void GCFireSearchViaService(void);

// 当前"页面签名"：主窗口 rootVC 的导航栈顶类名 + presented 链顶类名。
// push/pop 都会改变 visibleViewController，present 会改变 presented 链。
static NSString *GCPageSignature(UIViewController *root) {
    if (!root) return @"(nil)";
    UIViewController *top = root;
    if ([top isKindOfClass:UINavigationController.class])
        top = ((UINavigationController *)top).visibleViewController ?: top;
    while (top.presentedViewController && !top.presentedViewController.isBeingDismissed)
        top = top.presentedViewController;
    return NSStringFromClass(top.class);
}

static void GCFireSearchClick(void) {
    UIView *bar = GCLiveSearchBar;
    if (!bar) { GCLog(@"[TAP] liveBar 为空"); return; }

    // 路径1：clickAction block（0.3.5 在 17.00.2 实测有效）
    // 17:21 面板实证：17.02.2 上 block 存在（__NSGlobalBlock__）且被调用，
    // 但搜索页没开 —— block 依赖的内部状态可能已被我们的隐藏/搬移破坏。
    // 策略：先调 block；0.4 秒后检查 keyWindow rootVC 是否变化，
    // 没变化就自动补发 path2/3/4 —— 一切都有日志，不再靠猜。
    __block BOOL pageChanged = NO;
    @try {
        id blk = [bar valueForKey:@"clickAction"];
        GCLog(@"[TAP] path1 block=%@", blk ? NSStringFromClass([blk class]) : @"nil");
        if (blk) {
            // 页面签名：导航栈顶类名 + presented 链顶类名。
            // 17:48 实证：搜索页在同一 AMNavigationController 里 push，
            // rootViewController 不变、无 presented —— 旧判据(rootChanged)恒假，
            // 开页成功也被误判"无效"而补发后续路径（双重导航风险）。
            UIViewController *navBefore = nil;
            for (UIScene *sc in UIApplication.sharedApplication.connectedScenes)
                if ([sc isKindOfClass:UIWindowScene.class])
                    for (UIWindow *w in ((UIWindowScene *)sc).windows)
                        if (w.isKeyWindow) { navBefore = w.rootViewController; break; }
            NSString *sigBefore = GCPageSignature(navBefore);
            void (^cb)(void) = blk;
            cb();
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                UIViewController *navAfter = nil;
                for (UIScene *sc in UIApplication.sharedApplication.connectedScenes)
                    if ([sc isKindOfClass:UIWindowScene.class])
                        for (UIWindow *w in ((UIWindowScene *)sc).windows)
                            if (w.isKeyWindow) { navAfter = w.rootViewController; break; }
                NSString *sigAfter = GCPageSignature(navAfter);
                pageChanged = ![sigAfter isEqualToString:sigBefore];
                GCLog(@"[TAP] path1 执行后 changed=%d top=%@", pageChanged, sigAfter);
                if (!pageChanged) {
                    GCLog(@"[TAP] path1 无效，补发 path2/4");
                    GCFireSearchFallback(bar);
                }
            });
            return;
        }
    } @catch (NSException *e) {
        GCLog(@"[TAP] path1 exception %@", e.reason);
    }
    GCFireSearchFallback(bar);
}

// path2/3/4 兜底链（path1 的 block 无效时由 dispatch_after 自动补发）
static void GCFireSearchFallback(UIView *bar) {
    if (!bar) return;

    // 路径2：onTapBackgound:（原生触摸回调）
    SEL s = NSSelectorFromString(@"onTapBackgound:");
    BOOL has2 = [bar respondsToSelector:s];
    GCLog(@"[TAP] path2 onTapBackgound:=%d", has2);
    if (has2) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
        [bar performSelector:s withObject:nil];
#pragma clang diagnostic pop
        return;
    }

    // 路径3：手势 target/action（私有属性，KVC）
    GCLog(@"[TAP] path3 gestures=%lu", (unsigned long)bar.gestureRecognizers.count);
    for (UIGestureRecognizer *g in bar.gestureRecognizers) {
        if (![g isKindOfClass:[UITapGestureRecognizer class]] || !g.enabled) continue;
        id tg = nil; SEL ac = NULL;
        @try {
            tg = [g valueForKey:@"target"];
            ac = NSSelectorFromString([g valueForKey:@"action"] ?: @"");
        } @catch (NSException *e) { tg = nil; }
        GCLog(@"[TAP] path3 target=%@ sel=%@",
              tg ? NSStringFromClass([tg class]) : @"nil",
              ac ? NSStringFromSelector(ac) : @"nil");
        if (tg && ac) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
            [tg performSelector:ac withObject:g];
#pragma clang diagnostic pop
            return;
        }
    }

    // 路径4：找 GDAmapHomeHandler，直接调它的搜索入口
    id handler = nil;
    for (UIView *v = bar.superview; v && !handler; v = v.superview) {
        id cand = objc_getAssociatedObject(v, &HandlerKey);
        if (cand) handler = cand;
    }
    GCLog(@"[TAP] path4 handler=%@", handler ? NSStringFromClass([handler class]) : @"nil");
    if (handler) {
        for (NSString *name in @[@"onSearchBarTapped", @"onTapSearchBar", @"showSearchPage",
                                 @"openSearch", @"onSearchEntryTapped", @"didTapSearchBar"]) {
            SEL h = NSSelectorFromString(name);
            if (![handler respondsToSelector:h]) continue;
            GCLog(@"[TAP] path4 命中 %@", name);
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
            [handler performSelector:h withObject:nil];
#pragma clang diagnostic pop
            return;
        }
    }

    // path5：绕过 UI 直接调搜索服务（17:38 定案的最终方案）
    GCFireSearchViaService();
}

// ===== path5：直接调搜索服务（K 组，最终方案）=====
//
// 17:38 面板定案：path1 clickAction（__NSGlobalBlock__ 空壳）与 path2
// onTapBackgound: 都被调用但都不开页 —— 它们依赖被我们隐藏/搬移的内部状态。
// 不再猜 UI 链路，直接调 App 的搜索服务打开输入页。
//
// 17.00.2 类转储（归档 analysis/classes.json）铁证：
//   WINGeneralSearchVAppService:
//     sharedInstance            ← 单例入口
//     openInput:                ← 打开搜索输入页（带1参数，传 nil）
//     openGeneralSearchHomePageWithKeyword:animated:  ← 备选
//     startNewSearchWithParams:controllerSource:completion: ← 再备选
static void GCFireSearchViaService(void) {
    Class svc = NSClassFromString(@"WINGeneralSearchVAppService");
    if (!svc) { GCLog(@"[TAP] path5 WINGeneralSearchVAppService 不存在"); return; }
    SEL get = NSSelectorFromString(@"sharedInstance");
    if (![svc respondsToSelector:get]) { GCLog(@"[TAP] path5 无 sharedInstance"); return; }
    id inst = ((id (*)(id, SEL))objc_msgSend)(svc, get);
    GCLog(@"[TAP] path5 service=%@", inst ? NSStringFromClass([inst class]) : @"nil");
    if (!inst) return;

    // 首选 openInput:（打输入法搜索页，等价点搜索框）。
    // 参数未知，可能是 nil 也可能要词典 —— 包 @try，崩了不拖累 App。
    SEL openInput = NSSelectorFromString(@"openInput:");
    if ([inst respondsToSelector:openInput]) {
        GCLog(@"[TAP] path5 调 openInput:");
        @try {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
            [inst performSelector:openInput withObject:nil];
#pragma clang diagnostic pop
        } @catch (NSException *e) {
            GCLog(@"[TAP] path5 openInput exception %@", e.reason);
        }
        return;
    }
    // 备选 openGeneralSearchHomePageWithKeyword:animated:
    SEL openHome = NSSelectorFromString(@"openGeneralSearchHomePageWithKeyword:animated:");
    if ([inst respondsToSelector:openHome]) {
        GCLog(@"[TAP] path5 调 openGeneralSearchHomePage");
        @try {
            ((void (*)(id, SEL, id, BOOL))objc_msgSend)(inst, openHome, nil, YES);
        } @catch (NSException *e) {
            GCLog(@"[TAP] path5 openHome exception %@", e.reason);
        }
        return;
    }
    GCLog(@"[TAP] path5 服务上无可用入口");
}

@interface GCTapRouter : NSObject
- (void)gcTap:(UITapGestureRecognizer *)gr;
@end
static GCTapRouter *GCSharedRouter;
@implementation GCTapRouter
- (void)gcTap:(UITapGestureRecognizer *)gr {
    if (gr.state != UIGestureRecognizerStateEnded) return;
    // G: 只认圆内。bar 若是 393x54 的搜索条形态，点在两端也不该触发
    UIView *v = gr.view;
    if (v) {
        CGPoint p = [gr locationInView:v];
        CGRect b = v.bounds;
        if (isfinite(b.size.width) && isfinite(b.size.height) && b.size.width > 1 && b.size.height > 1) {
            CGFloat dx = p.x - CGRectGetMidX(b), dy = p.y - CGRectGetMidY(b);
            CGFloat r = MIN(b.size.width, b.size.height) / 2.0 + 1.0;
            if (dx * dx + dy * dy > r * r) return;
        }
    }
    GCFireSearchClick();
}
@end

static void GCAttachSearchTap(UIView *bar) {
    if (![bar isKindOfClass:UIView.class]) return;
    GCLiveSearchBar = bar;
    if (!GCSharedRouter) GCSharedRouter = [GCTapRouter new];
    for (UIGestureRecognizer *g in bar.gestureRecognizers) {
        if (![g isKindOfClass:[UITapGestureRecognizer class]]) continue;
        id tg = nil;
        @try { tg = [g valueForKey:@"target"]; } @catch (NSException *e) {}
        if (tg == GCSharedRouter) return;
    }
    UITapGestureRecognizer *tr = [[UITapGestureRecognizer alloc] initWithTarget:GCSharedRouter
                                                                       action:@selector(gcTap:)];
    tr.cancelsTouchesInView = NO;
    [bar addGestureRecognizer:tr];
}

static void LayoutMinimalHome(id handler) {
    if (LayingOutHome) return;
    UIView *bar = ObjectGetter(handler, @"searchBar");
    UIView *sheet = ObjectGetter(handler, @"slidableView");
    id tabs = ObjectGetter(handler, @"tabBarControl");
    id selected = ObjectGetter(tabs, @"selectedViewControl");
    if (![bar isKindOfClass:UIView.class] || ![sheet isKindOfClass:UIView.class] || !sheet.superview) return;
    BOOL home = [NSStringFromClass([selected class]) isEqualToString:@"WINAmapHomeControl"];
    if (!home) { bar.hidden = YES; return; }
    UIView *tabBar = ObjectGetter(tabs, @"tabBar");
    UIView *parent = sheet.superview;
    if (!parent.window || ![tabBar isKindOfClass:UIView.class]) return;
    LayingOutHome = YES;
    if (bar.superview != parent) [parent addSubview:bar];
    // H3: 把 handler 挂到 parent 上，供 GCFireSearchClick 走父链找回搜索入口
    objc_setAssociatedObject(parent, &HandlerKey, handler, OBJC_ASSOCIATION_ASSIGN);
    sheet.hidden = YES;
    UIView *mask = ObjectGetter(handler, @"maskView");
    if ([mask isKindOfClass:UIView.class]) mask.hidden = YES;
    CALayer *bottomMask = ObjectGetter(handler, @"bottomMaskLayer");
    if ([bottomMask isKindOfClass:CALayer.class]) bottomMask.hidden = YES;

    // ===== 0.4.10 B1: 搜索框不再是底栏上方的长条，而是三槽位中间那颗圆钮 =====
    // 用窗口坐标算圆心，再转回 parent 坐标，避免父子层级不同导致错位。
    // ★ 只写 bounds/center，绝不写 frame（transform 非单位阵时 frame 是合成值），
    //   也绝不对 bar 写 transform（0.4.9 就是这样把 CALayer.position 算成 NaN 崩掉的）。
    UIWindow *win = parent.window;
    CGFloat screenH = win ? win.bounds.size.height : parent.bounds.size.height;
    CGFloat screenW = win ? win.bounds.size.width : parent.bounds.size.width;
    if (!isfinite(screenH) || !isfinite(screenW) || screenH < 200 || screenW < 200) { LayingOutHome = NO; return; }
    // ★ 圆心 y 一律从底栏自身的实际 frame 取，禁止用「屏高 - 常量」另算一套。
    //   两套坐标系一旦有偏移，三颗钮就不在同一水平线（0.4.9 偏左+重叠的同类问题）。
    CGRect tabInParent = [tabBar convertRect:tabBar.bounds toView:parent];
    CGFloat dotCY = CGRectGetMidY(tabInParent);
    if (!isfinite(dotCY) || dotCY <= 0) dotCY = screenH - GC_BOTTOM_INSET - GC_DOT / 2.0 - 4.0;
    CGPoint centerInParent = CGPointMake(CGRectGetMidX(parent.bounds), dotCY);
    if (!isfinite(centerInParent.x) || !isfinite(centerInParent.y)) { LayingOutHome = NO; return; }
    bar.bounds = CGRectMake(0, 0, GC_DOT, GC_DOT);
    bar.center = centerInParent;
    objc_setAssociatedObject(bar, &SearchDotKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    GCDressSearchDot(bar);
    GCAttachSearchTap(bar);
    bar.hidden = NO;
    // I3: 搜索钮必须在底栏之上。App 每次布局都会把 WINTabBar 重新置顶，
    // 单次 bringSubviewToFront 不够 —— 由两处兜底：
    //   ① 布局同帧 dispatch_async 再提一次（排在 App 的布局块后面执行）
    //   ② 0.5s 定时器周期性提一次
    // 实证（17:11 面板）：点中间钮命中的是 WINTabBar，说明 bar 被压在底栏下。
    [parent bringSubviewToFront:bar];
    dispatch_async(dispatch_get_main_queue(), ^{
        UIView *p = bar.superview;
        if (p && bar.superview == p) [p bringSubviewToFront:bar];
    });
    LayingOutHome = NO;
}

// ===== 0.4.10 B2: 搜索钮内部重绘 =====
// 铁证（0.4.8 真机层级）：
//   _ContentView {0,0,377,54}
//     UIImageView {0,0,377,54}        ← 底图
//       UIImageView {16,15,24,24}     ← 放大镜就挂在底图下面！
// 因此「隐藏底图」会连带整棵子树消失（放大镜一起没了），
// 「对底图做 transform 缩放」会把图形推出 52pt 圆外只剩月牙。
// 唯一稳的做法：原生效层全部关掉，自己画一个放大镜。
static void GCDressSearchDot(UIView *bar) {
    if (![bar isKindOfClass:UIView.class]) return;
    bar.userInteractionEnabled = YES;
    if (bar.alpha < 0.99) bar.alpha = 1.0;

    // ===== F1: 每帧把 bounds 压回 52x52 =====
    // 真机实测（2026-10-28 16:43 截图）：中间钮白底只有 35pt 宽，是个竖着的
    // 圆角矩形，而左右两颗钮是 50pt 正圆。
    // 根因：App 会把 bar.bounds 改回 393x54，而 cornerRadius 的有效上限是
    // min(w,h)/2 = 27，横向根本不裁 → masksToBounds 只能竖向裁出 35pt 白块。
    // 所以「设圆角之前必须先确定 bounds」，且每帧都要重压一次。
    CGRect want = CGRectMake(0, 0, GC_DOT, GC_DOT);
    if (fabs(bar.bounds.size.width - GC_DOT) > 0.5 || fabs(bar.bounds.size.height - GC_DOT) > 0.5) {
        bar.bounds = want;
    }

    static char GlyphKey, BackKey;
    // ===== F2: 白底自己画，不依赖原生毛玻璃胶囊 =====
    // 原生胶囊是 UIVisualEffectView（毛玻璃），backgroundColor 盖不住它；
    // 之前完全靠 masksToBounds 硬裁，一旦 bounds 错就露出 35pt 竖块。
    // 现在插一层自己的不透明白圆垫在最底下，原生层全部 hidden。
    UIView *back = objc_getAssociatedObject(bar, &BackKey);
    if (!back || back.superview != bar) {
        back = [[UIView alloc] initWithFrame:want];
        back.backgroundColor = [UIColor colorWithWhite:0.97 alpha:1.0];
        back.layer.cornerRadius = GC_DOT / 2.0;
        back.layer.masksToBounds = YES;
        back.userInteractionEnabled = NO;
        back.accessibilityIdentifier = @"GCSearchDotBack";
        [bar addSubview:back];
        objc_setAssociatedObject(bar, &BackKey, back, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    back.frame = want;
    back.hidden = NO;
    back.alpha = 1.0;

    for (UIView *v in bar.subviews) {
        if (v == back) continue;
        UIImageView *g = objc_getAssociatedObject(bar, &GlyphKey);
        if (g && v == g) continue;
        // H2: 原生效层视觉上必须不可见，但【不能】让它 alpha=0 ——
        // iOS 上 alpha<0.01 的视图不参与 hitTest，原生 clickAction 的手势
        // 就再也收不到触摸，表现就是「点搜索钮没反应」。
        // 改为 alpha=0.01 + userInteractionEnabled=NO：看不见，但不破坏命中链。
        v.hidden = NO;
        v.alpha = 0.01;
        v.userInteractionEnabled = NO;
    }
    // bar 自身不再画底色，白底由 back 负责，避免两层叠加出灰边
    bar.backgroundColor = UIColor.clearColor;
    bar.layer.cornerRadius = GC_DOT / 2.0;
    bar.layer.masksToBounds = YES;

    UIImageView *glyph = objc_getAssociatedObject(bar, &GlyphKey);
    UIImage *img = [UIImage systemImageNamed:@"magnifyingglass"];
    if (!glyph || (img && glyph.image != img)) {
        glyph = [[UIImageView alloc] initWithImage:img];
        glyph.contentMode = UIViewContentModeScaleAspectFit;
        glyph.userInteractionEnabled = NO;
        glyph.tintColor = [UIColor colorWithWhite:0.13 alpha:1.0];
        objc_setAssociatedObject(bar, &GlyphKey, glyph, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    if (glyph.superview != bar) [bar addSubview:glyph];
    // ===== F3: 图标按 bar.bounds 中心摆，不用常量 26 =====
    CGFloat glyphSide = 26.0;
    glyph.bounds = CGRectMake(0, 0, glyphSide, glyphSide);
    glyph.center = CGPointMake(CGRectGetMidX(bar.bounds), CGRectGetMidY(bar.bounds));
    if (!isfinite(glyph.center.x) || !isfinite(glyph.center.y))
        glyph.center = CGPointMake(GC_DOT / 2.0, GC_DOT / 2.0);
    glyph.hidden = NO;
    glyph.alpha = 1.0;
    [bar bringSubviewToFront:glyph];
}

// ===== 底栏平板隐藏 =====
//
// 0.4.11 E2 —— 黑名单法失败实证（2026-10-28 15:35 截图）：
//   我原来只按「UIImageView 且 height > 60」隐藏，但原生选中态高亮是一条
//   345x40pt 的灰胶囊（实测 x 25~370pt / y 790~830pt），高度 40 < 60，
//   直接漏网，在真机上就是图二那条横贯屏幕的灰条。
//   黑名单永远会漏项，改成白名单：只保留 tabBarItems，其余子视图一律隐藏。
static void GCHideBarPlatter(UIView *bar) {
    if (![bar isKindOfClass:UIView.class]) return;
    NSArray *items = ObjectGetter(bar, @"tabBarItems");
    NSMutableSet *keep = [NSMutableSet set];
    if ([items isKindOfClass:NSArray.class]) {
        for (UIView *item in items)
            if ([item isKindOfClass:UIView.class]) [keep addObject:item];
    }
    for (UIView *v in bar.subviews) {
        if ([keep containsObject:v]) continue;
        v.hidden = YES;
        v.alpha = 0;
        v.userInteractionEnabled = NO;
    }
}

// 圆钮外观：52pt 正圆 + 纯白底 + 隐藏文字。
//
// 0.4.11 E1 —— 真机截图暴露的两个问题（2026-10-28 15:35）：
//   ① 圆里叠着一个「更白更窄的圆角矩形」(实测 x 181~212pt / 宽 31pt)；
//   ② 另一个页面上两颗钮仍是 84x54 胶囊形，压根没变圆。
// 根因：WINTabBarItem 内部是「选中态 / 未选中态」两层 icon 图片，各自带
//   84x54 的位图。只对外层设 cornerRadius + masksToBounds 并不能改变内层
//   位图的绘制尺寸，形状就残留在圆里。
// 所以这里递归遍历整棵子树：凡是 UIImageView 一律 scaleAspectFit 并压到
//   GC_DOT 内，凡是背景色块一律清成透明，凡是文字一律隐藏。
#define GC_ICON_SIDE 26.0

static void GCDotDressLayer(UIView *v, int depth) {
    if (![v isKindOfClass:UIView.class] || depth > 4) return;
    if ([v isKindOfClass:UILabel.class]) { v.hidden = YES; return; }
    if ([v isKindOfClass:[UIImageView class]]) {
        // icon 位图：不透明、按 26pt 等比缩放，居中到「自己父视图」的中心。
        //
        // 0.4.11 真机实证（2026-10-28 16:32 截图）：图标整个跑到圆的右上角。
        // 根因是我把 center 写成了 CGPointMake(GC_DOT/2, GC_DOT/2) = (26,26)，
        // 但 center 是「直接父视图坐标系」——图标可能挂在 item > 选中层 > 容器
        // 三层下面，每层都拿 (26,26) 当中心，误差逐层累积，最后偏出圆外。
        // 正确做法：在父视图坐标系里取父视图 bounds 的中心，而不是猜一个常量。
        UIImageView *iv = (UIImageView *)v;
        iv.hidden = NO;
        iv.alpha = 1.0;
        iv.backgroundColor = UIColor.clearColor;
        iv.contentMode = UIViewContentModeScaleAspectFit;
        iv.bounds = CGRectMake(0, 0, GC_ICON_SIDE, GC_ICON_SIDE);
        UIView *sp = iv.superview;
        if (sp) {
            CGRect pb = sp.bounds;
            if (isfinite(pb.size.width) && isfinite(pb.size.height) &&
                pb.size.width > 1 && pb.size.height > 1) {
                iv.center = CGPointMake(CGRectGetMidX(pb), CGRectGetMidY(pb));
            }
        }
        if (!isfinite(iv.center.x) || !isfinite(iv.center.y))
            iv.center = CGPointMake(GC_DOT / 2.0, GC_DOT / 2.0);
        iv.layer.cornerRadius = 0;
        iv.layer.masksToBounds = NO;
        return;
    }
    // 普通容器：清掉自己的底色（否则会在圆里留一块矩形），
    // 并把自己「摆到父容器正中、尺寸与父一致」。
    // icon 的 center 是相对它算的，它一旦是 84x54 或偏离父中心，
    // icon 就永远对不齐圆心（真机实测：图标整体跑到圆右上角）。
    CGFloat a = 0;
    UIColor *bg = v.backgroundColor;
    if (bg && [bg getRed:NULL green:NULL blue:NULL alpha:&a] && a > 0.02) v.backgroundColor = UIColor.clearColor;
    v.layer.masksToBounds = NO;
    UIView *superview = v.superview;
    CGSize target = CGSizeMake(GC_DOT, GC_DOT);
    CGPoint center = CGPointMake(GC_DOT / 2.0, GC_DOT / 2.0);
    if (superview) {
        CGSize sb = superview.bounds.size;
        if (isfinite(sb.width) && isfinite(sb.height) && sb.width > 1 && sb.height > 1) {
            target = sb;
            center = CGPointMake(CGRectGetMidX(superview.bounds), CGRectGetMidY(superview.bounds));
        }
    }
    if (isfinite(target.width) && isfinite(target.height) &&
        fabs(v.bounds.size.width - target.width) > 0.5) {
        v.bounds = CGRectMake(0, 0, target.width, target.height);
    }
    // bounds.origin 非 0 时（原生容器偶发如此），center 要按 bounds 中点算，
    // 否则父坐标系里实际位置会再偏一个 origin。
    CGRect vb = v.bounds;
    CGPoint want = center;
    if (isfinite(vb.origin.x) && isfinite(vb.origin.y))
        want = CGPointMake(center.x - vb.origin.x, center.y - vb.origin.y);
    if (isfinite(want.x) && isfinite(want.y)) v.center = want;
    for (UIView *sub in v.subviews) GCDotDressLayer(sub, depth + 1);
}

static void GCDotDress(UIView *v, BOOL hideText) {
    if (![v isKindOfClass:UIView.class]) return;
    v.layer.cornerRadius = GC_DOT / 2.0;
    v.layer.masksToBounds = YES;
    CGFloat alpha = 0;
    UIColor *bg = v.backgroundColor;
    if (!bg || ![bg getRed:NULL green:NULL blue:NULL alpha:&alpha] || alpha < 0.99)
        v.backgroundColor = [UIColor colorWithWhite:0.97 alpha:1.0];
    for (UIView *sub in v.subviews) GCDotDressLayer(sub, 1);
    if (!hideText) return;
    for (UIView *s1 in v.subviews) {
        if ([s1 isKindOfClass:UILabel.class]) s1.hidden = YES;
        for (UIView *s2 in s1.subviews)
            if ([s2 isKindOfClass:UILabel.class]) s2.hidden = YES;
    }
}

// ===== E4: 真机探针 =====
// 这一轮翻车最大的教训是「全程靠猜层级」，改三次都没命中。加这个探针后，
// 底栏真实子视图的 class/frame/hidden 会直接进日志，不用再猜。
static void GCLogBarTree(__unused UIView *bar, __unused CGFloat winW) {
#if GCC_DEVICE_TEST
    static int loggedFrames;
    if (loggedFrames > 6) return;
    loggedFrames++;
    NSArray *titems = ObjectGetter(bar, @"tabBarItems");
    NSUInteger icount = [titems isKindOfClass:NSArray.class] ? titems.count : 0;
    GCLog(@"[BAR] #%d bar={%.1f,%.1f,%.1f,%.1f} winW=%.1f items=%lu",
          loggedFrames, bar.frame.origin.x, bar.frame.origin.y,
          bar.frame.size.width, bar.frame.size.height, winW, (unsigned long)icount);
    int i = 0;
    for (UIView *v in bar.subviews) {
        if (i++ > 40) break;
        GCLog(@"[BAR] sub[%d] %@ {%.1f,%.1f,%.1f,%.1f} hid=%d a=%.2f txt=%@",
              i, NSStringFromClass(v.class), v.frame.origin.x, v.frame.origin.y,
              v.frame.size.width, v.frame.size.height, v.hidden, v.alpha,
              [NodeText(v) stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet]);
    }
#endif
}

static void CenterTabButtons(UIView *bar) {
    static BOOL adjusting;
    if (adjusting) return;
    NSArray *items = ObjectGetter(bar, @"tabBarItems");
    if (![items isKindOfClass:NSArray.class] || items.count != 2) return;
    adjusting = YES;

    // ===== E2: 先摘掉底栏平板（白名单法，只留 tabBarItems） =====
    GCHideBarPlatter(bar);

    // ===== E3: 三槽位用「窗口宽度」算，不信 bar.bounds =====
    // bar.bounds.width 会被 App 在窄栏/宽栏之间来回改（0.3.x 就限制成 252），
    // 一旦用 bar 宽度算，三颗钮会整体歪掉。窗口宽度才是稳定基准。
    // 393pt 视口 → 圆心 136.5 / 196.5 / 256.5，各差 GC_PITCH=60
    UIWindow *win = bar.window;
    CGFloat W = win ? win.bounds.size.width : bar.bounds.size.width;
    if (!isfinite(W) || W < 200) W = bar.bounds.size.width;
    CGFloat midY = bar.bounds.size.height / 2.0;
    CGFloat cx[3] = { W / 2.0 - GC_PITCH, W / 2.0, W / 2.0 + GC_PITCH };
    GCLogBarTree(bar, W);

    for (NSUInteger index = 0; index < items.count; index++) {
        UIView *item = items[index];
        if (![item isKindOfClass:UIView.class] || !item.superview) continue;
        // ★ 只写外层 item 的 bounds/center。写 frame 会在 App 内部重设 bounds 后
        //   产生非线性抖动。内层容器的尺寸交给 GCDotDressLayer 处理
        //   （它会让内层「填满父容器」），这里再压一层会把 icon 顶出圆心。
        item.bounds = CGRectMake(0, 0, GC_DOT, GC_DOT);
        GCDotDress(item, YES);
        CGPoint center = [item.superview convertPoint:item.center toView:bar];
        center.x = cx[index == 0 ? 0 : 2];
        center.y = midY;
        if (!isfinite(center.x) || !isfinite(center.y)) continue;
        item.center = [bar convertPoint:center toView:item.superview];
    }

    SEL sync = NSSelectorFromString(@"amap_syncLegacySelectionAnimated:");
    if ([bar respondsToSelector:sync]) ((void (*)(id, SEL, BOOL))objc_msgSend)(bar, sync, NO);
    adjusting = NO;
}

// ===== M0: 白雾取证 =====
//
// 用户两轮反馈"还有白雾"，说明我压错了对象（maskView / bottomMaskLayer 都不是）。
// 不再猜 —— 点完扫全窗口，把"大面积、可见、背景偏白"的视图全部报出来，
// 真身就在里面。只读不写，纯诊断。
static void GCProbeWhiteFog(__unused const char *tag) {
#if GCC_DEVICE_TEST
    UIWindow *win = nil;
    for (UIScene *sc in UIApplication.sharedApplication.connectedScenes) {
        if (![sc isKindOfClass:UIWindowScene.class]) continue;
        for (UIWindow *w in ((UIWindowScene *)sc).windows) {
            if (w.isKeyWindow) { win = w; break; }
        }
        if (win) break;
    }
    if (!win) { GCLog(@"[FOG %s] 无窗口", tag); return; }
    CGFloat area = win.bounds.size.width * win.bounds.size.height;
    if (area <= 0) return;
    __block int hits = 0;
    // 广度遍历整棵窗口树（上限 4000 个节点，防异常树卡死）
    NSMutableArray<UIView *> *stack = [NSMutableArray arrayWithObject:win];
    NSUInteger guard = 0;
    while (stack.count && guard++ < 4000) {
        UIView *v = stack.lastObject;
        [stack removeLastObject];
        for (UIView *sub in v.subviews) [stack addObject:sub];
        if (v == win) continue;
        if (v.hidden || v.alpha < 0.05) continue;
        CGRect r = [v convertRect:v.bounds toView:win];
        if (!isfinite(r.size.width) || !isfinite(r.size.height)) continue;
        if (r.size.width * r.size.height < area * 0.18) continue;   // 只看大面积
        // 背景偏白？（含 layer.backgroundColor）
        CGFloat rr = 0, gg = 0, bb = 0, aa = 0;
        BOOL whiteish = NO;
        if ([v.backgroundColor getRed:&rr green:&gg blue:&bb alpha:&aa] && aa > 0.05) {
            whiteish = (rr > 0.85 && gg > 0.85 && bb > 0.85);
        } else {
            CGColorRef c = v.layer.backgroundColor;
            if (c) {
                const CGFloat *comp = CGColorGetComponents(c);
                if (comp && CGColorGetNumberOfComponents(c) >= 4) {
                    whiteish = (comp[0] > 0.85 && comp[1] > 0.85 && comp[2] > 0.85 && comp[3] > 0.05);
                }
            }
        }
        // 毛玻璃（UIVisualEffectView）backgroundColor 为 nil，必须单独识别 ——
        // "白雾状"极可能就是一层 blur。
        BOOL isEffect = [v isKindOfClass:[UIVisualEffectView class]];
        if (!whiteish && !isEffect) continue;
        hits++;
        if (hits > 12) continue;
        GCLog(@"[FOG %s] %@ {%.0f,%.0f,%.0f,%.0f} a=%.2f bg=%.2f,%.2f,%.2f,%.2f%@",
              tag, NSStringFromClass([v class]), r.origin.x, r.origin.y,
              r.size.width, r.size.height, v.alpha, rr, gg, bb, aa,
              isEffect ? @" ←毛玻璃" : @"");
    }
    GCLog(@"[FOG %s] 命中 %d 个", tag, hits);
#endif
}

static void InstallMinimalHome(void) {
    HookVoid(@"WINTabBar", @"layoutSubviews", ^(UIView *bar) { CenterTabButtons(bar); });
    HookVoid(@"WINTabBar", @"amap_relayoutTabItems", ^(UIView *bar) { CenterTabButtons(bar); });

    // L2: 点底栏圆钮后立即压制首页遮罩。
    // handleTap: 是 WINTabBar 的点击入口（17.00.2 类转储确认），带 1 个手势参数，
    // 不能用 HookVoid（它只接无参方法），所以直接 Replace。
    // 再点「首页」时 App 会重新显示 maskView → 白雾，这里当场压掉，
    // 不必等 100ms 的 Schedule 循环（那会让白雾闪一下）。
    {
        Class tb = NSClassFromString(@"WINTabBar");
        SEL ht = NSSelectorFromString(@"handleTap:");
        Method hm = class_getInstanceMethod(tb, ht);
        if (hm) {
            IMP orig = method_getImplementation(hm);
            Replace(tb, ht, imp_implementationWithBlock(^(id self, id gesture) {
                // ===== M1: 已在首页又点首页 → 直接吞掉，不让 App 走重选流程 =====
                // 白雾的源头是"重选首页"这个动作本身，压遮罩只是治标。
                UIView *bar = (UIView *)self;
                CGPoint p = CGPointZero;
                BOOL havePoint = NO;
                if ([gesture isKindOfClass:UIGestureRecognizer.class]) {
                    p = [(UIGestureRecognizer *)gesture locationInView:bar];
                    havePoint = YES;
                }
                NSInteger slot = havePoint ? GCTabDotSlot(bar, p) : -1;
                // 判断"当前是不是首页"：优先用 selectIndex，但它可能是 NSUInteger
                // 也可能是 NSNumber，类型不确定 —— 两条路都试，再退到
                // tabBarControl.selectedViewControl 的类名判断。
                BOOL onHome = NO;
                SEL siSel = NSSelectorFromString(@"selectIndex");
                if ([bar respondsToSelector:siSel]) {
                    @try {
                        NSMethodSignature *sig = [bar methodSignatureForSelector:siSel];
                        if (sig && sig.numberOfArguments == 2) {
                            const char *rt = sig.methodReturnType;
                            if (rt[0] == 'Q' || rt[0] == 'q' || rt[0] == 'I' || rt[0] == 'i') {
                                NSUInteger v = ((NSUInteger (*)(id, SEL))objc_msgSend)(bar, siSel);
                                onHome = (v == 0);
                            } else if (rt[0] == '@') {
                                id v = ((id (*)(id, SEL))objc_msgSend)(bar, siSel);
                                if ([v respondsToSelector:@selector(integerValue)])
                                    onHome = ([v integerValue] == 0);
                            }
                        }
                    } @catch (NSException *e) {}
                }
                if (!onHome) {
                    for (id tabs in TabControllers.allObjects) {
                        id sv = ObjectGetter(tabs, @"selectedViewControl");
                        if ([NSStringFromClass([sv class]) isEqualToString:@"WINAmapHomeControl"]) { onHome = YES; break; }
                    }
                }
                if (slot == 0 && onHome) {
                    GCLog(@"[TAP] 已在首页，吞掉点击 (slot=0)");
                    GCProbeWhiteFog("before");
                    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)),
                                   dispatch_get_main_queue(), ^{
                        GCProbeWhiteFog("after-swallow");
                    });
                    return;   // ★ 不调原实现
                }
                ((void (*)(id, SEL, id))orig)(self, ht, gesture);
                for (id handler in HomeHandlers.allObjects) GCSuppressHomeMask(handler);
                GCKillWhiteOverlay(bar);
                dispatch_async(dispatch_get_main_queue(), ^{
                    for (id handler in HomeHandlers.allObjects) GCSuppressHomeMask(handler);
                    GCKillWhiteOverlay(bar);
                });
                // 每次点击后取一次证，看白雾是否出现、是谁
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)),
                               dispatch_get_main_queue(), ^{
                    GCProbeWhiteFog("after-tap");
                });
            }), method_getTypeEncoding(hm));
            GCLog(@"[MASK] handleTap: 已挂钩（含首页吞点击）");
        } else {
            GCLog(@"[MASK] WINTabBar.handleTap: 不存在");
        }
    }

    // ===== M2: 拦掉双击 =====
    // 快速连点首页会被识别成双击，触发 App 未知行为（疑似白雾来源之一）。
    for (NSString *name in @[@"handleDoubleTap:", @"doubleclick:"]) {
        Class tb = NSClassFromString(@"WINTabBar");
        SEL s = NSSelectorFromString(name);
        Method m = class_getInstanceMethod(tb, s);
        if (!m) { GCLog(@"[MASK] WINTabBar.%@ 不存在", name); continue; }
        IMP o = method_getImplementation(m);
        Replace(tb, s, imp_implementationWithBlock(^(id self, id arg) {
            GCLog(@"[MASK] 拦截 %@", name);
            (void)o; (void)self; (void)arg;
        }), method_getTypeEncoding(m));
        GCLog(@"[MASK] %@ 已拦截", name);
    }

    HookVoid(@"GDAmapHomeHandler", @"viewDidLoad", ^(id handler) { [HomeHandlers addObject:handler]; });
    HookVoid(@"GDAmapHomeHandler", @"layoutBottomSearchBar", ^(id handler) { [HomeHandlers addObject:handler]; LayoutMinimalHome(handler); });
    HookVoid(@"GDAmapHomeHandler", @"viewDidLayoutSubviews", ^(id handler) { [HomeHandlers addObject:handler]; LayoutMinimalHome(handler); });
    Class cls = NSClassFromString(@"WINAMapHomeStateMachine");
    SEL sel = NSSelectorFromString(@"setState:");
    Method method = class_getInstanceMethod(cls, sel);
    if (method) {
        IMP original = method_getImplementation(method);
        Replace(cls, sel, imp_implementationWithBlock(^(id self, id state) {
            NSString *name = NSStringFromClass([state class]);
            id compact = nil;
            if ([name containsString:@"BottomSearchBar"]) compact = ObjectGetter(self, @"bottomSearchBarImmersiveState");
            if ([name containsString:@"TopSearchBar"]) compact = ObjectGetter(self, @"topSearchBarImmersiveState");
            ((void (*)(id, SEL, id))original)(self, sel, compact ?: state);
        }), method_getTypeEncoding(method));
    }
    sel = NSSelectorFromString(@"showTabBar:animated:");
    method = class_getInstanceMethod(cls, sel);
    if (method) {
        IMP original = method_getImplementation(method);
        Replace(cls, sel, imp_implementationWithBlock(^(id self, __unused BOOL show, BOOL animated) {
            ((void (*)(id, SEL, BOOL, BOOL))original)(self, sel, YES, animated);
        }), method_getTypeEncoding(method));
    }
    cls = NSClassFromString(@"WINQuickSearchBarV2");
    sel = NSSelectorFromString(@"updatePlaceholderText:leftIcon:rightIcon:words:animation:");
    method = class_getInstanceMethod(cls, sel);
    if (method) {
        IMP original = method_getImplementation(method);
        Replace(cls, sel, imp_implementationWithBlock(^(id self, __unused id text, __unused id left, __unused id right, __unused id words, __unused BOOL animated) {
            ((void (*)(id, SEL, id, id, id, id, BOOL))original)(self, sel, @"", nil, nil, nil, NO);
        }), method_getTypeEncoding(method));
    }
    // ===== 0.4.10 B4: 每次布局都把搜索框压回 52x52 =====
    // 铁证（0.4.9 实测）：App 会把 WINQuickSearchBarV2 的 bounds 重置回 393x54，
    // 只在 LayoutMinimalHome 里写一次会被覆盖，所以必须挂在 layoutSubviews 上补压。
    // 用 setFrame: 钩子而不是 transform —— 两者绝不能同时写（0.4.9 NaN 崩溃根因）。
    HookVoid(@"WINQuickSearchBarV2", @"layoutSubviews", ^(id obj) {
        UIView *bar = (UIView *)obj;
        UIView *text = ObjectGetter(bar, @"verticalScrollText");
        if ([text isKindOfClass:UIView.class]) text.hidden = YES;
        if (![bar isKindOfClass:UIView.class] || !bar.window) return;
        // ★ 只处理首页那颗已被接管的圆钮。搜索页里的原生搜索框必须保持原样，
        //   否则一进搜索页整条输入框会被隐藏（0.3.x 踩过）。
        if (!objc_getAssociatedObject(bar, &SearchDotKey)) return;
        if (fabs(bar.bounds.size.width - GC_DOT) > 0.5 || fabs(bar.bounds.size.height - GC_DOT) > 0.5)
            bar.bounds = CGRectMake(0, 0, GC_DOT, GC_DOT);
        GCDressSearchDot(bar);
    });
    HookVoid(@"WINAJXCombinedItemView", @"layoutSubviews", ^(id view) { if (IsStreetRank(view)) [view setHidden:YES]; });
    cls = NSClassFromString(@"WINAJXCombinedItemView");
    sel = @selector(setHidden:);
    method = class_getInstanceMethod(cls, sel);
    if (method) {
        IMP original = method_getImplementation(method);
        Replace(cls, sel, imp_implementationWithBlock(^(UIView *self, BOOL hidden) {
            ((void (*)(id, SEL, BOOL))original)(self, sel, hidden || IsStreetRank(self));
        }), method_getTypeEncoding(method));
    }
    HookVoid(@"WINAJXCombinedWidgetView", @"layoutSubviews", ^(id view) { if (IsStreetRank(view)) [view setHidden:YES]; });
    cls = NSClassFromString(@"WINAJXCombinedWidgetView");
    sel = @selector(setHidden:);
    method = class_getInstanceMethod(cls, sel);
    if (method) {
        IMP original = method_getImplementation(method);
        Replace(cls, sel, imp_implementationWithBlock(^(UIView *self, BOOL hidden) {
            ((void (*)(id, SEL, BOOL))original)(self, sel, hidden || IsStreetRank(self));
        }), method_getTypeEncoding(method));
    }
}

__attribute__((constructor)) static void Initialize(void) {
    @autoreleasepool {
        if (![NSBundle.mainBundle.bundleIdentifier isEqualToString:@"com.autonavi.amap"]) return;
        // 0.4.10: 原硬闸门 isEqual:@"17.00.2" 已删除。17.02.2 及以后版本的类/selector
        // 变化由各 Hook 内的 `if (!m) return;` 逐项跳过，不能整体零钩子安装。
        NSString *appVersion = [NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"] ?: @"unknown";
        NSLog(@"[GaodeClean] app version %@ - installing hooks (no version limit)", appVersion);
        Pages = [NSHashTable weakObjectsHashTable];
        NearbyControllers = [NSHashTable weakObjectsHashTable];
        TabControllers = [NSHashTable weakObjectsHashTable];
        HomeHandlers = [NSHashTable weakObjectsHashTable];
        InstallScrollHooks();
        InstallMinimalHome();
        HookVoid(@"GDMapHomeTabBarControl", @"loadViewControlParams", ^(id tabs) {
            id params = ObjectGetter(tabs, @"viewControlParams");
            if (![params isKindOfClass:NSArray.class]) return;
            NSMutableArray *kept = [NSMutableArray array];
            for (id item in params) {
                if ([@[@"WINAmapHomeControl", @"WINMineViewControl"] containsObject:ObjectGetter(item, @"className") ?: @""])
                    [kept addObject:item];
            }
            if (kept.count == 2) ((void (*)(id, SEL, id))objc_msgSend)(tabs, NSSelectorFromString(@"setViewControlParams:"), kept);
        });
        HookHitTest(UIView.class);
        HookHitTest(NSClassFromString(@"AJX3View"));
        // G: 底栏圆钮只认圆内点击（圆外四角穿透到底图）
        InstallTabDotHitTest();
        Class registry = NSClassFromString(@"GDTabBarItemRegistry");
        SEL sel = NSSelectorFromString(@"registerTabProvider:");
        Method m = class_getInstanceMethod(registry, sel);
        if (m) {
            NSMethodSignature *s = [NSMethodSignature signatureWithObjCTypes:method_getTypeEncoding(m)];
            if (s.numberOfArguments == 3 && s.methodReturnType[0] == 'v' && [s getArgumentTypeAtIndex:2][0] == '#') {
                IMP original = method_getImplementation(m);
                IMP imp = imp_implementationWithBlock(^(id self, Class provider) {
                    if (![@[@"GDMainTabBarConfigProvider", @"GDMineTabBarConfigProvider"] containsObject:NSStringFromClass(provider) ?: @""]) {
                        NSLog(@"[GaodeClean] removed tab provider %@", NSStringFromClass(provider));
                        return;
                    }
                    ((void (*)(id, SEL, Class))original)(self, sel, provider);
                });
                Replace(registry, sel, imp, method_getTypeEncoding(m));
            }
        }
        HookVoid(@"AJXBaseElement", @"reloadView", ^(id e) { Capture(e); });
        HookVoid(@"AJXBaseElement", @"layoutSubViews", ^(id e) { Capture(e); });
        HookVoid(@"AJXBaseElement", @"updateVoiceOverIDAndLabel", ^(id e) { Capture(e); });
        HookVoid(@"AJX3View", @"layoutSubviews", ^(id page) { [Pages addObject:page]; if (!Cleaning) { Cleaning = YES; CleanPage(page); Cleaning = NO; } Schedule(); });
        HookVoid(@"AJX3View", @"didMoveToWindow", ^(id page) { [Pages addObject:page]; CleanPage(page); Schedule(); });
        HookVoid(@"AJXWINNearbyViewControl", @"viewDidLoad", ^(id controller) { [NearbyControllers addObject:controller]; Schedule(); });
        HookVoid(@"WINTabBarControl", @"viewDidLoad", ^(id tabs) { [TabControllers addObject:tabs]; Schedule(); });
        // Recheck after asynchronous cards and cell reuse; only attached target pages are scanned.
        dispatch_async(dispatch_get_main_queue(), ^{
            [NSTimer scheduledTimerWithTimeInterval:0.5 repeats:YES block:^(__unused NSTimer *timer) { Schedule(); }];
            // I3: 搜索钮置顶保活（App 重布局会把它压回底栏下面）
            [NSTimer scheduledTimerWithTimeInterval:0.5 repeats:YES block:^(__unused NSTimer *timer) {
                UIView *bar = GCLiveSearchBar;
                UIView *p = bar.superview;
                if (!p || !p.window) return;
                NSArray *subs = p.subviews;
                if (subs.lastObject != bar) [p bringSubviewToFront:bar];
            }];
#ifdef GCC_DEVICE_TEST
            // N2: 启动后自动取证两次（白雾不一定需要点击才出现）
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{ GCProbeWhiteFog("startup3s"); });
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(8.0 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{ GCProbeWhiteFog("startup8s"); });
            // HUD 会被 App 的重布局压到下面，1 秒拉回一次
            [NSTimer scheduledTimerWithTimeInterval:1.0 repeats:YES block:^(__unused NSTimer *timer) {
                [(GCHUDView *)[GCHUDView shared] refresh];
                if (!GCHUDView.shared.superview) GCLog(@"[HUD] 等待窗口…");
            }];
#endif
        });
        GCLog(@"[INIT] loaded 0.4.23 appVer=%@", appVersion);
    }
}
