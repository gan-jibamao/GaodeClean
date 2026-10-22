// ============================================================================
//  GaodeClean —— 高德地图 UI 精简
//
//      Author  : jibamao
//      Repo    : https://gan-jibamao.github.io/
//      Section : jibamao-Tweaks
//      Target  : AMap / 高德地图  com.autonavi.amap  （版本限制已取消，全版本自适应）
//
//  This tweak changes UI only. No network interception or modification of the IPA.
// ============================================================================

#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import "GCCGeometry.h"

// ---- jibamao 个人标识（编译进 dylib，可用 strings 核对）----
static NSString *const kGCAuthor      = @"jibamao";
static NSString *const kGCRepo        = @"https://gan-jibamao.github.io/";
static NSString *const kGCSection     = @"jibamao-Tweaks";
static NSString *const kGCVersion     = @"0.9.19";
static NSString *const kGCSignature   = @"GaodeClean by jibamao";

// 0.9.18（A1）：底边间隙**按控件分开**，对表原生（搜索栏白底顶边 = 702.6pt）
//   车机钮（连接车机 · WINDeviceInterconnectWidget）：原生底 652 → 间隙 50.6 → 取 50
//   ⊙/↰ 胶囊（WINAJXCombinedWidgetView）：原生底 683 → 间隙 19.5 → 取 20（0.9.17 已实测 Δ=0）
//   0.9.17 之前两者共用 20 ⇒ 车机钮低了 30pt，被塞进天气行（真机铁证：我们 648..682 vs 原生 616..652）
static const CGFloat GCGapCar     = 50.0;
static const CGFloat GCGapCapsule = 20.0;
// 0.9.19（A1）：2D/3D 按钮与胶囊的原生间隙 —— 按原生实测校准为 13.3
//   原生：2D 按钮顶 536.7 + 高 44 → 底 580.7；胶囊顶 594 ⇒ 间隙 13.3
//   （0.9.18 用的 15 偏 1.7pt；本轮「真机 diag + 原生录屏模板匹配」双证）
static const CGFloat GCGapMapType = 13.3;

// 对外签名（供 log / 诊断 / 二次核对使用）
const char *GaodeCleanSignature(void) {
    static char buf[160];
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        snprintf(buf, sizeof(buf), "%s v%s | %s | %s",
                 "GaodeClean", kGCVersion.UTF8String,
                 kGCAuthor.UTF8String, kGCRepo.UTF8String);
    });
    return buf;
}

// ============================================================================
// 0.9.14（A9）：诊断日志编译期分档
//
//   正式包（Makefile 注入 -DGAODECLEAN_STRIP_LOGS=1）下 GCLog 展开为无副作用的
//   空操作 —— 每次启动省下十余条运行时写日志的 I/O，定制行为的字符串也不再进入
//   发布二进制。开关类/版本类的日志仍走 NSLog：装机后要能在 Console 里核对
//   「装的是哪一版、哪些钩子装上/跳过了」，这是验收依赖，不可剥。
// ============================================================================
#ifdef GAODECLEAN_STRIP_LOGS
#define GCLog(...) do { } while (0)
#else
#define GCLog(...) NSLog(__VA_ARGS__)
#endif

// 0.8.0：迁移边界缓存键随「当前已识别版本」变化，跨版本不再串味
static NSString *GCBoundaryKey(void) {
    static NSString *k;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSString *v = [NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"] ?: @"?";
        k = [NSString stringWithFormat:@"GaodeClean.MineBoundary.%@", v];
    });
    return k;
}

// This tweak changes UI only. No network interception or modification of the IPA.
static char TextKey, StateKey, LimitKey, ForcedKindKey, ForcedPathKey;
static NSHashTable<UIView *> *Pages;
static NSHashTable *NearbyControllers;
static NSHashTable *TabControllers;
static NSHashTable *HomeHandlers;
static BOOL LayingOutHome;
static BOOL Scheduled, Applying;
static CGFloat SearchBarSettledY;
static BOOL SearchBarSettled;
static NSInteger BarStableTicks;
// 0.9.15：搜索栏「上一拍」的位置 —— 稳定性计数改为与上一拍比较，
// 不再与「已锁定的目标值」比较（旧写法在锚点迁移时会自我循环，见 §Y）
static CGFloat BarLastY = -1;
static BOOL BarShownOnce;      // 0.9.2：搜索栏在正确位置显示过至少一次（冷启动防闪断标记）
// 0.9.14（A8 回退）：HomeSettled 恢复。它是 0.4.41 兜底的**唯一门控** ——
// 「任一控件对齐成功」= 首页布局已稳定 = 兜底无需再跑。
// 0.9.8 把这条门控拆掉后，兜底从「一次性」变成「每拍跑」，于是启动 2.4s 起
// 每 200ms 把 ColdWidgets 里尚未对齐的控件 hidden=NO —— 右下定位钮就以
// 原生中部位置（屏高 25%-70%）现身。真机逐帧铁证：0.9.7 = 0 帧裸露，
// 0.9.8 = 19 帧；0.9.9~0.9.13 用五层显示路径拦截去打这个症状，反而造出
// 「alpha 卡 0 / 丢弃 frame / 兜底抢 AlignedKey」等新自锁，数据在
// 19→21→14→4→2→14 之间钟摆，从未归零。
static BOOL HomeSettled;
static NSHashTable<UIView *> *ColdWidgets;
static NSInteger ColdTicks;
static char AlignedKey;
static dispatch_source_t ScheduleTimer;
static __weak UIView *BarParent;
static __weak UIView *CachedCar, *CachedRight, *CachedRoute;
// 0.9.16（A2）：App 原生「轻量控件组」容器（中部裸露胶囊的真身，见 A1）
static __weak UIView *CachedLiteGroup;
static NSHashTable<UIView *> *GCWeatherHeldRows;   // 0.9.3：冷启动被扣留的天气行（锚点未就绪期间不显示）
static __weak id CachedTabs;
static __weak UIView *SearchBarView;   // 0.5.58   // 0.5.55：用于判断当前是否「首页」选中
static void UpdateMask(UIView *page);
static void Schedule(void);
static void LayoutMinimalHome(id handler);
static void AlignCornerWidgets(UIView *bar);
static BOOL FixingHintText;
static __weak UIView *CachedTabBar;
static int BarFixStalls;      // 0.6.8：早退续窗次数上限，防止 8ms 自旋
static int BarFixIdle;        // 0.6.9：连续「无改动」拍数，够了就立刻收窗
static void AlignWeatherRowTick(UIWindow *win);
static void SweepTabBarHints(UIView *bar);
static void SweepFogOverlay(void);
static void StripSlidablePan(void);
static void StripTabBarGestures(void);
static void KickBarFix(void);
static void KickBarFixFor(NSTimeInterval seconds);
static void WatchHomeTransition(id tabs);
static __weak UIWindow *GCCMainWindow;
static __weak UIWindow *GCCSplashWindow;      // 已识别的广告窗口，之后拒绝其可见
static NSInteger GCCSplashTicks;              // 兜底扫描剩余拍数（有界）
static int GCCSplashUntil;                    // 0.7.5(B2)：窗口拉黑失效拍号（60s 后自动解除）
static int TickCount;         // 0.7.2：主 tick 计数（降频兜底用）
static BOOL CleanForce;       // 0.7.2：下一拍强制跑一次全量 CleanPage
static int GCCActiveUntil;    // 0.7.4(A4)：活跃窗截止拍号（切页/新页面挂载后 TickCount+8）
static void GCCArmTick(void); // 0.7.4(A3)：按前台/后台动态整备 tick 节拍
static NSMutableDictionary<NSString *, NSNumber *> *AjxCache;  // 0.7.2：类名→是否 AJX
static void InstallSplashAdGuard(void);
static void SplashAdTick(void);
static void AlignOneWidget(UIView *bar, UIView *w, CGFloat barTop, CGFloat gap);

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
@property(nonatomic) CGFloat clipHeight;
@property(nonatomic) BOOL matched;
@property(nonatomic) BOOL reportedMatch;
@property(nonatomic) BOOL reportedMiss;
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
    if ([p hasSuffix:@"/amap_bundle_quickservice/src/pages/QuickServiceRedesign.page.js"]) return 1;
    if ([p hasSuffix:@"/amap_bundle_nearby/src/pages/BizNearbyIndex.page.js"]) return 2;
    if ([p hasSuffix:@"/amap_bundle_globalvoice/src/llm/ExplorePage/ExplorePage.page.js"]) return 2;
    if ([p hasSuffix:@"/amap_bundle_mine/src/pages/MinePage.page.js"]) return 3;
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

// 0.7.2：AJX 判定按类缓存。CleanPage 每拍对上千节点调 NodeText，
// 原来每个节点都要 NSStringFromClass + hasPrefix —— 缓存后只剩一次字典查找。
static BOOL NodeIsAjx(UIView *v) {
    NSString *cn = NSStringFromClass(v.class);
    NSNumber *cached = AjxCache[cn];
    if (cached) return cached.boolValue;
    BOOL is = [cn hasPrefix:@"AJX"];
    AjxCache[cn] = @(is);
    return is;
}

static NSString *NodeText(UIView *v) {
    NSMutableString *s = [NSMutableString string];
    if ([v isKindOfClass:UILabel.class]) [s appendString:((UILabel *)v).text ?: @""];
    // AJX uses custom CoreText labels, not just UIKit UILabel.
    if (NodeIsAjx(v)) {
        static NSArray<NSString *> *getters;
        static dispatch_once_t once;
        dispatch_once(&once, ^{ getters = @[@"attributedString", @"attributedText", @"text"]; });
        for (NSString *getter in getters) {
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
    // 0.9.8（A10）：Kind() 走的是 PagePath → ObjectGetter → methodSignatureForSelector
    // 的完整链路，原来在这里被算了**两遍**。UpdateMask 挂在 setBounds: 之后，
    // 滚动时每帧触发，Pages 有几个页就乘几 —— 白烧一半。
    NSInteger kind = Kind(page);
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    if (kind == 2 || kind == 3) {
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
        // 0.7.3：原来每帧无条件 bringSubviewToFront —— 父视图层级每帧重排。
        if (page.subviews.lastObject != state.blankArea)
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
    // 0.7.3：滚动时这条路径每帧都在重建（UIBezierPath + CGPath 分配）。
    if (!state.clip.path || fabs(state.clipHeight - height) > 0.5) {
        state.clipHeight = height;
        state.clip.path = [UIBezierPath bezierPathWithRect:CGRectMake(0, 0, page.bounds.size.width, height)].CGPath;
    }
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

static void CleanPage(UIView *page, BOOL full) {
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
    // 0.7.2：非全量拍且已匹配 → 跳过全树扫描。
    // 原来每拍对每页 Flatten ≤2000 节点 + 每节点 2–6 次 msgSend（5 次/秒），
    // 是整个 tweak 最重的一条常驻路径。app 改内容会触发 AJX3View 的
    // layoutSubviews / didMoveToWindow 钩子，那里置 CleanForce —— 事件不会漏。
    // 兜底降到每 5 拍（1 秒）一次。
    if (!full && state.matched) { ApplyLimits(state); return; }
    NSArray<UIView *> *nodes = Flatten(page);
    if (!nodes) { ApplyLimits(state); return; }
    NSArray *primary = kind == 1 ? @[@"常去地点"] : kind == 2 ? @[@"停车", @"美食", @"酒店", @"加油", @"旅游"] : @[@"家人地图", @"地图共建"];
    NSArray *secondary = kind == 1 ? @[@"回家", @"去单位", @"编辑"] : kind == 2 ? @[@"美食", @"酒店", @"加油", @"旅游"] : @[@"车辆服务", @"高德运动", @"店铺入驻"];
    UIView *anchor = nil, *peer = nil;
    CGFloat boundary = 0;
    if (kind == 3) {
        for (UIView *node in nodes) {
            if (!Visible(node) || ![NodeText(node) containsString:@"足迹"] || node.bounds.size.height > 80) continue;
            for (UIView *card = node.superview; card && card != page; card = card.superview) {
                CGRect rect = [card convertRect:card.bounds toView:page];
                if (rect.size.width >= page.bounds.size.width * 0.75 && rect.size.height >= 70 && rect.size.height <= 200) {
                    anchor = peer = node;
                    boundary = CGRectGetMaxY(rect) + 8;
                    break;
                }
            }
            if (anchor) break;
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
            // 0.6.8：这里原本会去读 Documents/GaodeClean-diagnostics.json（0.5.1 时代的诊断产物）。
            // 「正式包零诊断」之后那个文件永远不会再生成，这段读取只剩一次无意义的磁盘探测，
            // 而且它只在从「我的」页取不到 anchor 时触发 —— 正好是切页路径上。整段删除。
            NSDictionary *cached = [NSUserDefaults.standardUserDefaults dictionaryForKey:GCBoundaryKey()];
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
            GCLog(@"[GaodeClean] page=%ld anchor=pending", (long)kind);
            state.reportedMiss = YES;
        }
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
    if (kind == 3 && boundary > 100 && boundary < page.bounds.size.height) {
        NSDictionary *cached = [NSUserDefaults.standardUserDefaults dictionaryForKey:GCBoundaryKey()];
        if (fabs([cached[@"bottom"] doubleValue] - boundary) > 0.5 || fabs([cached[@"width"] doubleValue] - page.bounds.size.width) > 0.5)
            [NSUserDefaults.standardUserDefaults setObject:@{@"width":@(page.bounds.size.width), @"bottom":@(boundary)} forKey:GCBoundaryKey()];
    }
    BindBoundary(page, anchor, peer, boundary, state);
    if (!state.reportedMatch) {
        GCLog(@"[GaodeClean] page=%ld anchor=matched limitedScrolls=%lu", (long)kind, (unsigned long)state.scrolls.count);
        state.reportedMatch = YES;
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

static void Schedule(void) {
    if (![NSThread isMainThread] || Scheduled) return;
    Scheduled = YES;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 100 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
        Scheduled = NO;
        // 0.6.4：**这里原本直接 return，把整条调度链掐死了**——
        // 冷启动瞬间 applicationState 还是 Inactive（app 已在屏幕上、但系统尚未置为 Active），
        // 于是这一拍提前返回、末尾的 Schedule() 不再执行 → 整个 tick 永久停跑。
        // 表现就是「冷启动后天气行停在原生位置，切一次页才归位」：搜索栏/车机钮各有自己的
        // layoutSubviews 钩子兜底，唯独天气行的对齐只挂在 tick 上，链一断就再也不跑。
        // （历史记录里那条「NSTimer/GCD timer 都在 ~1.35s 停跑」是同一个坑。）
        // 修法：不 return，而是「不活跃时不干活、但照样续链」；并用 dispatch_after 兜底续链，
        // 即使某一拍真的返回了，1 秒后也会重新接上。
        // 0.7.4(A2)：删掉 100ms 自持重试链。它是 NSTimer 时代的补丁（当年 tick 自己续链，
        // 一旦 return 就永久停跑），而 0.6.4 起链已由 200ms 的 GCD ScheduleTimer 驱动，
        // 不会因提前返回而断。重试链只剩副作用：非活跃时额外 10 次/秒空转唤醒。
        if (UIApplication.sharedApplication.applicationState != UIApplicationStateActive) return;
        TickCount++;
        for (id tabs in TabControllers.allObjects) {
            id selected = ObjectGetter(tabs, @"selectedViewControl");
            id params = ObjectGetter(tabs, @"viewControlParams");
            if ([params isKindOfClass:NSArray.class]) for (id item in params) {
                if (selected && ObjectGetter(item, @"viewControl") == selected) {
                    id title = ObjectGetter(item, @"title");
                    id label = ObjectGetter(item, @"accessibilityLabel");
                    static NSArray<NSString *> *nearbyTitles;
                    static dispatch_once_t once;
                    dispatch_once(&once, ^{ nearbyTitles = @[@"探索", @"附近"]; });
                    if ([nearbyTitles containsObject:title ?: @""] || [nearbyTitles containsObject:label ?: @""]) {
                        [NearbyControllers addObject:selected];
                    }
                }
            }
        }
        for (id tabs in TabControllers.allObjects) WatchHomeTransition(tabs);
        for (id controller in NearbyControllers.allObjects) RegisterNearby(controller);
        // 0.7.2：全量 CleanPage 只在「事件 + 每 5 拍兜底」时跑；
        // 非全量拍走轻路径（Restore / 宽度检查 / ApplyLimits），不碰页面树。
        BOOL fullClean = CleanForce || (TickCount % 5 == 0);
        for (UIView *page in Pages.allObjects) CleanPage(page, fullClean);
        // 0.7.3：三个周期扫描降到 400ms（白雾是持续态不是闪现，
        // 源头修复 0.5.8/0.5.9/0.5.50 已掐死它的出现条件，这里只是兜底）
        // 0.7.4(A1)：0.7.3 用「注释行 + SweepFogOverlay 行」做锚点替换新块时，
        // 旧的两行调用（带对齐注释）没被一并删掉 -> 同一个 400ms 窗口内各跑两遍。
        // 0.7.4(A4)：白雾/可滑手势都是「切页、新页面挂载」那一瞬间的产物，
        // 加活跃窗门控 —— 事件后 8 拍（1.6s）内每 2 拍扫，静默期降到每 6 拍（1.2s）。
        if (TickCount % (TickCount < GCCActiveUntil ? 2 : 6) == 0) {
            SweepFogOverlay();
            StripSlidablePan();
            StripTabBarGestures();
        }
        // 0.4.41 冷启动兜底：定位超时(约 2.4s)仍未完成则强制显示，避免卡在隐藏态
        // 0.9.14（A8 回退）：恢复 0.9.7 的**一次性**语义（HomeSettled 门控）。
        //   0.9.8 把门控拆掉后，这条兜底从「最后保险」变成了「每拍的显示通道」：
        //   启动 2.4s 起每 200ms 把 ColdWidgets 里尚未对齐的控件 hidden=NO。
        //   右下定位钮首当其冲 —— 它的 getItemTag 精确判据（IsRightBottomWidget）
        //   在那一刻还没配对，AlignOneWidget 没碰过它，frame 仍停在 app 原生中部
        //   位置，于是「一开闸就以错误位置现身」。逐帧铁证：0.9.7 = 0 帧裸露、
        //   0.9.8 = 19 帧；之后 0.9.9~0.9.13 五层显示路径拦截全是在打这个症状。
        //   恢复后：任一控件对齐成功即封门，兜底只在「整套对齐机制都失败」时跑一次。
        // 0.9.15（A2 配套）：锚点（搜索栏）未定格前 AlignCornerWidgets 会直接返回，
        //   因此「对齐成功」最早发生在搜索栏稳定 3 拍之后 —— 封门时刻相应后移，
        //   这正好让兜底与真机启动节奏对齐（见 A4 的阈值调整）。
        ColdTicks++;
        if (!HomeSettled && ColdTicks > 16) {
            // 0.9.15（A4）：阈值 12 → 16。A2 的锚点闸门保证「最早也要 ColdTicks>=15
            // 才认领」—— 12 拍开闸会**先**把控件按 app 原始位置强显（中部位），
            // 等于把刚堵上的裸露从兜底这条路重新放出来。16 拍确保闸门先跑。
            HomeSettled = YES;
            for (UIView *w in ColdWidgets.allObjects) {
                if (![w isKindOfClass:UIView.class]) continue;
                objc_setAssociatedObject(w, &AlignedKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                // 兜底同样要恢复 alpha，否则被压成 0 的控件即使 hidden=NO 也不可见。
                if (w.alpha < 0.01) w.alpha = 1.0;
                w.hidden = NO;
            }
        }
        // 0.4.45：搜索栏被 app 拉回原生位置(447)时重新隐藏并重置稳定性计数（兜底）
        for (id handler in HomeHandlers.allObjects) {
            UIView *hb = ObjectGetter(handler, @"searchBar");
            if ([hb isKindOfClass:UIView.class]) {
                // 0.5.52：这条兜底**只用于冷启动**。页面切换（我的→首页）时 app 会
                // 临时重排整个首页，搜索栏 y 短暂偏离，旧逻辑立刻 hidden=YES 并重置稳定
                // 计数 → 搜索栏闪一下再回来。下面那行显示逻辑本来就带 ColdTicks<15
                // 条件，隐藏这条当初漏了，现在补齐（切页不再隐藏搜索栏）。
                if (ColdTicks < 15 && SearchBarSettled &&
                    fabs(hb.frame.origin.y - SearchBarSettledY) > 2) {
                    hb.hidden = YES;
                    BarStableTicks = 0;
                }
                break;
            }
        }
        for (id handler in HomeHandlers.allObjects) {
            LayoutMinimalHome(handler);
            // 0.4.44：对齐独立于 LayoutMinimalHome（后者早退时仍能持续把圆钮拉回对齐位）
            UIView *bar = ObjectGetter(handler, @"searchBar");
            if ([bar isKindOfClass:UIView.class]) {
                AlignCornerWidgets(bar);
                AlignWeatherRowTick(bar.window);
            }
        }
        // 0.7.0：开屏广告兜底（有界窗口内）
        SplashAdTick();
        // 0.6.7：底栏「上拉发现」提示的周期通道 —— 引导态常常晚于最后一次布局才落地，
        // 只挂 layout 就是这个 bug 偶发的根因。扫描范围只有底栏子树，开销可忽略。
        // 0.7.4(A6)：「上拉发现」是 200ms~1s 级的异步引导态，5Hz 采样过剩，降到 2.5Hz。
        if (CachedTabBar && TickCount % 2 == 0) SweepTabBarHints(CachedTabBar);
#if GCC_DEVICE_TEST
        RunDeviceCheck();
#endif
    });
}

// 0.7.4(A3)：按前台/后台动态整备 tick 节拍。
// 高德带导航后台模式，切后台后主线程仍在跑 —— 原来的 200ms 定时器会 5 次/秒
// 空转唤醒（每拍都在 applicationState != Active 分支直接 return）。UI 清理在后台
// 毫无意义，所以后台拉长到 2s（仅作保险），回前台由 DidBecomeActive 立即恢复 200ms。
static void GCCArmTick(void) {
    if (!ScheduleTimer) {
        ScheduleTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
        dispatch_source_set_event_handler(ScheduleTimer, ^{ Schedule(); });
        dispatch_resume(ScheduleTimer);
    }
    BOOL active = (UIApplication.sharedApplication.applicationState == UIApplicationStateActive);
    // 0.7.5(B3)：起拍改回 +200ms（0.7.4 用的是 NOW+0，等于 didBecomeActive 时立即起拍，
    // 会把第一拍推进 App 的 UI 构建期 —— 正是踩中「主窗口未定就拉黑」地雷的推手）。
    // A3 的后台省电收益不受影响：间隔仍是 200ms / 2000ms。
    dispatch_source_set_timer(ScheduleTimer, dispatch_time(DISPATCH_TIME_NOW, 200 * NSEC_PER_MSEC),
                              (active ? 200 : 2000) * NSEC_PER_MSEC, 20 * NSEC_PER_MSEC);
}

static void Capture(id element) {
    if (![NSThread isMainThread]) return;
    id render = ObjectGetter(element, @"rootRender") ?: ObjectGetter(element, @"render");
    UIView *page = ObjectGetter(render, @"ajx3View");
    if (![page isKindOfClass:UIView.class] || !Kind(page)) return;
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
    // 0.7.3：Capture 在元素重渲染时也会频繁触发（滚动时每帧多次），
    // 与 layoutSubviews 同理，不能再当事件源。兜底 5 拍（1s）已覆盖。
    Schedule();
}

// 0.9.4：统一窗口枚举入口（审计统一处理弃用警告；iOS 15+ 下 UIApplication.windows
// 仍返回全部连接 scene 的窗口，对本插件「扫描广告窗口/清理」的用途语义更稳，
// 故保留 .windows（场景 API 覆盖不到非前景 scene 的窗口），在此集中 suppress）。
static NSArray<UIWindow *> *GCAllWindows(void) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    return UIApplication.sharedApplication.windows;
#pragma clang diagnostic pop
}

// Install on a class's own method table, preserving inherited implementations.
static void Replace(Class cls, SEL sel, IMP replacement, const char *types) {
    if (!class_addMethod(cls, sel, replacement, types))
        method_setImplementation(class_getInstanceMethod(cls, sel), replacement);
}

static void HookVoid(NSString *name, NSString *methodName, void (^after)(id)) {
    Class cls = NSClassFromString(name);
    if (!cls) return;
    SEL sel = NSSelectorFromString(methodName);
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) return;
    NSMethodSignature *s = [NSMethodSignature signatureWithObjCTypes:method_getTypeEncoding(m)];
    if (s.numberOfArguments != 2 || s.methodReturnType[0] != 'v') {
        // 0.9.8（A4）：原来这里静默 return —— initWithFrame:model:（4 参 + 返回 @）
        // 就是这样被无声跳过的，导致「item 建好后关掉重复点击」从未执行。
        // 这里不再假装成功：留下证据，调用点必须改用 ABI 安全的等价通道。
        if (getenv("GAODECLEAN_DEBUG_HOOKS")) {
            NSLog(@"[GaodeClean] hook SKIPPED (sig %lu/%c): %@ -%@",
                  (unsigned long)s.numberOfArguments, s.methodReturnType[0], name, methodName);
        }
        return;
    }
    IMP original = method_getImplementation(m);
    IMP imp = imp_implementationWithBlock(^(id self) {
        ((void (*)(id, SEL))original)(self, sel);
        after(self);
    });
    Replace(cls, sel, imp, method_getTypeEncoding(m));
}

// 0.9.4：删除 IsBlurOverlayView / GCCColorStr / GCCScreenMapMean
// （审计确认零引用的诊断期遗留，编译器 -Wunused-function 实证）。
// 0.5.34 白雾判定现由 GCCIsWhiteVeil（半透明白特征）直接承担。

static BOOL GCCIsWhiteVeil(UIView *v, CGFloat *outA) {
    UIColor *bg = v.backgroundColor;
    if (!bg) return NO;
    if (@available(iOS 13.0, *)) bg = [bg resolvedColorWithTraitCollection:v.traitCollection];
    CGColorRef cg = bg.CGColor;
    if (!cg) return NO;
    size_t n = CGColorGetNumberOfComponents(cg);
    const CGFloat *c = CGColorGetComponents(cg);
    CGFloat r = 0, g = 0, b = 0, a = 0;
    if (n == 2) { r = g = b = c[0]; a = c[1]; }
    else if (n == 4) { r = c[0]; g = c[1]; b = c[2]; a = c[3]; }
    else return NO;
    if (outA) *outA = a;
    return r > 0.72 && g > 0.72 && b > 0.72 && a > 0.30 && a < 0.995;
}


// 每 300ms 扫一次：找出「覆盖 ≥70% 窗口的半透明白色视图」并压掉。


// 0.5.46：上拉闪白的真凶是 AMapUIWaterFallContentSlidableView 的
// headerPanGestureRecognizer / mockPanGestureRecognizer —— 手势不在类本体上，
// 所以拦 addGestureRecognizer: 拦不住。这里精准摘除这两个手势（不动搜索栏）。
static void StripSlidablePan(void) {
    Class sv = NSClassFromString(@"AMapUIWaterFallContentSlidableView");
    if (!sv) return;
    for (UIWindow *w in GCAllWindows()) {
        if (w.hidden) continue;
        NSMutableArray *q = [NSMutableArray arrayWithObject:w];
        for (NSUInteger i = 0; i < q.count && q.count < 1200; i++) {
            UIView *v = q[i];
            for (UIView *sub in v.subviews) [q addObject:sub];
            if (![v isKindOfClass:sv]) continue;
            for (NSString *prop in @[@"headerPanGestureRecognizer", @"mockPanGestureRecognizer"]) {
                id g = ObjectGetter(v, prop);
                if (![g isKindOfClass:UIGestureRecognizer.class]) continue;
                UIView *gv = ((UIGestureRecognizer *)g).view;
                if (gv) [gv removeGestureRecognizer:g];
                // 0.9.8（A3-1）：裸 setValue:forKey: 在新版删除/改名该属性时会抛
                // NSUnknownKeyException（uncaught → 直接崩）。这里吞掉异常，
                // 摘手势这个核心动作已经完成，KVC 置空只是清理残留引用。
                @try { [v setValue:nil forKey:prop]; }
                @catch (__unused NSException *e) {}
            }
            for (UIGestureRecognizer *g in [v.gestureRecognizers copy])
                if ([g isKindOfClass:UIPanGestureRecognizer.class]) [v removeGestureRecognizer:g];
        }
    }
}
static void SweepFogOverlay(void) {
    for (UIWindow *w in GCAllWindows()) {
        if (w.hidden || w.alpha < 0.02) continue;
        CGRect wb = w.bounds;
        NSMutableArray *q = [NSMutableArray arrayWithObject:w];
        for (NSUInteger i = 0; i < q.count && q.count < 600; i++) {
            UIView *v = q[i];
            for (UIView *sub in v.subviews) [q addObject:sub];
            if (v == w || v.hidden || v.alpha < 0.02) continue;
            CGRect f = [v convertRect:v.bounds toView:w];
            if (f.size.width < wb.size.width * 0.50 || f.size.height < wb.size.height * 0.50) continue;
            CGFloat a = 0;
            if (!GCCIsWhiteVeil(v, &a)) continue;
            static NSInteger GCCTealsSweepLogs = 0;
            if (GCCTealsSweepLogs < 10) {
                GCCTealsSweepLogs++;
                GCLog(@"[GaodeClean] fog sweep hides %@ a=%.2f", NSStringFromClass(v.class), a);
            }
            v.hidden = YES;
        }
    }
}


// 0.7.2：从 400ms 定时器抽出来，由主 tick 每 2 拍调一次。节点上限 400
// （WINTabBar / WINMultiStyleRootView 都在浅层，够用）。
static void StripTabBarGestures(void) {
    for (UIWindow *w in GCAllWindows()) {
        if (w.hidden) continue;
        NSMutableArray *q = [NSMutableArray arrayWithObject:w];
        for (NSUInteger i = 0; i < q.count && q.count < 400; i++) {
            UIView *v = q[i];
            for (UIView *sub in v.subviews) [q addObject:sub];
            NSString *cn = NSStringFromClass(v.class);
            if (![cn isEqualToString:@"WINTabBar"] &&
                ![cn isEqualToString:@"WINMultiStyleRootView"]) continue;
            for (UIGestureRecognizer *g in [v.gestureRecognizers copy])
                if ([g isKindOfClass:UIPanGestureRecognizer.class] ||
                    [g isKindOfClass:UISwipeGestureRecognizer.class])
                    [v removeGestureRecognizer:g];
        }
    }
}

static void SealBlurOverlay(void) {
    Class mask = NSClassFromString(@"WINMapMaskView");
    if (mask) {
        SEL sh = @selector(setHidden:);
        Method m = class_getInstanceMethod(mask, sh);
        if (m) {
            IMP o = method_getImplementation(m);
            const char *t = method_getTypeEncoding(m);
            Replace(mask, sh, imp_implementationWithBlock(^(UIView *self, __unused BOOL hidden) {
                ((void (*)(id, SEL, BOOL))o)(self, sh, YES);
            }), t);
        }
        SEL sa = @selector(setAlpha:);
        Method m2 = class_getInstanceMethod(mask, sa);
        if (m2) {
            IMP o2 = method_getImplementation(m2);
            const char *t2 = method_getTypeEncoding(m2);
            Replace(mask, sa, imp_implementationWithBlock(^(UIView *self, __unused CGFloat a) {
                ((void (*)(id, SEL, CGFloat))o2)(self, sa, 0);
            }), t2);
        }
        HookVoid(@"WINMapMaskView", @"layoutSubviews", ^(UIView *v) { v.hidden = YES; v.alpha = 0; });
    }
    // AUGlobalBlurService 往窗口加的全屏模糊视图同样封死。
    // 0.9.8（A3-2/3）：valueForKey:/clearBlurViews 都是**裸调用**。
    //   · `maskViews` 属性被删/改名 → NSUnknownKeyException（uncaught 崩溃）；
    //     返回非数组（NSNull/NSSet）→ makeObjectsPerformSelector: 崩。
    //   · `clearBlurViews` 不存在 → unrecognized selector 崩。
    //   两条都在 App 启动路径上（startService 由高德自己调），必须防御。
    HookVoid(@"AUGlobalBlurService", @"addBlurViewToScreen", ^(id s) {
        id mv = nil;
        @try { mv = [s valueForKey:@"maskViews"]; }
        @catch (__unused NSException *e) { mv = nil; }
        if ([mv isKindOfClass:NSArray.class]) {
            for (id v in (NSArray *)mv)
                if ([v isKindOfClass:UIView.class]) [v removeFromSuperview];
        } else if ([mv isKindOfClass:NSSet.class]) {
            for (id v in [(NSSet *)mv allObjects])
                if ([v isKindOfClass:UIView.class]) [v removeFromSuperview];
        }
    });
    HookVoid(@"AUGlobalBlurService", @"startService", ^(id s) {
        SEL clr = NSSelectorFromString(@"clearBlurViews");
        if (![s respondsToSelector:clr]) return;
        NSMethodSignature *sig = [s methodSignatureForSelector:clr];
        if (sig.numberOfArguments != 2) return;
        ((void (*)(id, SEL))objc_msgSend)(s, clr);
    });
    // 根因入口：底栏上滑 → WINViewControl showMapMaskView → 亮起全屏白色蒙版。
    // 二进制实测签名：showMapMaskView B16@0:8（返回 BOOL！）、resetMapMaskView v16@0:8、
    // setShowMapMaskView: v20@0:8B16。showMapMaskView 必须返回 NO 才算拒绝，
    // 早先按 "void" 判断会直接跳过它 —— 拦截落空的坑。
    {
        Class vc = NSClassFromString(@"WINViewControl");
        SEL sl = NSSelectorFromString(@"showMapMaskView");
        Method mm = class_getInstanceMethod(vc, sl);
        if (mm) Replace(vc, sl, imp_implementationWithBlock(^(__unused id self) { return NO; }),
                        method_getTypeEncoding(mm));
        SEL rl = NSSelectorFromString(@"resetMapMaskView");
        Method rm = class_getInstanceMethod(vc, rl);
        if (rm) Replace(vc, rl, imp_implementationWithBlock(^(__unused id self) {}),
                        method_getTypeEncoding(rm));
        SEL sl2 = NSSelectorFromString(@"setShowMapMaskView:");
        Method mm2 = class_getInstanceMethod(vc, sl2);
        if (mm2) Replace(vc, sl2, imp_implementationWithBlock(^(__unused id self, __unused BOOL on) {}),
                         method_getTypeEncoding(mm2));
    }
    // 诊断 v2：把「谁盖在地图上」查清楚。
    // 上一版只按类名关键词过滤，漏掉了普通 UIView。这一版直接列
    //  (A) 地图上几个探测点上的完整图层栈（自下而上）
    //  (B) MapWidgetContainerView 的整棵子树
    //  (C) 所有面积 ≥ 50% 窗口且可见的视图
    // 全部迭代 BFS，不递归。
    // 0.6.0（正式版）：摘除全部诊断埋点。
    // 这个定时器原本同时挂着两件事 —— 功能性动作 + 诊断日志，现在只留功能：
    //   SweepFogOverlay()  清掉「覆盖 >=50% 窗口的半透明白层」（0.5.37 起）
    //   StripSlidablePan() 维护上拉手势的摘除结果（0.5.46 起）
    // 诊断部分（每 1.5s 全窗口树 BFS + 写 Documents/GaodeClean-blur.txt）整段删除：
    // 正式包不再产生任何日志文件，也没有每分钟 40 次的全树遍历。
    // 0.7.2：这里的 300ms 定时器已并入主 tick（Schedule，200ms）——
    //   SweepFogOverlay 每拍跑一次，节点上限 6000 → 600（白雾是顶层覆盖物，浅层就能找到）
    //   StripSlidablePan 每 2 拍跑一次，节点上限 6000 → 1200
    // 唤醒次数 10.8/s → 5/s，且不再有独立的 300ms 唤醒源。
    // 顺带删掉 SweepLog —— 它只增不减，而写文件的代码 0.6.0 就删了，纯泄漏。
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

static void HookHitTest(Class cls) {
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

static BOOL IsHiddenMapPromo(UIView *view) {
    // 左上「来扫街」= template_oparate_icon（0.4.3 实测 tag，注意拼写 oparate）；
    // 右上「扫街榜」= template_rank（0.4.7 加回）。两者都隐藏。
    id tag = ObjectGetter(view, @"getItemTag");
    if ([tag isEqual:@"template_oparate_icon"] || [tag isEqual:@"template_rank"]) return YES;
    NSMutableString *identity = [NSMutableString string];
    static NSArray<NSString *> *getters;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ getters = @[@"iconImageName", @"accessibilityLabel"]; });
    for (NSString *getter in getters) {
        id value = ObjectGetter(view, getter);
        if ([value isKindOfClass:NSString.class]) [identity appendFormat:@" %@", value];
    }
    NSString *lower = identity.lowercaseString;
    return [identity containsString:@"扫街榜"] || [lower containsString:@"saojie"] || [lower containsString:@"streetrank"];
}


// 输入框实时文本（含 AJX 输入组件），用于识别「用户打字的回显 label」——
// 回显与推广预填（湘满天）渲染在同一位置（y≈74），必须按文本内容区分。


// 输入框里有内容（用户正在输入/已输入未清）时，顶部两条位置带里全是用户内容：
// 回显 label（文字只存在 accessibilityLabel 里，getter 读不到，无法按文本区分）
// 与历史/建议区。此时两条带整体休眠；输入框为空时才隐藏推广与分类行。



// 0.4.32 核心防线：输入相关的一切（文本框本体、祖先容器、键盘、第一响应者）
// 一律不隐藏、不清空、不移动。这就是 0.4.29-0.4.31 输入文字不显示的根因——
// CleanSearchPromo 的按位置隐藏把搜索框内部的文本视图一并摘掉。
static BOOL IsInputLike(UIView *v) {
    if (!v) return NO;
    if ([v isKindOfClass:UIControl.class]) return YES;
    if (v.isFirstResponder) return YES;
    for (UIView *p = v; p && p != v.window; p = p.superview) {
        NSString *cn = NSStringFromClass(p.class);
        if ([cn containsString:@"TextField"] || [cn containsString:@"TextInput"] ||
            [cn containsString:@"Input"] || [cn containsString:@"TextView"] ||
            [cn containsString:@"Keyboard"]) return YES;
    }
    return NO;
}


// 0.4.32：收起分类入口行。只对「包含 36x36 分类图标的整宽行容器」生效，
// 且整场上移只做一次（associated object 标记）——0.4.31 的每轮 y-=行高
// 没有一次性守卫，0.2s 轮询把整个历史列表推出屏幕，这就是历史消失的根因。


// 搜索页清理（0.4.24-0.4.31 终态 + 0.4.33 收敛）：
// - 只摘文字/图标/图片（AJXLabel、AJXImageView、UIImageView）与滚动推广容器；
// - 判定一律用窗口坐标，且跳过滚动列表/按钮内的内容（0.4.32 教训：局部
//   frame 会把历史列表、按钮文字、隐私模式等全页文字错杀）；
// - 不再盲隐藏任意 AJXContainerView（0.4.29 误伤输入区）；
// - 行容器收起 + 内容上移各带一次性守卫（0.4.31 无守卫 = 历史列表飞出屏幕）；
// - 任何输入相关视图先被 IsInputLike 拦下。

// ===========================================================================
// 0.9.3：「天气行+LOGO 错误位置闪现」修复
// 60fps 逐帧实测：t≈2.12-2.47s 天气行停在原生位置（屏幕中部 y≈411pt），
// 搜索栏就位后才瞬跳回搜索栏上方（约 350ms 的可见错误位置）。
// 根因：对齐锚点（车机圆钮）比天气行晚就绪；锚点未就绪时没有任何扣留机制，
// 天气行就直接以 app 的原生位置露出来了。
// 策略（与车机圆钮 0.4.41「冷启动先隐藏、对齐后再显示」同一套路）：
//   ① 冷启动「扣留窗」内（ColdTicks<30 且锚点未就绪）——凡是要显示的天气行
//      一律按住（hidden=YES）并登记；
//   ② 对齐成功 / 6 秒兜底 —— 统一恢复显示（此时已在搜索栏上方的正确位置）。
// ===========================================================================
static BOOL GCWeatherAnchorReady(void) {
    // 0.9.5：锚点就绪 = 车机钮「已对齐」（打过 AlignedKey），而不只是「在窗上」——
    // 过早放行会让天气行落在旧目标位、随后再跳一下。
    return CachedCar && CachedCar.window
        && objc_getAssociatedObject(CachedCar, &AlignedKey) != nil;
}
static BOOL GCWeatherDoneOnce;   // 0.9.7：本轮冷启动已释放过扣留 → 不再重新开窗
static BOOL GCWeatherInHoldPhase(void) {
    // 0.9.7：加 !GCWeatherDoneOnce —— 首次释放（锚点就绪或 6s 兜底）后本轮封网。
    // 背景：真机实测 app 会刷新车机钮实例（AlignedKey 随实例丢失），扣留窗会
    // 在启动中段重新打开，把「200米」比例尺误关 3.2 秒（0.9.6 案例）。
    return ColdTicks < 30 && !GCWeatherAnchorReady() && !GCWeatherDoneOnce;
}
static BOOL GCWeatherHoldRow(UIView *v) {
    if (!v) return NO;
    // 0.9.7：位置门槛 —— 只扣留「落在中屏原生错误位」的元素（冷启动闪现指纹）。
    // 没有这道门，扩网钩子（setHidden:/setAlpha:/setFrame:）会误伤正常刷新的
    // 行内元素（0.9.6 真机案例：200米比例尺被误关 3.2s）。
    // 0.9.8（A1）：门槛 0.55 → 0.70。原生错误位是**绝对 411pt**（见 LayoutMinimalHome
    //   内 {{10,411}} 的实测注释），不是窗高比例。667pt 机型 0.55h = 367pt < 411pt
    //   → 门槛在错误位置上方就已经放行，扣留网整个放空 —— SE2/8/8P 上 0.9.3~0.9.5
    //   修掉的「LOGO 中屏闪现」会回归。0.70 × 667 = 467pt > 411pt，667~932pt 全机型覆盖。
    if (v.window) {
        CGRect r = [v convertRect:v.bounds toView:v.window];
        if (r.origin.y > v.window.bounds.size.height * 0.70) return NO;   // 位置正确，不扣
    }
    if (!GCWeatherHeldRows) GCWeatherHeldRows = [NSHashTable weakObjectsHashTable];
    if (![GCWeatherHeldRows containsObject:v]) {
        [GCWeatherHeldRows addObject:v];
        static NSInteger GCWeatherHoldLogs = 0;
        if (GCWeatherHoldLogs < 5) {
            GCWeatherHoldLogs++;
            GCLog(@"[GaodeClean] weather row held (cold start, anchor not ready): %@",
                  NSStringFromClass(v.class));
        }
    }
    v.hidden = YES;
    return YES;
}
static void AlignWeatherRow(UIView *row);      // 0.9.5：前置声明（释放路径要用）
static BOOL IsWeatherRowView(UIView *v);       // 0.9.5：前置声明
static void GCWeatherReleaseHeld(void) {
    if (!GCWeatherHeldRows || GCWeatherHeldRows.count == 0) {
        // 0.9.8（A13）：本轮一行都没扣留时（机型没有该行 / 位置本来就对），
        // 下面那句 GCWeatherDoneOnce = YES 永远走不到 —— 于是整个 ColdTicks<30
        // 期间 GCWeatherInHoldPhase() 恒为真，AlignWeatherRowTick 每拍全功率
        // 全窗 BFS（≤2000 节点），纯空转 6 秒。没有待释放对象时同样要封网。
        if (!GCWeatherInHoldPhase()) GCWeatherDoneOnce = YES;
        return;
    }
    if (GCWeatherInHoldPhase()) return;   // 仍在扣留窗 → 继续按住
    NSArray *all = GCWeatherHeldRows.allObjects;
    [GCWeatherHeldRows removeAllObjects]; // 0.9.5：先清表，杜绝「释放→对齐→再释放」递归
    for (UIView *v in all) if (v) {
        v.hidden = NO;
        // 0.9.6：恢复后**不再逐元素搬运** —— 0.9.5 曾在这里顺手 AlignWeatherRow(v)，
        // 导致 LOGO 半件与天气件各自被搬到「车机钮右侧」同一目标位、互相叠压（真机回归）。
        // 搬运权收归单一链路：tick 选行 / WINGroupMapWidget 布局钩子（0.9.4 验收行为）。
    }
    GCWeatherDoneOnce = YES;   // 0.9.7：本轮冷启动扣留使命完成，此后不再重开窗
    GCLog(@"[GaodeClean] weather row released (%lu)", (unsigned long)all.count);
}

static void AlignWeatherRow(UIView *row) {
    // 0.5.33：把「天气+LOGO」行对齐到车机钮右边。用坐标转换 + center 写入
    // （transform 安全、幂等，不累积误差）。
    static BOOL inAlign = NO;
    if (inAlign) return;
    if (!row || !row.window || !row.superview) return;
    UIView *car = CachedCar;
    if (!car || !car.window) return;
    inAlign = YES;
    UIWindow *win = row.window;
    CGRect carRect = [car convertRect:car.bounds toView:win];
    // 0.9.18（A2）：对表原生 —— 车机钮在上、天气行在**正下方**且左对齐。
    //   0.5.33 起这里写的是「搬到车机钮右侧」，那是当年的假设，从没对过表；
    //   原生实测（原生录屏 vs 我们逐元素比对）：车机钮 616..652、天气行 670..690、
    //   两者 x 均为 10 ⇒ 关系是「上下 + 左对齐」，间隙 18pt。
    CGPoint wantWin = CGPointMake(carRect.origin.x,
                                  CGRectGetMaxY(carRect) + 18);
    CGPoint wantInParent = [row.superview convertPoint:wantWin fromView:win];
    CGPoint wantCenter = CGPointMake(wantInParent.x + row.bounds.size.width * 0.5,
                                     wantInParent.y + row.bounds.size.height * 0.5);
    if (fabs(row.center.x - wantCenter.x) > 0.5 || fabs(row.center.y - wantCenter.y) > 0.5) {
        // 0.6.2：切 2D/3D 时 app 会把这一行往下推 ~17pt，我的对齐随后才追上 ——
        // 中间那 3–4 帧就是用户看到的「天气和 LOGO 跳一下」
        // （逐帧实测：云图标 y 379.2 → 388.7/389.0/388.6/389.1 → 383 → 380 → 379）。
        // 两处修正：① 禁掉隐式动画，否则修正本身会走动画 = 掉下去再弹回来；
        //           ② 偏差 >2pt 时清掉 layer 上正在跑的动画，让修正瞬时落到当前帧。
        BOOL big = (fabs(row.center.y - wantCenter.y) > 2.0 || fabs(row.center.x - wantCenter.x) > 2.0);
        [CATransaction begin];
        [CATransaction setDisableActions:YES];
        if (big) [row.layer removeAllAnimations];
        row.center = wantCenter;
        [CATransaction commit];
    }
    GCWeatherReleaseHeld();   // 0.9.3：对齐完成 → 恢复扣留的天气行（出现在正确位置）
    inAlign = NO;
}

// 0.6.2：天气行的尺寸自识别（认「行」不认实例）。
// 实测这一行是宽 200-320、高 <40 的容器；离屏实例（历史上见过 y=1073）直接排除。
// 0.6.6：冷启动诊断（GaodeClean-cold.txt）给出决定性事实 ——
//   tick 在跑、CachedCar=WINDeviceInterconnectWidget 正常，
//   但 **WINGroupMapWidget 整个不在视图树里**；承载这一行的是
//   WINScaleLineLogoMapWidget {{10,411},{188,20}}（原生位置）。
// 也就是说：正常态用容器 WINGroupMapWidget，冷启动态只有子件 WINScaleLineLogoMapWidget。
// 原来的查找只认前者 → 冷启动永远找不到 → 不归位；切页后容器才被建出来 → 才归位。
static BOOL IsWeatherRowClass(NSString *cn) {
    if (!cn.length) return NO;
    // 0.9.8（A12）：冷启动 hold 期每拍一次 ≤2000 节点全窗 BFS（见 AlignWeatherRowTick），
    // 每个节点都要过这里 8 次字符串比较 —— 30 拍 × 2000 × 8 ≈ 48 万次，全在启动关键 6 秒。
    // 类名集合有限且稳定，按 AjxCache 同样的思路缓存判定结果。
    static NSMutableDictionary<NSString *, NSNumber *> *cache;
    if (!cache) cache = [NSMutableDictionary dictionary];
    NSNumber *cached = cache[cn];
    if (cached) return cached.boolValue;
    BOOL hit = NO;
    if ([cn isEqualToString:@"WINGroupMapWidget"]
        || [cn isEqualToString:@"WINScaleLineLogoMapWidget"]
        || [cn isEqualToString:@"WINWeatherLimitView"]
        || [cn isEqualToString:@"WINLiteWidgetLogoScaleLineView"]   // 0.9.5：17.01.1 冷启动 Lite 版 LOGO 视图
        || [cn isEqualToString:@"LTMBigPearMapLogoView"]            // 0.9.5：引擎内 LOGO 视图
        || [cn isEqualToString:@"LTMBigPearScaleLine"])             // 0.9.5：引擎内比例尺
        hit = YES;
    else
        hit = [cn containsString:@"LogoScaleLine"] || [cn containsString:@"ScaleLineLogo"];
    cache[cn] = @(hit);
    return hit;
}

static BOOL IsWeatherRowView(UIView *v) {
    if (!v || !v.window || !v.superview) return NO;
    CGRect r = [v convertRect:v.bounds toView:v.window];
    if (r.size.width < 150 || r.size.width > 360 || r.size.height >= 40) return NO;
    if (r.origin.y < 60 || r.origin.y > v.window.bounds.size.height - 40) return NO;
    return YES;
}

static void HookWeatherRow(void) {
    // 0.5.39：改为「布局完成后再对齐」，不再拦截 setFrame:/setCenter:。
    // 0.5.33 的 setFrame:/setCenter: 拦截会在 app 每一次写入时重排布局，
    // 上拉发现时 app 的地图快照背板被截成空白 → 整张地图被白雾蒙住
    // （实测：0.5.30/0.5.32 无白雾，只有 0.5.33 有，唯一差异就是这个拦截器）。
    Class cls = NSClassFromString(@"WINGroupMapWidget");
    if (!cls) return;
    // 0.6.5：**关键** —— WINGroupMapWidget 自己有一个 `-layout` 方法（不是 layoutSubviews），
    // app 走的是它。原来的钩子挂 layoutSubviews，冷启动时根本不触发；
    // 只有切页等个别路径才会连带跑到一次 → 表现为「冷启动后不归位，切一次页才对」。
    // 两个方法都挂。
    HookVoid(@"WINGroupMapWidget", @"layout", ^(id v) {
        UIView *win = nil;
        if ([v isKindOfClass:UIView.class]) {
            win = ((UIView *)v).window;
            if (!win || !CachedCar || !CachedCar.window) return;
            if (!IsWeatherRowView(v)) return;
            objc_setAssociatedObject(v, &AlignedKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            AlignWeatherRow(v);
        }
    });
    HookVoid(@"WINGroupMapWidget", @"layoutSubviews", ^(UIView *v) {
        // 0.6.1：原来这里写的是 if (!AlignedKey) return —— 依赖「缓存实例 + 一次性标记」。
        // 但切换 2D/3D 时 app 会重建地图控件树，**新实例没有 AlignedKey**，
        // 钩子直接 return，天气行就退回 app 的原生位置 ——
        // 逐帧实测：切到 3D 后 ☁ 云 −13pt、30°C −11pt、🔷高德地图 −13pt（比例尺不动），
        // 就是「切 2D/3D 时天气和 LOGO 位置跳一下」。
        // 现在改为按尺寸自识别，任何实例都能立即对齐，不再依赖缓存命中。
        UIView *win = v.window;
        if (!win || !CachedCar || !CachedCar.window) return;
        if (CachedTabs) {
            id sel = ObjectGetter(CachedTabs, @"selectedViewControl");
            if (sel && ![NSStringFromClass([sel class]) isEqualToString:@"WINAmapHomeControl"]) return;
        }
        if (!IsWeatherRowClass(NSStringFromClass(v.class))) return;
        if (!IsWeatherRowView(v)) return;
        objc_setAssociatedObject(v, &AlignedKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        AlignWeatherRow(v);
    });
    // 0.6.2：有些时刻 app 是直接写位置（不走 layoutSubviews），
    // 那样我只能等下一次布局才追上（实测落后 3-4 帧）。这里在 app 一写就同步纠回，
    // 同一个 runloop 内完成，那一帧就不会显示在错误位置。
    {
        Class rc = NSClassFromString(@"WINGroupMapWidget");
        Method mc = class_getInstanceMethod(rc, @selector(setCenter:));
        Method mf = class_getInstanceMethod(rc, @selector(setFrame:));
        if (mc) {
            IMP o = method_getImplementation(mc);
            const char *t = method_getTypeEncoding(mc);
            Replace(rc, @selector(setCenter:), imp_implementationWithBlock(^(UIView *self, CGPoint c) {
                ((void (*)(id, SEL, CGPoint))o)(self, @selector(setCenter:), c);
                if (IsWeatherRowView(self)) AlignWeatherRow(self);
            }), t);
        }
        if (mf) {
            IMP o = method_getImplementation(mf);
            const char *t = method_getTypeEncoding(mf);
            Replace(rc, @selector(setFrame:), imp_implementationWithBlock(^(UIView *self, CGRect f) {
                ((void (*)(id, SEL, CGRect))o)(self, @selector(setFrame:), f);
                if (IsWeatherRowView(self)) AlignWeatherRow(self);
            }), t);
        }
    }
    // 0.9.3：冷启动扣留 —— 锚点未就绪期间，天气行三类的「显示」请求全部按住：
    //   didMoveToWindow 抓「刚上窗」；setHidden: 拒绝「想要显示」。
    // 释放统一走 A3（对齐成功）与 A4a（6 秒兜底）。
    // 0.9.5：六类 × 四路径全挂（上窗 / 显示 / 位置写入×2 / 透明度），
    // 且扣留判断**不再要求行级尺寸** —— 2.4s 闪现的 LOGO 半件仅 ~65pt 宽，
    // 尺寸门槛会让它从扣留网里漏掉（逐帧实测 130ms 窗口）。
    for (NSString *cn in @[@"WINGroupMapWidget", @"WINScaleLineLogoMapWidget", @"WINWeatherLimitView",
                           @"WINLiteWidgetLogoScaleLineView", @"LTMBigPearMapLogoView", @"LTMBigPearScaleLine"]) {
        Class c = NSClassFromString(cn);
        if (!c) continue;
        // ① 上窗
        HookVoid(cn, @"didMoveToWindow", ^(UIView *v) {
            if (!v.window) return;
            // 0.9.6：出窗后只做「扣留」（在扣留窗内）；**不再** AlignWeatherRow(v) ——
            // 0.9.5 的新增搬运会让每个家族元素各自叠到同一目标位（真机回归）。
            if (GCWeatherInHoldPhase()) GCWeatherHoldRow(v);
        });
        // ② setHidden:（扣留窗内拒绝显示；出窗后行级元素先对齐再显示）
        {
            SEL sh = @selector(setHidden:);
            Method m = class_getInstanceMethod(c, sh);
            if (m) {
                IMP o = method_getImplementation(m);
                const char *t = method_getTypeEncoding(m);
                Replace(c, sh, imp_implementationWithBlock(^(UIView *self, BOOL h) {
                    if (!h && GCWeatherInHoldPhase()) {
                        // 0.9.7：HoldRow 返回是否真正扣留 —— 位置门槛放行的元素
                        // **不得**拒绝显示（否则藏了却没登记，永远等不到释放）。
                        if (GCWeatherHoldRow(self)) h = YES;
                    }
                    ((void (*)(id, SEL, BOOL))o)(self, sh, h);
                }), t);
            }
        }
        // ③ 位置写入（WINGroupMapWidget 已有独立钩子块，此处只补其余五类，避免重复叠加）
        if (![cn isEqualToString:@"WINGroupMapWidget"]) {
            SEL fs = @selector(setFrame:);
            Method fm = class_getInstanceMethod(c, fs);
            if (fm) {
                IMP fo = method_getImplementation(fm);
                const char *ft = method_getTypeEncoding(fm);
                Replace(c, fs, imp_implementationWithBlock(^(UIView *self, CGRect f) {
                    ((void (*)(id, SEL, CGRect))fo)(self, fs, f);
                    // 0.9.6：位置写入路径只做「扣留」，**不搬运**（见 A1a 注释）。
                    if (self.window && GCWeatherInHoldPhase()) GCWeatherHoldRow(self);
                }), ft);
            }
            SEL cs = @selector(setCenter:);
            Method cm = class_getInstanceMethod(c, cs);
            if (cm) {
                IMP co = method_getImplementation(cm);
                const char *ct = method_getTypeEncoding(cm);
                Replace(c, cs, imp_implementationWithBlock(^(UIView *self, CGPoint center) {
                    ((void (*)(id, SEL, CGPoint))co)(self, cs, center);
                    // 0.9.6：同上，只扣留不搬运。
                    if (self.window && GCWeatherInHoldPhase()) GCWeatherHoldRow(self);
                }), ct);
            }
        }
        // ④ setAlpha:（防止 app 用透明度淡入绕过 setHidden:）
        {
            SEL al = @selector(setAlpha:);
            Method am = class_getInstanceMethod(c, al);
            if (am) {
                IMP ao = method_getImplementation(am);
                const char *at = method_getTypeEncoding(am);
                Replace(c, al, imp_implementationWithBlock(^(UIView *self, CGFloat alpha) {
                    ((void (*)(id, SEL, CGFloat))ao)(self, al, alpha);
                    if (alpha > 0.01 && self.window && GCWeatherInHoldPhase()) GCWeatherHoldRow(self);
                }), at);
            }
        }
    }
}

static void LayoutMinimalHome(id handler) {
    if (LayingOutHome) return;
    UIView *bar = ObjectGetter(handler, @"searchBar");
    UIView *sheet = ObjectGetter(handler, @"slidableView");
    id tabs = ObjectGetter(handler, @"tabBarControl");
    if (tabs) CachedTabs = tabs;
    if ([bar isKindOfClass:UIView.class]) SearchBarView = bar;
    id selected = ObjectGetter(tabs, @"selectedViewControl");
    if (![bar isKindOfClass:UIView.class] || ![sheet isKindOfClass:UIView.class] || !sheet.superview) return;
    BOOL home = [NSStringFromClass([selected class]) isEqualToString:@"WINAmapHomeControl"];
    if (!home) { if (!bar.hidden) { bar.hidden = YES; BarFixIdle = 0; } return; }
    UIView *tabBar = ObjectGetter(tabs, @"tabBar");
    UIView *parent = sheet.superview;
    // 0.6.8：首页容器还没上屏（切页转场中间态）时，**开快修窗**而不是直接退出。
    // 原来这里 `return` 等于把这一拍丢掉，只能等下一次 100ms tick —— 这正是
    // 「我的切首页」比反向慢的主因之一：反向只需要隐藏搜索栏，不经过这条早退。
    if (!parent.window || ![tabBar isKindOfClass:UIView.class]) {
        // 封顶：最多续 60 段窗口（≈9.6s）。否则一旦 parent.window 始终不为真，
        // 这个 8ms 的循环会无限自旋下去 —— 比原来多等一个 tick 糟糕得多。
        if (BarFixStalls < 60) { BarFixStalls++; KickBarFixFor(0.16); }
        return;
    }
    BarFixStalls = 0;
    BarParent = parent;
    LayingOutHome = YES;
    // 0.6.9：先算期望 frame，只有**真的不一样**才写。
    // 0.6.8 的写法是无条件 bar.frame = ... + bringSubviewToFront:，而快修窗每 8ms
    // 跑一次 —— 等于切页后几百毫秒里每 8ms 给搜索栏设一次 frame 并重排兄弟层级。
    // 逐帧实测：mine→home 之后地图区 Δ≈0.41 持续 ~880ms（静止首页只有 0.02-0.06，
    // 是噪声的 10-20 倍），home→mine 只有 0.00 —— 差异就来自这个不对称。
    // 反向（!home）只走一句 bar.hidden = YES 就 return，根本不碰这些。
    if (bar.superview != parent) [parent addSubview:bar];
    // 0.5.9：恢复隐藏「上拉发现」容器（sheet）与其遮罩。
    // 0.5.1 曾移除这三行，结果面板的白底永久露出（跨版本实测：0.5.0 无白块，
    // 0.5.7/0.5.8 每帧都在 544-682pt 出现纯白块）。搜索栏已挂到 parent
    // 并在 sheet 之外，隐藏 sheet 不会影响它（0.5.0 即如此工作）。
    if (!sheet.hidden) { sheet.hidden = YES; BarFixIdle = 0; }
    UIView *mask = ObjectGetter(handler, @"maskView");
    if ([mask isKindOfClass:UIView.class] && !mask.hidden) { mask.hidden = YES; BarFixIdle = 0; }
    CALayer *bottomMask = ObjectGetter(handler, @"bottomMaskLayer");
    if ([bottomMask isKindOfClass:CALayer.class] && !bottomMask.hidden) { bottomMask.hidden = YES; BarFixIdle = 0; }
    CGRect tabFrame = [tabBar convertRect:tabBar.bounds toView:parent];
    CGFloat height = MAX(50, MIN(64, bar.bounds.size.height));
    CGRect want = CGRectMake(0, MAX(0, tabFrame.origin.y - height - 12),
                             parent.bounds.size.width, height);
    BOOL moved = !CGRectEqualToRect(bar.frame, want);
    if (moved) { bar.frame = want; BarFixIdle = 0; }
    // 层级单独判：app 可能不动 frame 却把兄弟视图插到搜索栏之上。
    // 只在「确实被压下去」时才 bringSubviewToFront（它比设 frame 重，会让父视图重排）。
    if (bar.superview == parent && parent.subviews.lastObject != bar) {
        [parent bringSubviewToFront:bar];
        BarFixIdle = 0;
    }
    if (bar.hidden) { bar.hidden = NO; BarFixIdle = 0; }
    // 0.5.27：移除全部天气行实验代码（含导致闪退的诊断块）。
    // 结论：415pt 那行「☀温度+高德地图+比例尺」不是 WINScaleLineLogoMapWidget
    // （该类只有 logoView+scaleLineView，实测在 1073pt 屏幕外）。待确认真身。
    // ===== 0.5.30：把「天气+LOGO+比例尺」整行移到车机钮右边 =====
    // 诊断（diag4）确认结构：
    //   WINGroupMapWidget {{10,411},{259,20}}          ← 父容器（整行）
    //     ├─ WINWeatherLimitView      {{10,411},{61,20}}    ☀26°C
    //     └─ WINScaleLineLogoMapWidget{{72,1073},{188,20}}  🔷高德地图+200米
    //   WINDeviceInterconnectWidget {{10,650},{44,44}}  ← 车机钮
    // 之前只移子视图 LOGO → 温度没动，只对一半。现在移**父容器**，两个一起走。
    {
        UIWindow *win = bar.window;
        static __weak UIView *CachedRow = nil;
        static int RowRescanTick = -4;
        // 0.6.1：缓存失效条件加上「尺寸不再匹配」—— 切 2D/3D 后 app 换掉的是实例，
        // 旧实例的 window 可能还在，原本的 !CachedRow.window 判据抓不到，缓存会一直指着旧的。
        BOOL rowStale = (!CachedRow || !CachedRow.window);
        if (!rowStale && win) {
            CGRect r0 = [CachedRow convertRect:CachedRow.bounds toView:win];
            if (r0.size.width < 150 || r0.size.width > 360 || r0.size.height >= 40) rowStale = YES;
        }
        // 0.9.8（A9）：这个块跑在 LayoutMinimalHome 里，而它被 BarFixTimer 以 **8ms**
        // 周期调用 —— 一次 640ms 快修窗最多 80 次。rowStale 时每次都是 ≤2000 节点的
        // 全窗 BFS，切页/切 2D-3D 瞬间就是 16 万次视图访问，全在主线程。
        // 与 AlignWeatherRowTick 同策略：非扣留期节流到每 4 拍（800ms）最多重扫一次；
        // 扣留期保持全速（0.9.5 的闪现窗口只有 ~130ms，不能等）。
        if (rowStale && !GCWeatherInHoldPhase() && TickCount - RowRescanTick < 4) rowStale = NO;
        if (win && rowStale) {
            RowRescanTick = TickCount;
            NSMutableArray *q = [NSMutableArray arrayWithObject:win];
            for (NSUInteger qi = 0; qi < q.count && q.count < 2000; qi++) {
                UIView *v = q[qi];
                [q addObjectsFromArray:v.subviews];
                if (IsWeatherRowClass(NSStringFromClass(v.class))) {
                    CGRect r = [v convertRect:v.bounds toView:win];
                    if (r.size.width > 150 && r.size.width < 360 && r.size.height < 40) {
                        if (!CachedRow || [NSStringFromClass(v.class) isEqualToString:@"WINGroupMapWidget"]
                            || v.bounds.size.width > CachedRow.bounds.size.width) CachedRow = v;
                        if ([NSStringFromClass(v.class) isEqualToString:@"WINGroupMapWidget"]) break;
                    }
                }
            }
        }
        if (CachedRow && CachedRow.window && !CachedRow.hidden
            && CachedCar && CachedCar.window && bar.window && CachedRow.superview) {
            objc_setAssociatedObject(CachedRow, &AlignedKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            AlignWeatherRow(CachedRow);
        }
    }
    // ===== 0.9.15：锚点目标改为「定格后才锁定」，并在启动窗口内自愈重锁
    //   真机铁证（diag 日志 + 逐帧录屏，见 HISTORY §Y）：
    //   搜索栏是**跟随 tab 栏**定位的（want = tabFrame.origin.y - 高度 - 12），
    //   而冷启动时 tab 栏自己还在迁移 —— 搜索栏先停在 y≈436（原生槽位附近），
    //   最终停在 y≈701（tab 栏上方 12pt）。
    //   0.4.19 的「首帧锁定」把 436 当成了最终位置，于是：
    //     ① 控件钳位目标 = 436-8 = 428 → 右下钮被**稳稳钉在屏高 40% 的中部**
    //        （逐帧实测裸露框 y768-958 = 窗口系 340-428，与该目标完全吻合）
    //     ② 搜索栏自身的回钉钩子也一直往 436 拉，与这里的 want(701) 对打
    //   现在：连续 3 拍位置不变才认；ColdTicks<30 内若又稳定停到新位置则重锁。
    // 0.9.15（A1 硬化）：目标位置必须落在容器**底部 30%** —— 这是「搜索栏在 tab 栏上方」
    //   的几何不变量。启动期 tab 栏自身还在迁移，算出来的 want 会落在屏高 ~51%
    //   （实测 436/852），那只是过渡值；此时既不能锁锚点，更不能显示它的伴随控件。
    //   纯计时判据（稳定 N 拍）会被「过渡值恰好稳定 600ms」骗过，几何判据不会。
    BOOL targetLooksFinal = (want.origin.y > parent.bounds.size.height * 0.70);
    if (fabs(bar.frame.origin.y - BarLastY) < 0.5) BarStableTicks++;
    else { BarStableTicks = 0; BarLastY = bar.frame.origin.y; }
    BOOL anchorMoved = (SearchBarSettled && ColdTicks < 30 && BarStableTicks >= 3
                        && fabs(bar.frame.origin.y - SearchBarSettledY) > 0.5);
    if ((!SearchBarSettled || anchorMoved) && (BarStableTicks >= 3 || ColdTicks >= 20)
        && (targetLooksFinal || ColdTicks >= 20)) {
        SearchBarSettledY = bar.frame.origin.y;
        SearchBarSettled = YES;
    }
    // 0.4.45：连续稳定 3 轮(~0.6s)后才显示，避免 app 中途把搜索栏拉回原生(447)造成闪跳
    bar.hidden = (BarStableTicks < 3 && ColdTicks < 15);
    if (!bar.hidden) BarShownOnce = YES;   // 0.9.2：记下「已显示过」——冷启动后段防瞬时隐藏
    LayingOutHome = NO;
    AlignCornerWidgets(bar);
}

// 0.5.57：切页时 app 会把搜索栏从父视图摘掉，而归位只发生在 LayoutMinimalHome 里 ——
// 它由 100ms 的 tick 驱动。逐帧实测缺席时长恰好是 16.7ms 的整数倍(17/33/67/83/100ms)，
// 就是在「等下一次 tick」。这里加一段 16ms 的快修窗口：搜索栏被动到的瞬间启动，
// 640ms 内以 60Hz 反复跑 LayoutMinimalHome，把缺席从「最多 100ms」压到「最多 1 帧」。
static dispatch_source_t BarFixTimer;
static int BarFixTicks;

// 0.6.8：切页快修窗口的时长改成参数。
// 「我的 → 首页」与「首页 → 我的」本来就不对称：
//   我的 → 首页：首页那棵树要重新挂搜索栏 + 对齐圆钮 + 复位 sheet/mask，
//                 而 app 在切页期间 parent.window 还是 nil，LayoutMinimalHome 第一道
//                 早退就把它挡在门外 —— 只能干等下一次 100ms tick。多个 tick 叠加起来
//                 就是你感觉到的「慢」。
//   首页 → 我的：LayoutMinimalHome 的 !home 分支只有一条 bar.hidden = YES，一次就完事。
// 所以切成【首页】时主动开窗，而不是被动等 app 去动搜索栏。
static void KickBarFixFor(NSTimeInterval seconds) {
    int ticks = (int)ceil(seconds / 0.008);
    if (ticks < BarFixTicks) ticks = BarFixTicks;    // 已在跑的窗口只延长、不缩短
    if (ticks < 1) ticks = 1;
    BarFixTicks = ticks;
    BarFixIdle = 0;
    if (BarFixTimer) return;
    BarFixTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    dispatch_source_set_timer(BarFixTimer, dispatch_time(DISPATCH_TIME_NOW, 0),
                              8ull * NSEC_PER_MSEC, 2ull * NSEC_PER_MSEC);
    dispatch_source_set_event_handler(BarFixTimer, ^{
        if (BarFixTicks <= 0) { dispatch_source_cancel(BarFixTimer); BarFixTimer = nil; return; }
        BarFixTicks--;
        for (id h in HomeHandlers.allObjects) LayoutMinimalHome(h);
        // 0.6.9：这一拍什么都没改（BarFixIdle 被 LayoutMinimalHome 清零过），
        // 连续 6 拍（≈48ms）即收敛 → 立刻收窗，不再空转满 640ms。
        if (++BarFixIdle >= 6) {
            BarFixTicks = 0;
            dispatch_source_cancel(BarFixTimer);
            dispatch_async(dispatch_get_main_queue(), ^{ BarFixTimer = nil; });
        }
    });
    dispatch_resume(BarFixTimer);
}

static void KickBarFix(void) { KickBarFixFor(0.64); }

static BOOL IsRightBottomWidget(UIView *v) {
    if (![NSStringFromClass(v.class) isEqualToString:@"WINAJXCombinedWidgetView"]) return NO;
    id tag = ObjectGetter(v, @"getItemTag");
    if (![tag isKindOfClass:NSString.class]) return NO;
    NSString *t = [(NSString *)tag lowercaseString];
    return [t containsString:@"rightbottom"] || [t containsString:@"locate"] || [t containsString:@"location"];
}

// 0.9.16（A1）：App 原生「轻量控件组」容器的识别与排除判定。
//   中部裸露胶囊的真身（diag2 铁证）；右上「+/图层」胶囊用的是同一类，
//   但它出生就在窗口顶部（y≈69 ≈ 窗高 3.6%），故用 25% 高度线排除。
static BOOL GCCIsLiteGroupCapsule(UIView *v) {
    if (![NSStringFromClass(v.class) isEqualToString:@"WINLiteWidgetGroupView"]) return NO;
    UIView *win = v.window;
    if (!win) return NO;
    CGFloat y = [v convertPoint:CGPointZero toView:win].y;
    return y > win.bounds.size.height * 0.25;
}

static void AlignOneWidget(UIView *bar, UIView *w, CGFloat barTop, CGFloat gap) {
    if (!w.window) return;
    UIWindow *win = bar.window;
    CGRect r = [w convertRect:w.bounds toView:win];
    // 0.5.1：改底边对齐——不管 44/88 高，底边都贴在搜索框上方一段固定间隙
    // 0.9.17（A1）：间隙对表原生实测。原生录屏（697 帧）vs 我们逐元素模板匹配
    //   （score 0.906/0.934，对齐原生 1.000）：⊙ 原生 599.7 / 我们 612.1，
    //   ↰ 原生 632.5 / 我们 644.9 —— 两图标位移完全一致 ⇒ 是整组平移；
    //   而搜索栏白底顶边两边都是 702.6pt（完全同位）⇒ 差值全部来自间隙：
    //   原生 19.5pt、我们只有 6.9pt。旧值 8 让 ⊙/↰（连接车机）整组低了 12.4pt，
    //   并压掉了它与 2D/3D 按钮之间的原生间隙。
    // 0.9.18（A1）：间隙按控件区分（GCGapCar / GCGapCapsule），不再共用。
    CGFloat targetBottom = barTop - gap;
    if (fabs(CGRectGetMaxY(r) - targetBottom) >= 1) {
        CGRect f = w.frame;
        f.origin.y += (targetBottom - CGRectGetMaxY(r));
        w.frame = f;
    }
    // 逐 widget 对齐标记：对齐过才显示，避免冷启动在原生位置(如 {0,0})闪现
    objc_setAssociatedObject(w, &AlignedKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    // 0.9.9（A2/A3 配套）：setAlpha: 拦截会把未对齐时的 alpha 压到 0，
    // 这里必须一并恢复 —— 否则 hidden 放行了、按钮仍然全透明（A2/A3 的自伤点）。
    if (w.alpha < 0.01) w.alpha = 1.0;
    if (w.hidden) w.hidden = NO;
    // 0.9.16（A2，A1 的对偶）：放行右下控件的「宿主」时，把 App 原生组容器一并放行。
    //   胶囊的毛玻璃底与 ⊙/↰ 图标由它承载 —— 只按不还会缺背景。
    //   两者同一时刻出现，正是「按钮与搜索栏同时出现」的设计意图。
    if (w == CachedRight && CachedLiteGroup && CachedLiteGroup.window) {
        CachedLiteGroup.hidden = NO;
    }
    // 0.9.14（A8 回退）：恢复 0.9.7 的「对齐即封门」。
    // 有任一控件对齐成功，就说明首页布局已稳定、兜底无存在必要 ——
    // 这正是 0.9.7 零裸露的机制：车机钮 ~1.3s 对齐 → HomeSettled=YES →
    // 2.4s 的一次性兜底根本不跑，右下钮只能由本函数在**正确位置**显示。
    HomeSettled = YES;
}


// 0.6.3：冷启动后天气行停在 app 原生位置（{{10,411}}），要切一次页才归位。
// 原因：天气行的对齐寄生在 LayoutMinimalHome 里，而它有一串早退条件
// （sheet 未就绪 / parent 无 window / tabBar 不是 UIView）—— 冷启动期间就直接 return 了，
// 后面那段天气行代码永远跑不到；而这一行之后是静态的，layoutSubviews 也不再触发。
// 修法：把它移出来，并入周期 tick（与车机钮同一条路径），并在冷启动头 2 秒加 8ms 快窗。
static void AlignWeatherRowTick(UIWindow *win) {
    if (!win) return;
    // 0.9.5：每拍检查释放（内部自判扣留窗）——锚点就绪后立即恢复，
    // 不再只等 6 秒兜底把半件 LOGO 按太久。
    GCWeatherReleaseHeld();
    static __weak UIView *Row = nil;
    static int RescanTick = -4;   // -4：保证首次调用一定重扫
    BOOL stale = (!Row || !Row.window);
    if (!stale) {
        CGRect r0 = [Row convertRect:Row.bounds toView:win];
        if (r0.size.width < 150 || r0.size.width > 360 || r0.size.height >= 40) stale = YES;
    }
    // 0.7.4(A6)：缓存失效时原本**每拍**都做一次 ≤2000 节点全窗 BFS（切页后连做几拍）。
    // 节流到每 4 拍（800ms）最多重扫一次。
    // 0.9.5：扣留窗内取消防抖 —— 2.4s 闪现窗口仅 ~130ms，节流会整段错过。
    BOOL holdNow = GCWeatherInHoldPhase();
    if (holdNow) stale = YES;   // Row 已缓存时也强制全扫
    if (stale && TickCount - RescanTick < 4 && !holdNow) return;
    if (stale) {
        RescanTick = TickCount;
        NSMutableArray *q = [NSMutableArray arrayWithObject:win];
        for (NSUInteger i = 0; i < q.count && q.count < 2000; i++) {
            UIView *v = q[i];
            [q addObjectsFromArray:v.subviews];
            // 0.9.5：扣留窗内，家族元素（不论尺寸，含半件 LOGO）一见光就按住
            if (holdNow && !v.hidden && v.window && IsWeatherRowClass(NSStringFromClass(v.class))) {
                GCWeatherHoldRow(v);
            }
            // 0.9.6：**搬运候选**收窄回 3 类（0.9.4 验收行为）——
            // 新增的 Lite/引擎族类只用于「扣留」（上一段），不得参与搬运：
            // 它们若成为 Row 候选，会把半件元素整体搬到车机钮右侧（真机回归）。
            NSString *vcn = NSStringFromClass(v.class);
            if (( [vcn isEqualToString:@"WINGroupMapWidget"]
                || [vcn isEqualToString:@"WINScaleLineLogoMapWidget"]
                || [vcn isEqualToString:@"WINWeatherLimitView"])
                && IsWeatherRowView(v)) {
                // 优先外层容器（WINGroupMapWidget 存在时它就是整行）；
                // 否则取最宽的那个候选（冷启动时是 WINScaleLineLogoMapWidget，188pt）
                if (!Row || [vcn isEqualToString:@"WINGroupMapWidget"]
                    || v.bounds.size.width > Row.bounds.size.width) Row = v;
                if ([vcn isEqualToString:@"WINGroupMapWidget"]) break;
            }
        }
    }
    if (!Row || !IsWeatherRowView(Row)) return;
    if (Row.hidden && !(GCWeatherHeldRows && [GCWeatherHeldRows containsObject:Row])) return;
    AlignWeatherRow(Row);   // 0.9.3：被扣留的行也放行（对齐成功即恢复显示）
}

// ===========================================================================
// 0.9.18（A3）—— 2D/3D（地图类型）按钮摆回 ⊙/↰ 胶囊正上方
//
// 事实（原生录屏 vs 我们 0.9.17，同口径逐元素比对）：
//   原生  2D 按钮 y 543..580（底边 580），胶囊顶 595 ⇒ 间隙 15pt
//   我们  2D 按钮 y 294..320（底边 325），而**组容器**（WINLiteWidgetGroupView）
//         冷启动期停在 (339,340) ⇒ 325 与 340 的间隙同样是 15pt
// ⇒ App 把 2D/3D 按钮锚在「组容器上方 15pt」，而我们的组容器在冷启动期还停在中部，
//   于是 2D/3D 被永久锚到屏高 35%。胶囊本身已被我们摆正（599.7/632.5 与原生 Δ=0），
//   但 App 的锚点用的是组容器、不是胶囊 ⇒ 必须显式把它摆回来。
//
// 识别（双守卫，避免误伤 + / 图层 / ⊙ / ↰）：
//   ① 尺寸 26..64pt 方形   ② 位于右列（中心 x > 屏宽 0.70）
//   ③ 子树（深度 ≤3）含文字为 2D / 3D 的 UILabel
// 摆放：bottom = 胶囊顶 - 15（原生关系）
// ===========================================================================
static BOOL GCCViewTreeHasMapTypeLabel(UIView *v, NSInteger depth) {
    if (depth > 3) return NO;
    if ([v isKindOfClass:[UILabel class]]) {
        NSString *t = [(UILabel *)v text];
        if (t.length) {
            NSString *s = [t stringByTrimmingCharactersInSet:
                           [NSCharacterSet whitespaceAndNewlineCharacterSet]];
            if ([s isEqualToString:@"2D"] || [s isEqualToString:@"3D"]) return YES;
        }
    }
    for (UIView *sub in v.subviews) {
        if (GCCViewTreeHasMapTypeLabel(sub, depth + 1)) return YES;
    }
    return NO;
}

// ---- 0.9.19（A2）：2D/3D（地图类型）按钮识别重写 --------------------------------
// 0.9.18 只用「子树里有 2D/3D 文本的 UILabel」判定 ⇒ 本机高德 17.00.2 **从未命中**。
// 真机 diag 铁证（2026-10-22 0.9.18+diag3 日志）：右侧 (339,286) 那个 44x44 按钮
//   类名 = WINPermanentCompassView，子视图只有 UIVisualEffectView（毛玻璃），
//   其子树里**没有任何** 2D/3D 文本视图（文字是自绘/图片）⇒ 文本判定必然失败。
// 现改为三级识别 + 唯一候选兜底，命中档位记进 GCReportedMapTypeTier 供 diag 打印。
static __weak UIView *GCReportedMapType = nil;   // 仅诊断用（diag 构建才被读）
static NSInteger GCReportedMapTypeTier = 0;

static BOOL GCCViewIsUnder(UIView *v, UIView *anc) {   // v == anc 或其后代？
    for (UIView *p = v; p; p = p.superview) if (p == anc) return YES;
    return NO;
}

// 已被我们认领的控件（车机钮 / ⊙↰ 胶囊 / 原生组容器）及其祖先后代 —— 一律不碰
static BOOL GCCIsClaimedWidget(UIView *v) {
    UIView *cs[3] = { CachedCar, CachedRight, CachedLiteGroup };
    for (int i = 0; i < 3; i++) {
        UIView *c = cs[i];
        if (!c) continue;
        if (v == c || GCCViewIsUnder(v, c) || GCCViewIsUnder(c, v)) return YES;
    }
    return NO;
}

static UIView *GCCFindMapTypeButton(UIWindow *win, UIView *capsule) {
    GCReportedMapTypeTier = 0;
    if (!win || !capsule || !capsule.window) return nil;
    CGRect cap = [capsule convertRect:capsule.bounds toView:win];
    NSMutableArray<UIView *> *cands = [NSMutableArray array];
    NSMutableArray<UIView *> *queue = [NSMutableArray arrayWithObject:win];
    for (NSUInteger i = 0; i < queue.count && queue.count < 4000; i++) {
        UIView *v = queue[i];
        [queue addObjectsFromArray:v.subviews];
        if (v == win || v == capsule) continue;
        if (v.hidden || v.alpha < 0.5) continue;            // 只认可见的
        if (GCCIsClaimedWidget(v)) continue;                // 不碰已认领控件
        CGSize sz = v.bounds.size;
        if (sz.width < 26 || sz.width > 64 || sz.height < 26 || sz.height > 64) continue;
        CGRect r = [v convertRect:v.bounds toView:win];
        if (CGRectGetMidX(r) < win.bounds.size.width * 0.70) continue;   // 右列
        if (CGRectGetMaxY(r) > CGRectGetMidY(cap)) continue;             // 必须在胶囊上方
        [cands addObject:v];                                             // BFS 序 = 外→内
    }
    // ① 文本判定（跨版本通用）
    for (UIView *v in cands)
        if (GCCViewTreeHasMapTypeLabel(v, 0)) { GCReportedMapTypeTier = 1; return v; }
    // ② 类名判定（本机实测：WINPermanentCompassView）
    for (UIView *v in cands) {
        NSString *cn = NSStringFromClass(v.class).lowercaseString;
        if ([cn containsString:@"compass"] || [cn containsString:@"maptype"] ||
            [cn containsString:@"mapstyle"] || [cn containsString:@"mapmode"]) {
            GCReportedMapTypeTier = 2;
            return v;
        }
    }
    // ③ 兜底：BFS 序里第一个 40..48 方形（最外层容器）
    for (UIView *v in cands) {
        CGSize sz = v.bounds.size;
        if (sz.width >= 40 && sz.width <= 48 && sz.height >= 40 && sz.height <= 48) {
            GCReportedMapTypeTier = 3;
            return v;
        }
    }
    return nil;
}

static void AlignMapTypeButton(UIView *capsule) {
    static BOOL busy = NO;                       // 0.9.19（A2）：重入保护（layoutSubviews 里会被回调）
    if (busy) return;
    if (!capsule || !capsule.window) return;
    // 0.9.19（A2）：锚点没定格就绝不摆位 —— 这时胶囊本身还在瞬态位（340），
    //   拿它当锚正是 App 摆错的原因，我们不能重蹈覆辙。
    if (!SearchBarSettled) return;
    busy = YES;
    UIWindow *win = capsule.window;
    UIView *btn = GCCFindMapTypeButton(win, capsule);
    GCReportedMapType = btn;
    if (btn) {
        CGRect cap = [capsule convertRect:capsule.bounds toView:win];
        CGFloat targetBottom = CGRectGetMinY(cap) - GCGapMapType;
        CGRect br = [btn convertRect:btn.bounds toView:win];
        if (fabs(CGRectGetMaxY(br) - targetBottom) >= 1) {
            // 刻意**不打** AlignedKey：它属于「胶囊/车机钮」那一套钳位，打上去会让
            // HookWidgetSetFrame 的底边钳位（gap 50）也作用到这个按钮上，与这里打架。
            CGRect f = btn.frame;
            f.origin.y += (targetBottom - CGRectGetMaxY(br));
            btn.frame = f;
            GCLog(@"0.9.19 2D/3D 摆位 tier=%ld %@ 底 %.1f→%.1f（胶囊顶 %.1f）",
                  (long)GCReportedMapTypeTier, NSStringFromClass(btn.class),
                  CGRectGetMaxY(br), targetBottom, CGRectGetMinY(cap));
        }
    }
    busy = NO;
}

static void AlignCornerWidgets(UIView *bar) {
    if (!bar.window) return;
    UIWindow *win = bar.window;
    CGFloat barTop = [bar convertPoint:CGPointZero toView:win].y;
    if (barTop < 40) return;                                 // 搜索框尚未就位（0.4.6: 80→40）
    // 0.9.15（A2）：锚点（搜索栏）**还没有定格**时，一律不摆位、不认领、不显示。
    //   真机日志铁证：0.9.14 时本函数在右下钮出生后约 40ms 就按搜索栏**当时的瞬态
    //   位置**（superview 系 y=436，对应窗口系 447 原生槽位）把它摆到屏高 40% 并显示，
    //   同时打上 AlignedKey —— 此后 layoutSubviews / setHidden: / didMoveToWindow
    //   全部「未对齐才隐藏」的钩子因 AlignedKey 已置而**集体跳过**，控件就此稳定可见
    //   21 帧/350ms，直到搜索栏落到最终 701 才被拉到底部（那一下「瞬移」）。
    //   此期间控件保持隐藏（由 layoutSubviews / didMoveToWindow 两条钩子按住），
    //   与搜索栏同一判据（BarStableTicks>=3）解除 —— 二者同时出现、位置都是最终值。
    if (!SearchBarSettled) return;

    // 0.5.0：缓存圆钮实例，每轮直接对齐，只有实例失效时才重扫窗口树
    if (!CachedCar || !CachedCar.window) CachedCar = nil;
    if (!CachedRight || !CachedRight.window) CachedRight = nil;
    if (!CachedRoute || !CachedRoute.window) CachedRoute = nil;
    if (!CachedLiteGroup || !CachedLiteGroup.window) CachedLiteGroup = nil;
    if (!CachedCar || !CachedRight || !CachedRoute || !CachedLiteGroup) {
        NSMutableArray<UIView *> *queue = [NSMutableArray arrayWithObject:win];
        for (NSUInteger i = 0; i < queue.count && queue.count < 2000; i++) {
            UIView *v = queue[i];
            [queue addObjectsFromArray:v.subviews];
            NSString *cn = NSStringFromClass(v.class);
            if ([cn isEqualToString:@"WINDeviceInterconnectWidget"]) CachedCar = v;
            // 0.9.9：CachedRight 仍用**精确 tag** 判定 —— 1.80s 时 getItemTag 已写入，
            // 精确判定能找到；几何兜底只用于「显示拦截」这条更早的路径，避免误选实例。
            else if (IsRightBottomWidget(v)) CachedRight = v;
            else if ([cn isEqualToString:@"WINRouteLineWidgetView"]) CachedRoute = v;
            // 0.9.16（A2）：缓存 App 原生组容器 —— 胶囊的背景与图标由它承载，
            // A1 按住它之后，必须由我们在「正确时刻」放行（与 CachedRight 同步）。
            else if (GCCIsLiteGroupCapsule(v)) CachedLiteGroup = v;
            if (CachedCar && CachedRight && CachedRoute && CachedLiteGroup) break;
        }
    }
    // 0.9.18（A1）：车机钮 50pt / 胶囊 20pt —— 原生两者间隙不同，共用会让车机钮低 30pt
    if (CachedCar) AlignOneWidget(bar, CachedCar, barTop, GCGapCar);
    if (CachedRight) AlignOneWidget(bar, CachedRight, barTop, GCGapCapsule);
    if (CachedRight) AlignMapTypeButton(CachedRight);   // 0.9.18（A3）：2D/3D 摆回胶囊正上方
    // 0.5.1：线路按钮（组合按钮下半部分）原生 hid=1，强制显示，保持原位在组合按钮内部
    if (CachedRoute) {
        if (CachedRoute.hidden) CachedRoute.hidden = NO;
        // 组合按钮高度不足时撑到 88，让线路按钮完整显示（不再溢出被裁）
        if (CachedRight && CachedRight.bounds.size.height < 88 && CachedRight.bounds.size.width > 0) {
            CGRect f = CachedRight.frame;
            f.size.height = 88;
            CachedRight.frame = f;
        }
    }
    // 0.9.16（A2 安全网）：锚点已定格、但我们仍按着 App 原生组容器时超时放行 ——
    //   覆盖「CachedRight 未配对 / AlignOneWidget 没跑到」的极端情形，
    //   确保胶囊的背景与图标绝不会永久缺失（宁可早放，不可不放）。
    if (SearchBarSettled && ColdTicks > 16 && CachedLiteGroup &&
        CachedLiteGroup.window && CachedLiteGroup.hidden) {
        CachedLiteGroup.hidden = NO;
    }
}

static void HookWidgetSetFrame(NSString *className, CGFloat gap) {
    Class cls = NSClassFromString(className);
    if (!cls) return;
    SEL fs = @selector(setFrame:);
    Method fm = class_getInstanceMethod(cls, fs);
    IMP fo = fm ? method_getImplementation(fm) : NULL;
    if (fm) {
        Replace(cls, fs, imp_implementationWithBlock(^(UIView *self, CGRect rect) {
            // 0.9.14（A5 回退）：W1f 的「中部写入拒绝」已移除。它丢弃写入并把视图
            // 压回 hidden，而 AlignOneWidget 的精确 tag 判定未必找得到实例 ⇒ 按钮
            // 卡死在 hidden，最后靠 W1g 兜底在错误位置硬显示（0.9.13 实测反弹回
            // 14 帧）。0.9.7 语义：位置写入一律放行，只在已对齐后做底边钳位。
            // 0.5.1：底边对齐钳位——不管 44/88 高，底边都贴在搜索框上方 20pt
            // 0.9.17（A1）：与 AlignOneWidget 同源常量，必须同步改；否则钳位会把摆放拉回旧位
            if (SearchBarSettled && objc_getAssociatedObject(self, &AlignedKey)) {
                UIView *sv = self.superview;
                if (sv && self.window) {
                    CGPoint p = [sv convertPoint:CGPointMake(rect.origin.x, rect.origin.y) toView:self.window];
                    CGFloat targetBottom = SearchBarSettledY - gap;  // 0.9.18(A1)：按类区分（车机钮 50 / 胶囊 20）
                    CGFloat proposedBottom = p.y + rect.size.height;
                    if (fabs(proposedBottom - targetBottom) > 2) rect.origin.y += (targetBottom - proposedBottom);
                }
            }
            ((void (*)(id, SEL, CGRect))fo)(self, fs, rect);
        }), method_getTypeEncoding(fm));
    }
    // 0.4.48：补 setCenter: 拦截
    SEL cs = @selector(setCenter:);
    Method cm = class_getInstanceMethod(cls, cs);
    if (cm) {
        IMP co = method_getImplementation(cm);
        Replace(cls, cs, imp_implementationWithBlock(^(UIView *self, CGPoint center) {
            // 0.9.14（A5 回退）：与 setFrame: 同策略，W1f 的 center 中部拒绝一并移除。
            if (SearchBarSettled && objc_getAssociatedObject(self, &AlignedKey)) {
                UIView *sv = self.superview;
                if (sv && self.window) {
                    CGFloat proposedY = center.y - self.bounds.size.height / 2;
                    CGPoint p = [sv convertPoint:CGPointMake(0, proposedY) toView:self.window];
                    CGFloat targetBottom = SearchBarSettledY - gap;  // 0.9.18(A1)：按类区分（车机钮 50 / 胶囊 20）
                    CGFloat proposedBottom = p.y + self.bounds.size.height;
                    if (fabs(proposedBottom - targetBottom) > 2) center.y += (targetBottom - proposedBottom);
                }
            }
            ((void (*)(id, SEL, CGPoint))co)(self, cs, center);
        }), method_getTypeEncoding(cm));
    }
}

// ===========================================================================
// 0.6.7 —— 底栏「上拉发现」提示根除
//
// 0.5.1 只把这件事挂在 WINTabBar 的 layoutSubviews / amap_relayoutTabItems 上，
// 而「上拉发现」是**异步引导态**，常在最后一次布局**之后**才写进 label ——
// 那一拍扫空，之后布局不再触发，提示就留在屏幕上。冷启动才偶发，正是因为
// 引导态与布局的先后顺序取决于启动耗时。三条通道全漏：
//   ① 时机：没有周期性通道（本版复用已经在跑的 200ms tick 兜住）
//   ② 判据：NodeText 只认 UILabel / AJX*，其它自定义 label 只能靠 accessibilityLabel
//   ③ 处置：扫到也只是 hidden=YES；引导态复用的就是 item 标题 label，
//           隐藏它等于把「首页」两个字一起抹掉
//
// 本版原则：**只作用在底栏子树**。不装任何全局钩子（上一版 Replace(UILabel,setText:)
// 把全 app 每个 label 的写文本都套了一层 block，直接卡死主线程），
// 不新增定时器，不做几何换算。扫描范围就 WINTabBar 那 20-40 个视图。
// ===========================================================================
static char LastTitleKey;

static BOOL IsDiscoverHintText(NSString *text) {
    if (!text.length || text.length > 24) return NO;
    return [text containsString:@"上拉"];
}

// 底栏子树专用的取文本：任何类都依次试常见的取文本方法。
// ObjectGetter 先校验「返回 @ 且无参」，所以不会误调 setter。
// 每个类第一次探完就把可用的 getter 名缓存下来 —— 之后每拍只是几次 msgSend，
// methodSignatureForSelector 不再重复调用（200ms 一拍也几乎零成本）。
static NSMutableDictionary<NSString *, NSArray<NSString *> *> *TextGetterCache;

static NSString *TabBarTextOf(UIView *v) {
    NSString *cls = NSStringFromClass(v.class);
    NSArray<NSString *> *getters = TextGetterCache[cls];
    if (!getters) {
        NSMutableArray *ok = [NSMutableArray array];
        for (NSString *getter in @[@"text", @"attributedText", @"attributedString",
                                   @"title", @"tipText", @"hintText"]) {
            SEL sel = NSSelectorFromString(getter);
            if (![v respondsToSelector:sel]) continue;
            NSMethodSignature *sig = [v methodSignatureForSelector:sel];
            if (sig.numberOfArguments == 2 && sig.methodReturnType[0] == '@') [ok addObject:getter];
        }
        getters = ok.count ? ok : @[];
        TextGetterCache[cls] = getters;
    }
    for (NSString *getter in getters) {
        id value = ((id (*)(id, SEL))objc_msgSend)(v, NSSelectorFromString(getter));
        if ([value isKindOfClass:NSAttributedString.class]) value = [value string];
        if ([value isKindOfClass:NSString.class] && [(NSString *)value length] < 200) return value;
    }
    NSString *label = v.accessibilityLabel;
    return label.length < 200 ? label : nil;
}

// item 的 model 上就写着该显示什么（底栏只有 首页 / 我的 两项）。
// 冷启动第一帧就是引导态、没来得及记下正常标题时，这是唯一的正确来源。
static NSString *TabItemModelTitle(UIView *item) {
    id model = ObjectGetter(item, @"model");
    for (NSString *getter in @[@"title", @"text", @"name", @"tabTitle", @"displayName"]) {
        id value = ObjectGetter(model, getter);
        if ([value isKindOfClass:NSString.class] && [(NSString *)value length]
            && [(NSString *)value length] <= 8 && !IsDiscoverHintText(value))
            return value;
    }
    return nil;
}

static void FixTabBarHint(UIView *hint, UIView *bar) {
    if (FixingHintText) return;
    if (![hint respondsToSelector:@selector(setText:)]) { hint.hidden = YES; return; }

    // 往上找它属于哪个 item
    UIView *item = hint.superview;
    while (item && item != bar) {
        if ([NSStringFromClass(item.class) isEqualToString:@"WINTabBarItem"]) break;
        item = item.superview;
    }
    if (item == bar) item = nil;

    // 正确文案：先看之前记下的，再从 model 取
    NSString *good = nil;
    if (item) {
        good = objc_getAssociatedObject(item, &LastTitleKey);
        if (![good isKindOfClass:NSString.class] || !good.length) good = TabItemModelTitle(item);
    }

    FixingHintText = YES;
    if (good.length) {
        ((void (*)(id, SEL, id))objc_msgSend)(hint, @selector(setText:), good);
        if (item) objc_setAssociatedObject(item, &LastTitleKey, good, OBJC_ASSOCIATION_COPY_NONATOMIC);
    } else {
        // 纯引导浮层（不是标题 label）：只收掉「类名一看就是提示」的那层，
        // 到 item 为止绝不越界。
        UIView *host = hint;
        for (int depth = 0; host && host != bar && depth < 3; depth++, host = host.superview) {
            host.hidden = YES;
            UIView *up = host.superview;
            if (!up) break;
            NSString *cn = NSStringFromClass(up.class);
            if ([cn isEqualToString:@"WINTabBar"] || [cn isEqualToString:@"WINTabBarItem"]) break;
            if (![cn containsString:@"Tip"] && ![cn containsString:@"Guide"] &&
                ![cn containsString:@"Discover"] && ![cn containsString:@"PullUp"] &&
                ![cn containsString:@"Hint"]) break;
        }
    }
    FixingHintText = NO;
}

// 0.6.8：切页的主动通道。
// tick 每拍读一次 selectedViewControl（本来就在读，零额外开销），
// 一旦从别的页翻到【首页】，立即开一段 320ms 快修窗 —— 不等 app 去动搜索栏。
// 这样无论 app 走哪条路径切页（setter / 状态机 / 内部重排），都能覆盖到。
static __weak id LastSelected;
static void WatchHomeTransition(id tabs) {
    if (!tabs) return;
    id selected = ObjectGetter(tabs, @"selectedViewControl");
    if (!selected) return;
    BOOL home = [NSStringFromClass([selected class]) isEqualToString:@"WINAmapHomeControl"];
    id prev = LastSelected;
    LastSelected = selected;
    if (!prev || prev == selected) return;          // 第一次见到 / 没变
    BOOL prevHome = [NSStringFromClass([prev class]) isEqualToString:@"WINAmapHomeControl"];
    if (home && !prevHome && ColdTicks >= 15) KickBarFixFor(0.32);
    // 0.7.2：切页 = 内容必然重排 → 强制全量 CleanPage
    if (prevHome != home) { CleanForce = YES; GCCActiveUntil = TickCount + 8; }
}

// 只走底栏子树：节点数 20-40，无 convertRect:，无窗口遍历。200ms 一次也无所谓。
static void SweepTabBarHints(UIView *bar) {
    if (![bar isKindOfClass:UIView.class]) return;
    NSMutableArray *q = [NSMutableArray arrayWithObject:bar];
    for (NSUInteger i = 0; i < q.count && q.count < 200; i++) {
        UIView *v = q[i];
        if (v != bar) {
            if (v.hidden) { [q addObjectsFromArray:v.subviews]; continue; }
            NSString *text = TabBarTextOf(v);
            if (IsDiscoverHintText(text)) FixTabBarHint(v, bar);
            else if (text.length && text.length <= 8)
                // 记下正常标题，供引导态覆盖时写回
                objc_setAssociatedObject(v, &LastTitleKey, text, OBJC_ASSOCIATION_COPY_NONATOMIC);
        }
        [q addObjectsFromArray:v.subviews];
    }
}

// item 级触发：item 一布局 / 一上树就查一次它自己。范围只有一棵小树。
static void InstallTabBarHintHooks(void) {
    TextGetterCache = [NSMutableDictionary dictionary];
    // 0.6.8：切到【首页】的那一瞬间就开快修窗（tick 检测最坏要等 200ms）。
    // 方法名拿不到就静默跳过 —— 上面 tick 里那条通道照样兜得住。
    {
        Class tbc = NSClassFromString(@"WINTabBarControl");
        SEL ss = NSSelectorFromString(@"setSelectedViewControl:");
        Method m = tbc ? class_getInstanceMethod(tbc, ss) : NULL;
        if (m) {
            IMP o = method_getImplementation(m);
            const char *t = method_getTypeEncoding(m);
            Replace(tbc, ss, imp_implementationWithBlock(^(id self, id vc) {
                ((void (*)(id, SEL, id))o)(self, ss, vc);
                if ([NSStringFromClass([vc class]) isEqualToString:@"WINAmapHomeControl"]
                    && ColdTicks >= 15)
                    KickBarFixFor(0.32);
            }), t);
        }
    }
    HookVoid(@"WINTabBarItem", @"didMoveToWindow", ^(UIView *item) {
        // 0.9.8（A4）：原「initWithFrame:model: 建好后关掉重复点击」的钩子，
        // 被 HookVoid 的签名守卫（只接受 2 参 + 返回 void）静默跳过 ——
        // 真实签名是 4 参、返回 @。这里迁到 didMoveToWindow（v16@0:8）：
        // 同一语义、零 ABI 风险；WINTabBarItem 固定两个、不复用，时机等价。
        for (NSString *setter in @[@"setAllowRepeatClick:", @"setAmap_allowRepeatClick:"]) {
            SEL s = NSSelectorFromString(setter);
            if ([item respondsToSelector:s]) ((void (*)(id, SEL, BOOL))objc_msgSend)(item, s, NO);
        }
        for (UIView *p = item.superview; p; p = p.superview)
            if ([NSStringFromClass(p.class) isEqualToString:@"WINTabBar"]) { SweepTabBarHints(p); break; }
    });
}

// ===========================================================================
// 0.9.1 —— 「上拉发现」引导 Lottie 拦截（17.01.1 新机制）
//
// 17.01.1 的「上拉发现」不再走文本替换，而是 GuideLottie 渲染链：
//   WINTabBarItemDataLogic.updateTabBar:param:callback:（服务端下发）
//   → WINTabBarItemStateModel.guide = WINTabBarItemGuideModel{lottieZipUrl}
//   → WINTabBarItemControl.updateGuideLottie:viewState:（转发）
//   → WINTabBarItem.updateGuideLottie:viewState:   ★ 唯一渲染点
//        创建 Lottie 动画（双箭头 morph + 文案）叠加到底栏 item 上，
//        并用 amap_setGuideMaskHidden:forViewState: 盖住原图标。
//
// 证据（17.01.1 主二进制实测）：
//   · 埋点字符串 "tab guide lottie start play" / "tab guide lottie finished"；
//   · 「上拉发现」文案不在任何本地资源（UTF-8/UTF-16 全域查过）→ 打包在
//     服务端下发的 Lottie 资源里 → 旧文本层扫描（0.6.7 SweepTabBarHints）失效；
//   · 全调用链 xref：唯一渲染点 = WINTabBarItem.updateGuideLottie:viewState:
//     （无子类覆写；其余方法都是它下游）。
//
// 处置：空实现渲染入口（不调用原实现）→ 不创建 Lottie、不叠加、不盖蒙版。
//   下游均有空值兜底：按压观察者对空 lottie 走 NSNull 分支；
//   WINTabBar.gestureRecognizerShouldBegin: 里 amap_hasActiveGuideLottie=NO
//   时跳过引导手势。均安全，底栏点按/切换/上拉手势不受影响。
// 真机验证：日志见 "blocked tab guide lottie"（限流 20 条）。
// ===========================================================================
static NSInteger GCGuideLottieBlocked = 0;

static void InstallTabBarGuideLottieBlock(void) {
    Class cls = NSClassFromString(@"WINTabBarItem");
    SEL sel = NSSelectorFromString(@"updateGuideLottie:viewState:");
    Method m = cls ? class_getInstanceMethod(cls, sel) : NULL;
    if (!m) return;                      // 方法不存在（旧版/未来改名）：静默跳过
    const char *t = method_getTypeEncoding(m);
    NSMethodSignature *s = [NSMethodSignature signatureWithObjCTypes:t];
    // 签名必须是 v@:@q（self,_cmd,guide,viewState）——不匹配就不动
    if (s.numberOfArguments != 4 || s.methodReturnType[0] != 'v') return;
    IMP imp = imp_implementationWithBlock(^(__unused id item, __unused id guide,
                                            __unused NSInteger viewState) {
        if (GCGuideLottieBlocked < 20) {
            GCGuideLottieBlocked++;
            GCLog(@"[GaodeClean] blocked tab guide lottie (viewState=%ld)", (long)viewState);
        }
        // 不调用原实现：整个「上拉发现」渲染链在此掐断
    });
    Replace(cls, sel, imp, t);
}

// 0.9.4：删除 ConfineLegacyChrome（审计确认零引用）。

static void CenterTabButtons(UIView *bar) {
    // 0.7.0：能承载底栏的窗口就是 App 主窗口 —— 后面屏蔽开屏广告时，
    // 这个窗口永远不在可隐藏名单里，避免误伤。
    if (bar.window && !GCCMainWindow) GCCMainWindow = bar.window;
    static BOOL adjusting;
    if (adjusting) return;
    NSArray *items = ObjectGetter(bar, @"tabBarItems");
    if (![items isKindOfClass:NSArray.class] || items.count != 2) return;
    adjusting = YES;
    // Keep the native full-width platter; retain the compact layout's item centers.
    CGFloat compactWidth = MIN(252, bar.bounds.size.width - 32);
    CGFloat separation = MAX(0, compactWidth - 48 - 84);
    UIView *selectedItem = nil;
    for (NSUInteger index = 0; index < items.count; index++) {
        UIView *item = items[index];
        if (![item isKindOfClass:UIView.class] || !item.superview) continue;
        if ([item respondsToSelector:@selector(isSelect)] && ((BOOL (*)(id, SEL))objc_msgSend)(item, @selector(isSelect))) selectedItem = item;
        CGPoint center = [item.superview convertPoint:item.center toView:bar];
        center.x = CGRectGetMidX(bar.bounds) + (index == 0 ? -0.5 : 0.5) * separation;
        item.center = [bar convertPoint:center toView:item.superview];
    }
    // 0.5.12：完整恢复 0.5.0 的胶囊跟随逻辑。
    // 0.5.11 的对照实验证明「完全不写胶囊」会错位——胶囊留在原生位置，
    // 而图标被 CenterTabButtons 挪到了 136/256pt，所以胶囊看起来跑到了两端。
    // 0.5.0 之所以对得上，靠的就是下面这两步：
    //   ① amap_syncLegacySelectionAnimated:NO —— 让 app 按新图标位置重算胶囊
    //   ② 只写 origin.x / width —— 跟随选中项，绝不碰 transform
    SEL sync = NSSelectorFromString(@"amap_syncLegacySelectionAnimated:");
    if ([bar respondsToSelector:sync]) ((void (*)(id, SEL, BOOL))objc_msgSend)(bar, sync, NO);
    UIView *pill = ObjectGetter(bar, @"amap_legacySelectionView");
    if (selectedItem && [pill isKindOfClass:UIView.class]) {
        CGRect r = [selectedItem convertRect:selectedItem.bounds toView:pill.superview];
        if (r.size.width > 0) {
            CGRect f = pill.frame;
            f.origin.x = r.origin.x - 8;
            f.size.width = r.size.width + 16;
            pill.frame = f;
        }
    }
    adjusting = NO;
    // 0.6.8：这里原本调 LogCoveringViews(bar) —— 它会 Flatten(win) 一整棵窗口树、
    // 再拼最多 130 行文本写进 Documents/GaodeClean-cover.txt。0.6.0 宣布「正式包零诊断」
    // 时漏掉了这一处，它一直挂在 WINTabBar 的 layoutSubviews 上：每次底栏布局都做一次
    // 全窗口遍历 + 文件写入，切页时正是底栏密集重排的时刻。整段删除。
}


// ===========================================================================
//  0.7.0 —— 启动屏广告移除
//
//  现象：开屏广告「偶发」出现，不是每次冷启动都有。这是广告 SDK 的**填充率**
//  决定的 —— 有素材才展示，没有就直接进 App。所以**不能只在某个固定时机扫一次**
//  （这正是 0.6.7「上拉发现」踩过的坑：只挂在 layoutSubviews 上，晚到的引导态就漏了）。
//
//  三条通道一起覆盖，全部限定在有界范围内：
//    ① UIWindow -addSubview:                        广告视图被塞进窗口的瞬间
//    ② UIViewController -presentViewController:...  模态全屏广告
//    ③ 启动 / 每次回到前台后 15s 内，由已有的 200ms tick 兜底扫描
//
//  安全边界（避免误伤 App 本体）：
//    · 只认类名含广告 SDK 关键词的视图 / 窗口 —— **不认裸「ad」**，
//      否则 header / download / shadow 全都会中
//    · 必须覆盖所在窗口 ≥60% 面积
//    · 绝不隐藏 App 主窗口（GCCMainWindow = 承载底栏的那个窗口）
//    · 自己创建的视图（GCC 前缀）一律跳过
// ===========================================================================

static BOOL GCCHasAdKeyword(NSString *name) {
    if (!name.length) return NO;
    static NSArray<NSString *> *kw;
    static dispatch_once_t once;
    static NSMutableDictionary<NSString *, NSNumber *> *hitCache;
    dispatch_once(&once, ^{
        // 只列**明确属于广告 SDK** 的词。注意不能放裸 "ad"：
        // header / download / shadow / badge 都会误伤。
        kw = @[@"splash", @"launchad", @"launchimageview", @"adview", @"advert",
               @"csj", @"buad", @"busplash", @"pangle",
               @"gdtsplash", @"gdtad", @"gdtnative", @"gdtuni",
               @"kssplash", @"ksad", @"mtgsplash", @"mtgad",
               @"baidumob", @"beacon", @"splashad", @"adskip",
               @"winsplash", @"amapsplash", @"autosplash"];
        hitCache = [NSMutableDictionary dictionary];
    });
    // 0.9.8（A11）：这个函数挂在 UIWindow -addSubview: 这条全局热路径上（开屏广告通道①），
    // 原来每次都要 lowercaseString（分配新字符串）+ 27 次 containsString:。
    // 类名集合有限且稳定，按原名缓存判定结果，命中即 O(1)。
    NSNumber *cached = hitCache[name];
    if (cached) return cached.boolValue;
    NSString *low = name.lowercaseString;
    BOOL hit = NO;
    for (NSString *k in kw) if ([low containsString:k]) { hit = YES; break; }
    hitCache[name] = @(hit);
    return hit;
}

// 覆盖所在窗口 ≥60% 面积才算开屏广告
static BOOL GCCIsFullScreen(UIView *v) {
    UIWindow *w = v.window;
    if (!w || ![w isKindOfClass:UIWindow.class]) return NO;
    if (w.bounds.size.width < 1 || w.bounds.size.height < 1) return NO;
    CGRect r = [v convertRect:v.bounds toView:w];
    return CGRectGetWidth(r)  >= w.bounds.size.width  * 0.6
        && CGRectGetHeight(r) >= w.bounds.size.height * 0.6;
}

// 0.9.8（A6）：高德自家的启动屏/开屏外壳 —— 类名含 splash，但**不是广告**。
// GCCHasAdKeyword 的词表里有裸词 "splash"，会把 APSplashScreen* 一并网住；
// 这条路径真实可达（见下面 GCCWindowIsAppHost 的原注释）：一旦被当广告隐藏，
// App 启动直接白屏。原则不变：宁可漏一个广告，也绝不误伤 App 自身。
static BOOL GCCIsAppOwnSplash(NSString *cn) {
    if (!cn.length) return NO;
    static NSArray<NSString *> *own;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        own = @[@"APSplashScreen", @"APLaunchScreen", @"AMapLaunchScreen",
                @"GDAmapLaunchScreen", @"WINAppLaunchScreen", @"AMapSplashScreen"];
    });
    for (NSString *p in own) if ([cn hasPrefix:p]) return YES;
    return NO;
}

static BOOL GCCIsSplashAd(UIView *v, UIWindow *win) {
    if (!v || v.hidden) return NO;
    NSString *cn = NSStringFromClass(v.class);
    if ([cn hasPrefix:@"GCC"]) return NO;                    // 自己的视图
    if (GCCIsAppOwnSplash(cn)) return NO;                    // 0.9.8(A6)：自家启动屏
    NSString *wcn = NSStringFromClass(win.class);
    if (GCCIsAppOwnSplash(wcn)) return NO;                   // 0.9.8(A6)：自家启动窗
    if (!GCCHasAdKeyword(cn) && !GCCHasAdKeyword(wcn)) return NO;
    return GCCIsFullScreen(v);
}

// 0.7.5(B1)：窗口级拉黑前的二次确认。
// 原来是「只靠 w == GCCMainWindow 排除」，而 GCCMainWindow 只在 WINTabBar 首次
// layoutSubviews 时才惰性赋值 —— 在那之前它是 nil，排除条件恒真失效，App 主窗口
// 会落进可拉黑范围。一旦被拉黑，setHidden: 钩子会**永久**拒绝它重新显示
// （makeKeyAndVisible 也被拦），表现就是「启动黑屏，必须杀后台重开才正常」。
// 高德自己的启动屏 APSplashScreenViewController 类名恰好含 "splash"，
// 正落在 GCCHasAdKeyword 词表里 —— 这条路径是真实可达的。
// 原则：宁可漏一个开屏广告，也绝不能拉黑 App 的 UI 宿主。
static BOOL GCCWindowIsAppHost(UIWindow *w) {
    if (!w) return YES;
    if (GCCMainWindow == nil) return YES;                    // ★ 保险丝：主窗口未定，谁都不许拉黑
    if (w == GCCMainWindow) return YES;
    if (w.isKeyWindow) return YES;   // 0.9.4：弃用 API → 属性
    UIViewController *root = w.rootViewController;           // 承载 App 根 VC 的窗口不是广告窗口
    if (root) {
        NSString *rc = NSStringFromClass(root.class);
        // 0.9.8（A6）：自家启动屏优先放行，再走关键词判定
        if (GCCIsAppOwnSplash(rc) || !GCCHasAdKeyword(rc)) return YES;
    }
    return NO;
}

// 处理命中：隐藏广告视图；若它住在一个**独立广告窗口**里（且不是主窗口），连窗口一起收掉。
static void GCCHideSplashAd(UIView *v, NSString *why) {
    if (!v) return;
    UIWindow *w = v.window;
    v.hidden = YES;
    GCLog(@"[GaodeClean] splash ad hidden [%@] view=%@ win=%@",
          why, NSStringFromClass(v.class), NSStringFromClass(w.class));

    // 0.7.5(B1)：同上的二次确认 —— 只有确认不是 App UI 宿主才连窗口一起收
    if (w && !GCCWindowIsAppHost(w)) {
        // 该窗口里除了广告没有别的可交互内容 → 直接收掉
        GCCSplashWindow = w;
        GCCSplashUntil = TickCount + 300;                    // 0.7.5(B2)
        w.hidden = YES;
    }
    GCCSplashTicks = 0;
}

// 主窗口之外的、类名像广告的窗口 —— 也是强信号
static void GCCHideAdWindows(void) {
    for (UIWindow *w in GCAllWindows()) {
        if (w.hidden) continue;
        NSString *wcn = NSStringFromClass(w.class);
        if (!GCCHasAdKeyword(wcn)) continue;
        if (GCCIsAppOwnSplash(wcn)) continue;                // 0.9.8(A6)：自家启动窗
        // 0.7.5(B1)：主窗口未确定 / 该窗口是 App UI 宿主 → 绝不拉黑
        if (GCCWindowIsAppHost(w)) {
            NSLog(@"[GaodeClean] ad-window blacklist SKIPPED (App host): %@", wcn);
            continue;
        }
        GCCSplashWindow = w;
        GCCSplashUntil = TickCount + 300;                    // 0.7.5(B2)：60s 后自动失效
        w.hidden = YES;
            GCLog(@"[GaodeClean] splash ad window hidden: %@", wcn);
    }
}

// 通道 ③：兜底扫描。只在启动 / 回前台后的有界窗口内跑，且有节点上限。
static void SplashAdTick(void) {
    // 0.7.4(A5)：15s 有界窗口结束后，窗口兜底降为每 10 拍（2s）。
    // 后置的广告窗口不靠这条路径 —— CNG 选择器挂钩 + 窗口 addSubview 钩子已覆盖，
    // 原来即使 GCCSplashTicks 归零也仍每拍遍历所有窗口做类名匹配。
    if (GCCSplashTicks <= 0) {
        if (TickCount % 10 != 0) return;
    } else {
        GCCSplashTicks--;
    }
    GCCHideAdWindows();
    for (UIWindow *w in GCAllWindows()) {
        if (w == GCCMainWindow || w.hidden) continue;
        // 只下潜两层、上限 200 个节点 —— 不做全树 BFS（0.6.7a 的教训）
        NSMutableArray *q = [NSMutableArray arrayWithObject:w];
        for (NSUInteger i = 0; i < q.count && q.count < 200; i++) {
            UIView *v = q[i];
            if (v != w) {
                UIWindow *owner = v.window ?: w;
                if (GCCIsSplashAd(v, owner)) { GCCHideSplashAd(v, @"tick"); return; }
            }
            [q addObjectsFromArray:v.subviews];
        }
    }
    // 主窗口里也可能直接盖了一层全屏广告（不走独立窗口）
    if (GCCMainWindow) {
        NSArray *subs = [GCCMainWindow.subviews copy];
        for (UIView *v in subs) {
            if (GCCIsSplashAd(v, GCCMainWindow)) { GCCHideSplashAd(v, @"tick-main"); return; }
        }
    }
}

static void ReArmSplashGuard(void) {
    GCCSplashTicks = 75;          // 75 × 200ms ≈ 15s
    SplashAdTick();
}

// ---------------------------------------------------------------------------
//  ❖ 决定性一层：从高德 17.00.2 的字符串表里抄出来的**真类名与真 selector**
//
//  高德的广告走阿里聚合 SDK，命名空间是 CNG（另有 CNB / CNGLaunchSplash*、
//  CNGSplashAds*、CNGDoubleSplashCoordinator …），配置键为
//  `ad_splash_enable` / `_ad_splash_enable` / `ignore_splash_ads`。
//  这些都不是猜的 —— 由二进制字符串表逐个核对：
//      CNGLaunchSplashView / CNGLaunchSplashImageView / CNGLaunchSplashPrefetchAds
//      CNGSplashAds* / CNBSplash / CNGDoubleSplashCoordinator
//      isSplashAd / hasSplash / isShowSplash / showSplashAdInWindow
//
//  做法：用 objc_getClassList() 把这些类找出来，再按**真实 selector** 挂钩：
//    · 「显示」类方法 → 空实现
//    · 「判定」类方法 → 返回 NO（先校验返回类型是 BOOL/char，不匹配就不动）
//  比猜类名可靠，也不会像 0.6.7a 那样把钩子挂到框架基类上。
// ---------------------------------------------------------------------------
static BOOL GCCIsAdNamespace(NSString *name) {
    if (!name.length) return NO;
    static NSArray<NSString *> *prefixes;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        // 17.00.2 = 阿里聚合广告（CNG 命名空间）
        // 17.01.0 = 自研原生 WINSplashScreen*（CNG 与第三方 SDK 已被高德整体移除，
        //           实测 BUAdSDK/GDTMobSDK/KSAdSDK/BaiduMobAd 在新包中 0 命中）
        prefixes = @[@"CNGLaunchSplash", @"CNGSplashAds", @"CNGSplash", @"CNBSplash",
                     @"CNGBaseThirdPartySDKSplashAds", @"CNGDoubleSplash",
                     @"CNGMSBaseSplashAd", @"CNGMSDirectSplashAd", @"CNGMSS2SBiddingSplashAd",
                     @"CNGMSSplashAdsManager", @"CNGCSJ", @"CNGAdSplash",
                     // 0.8.0 新增：17.01.0 自研开屏广告体系
                     @"WINSplashScreen", @"WINSplashFilter", @"WINSplashPreFilter",
                     @"WINSplashFrequency", @"WINSplashFrequecy", @"WINSplashScene",
                     @"WINSplashCloud", @"WINSplashCreative", @"WINSplashRealtime",
                     @"WINSplashStandard", @"WINSplashAnimator", @"WINSplashArcss",
                     @"WINSplashSpeed", @"WINSplashActivity", @"WINSplashRoll",
                     @"WINSplashShake"];
    });
    for (NSString *p in prefixes) if ([name hasPrefix:p]) return YES;
    return NO;
}

// 该方法是否由**这个类自己**实现（而非继承）
static BOOL GCCClassImplements(Class cls, SEL sel) {
    unsigned int n = 0;
    Method *list = class_copyMethodList(cls, &n);
    BOOL found = NO;
    for (unsigned int i = 0; i < n; i++) {
        if (method_getName(list[i]) == sel) { found = YES; break; }
    }
    if (list) free(list);
    return found;
}

static void GCCHookAdClasses(void) {
    // 0.9.8（A7）：原来每次回到前台都跑一遍 objc_getClassList（真机约 4 万类）
    // + malloc，日志还会把已经装过的钩子重打一遍。类表在启动后不久就稳定，
    // 这里限制为 4 次（install / +1s / +3s / 首个回前台），之后交给
    // GCCHideAdWindows 的窗口级兜底。真机卡顿与日志刷屏同时消失。
    static int runs = 0;
    if (runs >= 4) return;
    runs++;

    int count = objc_getClassList(NULL, 0);
    if (count <= 0) return;
    Class *all = (Class *)malloc(sizeof(Class) * (size_t)count);
    if (!all) return;
    count = objc_getClassList(all, count);

    // 「显示」——空实现即可。只接受无参或至多两参的、返回 void 的方法。
    NSArray<NSString *> *showSels = @[@"showSplash", @"showSplashAd", @"showSplashAdInWindow",
                                      @"showSplashViewInRootViewController", @"showSplashWithConfigEntry",
                                      @"showSplashPlaceholderView", @"showSplashCardInRootVC",
                                      @"beginToShowNativeSplashAd"];
    // 「判定」——返回 NO。只接受返回 BOOL/char 的。
    NSArray<NSString *> *boolSels = @[@"isSplashAd", @"hasSplash", @"isShowSplash", @"isSplash",
                                      @"isSplashExist", @"isSplashAdDidLoad", @"isSplashImageAd",
                                      // 0.8.0：17.01.0 自研体系（语义明确：返回 NO = 不展示广告）
                                      // ★ 不碰 present* 展示层 —— 它带 4 个 completion block，
                                      //   置空会让启动流程等不到 playFinish/animationFinish，
                                      //   高概率卡白屏（0.7.4 黑屏事故同源）。
                                      @"shouldSplashScreenShow:launchCheck:",
                                      @"isLocalSplashDataCanExposure"];
    NSMutableArray<NSString *> *hooked = [NSMutableArray array];

    for (int i = 0; i < count; i++) {
        Class cls = all[i];
        if (!cls) continue;
        NSString *cn = NSStringFromClass(cls);
        if (!GCCIsAdNamespace(cn)) continue;

        for (NSString *name in showSels) {
            SEL sel = NSSelectorFromString(name);
            Method m = class_getInstanceMethod(cls, sel);
            if (!m) continue;
            // 只钩「这个类自己实现」的方法。否则 Replace() 会退化成
            // method_setImplementation → 改到父类，波及所有子类（过宽）。
            if (!GCCClassImplements(cls, sel)) continue;
            const char *t = method_getTypeEncoding(m);
            NSMethodSignature *sig = [NSMethodSignature signatureWithObjCTypes:t];
            if (sig.methodReturnType[0] != 'v') continue;           // 只换 void
            // ★ block 的参数个数必须与真实方法**一致**，否则调用约定不匹配
            //   （0.6.7a 的教训：钩子签名不对会直接崩 / 卡死）。
            //   numberOfArguments 含 self 与 _cmd，所以 2 → 无参，3 → 一参，4 → 两参。
            NSUInteger na = sig.numberOfArguments;
            IMP empty = nil;
            if (na == 2)      empty = imp_implementationWithBlock(^(__unused id self) {});
            else if (na == 3) empty = imp_implementationWithBlock(^(__unused id self, __unused id a1) {});
            else if (na == 4) empty = imp_implementationWithBlock(^(__unused id self, __unused id a1, __unused id a2) {});
            if (!empty) continue;                                   // 参数更多就不动
            Replace(cls, sel, empty, t);
            [hooked addObject:[NSString stringWithFormat:@"%@-%@", cn, name]];
        }
        for (NSString *name in boolSels) {
            SEL sel = NSSelectorFromString(name);
            Method m = class_getInstanceMethod(cls, sel);
            if (!m) continue;
            if (!GCCClassImplements(cls, sel)) continue;
            const char *t = method_getTypeEncoding(m);
            NSMethodSignature *sig = [NSMethodSignature signatureWithObjCTypes:t];
            char r = sig.methodReturnType[0];
            if (r != 'B' && r != 'c') continue;                     // 必须返回 BOOL/char
            // 0.8.0(A3-3)：新版 WINSplashScreen* 的判定方法**带参**
            // （shouldSplashScreenShow:launchCheck: 两参），旧版「必须无参」会让它们
            // 一律挂不上。放开到 ≤2 参，并按真实参数个数生成对应 block
            // —— block 签名必须与方法一致，否则调用约定不匹配（0.6.7a 的教训）。
            NSUInteger na = sig.numberOfArguments;
            IMP no = nil;
            if (na == 2)      no = imp_implementationWithBlock(^(__unused id self) { return (BOOL)NO; });
            else if (na == 3) no = imp_implementationWithBlock(^(__unused id self, __unused id a1) { return (BOOL)NO; });
            else if (na == 4) no = imp_implementationWithBlock(^(__unused id self, __unused id a1, __unused id a2) { return (BOOL)NO; });
            if (!no) continue;                                      // 参数更多就不动
            Replace(cls, sel, no, t);
            [hooked addObject:[NSString stringWithFormat:@"%@-%@", cn, name]];
        }
    }
    free(all);
    if (hooked.count) NSLog(@"[GaodeClean] splash guard hooked %lu: %@",
                            (unsigned long)hooked.count, [hooked componentsJoinedByString:@", "]);
}

// ---------------------------------------------------------------------------
//  0.8.0(A4)：只读探针
//  新版（17.01.0）开屏广告走自研 WINSplashScreen*。静态只能证明「类存在」，
//  运行时到底哪条路径真被调用必须真机取证。这里只打印、不挂钩、不改行为：
//  把这份类清单与 GCCHideSplashAd 已有的「兜底命中」日志对照，即可定位下一轮
//  精确拦截的靶子（届时只动判定层，绝不动展示层）。
// ---------------------------------------------------------------------------
static void GCReportSplashClasses(void) {
    // 0.9.8（A7）：诊断探针默认关闭 —— 原来 install / +1s / +3s 各跑一次
    // 全类枚举（约 4 万类）并打一整行类名日志，正式包里毫无产出价值。
    // 需要取证时：启动环境加 GAODECLEAN_DEBUG_SPLASH=1。
    static int enabled = -1;
    if (enabled < 0) enabled = getenv("GAODECLEAN_DEBUG_SPLASH") ? 1 : 0;
    if (!enabled) return;

    int n = objc_getClassList(NULL, 0);
    if (n <= 0) return;
    Class *all = (Class *)malloc(sizeof(Class) * (size_t)n);
    if (!all) return;
    n = objc_getClassList(all, n);
    NSMutableArray<NSString *> *hit = [NSMutableArray array];
    for (int i = 0; i < n; i++) {
        Class c = all[i];
        if (!c) continue;
        NSString *cn = NSStringFromClass(c);
        if ([cn hasPrefix:@"WINSplash"] || [cn hasPrefix:@"WINRealtimeSplash"]) [hit addObject:cn];
    }
    free(all);
    GCLog(@"[GaodeClean] WINSplash classes at runtime: %lu [%@]",
          (unsigned long)hit.count, [hit componentsJoinedByString:@","]);
}

static void InstallSplashAdGuard(void) {
    GCCHookAdClasses();
    GCReportSplashClasses();          // 0.8.0(A4)：只读
    ReArmSplashGuard();

    // 通道 ①：广告视图被加进窗口的瞬间。钩 UIWindow 而不是 UIView ——
    // UIWindow 是具体类，addSubview: 调用频率低，不会像钩基类那样拖死主线程。
    {
        SEL sel = @selector(addSubview:);
        Method m = class_getInstanceMethod(UIWindow.class, sel);
        if (m) {
            IMP o = method_getImplementation(m);
            const char *t = method_getTypeEncoding(m);
            Replace(UIWindow.class, sel, imp_implementationWithBlock(^(UIWindow *self, UIView *sub) {
                ((void (*)(id, SEL, id))o)(self, sel, sub);
                if (GCCIsSplashAd(sub, self)) GCCHideSplashAd(sub, @"addSubview");
            }), t);
        }
    }

    // 通道 ②：模态全屏广告。presentViewController 一次会话只调用几次，
    // 不是热路径；且只在「呈现出来的确实是广告」时才动手。
    // 0.9.8（A2）：判定点从**调用栈内**移到 completion 块。
    //   原实现在 present 返回瞬间读 vc.view / pv.window：present 尚未开始转场，
    //   pv.window 恒为 nil → GCCIsSplashAd 的 GCCIsFullScreen 首句就判死 →
    //   这条通道**从未命中过**；而且即便命中，在 present 调用栈里同步 dismiss
    //   会撞 UIKit 的「presentation in progress」断言。
    //   现在：completion 里再判，dismiss 也放到下一 runloop，避开转场锁。
    {
        SEL sel = @selector(presentViewController:animated:completion:);
        Method m = class_getInstanceMethod(UIViewController.class, sel);
        if (m) {
            IMP o = method_getImplementation(m);
            const char *t = method_getTypeEncoding(m);
            Replace(UIViewController.class, sel,
                imp_implementationWithBlock(^(UIViewController *self, UIViewController *vc,
                                              BOOL animated, void (^done)(void)) {
                    void (^tail)(void) = ^{
                        if (done) done();
                        dispatch_async(dispatch_get_main_queue(), ^{
                            UIView *pv = vc.viewIfLoaded;
                            if (!pv || !GCCIsSplashAd(pv, pv.window)) return;
                            GCCHideSplashAd(pv, @"present");
                            if (vc.presentingViewController) {
                                [vc dismissViewControllerAnimated:NO completion:nil];
                            }
                        });
                    };
                    ((void (*)(id, SEL, id, BOOL, id))o)(self, sel, vc, animated, tail);
                }), t);
        }
    }

    // 已识别的广告窗口：之后 app 再想让它可见 / 变 key，一律拒绝
    {
        SEL sel = @selector(setHidden:);
        Method m = class_getInstanceMethod(UIWindow.class, sel);
        if (m) {
            IMP o = method_getImplementation(m);
            const char *t = method_getTypeEncoding(m);
            Replace(UIWindow.class, sel, imp_implementationWithBlock(^(UIWindow *self, BOOL hidden) {
                // 0.7.5(B2)：拦截有界化 —— 即便误判，60s 后自动失效；
                // 且窗口一旦成为 keyWindow / 是 App UI 宿主，立即解除。
                if (!hidden && self == GCCSplashWindow
                    && TickCount < GCCSplashUntil && !GCCWindowIsAppHost(self)) hidden = YES;
                ((void (*)(id, SEL, BOOL))o)(self, sel, hidden);
            }), t);
        }
        SEL mk = NSSelectorFromString(@"makeKeyAndVisible");
        Method m2 = class_getInstanceMethod(UIWindow.class, mk);
        if (m2) {
            IMP o2 = method_getImplementation(m2);
            const char *t2 = method_getTypeEncoding(m2);
            Replace(UIWindow.class, mk, imp_implementationWithBlock(^(UIWindow *self) {
                // 0.7.5(B2)：同上的有界化
                if (self == GCCSplashWindow
                    && TickCount < GCCSplashUntil && !GCCWindowIsAppHost(self)) return;
                ((void (*)(id, SEL))o2)(self, mk);
            }), t2);
        }
    }

    // 每次回到前台重新武装（用户可能切出去再回来，广告会重新拉）
    [NSNotificationCenter.defaultCenter addObserverForName:UIApplicationDidBecomeActiveNotification
                                                    object:nil queue:NSOperationQueue.mainQueue
                                                usingBlock:^(__unused NSNotification *n) {
        GCCHookAdClasses();          // 懒加载的广告 SDK 这时可能才注册类
        ReArmSplashGuard();
    }];
    // 广告 SDK 常是懒加载：启动后 1s / 3s 各再发现一次（一次性，非周期）
    for (NSNumber *delay in @[@1.0, @3.0]) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                     (int64_t)(delay.doubleValue * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            GCCHookAdClasses();
            ReArmSplashGuard();
            GCReportSplashClasses();  // 0.8.0(A4)：懒注册的类这时才可能出现
        });
    }
}

static void InstallMinimalHome(void) {
    // 0.7.0：开屏广告移除
    InstallSplashAdGuard();
    HookVoid(@"WINTabBar", @"layoutSubviews", ^(UIView *bar) { CachedTabBar = bar; CenterTabButtons(bar); SweepTabBarHints(bar); });
    InstallTabBarHintHooks();
    // 0.9.1：「上拉发现」引导 Lottie 拦截（17.01.1 GuideLottie 机制）
    InstallTabBarGuideLottieBlock();

    HookVoid(@"GDAmapHomeHandler", @"viewDidLoad", ^(id handler) {
        [HomeHandlers addObject:handler];
        // 0.4.41：冷启动先隐藏搜索栏，LayoutMinimalHome 定位到最终位置后再显示，消除跳动
        UIView *bar = ObjectGetter(handler, @"searchBar");
        if ([bar isKindOfClass:UIView.class]) bar.hidden = YES;
    });
    HookVoid(@"GDAmapHomeHandler", @"layoutBottomSearchBar", ^(id handler) { [HomeHandlers addObject:handler]; LayoutMinimalHome(handler); });
    HookVoid(@"GDAmapHomeHandler", @"viewDidLayoutSubviews", ^(id handler) { [HomeHandlers addObject:handler]; LayoutMinimalHome(handler); });
    // 0.5.32：移除「上拉发现」——把 sheet 的手势/交互彻底关掉，
    // 上拉不再弹出发现面板（面板本身也被 sheet.hidden 挡着）。
    SealBlurOverlay();
    // 0.5.47：MapWidgetContainerView 被 app 在滑动时淡到 0（实测 a=0.00，弹簧过冲到 -2.33）
    // → 控件整片消失。这里把它的 alpha 恒定为 1（不动 setHidden:，避免按死搜索栏）。
    {
        Class mc = NSClassFromString(@"MapWidgetContainerView");
        if (mc) {
            SEL sa = @selector(setAlpha:);
            Method m = class_getInstanceMethod(mc, sa);
            if (m) {
                IMP o = method_getImplementation(m); const char *t = method_getTypeEncoding(m);
                Replace(mc, sa, imp_implementationWithBlock(^(UIView *self, __unused CGFloat a) {
                    ((void (*)(id, SEL, CGFloat))o)(self, sa, 1.0);
                }), t);
            }
        }
    }
    // 0.5.48：地图本体 AMap3DView 的透明度（两个入口，防止绕过 setAlpha:）。
    {
        Class mv = NSClassFromString(@"AMap3DView");
        if (mv) {
            SEL sa = @selector(setAlpha:);
            Method m = class_getInstanceMethod(mv, sa);
            if (m) {
                IMP o = method_getImplementation(m); const char *t = method_getTypeEncoding(m);
                Replace(mv, sa, imp_implementationWithBlock(^(UIView *self, __unused CGFloat a) {
                    ((void (*)(id, SEL, CGFloat))o)(self, sa, 1.0);
                }), t);
            }
        }
        SEL so = @selector(setOpacity:);
        Method lm = class_getInstanceMethod(CALayer.class, so);
        if (lm) {
            IMP o2 = method_getImplementation(lm); const char *t2 = method_getTypeEncoding(lm);
            Replace(CALayer.class, so, imp_implementationWithBlock(^(CALayer *self, float op) {
                // 0.9.8（A14）：setOpacity: 是全 app 每个图层动画都走的方法。
                // 原来先取 delegate 再判值，而绝大多数调用 op == 1.0。
                // 把判值提到最前，省掉 99% 的 delegate 访问 + isKindOfClass:。
                if (op < 0.99f) {
                    id dg = self.delegate;
                    if (dg && [dg isKindOfClass:mv]) op = 1.0f;
                }
                ((void (*)(id, SEL, float))o2)(self, so, op);
            }), t2);
        }
    }
    // 0.5.49：地图引擎的全局蒙版（VMap）—— 从命令层封死，永不开启。
    {
        Class vc = NSClassFromString(@"VMapDSLBaseCommand");
        if (vc) {
            SEL sl = NSSelectorFromString(@"setGlobalShowMask:");
            Method m = class_getInstanceMethod(vc, sl);
            if (m) Replace(vc, sl, imp_implementationWithBlock(^(__unused id self, __unused BOOL on) {}),
                           method_getTypeEncoding(m));
            SEL sc = NSSelectorFromString(@"setMaskColor:value:");
            Method m2 = class_getInstanceMethod(vc, sc);
            if (m2) Replace(vc, sc, imp_implementationWithBlock(^(__unused id self, __unused id ek, __unused int c) {}),
                            method_getTypeEncoding(m2));
        }
    }
    // 0.5.50：上拉手势的另一个宿主 —— 只对这两个类的【本体】摘 pan/swipe，
    // 绝不碰子树（搜索栏是 WINMultiStyleRootView 的子视图）。
    // 0.7.2：这里的 400ms 定时器已并入主 tick（StripTabBarGestures，每 2 拍一次，
    // 节点上限 6000 → 400）。WINTabBar / WINMultiStyleRootView 都在浅层，够用。
    HookWeatherRow();
    HookVoid(@"AMapUIWaterFallContentSlidableView", @"didMoveToWindow", ^(UIView *v) {
        v.userInteractionEnabled = NO;
        v.hidden = YES;
    });
    HookVoid(@"AMapUIWaterFallContentSlidableView", @"layoutSubviews", ^(UIView *v) {
        v.hidden = YES;
        v.userInteractionEnabled = NO;
    });
    // 0.5.45：压白雾的最小组合 —— 只断「上拉」这条路。
    // 绝不碰 setHidden:（那是按死搜索页的元凶：高德搜索页本身就是这个面板）。
    {
        Class sv = NSClassFromString(@"AMapUIWaterFallContentSlidableView");
        if (sv) {
            SEL ag = @selector(addGestureRecognizer:);
            Method m = class_getInstanceMethod(sv, ag);
            if (m) Replace(sv, ag, imp_implementationWithBlock(^(__unused id self, __unused id g) {}),
                           method_getTypeEncoding(m));
            for (NSString *setter in @[@"setHeaderPanGestureRecognizer:",
                                       @"setMockPanGestureRecognizer:"]) {
                SEL sl = NSSelectorFromString(setter);
                Method mm = class_getInstanceMethod(sv, sl);
                if (mm) Replace(sv, sl, imp_implementationWithBlock(^(__unused id self, __unused id g) {}),
                                method_getTypeEncoding(mm));
            }
        }
    }
    Class cls = NSClassFromString(@"WINAMapHomeStateMachine");
    SEL sel = NSSelectorFromString(@"setState:");
    Method method = class_getInstanceMethod(cls, sel);
    if (method) {
        IMP original = method_getImplementation(method);
        Replace(cls, sel, imp_implementationWithBlock(^(id self, id state) {
            // 0.5.8：ImmersiveState 进入时会发 D_map_immersive_gauss_active 事件
            // （地图高斯模糊 = 那条软边白雾带）。改派到 EmptyImmersiveState ——
            // 保留沉浸布局，但不触发高斯。这是源头修法：
            // 不再需要隐藏 WaterFall 容器（那是白区 506pt 的成因）。
            NSString *name = NSStringFromClass([state class]);
            id replacement = state;
            // 0.5.45：拒绝「上拉」状态跃迁 —— 上拉手势的落点就在这，
            // 白雾是这条路径上的产物。保持当前状态即可（不动任何 setHidden:）。
            if ([name containsString:@"PullUp"]) {
                id cur = ObjectGetter(self, @"currentState");
                if (cur) replacement = cur;
            }
            if ([name containsString:@"Immersive"] && ![name containsString:@"EmptyImmersive"]) {
                id empty = nil;
                if ([name containsString:@"BottomSearchBar"]) empty = ObjectGetter(self, @"bottomSearchBarEmptyImmersiveState");
                if ([name containsString:@"TopSearchBar"]) empty = ObjectGetter(self, @"topSearchBarEmptyImmersiveState");
                if (!empty) empty = ObjectGetter(self, @"bottomSearchBarEmptyImmersiveState");
                if (empty) replacement = empty;
            }
            ((void (*)(id, SEL, id))original)(self, sel, replacement);
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
    HookVoid(@"WINQuickSearchBarV2", @"layoutSubviews", ^(id bar) {
        UIView *text = ObjectGetter(bar, @"verticalScrollText");
        if ([text isKindOfClass:UIView.class]) text.hidden = YES;
        // 0.4.42：搜索栏尚未定位完成前保持隐藏，定位完成(LayoutMinimalHome)后再显示
        if (!SearchBarSettled) {
            UIView *b = bar;
            if (!b.hidden) b.hidden = YES;
        }
        // 0.5.54：切页（我的→首页）时 app 会短暂隐藏搜索栏 —— 逐帧实测 5 帧(≈42ms)
        // 搜索栏缺席、露出地图，就是你看到的「闪一下」。冷启动结束后一律强制可见；
        // 位置由下面的首帧锁定负责，不会跑偏（冷启动阶段仍按原逻辑隐藏）。
        if (SearchBarSettled && ColdTicks >= 15) {
            UIView *b = bar;
            if (b.hidden) b.hidden = NO;
        }
        // 0.4.19 首帧锁定：原生布局把搜索栏拉回顶部时立即钉回最终位置
        if (SearchBarSettled) {
            UIView *b = bar;
            if (fabs(b.frame.origin.y - SearchBarSettledY) > 0.5) {
                CGRect f = b.frame;
                f.origin.y = SearchBarSettledY;
                b.frame = f;
            }
        }
        // 0.4.49：app 会把搜索栏重新塞回 sheet(AMapUIWaterFallContentSlidableView)并挪离屏(1140)，
        // 检测到父视图被换即挂回 BarParent 并钉回 702——不依赖 timer，下一次布局自愈
        if (SearchBarSettled && BarParent) {
            UIView *b = bar;
            if (b.superview != BarParent) {
                [BarParent addSubview:b];
                CGRect f = b.frame;
                f.origin.y = SearchBarSettledY;
                b.frame = f;
                [BarParent bringSubviewToFront:b];
            }
        }
        // 0.4.8 首页搜索框去文字：隐藏推广 label/富文本视图，保留输入与按钮
        NSArray *nodes = Flatten(bar);
        if (!nodes || nodes.count > 400) return;
        for (UIView *v in nodes) {
            if (v == bar || v.hidden) continue;
            if ([v isKindOfClass:UIButton.class]) continue;
            if (IsInputLike(v)) continue;
            if ([v isKindOfClass:UILabel.class]) { v.hidden = YES; continue; }
            id t = ObjectGetter(v, @"text");
            if ([t isKindOfClass:NSString.class] && [(NSString *)t length]) { v.hidden = YES; continue; }
            id a = ObjectGetter(v, @"attributedText");
            if ([a isKindOfClass:NSAttributedString.class] && [(NSAttributedString *)a length]) v.hidden = YES;
        }
    });
    // 0.4.46：拦截 setFrame:，settled 后把搜索栏 y 钉死，杜绝 app 动画/布局拉回原生 447 造成闪跳
    {
        Class barCls = NSClassFromString(@"WINQuickSearchBarV2");
        SEL fs = @selector(setFrame:);
        Method fm = class_getInstanceMethod(barCls, fs);
        if (fm) {
            IMP fo = method_getImplementation(fm);
            Replace(barCls, fs, imp_implementationWithBlock(^(UIView *self, CGRect rect) {
                if (SearchBarSettled && fabs(rect.origin.y - SearchBarSettledY) > 2) {
                    rect.origin.y = SearchBarSettledY;
                }
                ((void (*)(id, SEL, CGRect))fo)(self, fs, rect);
            }), method_getTypeEncoding(fm));
        }
    }
    // 0.4.48：补 setCenter: 拦截——app 也会走 center/layer 路径把搜索栏挪走(如 1140 离屏)
    {
        Class barCls = NSClassFromString(@"WINQuickSearchBarV2");
        SEL cs = @selector(setCenter:);
        Method cm = class_getInstanceMethod(barCls, cs);
        if (cm) {
            IMP co = method_getImplementation(cm);
            Replace(barCls, cs, imp_implementationWithBlock(^(UIView *self, CGPoint center) {
                if (SearchBarSettled) {
                    CGFloat targetCenterY = SearchBarSettledY + self.bounds.size.height / 2;
                    if (fabs(center.y - targetCenterY) > 2) center.y = targetCenterY;
                }
                ((void (*)(id, SEL, CGPoint))co)(self, cs, center);
            }), method_getTypeEncoding(cm));
        }
    }
    // 0.4.50：hook didMoveToSuperview——app 重挂搜索栏时同步触发，父视图一被换立刻挂回 BarParent
    // 0.5.56：真正的机制查清了 —— app 切页时是把搜索栏 **removeFromSuperview**（不是 hidden，
    //         所以 0.5.54/0.5.55 的 layoutSubviews 强制可见 与 setHidden: 拦截全部无效）。
    //         而 b.superview && 这个守卫恰好把「被摘掉」(superview==nil) 这个唯一要管的场景跳过了，
    //         于是搜索栏以「无父视图」状态消失 4-5 帧(≈40ms) —— 就是「切到首页搜索栏闪一下」。
    // 新规则：当前是【首页】选中、冷启动已结束、且搜索栏被摘掉时显示状态 → 立刻挂回 BarParent 并钉回 y。
    //         被摘时若已 hidden（切到「我的」的正常摘除）则不介入；切「我的」时 onHome=NO 也不介入。
    HookVoid(@"WINQuickSearchBarV2", @"didMoveToSuperview", ^(UIView *b) {
        if (!SearchBarSettled || !BarParent || b.superview == BarParent) return;
        // 0.9.2：冷启动后段保护 —— 已显示过一次且仍可见的搜索栏被摘掉时也立即挂回；
        // 未显示过 / 已隐藏（切「我的」的正常摘除）/ 非首页选中 → 维持原早退。
        if (ColdTicks < 15) {
            if (!BarShownOnce || b.hidden) return;
            if (CachedTabs) {
                id sel = ObjectGetter(CachedTabs, @"selectedViewControl");
                if (![NSStringFromClass([sel class]) isEqualToString:@"WINAmapHomeControl"]) return;
            }
            static NSInteger GCBarReattach = 0;
            if (GCBarReattach < 5) {
                GCBarReattach++;
                GCLog(@"[GaodeClean] re-attached search bar (cold start, shown-once)");
            }
        }
        KickBarFix();                               // 0.5.57：被动到就立刻进快修，不等 100ms tick
        // 0.5.58：不再等 selectedViewControl 翻转（app 切页完成才翻，实测有 ~33ms 延迟），
        // 搜索栏一被 app 动到就立刻挂回并显示 —— 若当前其实是「我的」页，
        // 8ms 快修会在 1 帧内由 LayoutMinimalHome(!home 分支) 再把它藏回去，视觉上不可见。
        if (SearchBarView) b = SearchBarView;
        [BarParent addSubview:b];
        b.hidden = NO;
        CGRect f = b.frame;
        f.origin.y = SearchBarSettledY;
        b.frame = f;
        [BarParent bringSubviewToFront:b];
    });
    // 0.5.55：切页（我的→首页）时 app 直接 hidden=YES 把搜索栏藏起来 —— 不移动父视图，
    // 所以 0.4.50 的 didMoveToSuperview 钩子抓不到；逐帧实测缺席 4-5 帧(≈40ms)，
    // 就是「切到首页搜索栏闪一下」。这里定向拒绝：
    //   仅当【首页选中】且冷启动结束后，拒绝隐藏搜索栏。
    //   切到「我的」时 onHome=NO，隐藏照常放行，不会在「我的」页露出搜索栏。
    {
        Class bc = NSClassFromString(@"WINQuickSearchBarV2");
        if (bc) {
            SEL sh = @selector(setHidden:);
            Method m = class_getInstanceMethod(bc, sh);
            if (m) {
                IMP o = method_getImplementation(m);
                const char *t = method_getTypeEncoding(m);
                Replace(bc, sh, imp_implementationWithBlock(^(UIView *self, BOOL h) {
                    // 0.9.2：把「已显示过一次的搜索栏」纳入防隐保护 —— 冷启动后段（<15 拍）
                    // app 的一次瞬时隐藏会让搜索栏消失 ~117ms（120fps 逐帧实测）。
                    if (h && (ColdTicks >= 15 || BarShownOnce) && CachedTabs) {
                        id sel = ObjectGetter(CachedTabs, @"selectedViewControl");
                        if ([NSStringFromClass([sel class]) isEqualToString:@"WINAmapHomeControl"]) {
                            if (ColdTicks < 15) {
                                static NSInteger GCBarHideRefused = 0;
                                if (GCBarHideRefused < 5) {
                                    GCBarHideRefused++;
                                    GCLog(@"[GaodeClean] refused search bar hide (cold start, shown-once)");
                                }
                            }
                            h = NO;
                        }
                    }
                    ((void (*)(id, SEL, BOOL))o)(self, sh, h);
                }), t);
            }
        }
    }
    HookVoid(@"WINAJXCombinedItemView", @"layoutSubviews", ^(id view) { if (IsHiddenMapPromo(view)) [view setHidden:YES]; });
    cls = NSClassFromString(@"WINAJXCombinedItemView");
    sel = @selector(setHidden:);
    method = class_getInstanceMethod(cls, sel);
    if (method) {
        IMP original = method_getImplementation(method);
        Replace(cls, sel, imp_implementationWithBlock(^(UIView *self, BOOL hidden) {
            ((void (*)(id, SEL, BOOL))original)(self, sel, hidden || IsHiddenMapPromo(self));
        }), method_getTypeEncoding(method));
    }
    HookVoid(@"WINAJXCombinedWidgetView", @"layoutSubviews", ^(UIView *view) {
        if (IsHiddenMapPromo(view)) [view setHidden:YES];
        // 0.9.14（A4 回退）：恢复 0.9.7 的精确 tag 判定。纯类名（W1c）过宽，
        // 非 WINAJXCombinedWidgetView 实例也被拦了。
        else if (view.window && !objc_getAssociatedObject(view, &AlignedKey) && IsRightBottomWidget(view)) {
            view.hidden = YES; [ColdWidgets addObject:view];
        }
    });
    // 0.9.15（A3）：**出生即藏** —— 只挂 layoutSubviews 还差一截。
    //   diag 日志铁证：1.187s 上窗那一刻 tag 已是 template_mainmapRightBottom，
    //   而 app 在同一毫秒内就把 frame 摆到 (339,281)=窗口系(339,340)；
    //   首次 layoutSubviews 要等到 1.229s —— 中间 42ms（≈2.5 帧）足以渲染。
    //   这条钩子在上窗瞬间按住它：判定用**精确 tag**，不会误伤同类的
    //   「+/图层」圆钮（日志里那是 template_mainmapRightTop，不上屏就摆位不同）。
    HookVoid(@"WINAJXCombinedWidgetView", @"didMoveToWindow", ^(UIView *view) {
        if (view.window && !objc_getAssociatedObject(view, &AlignedKey) && IsRightBottomWidget(view)) {
            view.hidden = YES; [ColdWidgets addObject:view];
        }
    });
    // ==========================================================================
    // 0.9.16（A1）：**真凶在这里** —— App 原生「轻量控件组」容器。
    //   七轮（0.9.9~0.9.15）全部按 WINAJXCombinedWidgetView 施工，而 diag2 日志
    //   逐拍铁证：中部裸露的 ⊙+↰ 胶囊是 WINLiteWidgetGroupView(339,340,44x88)
    //   自身可见 + 它的毛玻璃 UIVisualEffectView + WINLocationView(⊙)；
    //   同一时刻我们的控件是 hid1（藏得好好的）。
    //   ⇒ 「藏宿主」挡不住「容器自身」，这就是为什么 0.9.7 也露、七轮修不掉。
    //   判据用几何排除右上「+/图层」胶囊（它出生就在 y≈69 = 窗高 3.6%）：
    //   只对 y 落在窗高 25% 以下的实例动手。
    HookVoid(@"WINLiteWidgetGroupView", @"didMoveToWindow", ^(UIView *v) {
        if (v.window && !SearchBarSettled && GCCIsLiteGroupCapsule(v)) {
            v.hidden = YES; [ColdWidgets addObject:v];
        }
    });
    HookVoid(@"WINLiteWidgetGroupView", @"layoutSubviews", ^(UIView *v) {
        // 锚点（搜索栏）未定格 = 冷启动未完成：按住它，不让它停在中部位显示。
        // 定格后交回给 A2（与我们的右下控件同一时刻放行）。
        if (!GCCIsLiteGroupCapsule(v)) return;
        if (!SearchBarSettled) { v.hidden = YES; [ColdWidgets addObject:v]; }
    });
    // 0.4.41：车机圆钮冷启动先隐藏，对齐后再显示，消除跳动
    HookVoid(@"WINDeviceInterconnectWidget", @"layoutSubviews", ^(UIView *w) {
        if (w.window && !objc_getAssociatedObject(w, &AlignedKey)) { w.hidden = YES; [ColdWidgets addObject:w]; }
    });
    // 0.9.14（A6 回退）：0.9.9（A3）给车机圆钮补的 setHidden:/setAlpha: 两条拦截已移除。
    //   与右下钮同源的「未对齐拒绝显示」逻辑 —— 车机钮虽然靠类名能被 CachedCar 稳定找到
    //   （不像右下钮依赖 getItemTag），但压 alpha 的自伤点（A2/A3 时报过「hidden 放行了、
    //   控件仍全透明」）与拦截带来的显示时序扰动没有存在必要。0.9.7 只挂 layoutSubviews
    //   一条，实测无跳动、无裸奔，恢复原样。
    // 0.4.47：拦截两圆钮 setFrame:，对齐后 y 钉死，杜绝 app 挪回原生位置闪跳
    HookWidgetSetFrame(@"WINDeviceInterconnectWidget", GCGapCar);
    HookWidgetSetFrame(@"WINAJXCombinedWidgetView", GCGapCapsule);
    // ---- 0.9.19（A3）：2D/3D（地图类型）圆钮 --------------------------------------
    // 本机实测类名 = WINPermanentCompassView（Amap 17.00.2，44x44，父类 MapWidgetContainerView）。
    // 真机 diag 铁证：App 只布局一次，且把它锚在**胶囊的冷启动瞬态位**(339,340) 上
    //   ⇒ 按钮被摆到 y=283（原生 536.7），与「胶囊顶 − 57.3」的原生关系刚好差 254pt。
    // 这里在它每次布局/上窗后立刻按「胶囊顶 − GCGapMapType」纠正，不必等 200ms 轮询；
    //   未定格期间由 AlignMapTypeButton 内部判空返回（绝不拿瞬态位当锚）。
    HookVoid(@"WINPermanentCompassView", @"layoutSubviews", ^(UIView *v) {
        AlignMapTypeButton(CachedRight);
    });
    HookVoid(@"WINPermanentCompassView", @"didMoveToWindow", ^(UIView *v) {
        AlignMapTypeButton(CachedRight);
    });
    // 0.5.19：拦截天气行 setFrame:，对齐后钉死到车机钮右边
    // 0.5.1：线路按钮原生 hid=1，setHidden: 强制 NO，app 再藏也压不住
    {
        Class rc = NSClassFromString(@"WINRouteLineWidgetView");
        SEL sh = @selector(setHidden:);
        Method sm = class_getInstanceMethod(rc, sh);
        if (sm) {
            IMP so = method_getImplementation(sm);
            Replace(rc, sh, imp_implementationWithBlock(^(UIView *self, __unused BOOL hidden) {
                ((void (*)(id, SEL, BOOL))so)(self, sh, NO);
            }), method_getTypeEncoding(sm));
        }
    }
    cls = NSClassFromString(@"WINAJXCombinedWidgetView");
    sel = @selector(setHidden:);
    method = class_getInstanceMethod(cls, sel);
    if (method) {
        IMP original = method_getImplementation(method);
        Replace(cls, sel, imp_implementationWithBlock(^(UIView *self, BOOL hidden) {
            // 0.9.14（A1 回退）：W1 系列的「未对齐拒绝显示」已全量移除。
            // 六轮复验 + 0.9.7 对照实证：拦截与 app 布局打仗是裸露根源，
            // 0.9.7「不干预 + AlignOneWidget 找到才搬」才是正确语义。
            // setHidden: 直通，只保留 IsHiddenMapPromo 强制隐藏。
            ((void (*)(id, SEL, BOOL))original)(self, sel, hidden || IsHiddenMapPromo(self));
        }), method_getTypeEncoding(method));
    }
    // 0.5.3：彻底去掉「重复点击首页」的所有触发链。
    // app 有两个注册入口（GDMapHomeTabBarControl / WINAmapHomeVAppService），
    // 两条都换成空 block（非 nil）；再把 item 自带的重复点击开关关掉，
    // 这样「已在首页再点首页」从注册层和 item 层同时被掐断。
    for (NSString *cn in @[@"GDMapHomeTabBarControl", @"WINAmapHomeVAppService"]) {
        Class tb = NSClassFromString(cn);
        if (!tb) continue;
        SEL selr = NSSelectorFromString(@"registerTabBarItemRepeatClickBlockWithKey:repeatBlock:");
        Method mr = class_getInstanceMethod(tb, selr);
        if (!mr) continue;
        IMP origr = method_getImplementation(mr);
        method_setImplementation(mr, imp_implementationWithBlock(^(id self, id key, __unused id blk) {
            void (^noop)(void) = ^{};
            ((void (*)(id, SEL, id, id))origr)(self, selr, key, noop);
        }));
    }
    // 注册顺序可能晚于此处，所以在每个 item 建好后同步清一次。
    // 0.9.8（A4）：这段原挂在 initWithFrame:model: 上，因签名不匹配从未执行；
    // 已并入上面的 WINTabBarItem -didMoveToWindow（见 InstallTabBarHintHooks）。
    HookVoid(@"WINTabBar", @"amap_relayoutTabItems", ^(UIView *bar) {
        // 0.6.7：这个 selector 在本文件被装了两次，而 Replace() 走
        // method_setImplementation —— 后装的那次会把先装的顶掉（CenterTabButtons 失效）。
        // 两条路径各自带上，谁后装都不丢功能。
        CachedTabBar = bar;
        CenterTabButtons(bar);
        SweepTabBarHints(bar);
        for (id item in (ObjectGetter(bar, @"tabBarItems") ?: @[])) {
            if (![item isKindOfClass:UIView.class]) continue;
            for (NSString *setter in @[@"setAllowRepeatClick:", @"setAmap_allowRepeatClick:"]) {
                SEL s = NSSelectorFromString(setter);
                if ([item respondsToSelector:s]) ((void (*)(id, SEL, BOOL))objc_msgSend)(item, s, NO);
            }
        }
    });
}

// ---------------------------------------------------------------------------
//  0.9.0：取消版本限制（应「取消版本限制」指令）
//  历史：0.7.5 硬匹配 17.00.2 → 0.8.0 白名单 {17.00.2, 17.01.0}
//  → 0.9.0 彻底移除版本判断，修复高德 17.01.1 升级后「失效」。
//  安全网改为运行时自适应：hook 目标不存在时各自静默跳过（HookVoid/Replace
//  内部均有存在性检查），未知版本照常安装全部可用钩子。
// ---------------------------------------------------------------------------

// 0.9.14-diag：真机事实采集模块（仅 -DGAODECLEAN_DIAG_LOG=1 时编译进去）
#ifdef GAODECLEAN_DIAG_LOG
#include "GCCDiag.h"
#endif

__attribute__((constructor)) static void Initialize(void) {
    @autoreleasepool {
        NSString *appVer = [NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"] ?: @"?";
        // ---- jibamao 个人标识：启动即打标（可在 Console / 崩溃日志中核对）----
        NSLog(@"[GaodeClean] %@", kGCSignature);
        NSLog(@"[GaodeClean] author=%@ section=%@ repo=%@ version=%@",
              kGCAuthor, kGCSection, kGCRepo, kGCVersion);
        NSLog(@"[GaodeClean] signature=%s", GaodeCleanSignature());

        if (![NSBundle.mainBundle.bundleIdentifier isEqualToString:@"com.autonavi.amap"]) return;
        NSLog(@"[GaodeClean] app version %@ - installing hooks (version limit removed)", appVer);
        AjxCache = [NSMutableDictionary dictionary];
        Pages = [NSHashTable weakObjectsHashTable];
        NearbyControllers = [NSHashTable weakObjectsHashTable];
        TabControllers = [NSHashTable weakObjectsHashTable];
        HomeHandlers = [NSHashTable weakObjectsHashTable];
        ColdWidgets = [NSHashTable weakObjectsHashTable];
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
            // 0.9.8（A3-4）：setViewControlParams: 是裸 objc_msgSend，方法被改名即崩。
            // 加存在性 + 签名（应为 void, 1 对象参数）。
            if (kept.count == 2) {
                SEL svp = NSSelectorFromString(@"setViewControlParams:");
                if ([tabs respondsToSelector:svp]) {
                    NSMethodSignature *sig = [tabs methodSignatureForSelector:svp];
                    if (sig.numberOfArguments == 3) {
                        ((void (*)(id, SEL, id))objc_msgSend)(tabs, svp, kept);
                    }
                }
            }
        });
        HookHitTest(UIView.class);
        HookHitTest(NSClassFromString(@"AJX3View"));
        Class registry = NSClassFromString(@"GDTabBarItemRegistry");
        SEL sel = NSSelectorFromString(@"registerTabProvider:");
        Method m = class_getInstanceMethod(registry, sel);
        if (m) {
            NSMethodSignature *s = [NSMethodSignature signatureWithObjCTypes:method_getTypeEncoding(m)];
            if (s.numberOfArguments == 3 && s.methodReturnType[0] == 'v' && [s getArgumentTypeAtIndex:2][0] == '#') {
                IMP original = method_getImplementation(m);
                IMP imp = imp_implementationWithBlock(^(id self, Class provider) {
                    if (![@[@"GDMainTabBarConfigProvider", @"GDMineTabBarConfigProvider"] containsObject:NSStringFromClass(provider) ?: @""]) {
                        GCLog(@"[GaodeClean] removed tab provider %@", NSStringFromClass(provider));
                        return;
                    }
                    ((void (*)(id, SEL, Class))original)(self, sel, provider);
                });
                Replace(registry, sel, imp, method_getTypeEncoding(m));
            }
        }
        HookVoid(@"AJXBaseElement", @"reloadView", ^(id e) { Capture(e); });
        // 0.9.8（A5）：这里原本是 @"layoutSubViews"（大写 V）—— ObjC/UIKit 惯例是
        // layoutSubviews（小写 v），自定义方法一律带 amap_ 前缀，所以这一行几乎可以
        // 断定从未命中过，是纯死代码。
        // **不能**改成 layoutSubviews：0.7.3 的实测结论就写在下面 —— 它在滚动动画里
        // 每帧触发，当事件源会让 fullClean 几乎每拍成立，把 0.7.2 的 CleanPage 降频
        // 整个抵消掉。删除即可，Capture 的事件源由 reloadView /
        // updateVoiceOverIDAndLabel / AJX3View-didMoveToWindow 三条承担。
        HookVoid(@"AJXBaseElement", @"updateVoiceOverIDAndLabel", ^(id e) { Capture(e); });
        // 0.7.3：layoutSubviews 在滚动动画里**每帧都触发**，把它当事件源会让
        // fullClean 几乎每拍成立 —— 0.7.2 的 CleanPage 降频实际上被它抵消了。
        // 只保留 didMoveToWindow（真正的页面挂载）。
        HookVoid(@"AJX3View", @"didMoveToWindow", ^(id page) {
            [Pages addObject:page]; CleanForce = YES; GCCActiveUntil = TickCount + 8; Schedule();
        });
        HookVoid(@"AJXWINNearbyViewControl", @"viewDidLoad", ^(id controller) { [NearbyControllers addObject:controller]; Schedule(); });
        HookVoid(@"WINTabBarControl", @"viewDidLoad", ^(id tabs) { [TabControllers addObject:tabs]; Schedule(); });
        // 0.7.4(A3)：前台立即恢复 200ms 节拍并立刻跑一拍；后台把节拍拉长到 2s。
        [NSNotificationCenter.defaultCenter addObserverForName:UIApplicationDidBecomeActiveNotification
                                                        object:nil queue:NSOperationQueue.mainQueue
                                                    usingBlock:^(__unused NSNotification *note) {
            GCCArmTick();
            Schedule();
        }];
        [NSNotificationCenter.defaultCenter addObserverForName:UIApplicationDidEnterBackgroundNotification
                                                        object:nil queue:NSOperationQueue.mainQueue
                                                    usingBlock:^(__unused NSNotification *note) {
            GCCArmTick();
        }];
        // 0.9.8（A15）：SearchBarSettled 原来**只置 YES、从不复位** —— 横竖屏切换 /
        // 分屏 / 窗口尺寸变化后，HookWidgetSetFrame 里的 targetBottom 仍然是旧坐标，
        // 搜索栏与两个圆钮整片错位，直到杀进程。方向变化时清掉首帧锁定，
        // 让下一拍 LayoutMinimalHome 按新宽度重算。
        // 该通知在 iOS 13 起标记废弃（推荐 viewWillTransitionToSize:），但对全屏单窗口
        // 的 App 仍会正常发送，且不依赖任何 VC 层级 —— 对本插件最稳。与 GCAllWindows
        // 一样在本处集中 suppress，保持全文件 0 警告基线。
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
        [NSNotificationCenter.defaultCenter addObserverForName:UIApplicationDidChangeStatusBarOrientationNotification
                                                        object:nil queue:NSOperationQueue.mainQueue
                                                    usingBlock:^(__unused NSNotification *note) {
            SearchBarSettled = NO;
            SearchBarSettledY = 0;
            BarStableTicks = 0;
            BarLastY = -1;      // 0.9.15：稳定性基线一并清掉，下一拍按新宽度重新计数
            CachedCar = nil;
            CachedRight = nil;
            CachedRoute = nil;
        }];
#pragma clang diagnostic pop
        // Recheck after asynchronous cards and cell reuse; only attached target pages are scanned.
        dispatch_async(dispatch_get_main_queue(), ^{
            Schedule();
            // 0.4.44：GCD 计时器（模式无关，比 NSTimer 更可靠；NSTimer 在 1.4s 后曾停止）
            // 0.7.4(A3)：改为 GCCArmTick() 整备，节拍随前台/后台自动切换
            GCCArmTick();
        });
        NSLog(@"[GaodeClean] loaded %@ (no version limit; appVer=%@)", kGCVersion, appVer);
#ifdef GAODECLEAN_DIAG_LOG
        GCDiagInstall();
#endif
    }
}
