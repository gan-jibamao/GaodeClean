#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import "GCCGeometry.h"

// This tweak changes UI only. No network interception or modification of the IPA.
static char TextKey, StateKey, LimitKey, ForcedKindKey, ForcedPathKey;
static NSHashTable<UIView *> *Pages;
static NSHashTable *NearbyControllers;
static NSHashTable *TabControllers;
static NSHashTable *HomeHandlers;
static BOOL LayingOutHome;
static BOOL Scheduled, Applying, Cleaning;
static CGFloat SearchBarSettledY;
static BOOL SearchBarSettled;
static NSInteger BarStableTicks;
static BOOL HomeSettled;
static NSHashTable<UIView *> *ColdWidgets;
static NSInteger ColdTicks;
static char AlignedKey;
static dispatch_source_t ScheduleTimer;
static __weak UIView *BarParent;
static __weak UIView *CachedCar, *CachedRight, *CachedRoute;
static __weak id CachedTabs;
static __weak UIView *SearchBarView;   // 0.5.58   // 0.5.55：用于判断当前是否「首页」选中
static void UpdateMask(UIView *page);
static void Schedule(void);
static void LayoutMinimalHome(id handler);
static void AlignCornerWidgets(UIView *bar);
static void AlignWeatherRowTick(UIWindow *win);
static void AlignSearchBarTick(id handler);
static BOOL IsWeatherRowView(UIView *v);
static void AlignOneWidget(UIView *bar, UIView *w, CGFloat barTop);

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
    NSData *data = [NSJSONSerialization dataWithJSONObject:@{@"version": @"0.5.1", @"pages": records} options:NSJSONWritingPrettyPrinted error:nil];
    NSURL *documents = [NSFileManager.defaultManager URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask].firstObject;
    if (data && documents) [data writeToURL:[documents URLByAppendingPathComponent:@"GaodeClean-diagnostics.json"] options:NSDataWritingAtomic error:nil];
}

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
            NSDictionary *cached = [NSUserDefaults.standardUserDefaults dictionaryForKey:@"GaodeClean.MineBoundary.17.00.2"];
            if (!cached) {
                NSString *dir = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
                NSData *data = [NSData dataWithContentsOfFile:[dir stringByAppendingPathComponent:@"GaodeClean-diagnostics.json"]];
                NSDictionary *report = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
                NSDictionary *mine = report[@"pages"][@"3"];
                if ([@[@"0.3.0", @"0.3.1", @"0.4.0", @"0.4.32", @"0.4.33", @"0.4.34", @"0.4.35", @"0.4.36", @"0.4.37", @"0.4.38", @"0.4.39", @"0.4.40", @"0.4.41", @"0.4.42", @"0.4.43", @"0.4.44", @"0.4.45", @"0.4.46", @"0.4.47", @"0.4.48", @"0.4.49", @"0.4.50", @"0.5.0", @"0.5.1"] containsObject:report[@"version"] ?: @""] && [mine[@"matched"] boolValue]) {
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
            NSLog(@"[GaodeClean] page=%ld anchor=pending", (long)kind);
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
    if (kind == 3 && boundary > 100 && boundary < page.bounds.size.height) {
        NSDictionary *cached = [NSUserDefaults.standardUserDefaults dictionaryForKey:@"GaodeClean.MineBoundary.17.00.2"];
        if (fabs([cached[@"bottom"] doubleValue] - boundary) > 0.5 || fabs([cached[@"width"] doubleValue] - page.bounds.size.width) > 0.5)
            [NSUserDefaults.standardUserDefaults setObject:@{@"width":@(page.bounds.size.width), @"bottom":@(boundary)} forKey:@"GaodeClean.MineBoundary.17.00.2"];
    }
    BindBoundary(page, anchor, peer, boundary, state);
    if (!state.reportedMatch) {
        NSLog(@"[GaodeClean] page=%ld anchor=matched limitedScrolls=%lu", (long)kind, (unsigned long)state.scrolls.count);
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
        if (UIApplication.sharedApplication.applicationState != UIApplicationStateActive) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 100 * NSEC_PER_MSEC),
                           dispatch_get_main_queue(), ^{ Schedule(); });
            return;
        }
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
        // 0.4.41 冷启动兜底：定位超时(约 2.4s)仍未完成则强制显示，避免卡在隐藏态
        ColdTicks++;
        if (!HomeSettled && ColdTicks > 12) {
            HomeSettled = YES;
            for (UIView *w in ColdWidgets.allObjects) {
                if ([w isKindOfClass:UIView.class]) {
                    objc_setAssociatedObject(w, &AlignedKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                    w.hidden = NO;
                }
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
            AlignSearchBarTick(handler);
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
    if (Kind(page) == 3 && !Cleaning) { Cleaning = YES; CleanPage(page); Cleaning = NO; }
    Schedule();
}

// Install on a class's own method table, preserving inherited implementations.
static void Replace(Class cls, SEL sel, IMP replacement, const char *types) {
    if (!class_addMethod(cls, sel, replacement, types))
        method_setImplementation(class_getInstanceMethod(cls, sel), replacement);
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

// 0.5.34：底栏上滑时出现的全屏白雾 = WINMapMaskView（393x852 全屏蒙版）
// + AUGlobalBlurService（往屏幕加模糊层的全局服务）。
// 实测该层 alpha 从 0 渐涨到 0.84 后常驻，把整张地图蒙白。
// 这里从三个入口封死：setHidden: / setAlpha: / addBlurViewToScreen。
static BOOL IsBlurOverlayView(UIView *v) {
    if (!v) return NO;
    return [NSStringFromClass(v.class) isEqualToString:@"WINMapMaskView"];
}


static NSString *GCCColorStr(CGColorRef cg) {
    if (!cg) return @"-";
    size_t n = CGColorGetNumberOfComponents(cg);
    const CGFloat *c = CGColorGetComponents(cg);
    if (n == 2) return [NSString stringWithFormat:@"gray%.2f/a%.2f", c[0], c[1]];
    if (n == 4) return [NSString stringWithFormat:@"rgba%.2f,%.2f,%.2f,%.2f", c[0], c[1], c[2], c[3]];
    return [NSString stringWithFormat:@"%zucomp", n];
}



// 判定：半透明白色（白雾的特征——不透明白会把地图整个盖死，
// 纯透明的又不显形）。只对这一类出手，避免误伤正常 UI。
// 把窗口渲染到一张小灰度图上，返回「地图区」的平均亮度。
// 白雾正在生效时这个值会接近 250；正常地图约 220-230。这样文件能自证抓取时机。
// 把窗口截图到一张 39x85 的 sRGB 位图上，返回「地图区」的平均亮度。
// 用它来自证：抓取的那一刻白雾在不在（正常地图 ~200-235，被压白 ~245+）。
static CGFloat GCCScreenMapMean(UIWindow *w) {
    const size_t W = 39, H = 85;
    unsigned char *buf = calloc(W * H * 4, 1);
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGContextRef c = CGBitmapContextCreate(buf, W, H, 8, W * 4, cs,
                                           kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
    CGColorSpaceRelease(cs);
    if (!c) { free(buf); return -1; }
    CGFloat px = w.bounds.size.width > 0 ? (CGFloat)W / w.bounds.size.width : 1;
    CGContextScaleCTM(c, px * (w.bounds.size.width > 0 ? 1 : 1), px);
    UIGraphicsPushContext(c);
    [w drawViewHierarchyInRect:CGRectMake(0, 0, w.bounds.size.width, w.bounds.size.height)
           afterScreenUpdates:NO];
    UIGraphicsPopContext();
    CGContextRelease(c);
    double sum = 0; int n = 0;
    for (size_t y = 20; y < 56; y++)
        for (size_t x = 2; x < 37; x++) {
            size_t o = (y * W + x) * 4;
            sum += (buf[o] + buf[o + 1] + buf[o + 2]) / 3.0; n++;
        }
    free(buf);
    return n ? (CGFloat)(sum / n) : -1;
}

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

static NSMutableArray *SweepLog = nil;

// 每 300ms 扫一次：找出「覆盖 ≥70% 窗口的半透明白色视图」并压掉。


// 0.5.46：上拉闪白的真凶是 AMapUIWaterFallContentSlidableView 的
// headerPanGestureRecognizer / mockPanGestureRecognizer —— 手势不在类本体上，
// 所以拦 addGestureRecognizer: 拦不住。这里精准摘除这两个手势（不动搜索栏）。
static void StripSlidablePan(void) {
    Class sv = NSClassFromString(@"AMapUIWaterFallContentSlidableView");
    if (!sv) return;
    for (UIWindow *w in UIApplication.sharedApplication.windows) {
        if (w.hidden) continue;
        NSMutableArray *q = [NSMutableArray arrayWithObject:w];
        for (NSUInteger i = 0; i < q.count && q.count < 6000; i++) {
            UIView *v = q[i];
            for (UIView *sub in v.subviews) [q addObject:sub];
            if (![v isKindOfClass:sv]) continue;
            for (NSString *prop in @[@"headerPanGestureRecognizer", @"mockPanGestureRecognizer"]) {
                id g = ObjectGetter(v, prop);
                if (![g isKindOfClass:UIGestureRecognizer.class]) continue;
                UIView *gv = ((UIGestureRecognizer *)g).view;
                if (gv) [gv removeGestureRecognizer:g];
                [v setValue:nil forKey:prop];
            }
            for (UIGestureRecognizer *g in [v.gestureRecognizers copy])
                if ([g isKindOfClass:UIPanGestureRecognizer.class]) [v removeGestureRecognizer:g];
        }
    }
}
static void SweepFogOverlay(void) {
    for (UIWindow *w in UIApplication.sharedApplication.windows) {
        if (w.hidden || w.alpha < 0.02) continue;
        CGRect wb = w.bounds;
        NSMutableArray *q = [NSMutableArray arrayWithObject:w];
        for (NSUInteger i = 0; i < q.count && q.count < 6000; i++) {
            UIView *v = q[i];
            for (UIView *sub in v.subviews) [q addObject:sub];
            if (v == w || v.hidden || v.alpha < 0.02) continue;
            CGRect f = [v convertRect:v.bounds toView:w];
            if (f.size.width < wb.size.width * 0.50 || f.size.height < wb.size.height * 0.50) continue;
            CGFloat a = 0;
            if (!GCCIsWhiteVeil(v, &a)) continue;
            if (SweepLog) {
                [SweepLog addObject:[NSString stringWithFormat:@"%@ {{%.0f,%.0f},{%.0f,%.0f}} a=%.2f 父=%@",
                    NSStringFromClass(v.class), f.origin.x, f.origin.y, f.size.width, f.size.height, a,
                    NSStringFromClass(v.superview.class)]];
            }
            NSLog(@"[GaodeClean] fog sweep hides %@ a=%.2f", NSStringFromClass(v.class), a);
            v.hidden = YES;
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
    HookVoid(@"AUGlobalBlurService", @"addBlurViewToScreen", ^(id s) { [[s valueForKey:@"maskViews"] makeObjectsPerformSelector:@selector(removeFromSuperview)]; });
    HookVoid(@"AUGlobalBlurService", @"startService", ^(id s) { ((void (*)(id, SEL))objc_msgSend)(s, NSSelectorFromString(@"clearBlurViews")); });
    // 根因入口：底栏上滑 → WINViewControl showMapMaskView → 亮起全屏白色蒙版。
    // 二进制实测签名：showMapMaskView B16@0:8（返回 BOOL！）、resetMapMaskView v16@0:8、
    // setShowMapMaskView: v20@0:8B16。showMapMaskView 必须返回 NO 才算拒绝，
    // 早先按 "void" 判断会直接跳过它 —— 拦截落空的坑。
    {
        Class vc = NSClassFromString(@"WINViewControl");
        SEL sl = NSSelectorFromString(@"showMapMaskView");
        Method mm = class_getInstanceMethod(vc, sl);
        if (mm) Replace(vc, sl, imp_implementationWithBlock(^(id self) { return NO; }),
                        method_getTypeEncoding(mm));
        SEL rl = NSSelectorFromString(@"resetMapMaskView");
        Method rm = class_getInstanceMethod(vc, rl);
        if (rm) Replace(vc, rl, imp_implementationWithBlock(^(id self) {}),
                        method_getTypeEncoding(rm));
        SEL sl2 = NSSelectorFromString(@"setShowMapMaskView:");
        Method mm2 = class_getInstanceMethod(vc, sl2);
        if (mm2) Replace(vc, sl2, imp_implementationWithBlock(^(id self, __unused BOOL on) {}),
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
    static dispatch_source_t actionTimer = nil;
    if (!actionTimer) {
        actionTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
        dispatch_source_set_timer(actionTimer, dispatch_time(DISPATCH_TIME_NOW, 300 * NSEC_PER_MSEC),
                                  300 * NSEC_PER_MSEC, 100 * NSEC_PER_MSEC);
        dispatch_source_set_event_handler(actionTimer, ^{
            if (!SweepLog) SweepLog = [NSMutableArray array];
            SweepFogOverlay();
            StripSlidablePan();
        });
        dispatch_resume(actionTimer);
    }
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
    for (NSString *getter in @[@"iconImageName", @"accessibilityLabel"]) {
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

// ===== 0.6.14d 诊断：记录「谁」在改天气行的位置 =====
// 0.6.13d 的链式 dump 已给出结论：L1..L9 祖先全部 m==p、transform 恒等、无动画；
// 只有 L0 自己分叉，且**所有渲染点精确落在 (10,352)↔(62,603) 这条直线上**
// （8 个采样点代入 y = 352 + 4.827(x-10)，误差全在 ±0.3pt）。
//   (10,352) 子视图坐标 = (10,411) 窗口坐标 = app 原生位置（与冷启动日志一致）
//   (62,603) 子视图坐标 = (62,662) 窗口坐标 = 我的对齐位置
// 即：这一行正在两点之间做直线位移动画。
// 现在必须确定：**是哪一方发起的写入**。所以直接 hook 二传手本身。
// 0.6.18 定版：诊断输出已摘除（RDLog/g_rdbuf/WinY/KeysOf）。
static int g_inMine = 0;                     // >0 表示我方正在写入（防递归）

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
    CGPoint wantWin = CGPointMake(CGRectGetMaxX(carRect) + 8,
                                  CGRectGetMidY(carRect) - row.bounds.size.height * 0.5);
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
        g_inMine++;
        [CATransaction begin];
        [CATransaction setDisableActions:YES];
        if (big) [row.layer removeAllAnimations];
        row.center = wantCenter;
        [CATransaction commit];
        g_inMine--;
    }
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
    return [cn isEqualToString:@"WINGroupMapWidget"]
        || [cn isEqualToString:@"WINScaleLineLogoMapWidget"]
        || [cn isEqualToString:@"WINWeatherLimitView"];
}

static BOOL IsWeatherRowView(UIView *v) {
    if (!v || !v.window || !v.superview) return NO;
    CGRect r = [v convertRect:v.bounds toView:v.window];
    if (r.size.width < 150 || r.size.width > 360 || r.size.height >= 40) return NO;
    if (r.origin.y < 60 || r.origin.y > v.window.bounds.size.height - 40) return NO;
    return YES;
}

// 0.6.8-①：顶部运营横幅「来领十一出行补贴啦」—— AUPopFloatView
// （有 initWithLeftIcon:text: / initWithStyle:leftIcon:text: / dismiss:，就是「左图标 + 文字 + ✕」那条）。
// 按特征识别后隐藏：宽 ≥ 70% 窗口、位于屏幕上半部、高度 20–100pt。
// 不用类名一刀切 —— AUPopFloatView 可能是通用组件，别的地方也在用。
static BOOL IsTopSubsidyBanner(UIView *v) {
    if (!v || !v.window) return NO;
    CGRect r = [v convertRect:v.bounds toView:v.window];
    CGFloat W = v.window.bounds.size.width;
    return (r.size.width >= W * 0.7 && r.origin.y < 200
            && r.size.height > 20 && r.size.height < 100);
}

static void HookSubsidyBanner(void) {
    if (!NSClassFromString(@"AUPopFloatView")) return;
    void (^hide)(UIView *) = ^(UIView *v) {
        if (IsTopSubsidyBanner(v) && !v.hidden) v.hidden = YES;
    };
    HookVoid(@"AUPopFloatView", @"didMoveToWindow", hide);
    HookVoid(@"AUPopFloatView", @"layoutSubviews", hide);
    // 拒绝被重新显示
    {
        Class c = NSClassFromString(@"AUPopFloatView");
        Method m = c ? class_getInstanceMethod(c, @selector(setHidden:)) : NULL;
        if (m) {
            IMP o = method_getImplementation(m);
            const char *t = method_getTypeEncoding(m);
            Replace(c, @selector(setHidden:), imp_implementationWithBlock(^(UIView *self, BOOL h) {
                if (h == NO && IsTopSubsidyBanner(self)) h = YES;
                ((void (*)(id, SEL, BOOL))o)(self, @selector(setHidden:), h);
            }), t);
        }
    }
}

// 0.6.8-②：切 2D/3D 时天气行会**整个消失约 100ms**（逐帧：f356 在 → f366/f376 无 → f386 回来，
// 位置始终 pt 88–150 不变）。若 app 是「隐藏」它就拒绝隐藏；若是移除实例则保不住，靠诊断确认。
// 0.6.9：**决定性的做法**。
// 前面所有版本都是「事后纠正」：app 动完，我在下一次 tick（或 layout）时修正。
// 但切 2D/3D 时这一行会被**整个移除**（不只 hidden），移除与重挂之间的那段空档
// 任何事后修正都够不着 —— 这就是「始终有问题」的原因。
// 换成搜索栏当初的成功模式（0.4.50）：**在 didMoveToSuperview 里同一帧挂回**。
//   · superview != nil → 新实例/重挂，立刻对齐并记住
//   · superview == nil → 被摘掉，若是首页且冷启动已结束，立刻挂回原父视图
// 因为发生在 didMoveToSuperview 内（主线程、渲染前），那一帧就不会显示空档。
static __weak UIView *KeepRow;
static __weak UIView *KeepRowParent;

static void HookWeatherRowKeep(void) {
    for (NSString *n in @[@"WINGroupMapWidget", @"WINScaleLineLogoMapWidget"]) {
        Class c = NSClassFromString(n);
        if (!c) continue;
        HookVoid(n, @"didMoveToWindow", ^(UIView *v) {
            if (IsWeatherRowView(v)) { KeepRow = v; KeepRowParent = v.superview; AlignWeatherRow(v); }
        });
        HookVoid(n, @"didMoveToSuperview", ^(UIView *v) {
            if (v.superview != nil) {
                if (IsWeatherRowView(v)) { KeepRow = v; KeepRowParent = v.superview; AlignWeatherRow(v); }
                return;
            }
            // ---- 被摘掉：同一帧挂回 ----
            if (v != KeepRow) return;
            if (ColdTicks < 15) return;                       // 冷启动交给原逻辑
            if (CachedTabs) {                                  // 只在首页管
                id sel = ObjectGetter(CachedTabs, @"selectedViewControl");
                if (sel && ![NSStringFromClass([sel class]) isEqualToString:@"WINAmapHomeControl"]) return;
            }
            UIView *par = KeepRowParent;
            if (!par || !par.window) return;
            [par addSubview:v];
            AlignWeatherRow(v);
        });
    }
}

static void HookWeatherRowHideGuard(void) {
    for (NSString *n in @[@"WINGroupMapWidget", @"WINScaleLineLogoMapWidget"]) {
        Class c = NSClassFromString(n);
        Method m = c ? class_getInstanceMethod(c, @selector(setHidden:)) : NULL;
        if (!m) continue;
        IMP o = method_getImplementation(m);
        const char *t = method_getTypeEncoding(m);
        Replace(c, @selector(setHidden:), imp_implementationWithBlock(^(UIView *self, BOOL h) {
            if (h && IsWeatherRowView(self)) h = NO;
            ((void (*)(id, SEL, BOOL))o)(self, @selector(setHidden:), h);
        }), t);
    }
}


// ===== 0.6.15：在源头拦截，不让 app 把行写回原生位 =====
//
// 0.6.14d 抓包给出完整因果链（19 次完全一致）：
//   1790821924.468 APP setFrame (10.0,352.0,188.0,20.0) 父系winY=411.0 keys=无
//   1790821924.469 APP LAYER+anim CABasicAnimation key=position dur=0.20   ← ①的隐式动画
//   1790821924.652 ALIGN 修正 center(104.0,362.0)→(156.0,613.0) keys前置=position
//   1790821924.658 MY  setCenter (156.0,613.0) ... keys=无
// 即：**app 在切 2D/3D 时于 UIView 动画块内把行 setFrame 回原生位 (10,352)，
//      UIKit 自动生成 0.20s 的 position 动画；我的 tick 最快也要 100ms 后才拉回。**
// 我方每一笔写入 keys 都是「无」，全程没有一条 MY LAYER+anim —— 动画不是我们加的。
// 9 版没修好，是因为一直在「事后拉回」，而正确做法是「不让它写进去」。
//
// 本版：hook setFrame:/setCenter: —— 在调用发生的**那一瞬间**把入参换成正确坐标，
// 并在禁动画事务内写入（外加 removeAllAnimations 兜底）。app 从此写不进原生位，
// 0 帧位移、0 条动画。
static CGPoint WeatherRowDesiredCenter(UIView *row) {
    UIView *car = CachedCar;
    if (!row || !row.window || !row.superview || !car || !car.window) return CGPointMake(NAN, NAN);
    if (row.bounds.size.width <= 0 || row.bounds.size.height <= 0) return CGPointMake(NAN, NAN);
    CGRect carRect = [car convertRect:car.bounds toView:row.window];
    CGPoint wantWin = CGPointMake(CGRectGetMaxX(carRect) + 8,
                                  CGRectGetMidY(carRect) - row.bounds.size.height * 0.5);
    CGPoint p = [row.superview convertPoint:wantWin fromView:row.window];
    return CGPointMake(p.x + row.bounds.size.width * 0.5, p.y + row.bounds.size.height * 0.5);
}

static void HookRowSetters(void) {
    // ===== 0.6.18：唯一正确的形态 ——「原样调用 + 同回合覆盖」=====
    // 教训链（三版才走对）：
    //  0.6.15 吞掉 app 的写入、换成自己的坐标 → **天气控件消失**。
    //         机制：在布局流程中间改写子件坐标，app 量到异常值，布局循环没走完，
    //         容器 WINGroupMapWidget 就没被建出来（天气控件是它的子件）。
    //  0.6.16d 改成「先原样、再立刻覆盖」→ 拦截生效但对象判据仍偏窄。
    //  0.6.18 关键修正：**挂到三个类上**。日志证明 app 写的是子件
    //         WINScaleLineLogoMapWidget，而 0.6.2 那段老钩子只挂了 WINGroupMapWidget。
    // 另注：HookWeatherRow 开头的历史注释写着 0.5.39 因同样原因撤掉过 setFrame 拦截
    //      （「在 app 每一次写入时重排布局 → 地图背板被截成空白」）。这次不再重蹈：
    //      **不吞写入、不重排，只在其后覆盖一个坐标**。
    NSArray *names = @[@"WINGroupMapWidget", @"WINScaleLineLogoMapWidget", @"WINWeatherLimitView"];
    for (NSString *n in names) {
        Class cls = NSClassFromString(n);
        if (!cls) continue;
        {   // ---- setFrame: ----
            Method m = class_getInstanceMethod(cls, @selector(setFrame:));
            if (m) {
                IMP o = method_getImplementation(m); const char *te = method_getTypeEncoding(m);
                Replace(cls, @selector(setFrame:), imp_implementationWithBlock(^(UIView *self, CGRect r) {
                    ((void (*)(id, SEL, CGRect))o)(self, @selector(setFrame:), r);       // ① 原样
                    if (g_inMine <= 0 && IsWeatherRowView(self))
                        AlignWeatherRow(self);                                          // ② 同回合覆盖
                }), te);
            }
        }
        {   // ---- setCenter: ----
            Method m = class_getInstanceMethod(cls, @selector(setCenter:));
            if (m) {
                IMP o = method_getImplementation(m); const char *te = method_getTypeEncoding(m);
                Replace(cls, @selector(setCenter:), imp_implementationWithBlock(^(UIView *self, CGPoint p2) {
                    ((void (*)(id, SEL, CGPoint))o)(self, @selector(setCenter:), p2);    // ① 原样
                    if (g_inMine <= 0 && IsWeatherRowView(self)) AlignWeatherRow(self);  // ② 覆盖
                }), te);
            }
        }
    }
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
    if (!home) { bar.hidden = YES; return; }
    UIView *tabBar = ObjectGetter(tabs, @"tabBar");
    UIView *parent = sheet.superview;
    if (!parent.window || ![tabBar isKindOfClass:UIView.class]) return;
    BarParent = parent;
    LayingOutHome = YES;
    if (bar.superview != parent) [parent addSubview:bar];
    // 0.5.9：恢复隐藏「上拉发现」容器（sheet）与其遮罩。
    // 0.5.1 曾移除这三行，结果面板的白底永久露出（跨版本实测：0.5.0 无白块，
    // 0.5.7/0.5.8 每帧都在 544-682pt 出现纯白块）。搜索栏已挂到 parent
    // 并在 sheet 之外，隐藏 sheet 不会影响它（0.5.0 即如此工作）。
    sheet.hidden = YES;
    UIView *mask = ObjectGetter(handler, @"maskView");
    if ([mask isKindOfClass:UIView.class]) mask.hidden = YES;
    CALayer *bottomMask = ObjectGetter(handler, @"bottomMaskLayer");
    if ([bottomMask isKindOfClass:CALayer.class]) bottomMask.hidden = YES;
    CGRect tabFrame = [tabBar convertRect:tabBar.bounds toView:parent];
    CGFloat height = MAX(50, MIN(64, bar.bounds.size.height));
    bar.frame = CGRectMake(0, MAX(0, tabFrame.origin.y - height - 12), parent.bounds.size.width, height);
    [parent bringSubviewToFront:bar];
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
        // 0.6.1：缓存失效条件加上「尺寸不再匹配」—— 切 2D/3D 后 app 换掉的是实例，
        // 旧实例的 window 可能还在，原本的 !CachedRow.window 判据抓不到，缓存会一直指着旧的。
        BOOL rowStale = (!CachedRow || !CachedRow.window);
        if (!rowStale && win) {
            CGRect r0 = [CachedRow convertRect:CachedRow.bounds toView:win];
            if (r0.size.width < 150 || r0.size.width > 360 || r0.size.height >= 40) rowStale = YES;
        }
        if (win && rowStale) {
            NSMutableArray *q = [NSMutableArray arrayWithObject:win];
            for (NSUInteger qi = 0; qi < q.count && q.count < 20000; qi++) {
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
    // ===== 0.4.19 首帧锁定：缓存最终 y，state 机/原生布局再拉也立即弹回
    if (!SearchBarSettled) {
        SearchBarSettledY = bar.frame.origin.y;
        SearchBarSettled = YES;
    }
    // 0.4.45：连续稳定 3 轮(~0.6s)后才显示，避免 app 中途把搜索栏拉回原生(447)造成闪跳
    if (fabs(bar.frame.origin.y - SearchBarSettledY) < 0.5) BarStableTicks++;
    else BarStableTicks = 0;
    bar.hidden = (BarStableTicks < 3 && ColdTicks < 15);
    LayingOutHome = NO;
    AlignCornerWidgets(bar);
}

// 0.5.57：切页时 app 会把搜索栏从父视图摘掉，而归位只发生在 LayoutMinimalHome 里 ——
// 它由 100ms 的 tick 驱动。逐帧实测缺席时长恰好是 16.7ms 的整数倍(17/33/67/83/100ms)，
// 就是在「等下一次 tick」。这里加一段 16ms 的快修窗口：搜索栏被动到的瞬间启动，
// 640ms 内以 60Hz 反复跑 LayoutMinimalHome，把缺席从「最多 100ms」压到「最多 1 帧」。
static dispatch_source_t BarFixTimer;
static int BarFixTicks;
// 0.6.7：**搜索栏缺席 267ms/150ms 的真因** —— 和 0.6.6 的天气行同源。
// LayoutMinimalHome 开头有一串早退：
//     if (![bar isKindOfClass:UIView.class] || ![sheet isKindOfClass:UIView.class]
//         || !sheet.superview) return;
// 切页转场期间 sheet.superview 为 nil → 整个函数早退 → **里面所有搜索栏归位代码都不执行**。
// 而 KickBarFix 快修窗口也只是反复调 LayoutMinimalHome，跟着一起早退，所以 8ms 快修也没用。
// （tick 本身没断 —— ScheduleTimer 200ms 兜底在跑，代码里查得到。）
// 修法：把搜索栏的「挂回 + 显示 + 定位」从 LayoutMinimalHome 里独立出来，
// 与车机钮/天气行同一条 tick 路径，不再受那串早退连累。
static void AlignSearchBarTick(id handler) {
    if (!SearchBarSettled || ColdTicks < 15) return;
    UIView *bar = ObjectGetter(handler, @"searchBar");
    if (![bar isKindOfClass:UIView.class] || !bar.window) return;
    id tabs = ObjectGetter(handler, @"tabBarControl");
    id sel = tabs ? ObjectGetter(tabs, @"selectedViewControl") : nil;
    if (sel && ![NSStringFromClass([sel class]) isEqualToString:@"WINAmapHomeControl"]) return;   // 只在首页管
    if (!BarParent || !BarParent.window) return;
    if (bar.superview != BarParent) [BarParent addSubview:bar];
    if (bar.hidden) bar.hidden = NO;
    CGRect f = bar.frame;
    if (fabs(f.origin.y - SearchBarSettledY) > 1.0) {
        f.origin.y = SearchBarSettledY;
        [CATransaction begin];
        [CATransaction setDisableActions:YES];
        bar.frame = f;
        [CATransaction commit];
    }
    [BarParent bringSubviewToFront:bar];
}

static void KickBarFix(void) {
    BarFixTicks = 80;                       // 80 × 8ms ≈ 640ms
    if (BarFixTimer) return;
    BarFixTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    dispatch_source_set_timer(BarFixTimer, dispatch_time(DISPATCH_TIME_NOW, 0),
                              8ull * NSEC_PER_MSEC, 2ull * NSEC_PER_MSEC);
    dispatch_source_set_event_handler(BarFixTimer, ^{
        if (BarFixTicks <= 0) { dispatch_source_cancel(BarFixTimer); BarFixTimer = nil; return; }
        BarFixTicks--;
        for (id h in HomeHandlers.allObjects) {
            LayoutMinimalHome(h);
            AlignSearchBarTick(h);          // 0.6.7：不依赖 LayoutMinimalHome 是否早退
        }
    });
    dispatch_resume(BarFixTimer);
}

static BOOL IsRightBottomWidget(UIView *v) {
    if (![NSStringFromClass(v.class) isEqualToString:@"WINAJXCombinedWidgetView"]) return NO;
    id tag = ObjectGetter(v, @"getItemTag");
    if (![tag isKindOfClass:NSString.class]) return NO;
    NSString *t = [(NSString *)tag lowercaseString];
    return [t containsString:@"rightbottom"] || [t containsString:@"locate"] || [t containsString:@"location"];
}

static void AlignOneWidget(UIView *bar, UIView *w, CGFloat barTop) {
    if (!w.window) return;
    UIWindow *win = bar.window;
    CGRect r = [w convertRect:w.bounds toView:win];
    // 0.5.1：改底边对齐——不管 44/88 高，底边都贴在搜索框上方 8pt
    CGFloat targetBottom = barTop - 8;
    if (fabs(CGRectGetMaxY(r) - targetBottom) >= 1) {
        CGRect f = w.frame;
        f.origin.y += (targetBottom - CGRectGetMaxY(r));
        w.frame = f;
    }
    // 逐 widget 对齐标记：对齐过才显示，避免冷启动在原生位置(如 {0,0})闪现
    objc_setAssociatedObject(w, &AlignedKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (w.hidden) w.hidden = NO;
    HomeSettled = YES;
}


// 0.6.3：冷启动后天气行停在 app 原生位置（{{10,411}}），要切一次页才归位。
// 原因：天气行的对齐寄生在 LayoutMinimalHome 里，而它有一串早退条件
// （sheet 未就绪 / parent 无 window / tabBar 不是 UIView）—— 冷启动期间就直接 return 了，
// 后面那段天气行代码永远跑不到；而这一行之后是静态的，layoutSubviews 也不再触发。
// 修法：把它移出来，并入周期 tick（与车机钮同一条路径），并在冷启动头 2 秒加 8ms 快窗。
static void AlignWeatherRowTick(UIWindow *win) {
    if (!win) return;
    static __weak UIView *Row = nil;
    BOOL stale = (!Row || !Row.window);
    if (!stale) {
        CGRect r0 = [Row convertRect:Row.bounds toView:win];
        if (r0.size.width < 150 || r0.size.width > 360 || r0.size.height >= 40) stale = YES;
    }
    if (stale) {
        NSMutableArray *q = [NSMutableArray arrayWithObject:win];
        for (NSUInteger i = 0; i < q.count && q.count < 20000; i++) {
            UIView *v = q[i];
            [q addObjectsFromArray:v.subviews];
            if (IsWeatherRowClass(NSStringFromClass(v.class)) && IsWeatherRowView(v)) {
                // 优先外层容器（WINGroupMapWidget 存在时它就是整行）；
                // 否则取最宽的那个候选（冷启动时是 WINScaleLineLogoMapWidget，188pt）
                if (!Row || [NSStringFromClass(v.class) isEqualToString:@"WINGroupMapWidget"]
                    || v.bounds.size.width > Row.bounds.size.width) Row = v;
                if ([NSStringFromClass(v.class) isEqualToString:@"WINGroupMapWidget"]) break;
            }
        }
    }
    if (!Row || !IsWeatherRowView(Row) || Row.hidden) return;
    KeepRow = Row;                          // 0.6.9：记住有效实例与父视图
    KeepRowParent = Row.superview;
    AlignWeatherRow(Row);
}

static void AlignCornerWidgets(UIView *bar) {
    if (!bar.window) return;
    UIWindow *win = bar.window;
    CGFloat barTop = [bar convertPoint:CGPointZero toView:win].y;
    if (barTop < 40) return;                                 // 搜索框尚未就位（0.4.6: 80→40）

    // 0.5.0：缓存圆钮实例，每轮直接对齐，只有实例失效时才重扫窗口树
    if (!CachedCar || !CachedCar.window) CachedCar = nil;
    if (!CachedRight || !CachedRight.window) CachedRight = nil;
    if (!CachedRoute || !CachedRoute.window) CachedRoute = nil;
    if (!CachedCar || !CachedRight || !CachedRoute) {
        NSMutableArray<UIView *> *queue = [NSMutableArray arrayWithObject:win];
        for (NSUInteger i = 0; i < queue.count && queue.count < 20000; i++) {
            UIView *v = queue[i];
            [queue addObjectsFromArray:v.subviews];
            NSString *cn = NSStringFromClass(v.class);
            if ([cn isEqualToString:@"WINDeviceInterconnectWidget"]) CachedCar = v;
            else if (IsRightBottomWidget(v)) CachedRight = v;
            else if ([cn isEqualToString:@"WINRouteLineWidgetView"]) CachedRoute = v;
            if (CachedCar && CachedRight && CachedRoute) break;
        }
    }
    if (CachedCar) AlignOneWidget(bar, CachedCar, barTop);
    if (CachedRight) AlignOneWidget(bar, CachedRight, barTop);
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
}

static void HookWidgetSetFrame(NSString *className) {
    Class cls = NSClassFromString(className);
    if (!cls) return;
    SEL fs = @selector(setFrame:);
    Method fm = class_getInstanceMethod(cls, fs);
    IMP fo = fm ? method_getImplementation(fm) : NULL;
    if (fm) {
        Replace(cls, fs, imp_implementationWithBlock(^(UIView *self, CGRect rect) {
            // 0.5.1：底边对齐钳位——不管 44/88 高，底边都贴在搜索框上方 8pt
            if (SearchBarSettled && objc_getAssociatedObject(self, &AlignedKey)) {
                UIView *sv = self.superview;
                if (sv && self.window) {
                    CGPoint p = [sv convertPoint:CGPointMake(rect.origin.x, rect.origin.y) toView:self.window];
                    CGFloat targetBottom = SearchBarSettledY - 8;
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
            if (SearchBarSettled && objc_getAssociatedObject(self, &AlignedKey)) {
                UIView *sv = self.superview;
                if (sv && self.window) {
                    CGFloat proposedY = center.y - self.bounds.size.height / 2;
                    CGPoint p = [sv convertPoint:CGPointMake(0, proposedY) toView:self.window];
                    CGFloat targetBottom = SearchBarSettledY - 8;
                    CGFloat proposedBottom = p.y + self.bounds.size.height;
                    if (fabs(proposedBottom - targetBottom) > 2) center.y += (targetBottom - proposedBottom);
                }
            }
            ((void (*)(id, SEL, CGPoint))co)(self, cs, center);
        }), method_getTypeEncoding(cm));
    }
}

// 0.5.1：移除底栏首页「上拉发现」提示文字（按文本内容隐藏）
static void HideDiscoverPrompt(UIView *bar) {
    NSArray *nodes = Flatten(bar);
    if (!nodes) return;
    for (UIView *v in nodes) {
        if (v == bar || v.hidden) continue;
        NSString *text = NodeText(v);
        if ([text containsString:@"上拉"] || [text containsString:@"发现"]) {
            v.hidden = YES;
        }
    }
}

// 底栏的 legacy 玻璃（模糊/backdrop/chrome/shadow）被 app 在按下时放大到覆盖地图区，
// 这就是残留的模糊带。只把「明显超出底栏范围」的收回到底栏矩形；不隐藏、不改 alpha。
static void ConfineLegacyChrome(UIView *bar) {
    if (!bar.bounds.size.width || !bar.bounds.size.height) return;
    UIWindow *win = bar.window;
    CGFloat sw = win ? win.bounds.size.width : bar.bounds.size.width;
    CGFloat sh = win ? win.bounds.size.height : bar.bounds.size.height;
    for (NSString *name in @[@"amap_legacyBlurView", @"amap_legacyChromeView",
                             @"amap_legacyBackdropView", @"amap_legacyShadowView",
                             @"amap_legacyBackdropGradient"]) {
        UIView *v = ObjectGetter(bar, name);
        if (![v isKindOfClass:UIView.class] || !v.superview || v.hidden) continue;
        CGRect f = v.frame;
        if (f.size.width < sw * 0.7 || f.size.height < sh * 0.35) continue;   // 没被放大就不动
        CGRect target = [bar convertRect:bar.bounds toView:v.superview];
        [CATransaction begin];
        [CATransaction setDisableActions:YES];
        v.frame = target;
        [CATransaction commit];
    }
}

// 只写文件：完整 dump 窗口中「比 300x200 还大」的视图（含底栏内部子视图），
// 用来定位产生模糊/压暗的那个视图。不 hook 任何显示 API，不改任何状态。
static void LogCoveringViews(UIView *bar) {
    UIWindow *win = bar.window;
    if (!win) return;
    static NSUInteger written;
    if (written >= 400) return;
    NSMutableArray<NSString *> *lines = [NSMutableArray array];
    [lines addObject:@"--- BAR.PARENT CHAIN ---"];
    for (UIView *v = bar; v; v = v.superview) {
        [lines addObject:[NSString stringWithFormat:@"  %@ %.0f,%.0f %.0fx%.0f hid=%d a=%.2f",
                          NSStringFromClass(v.class), v.frame.origin.x, v.frame.origin.y,
                          v.frame.size.width, v.frame.size.height, v.hidden, v.alpha]];
    }
    [lines addObject:@"--- BAR SUBVIEWS ---"];
    for (UIView *v in Flatten(bar)) {
        CGRect f = v.frame;
        if (f.size.width < 100 || f.size.height < 40) continue;
        NSString *cn = NSStringFromClass(v.class);
        UIColor *bg = v.backgroundColor;
        CGFloat a = 0;
        BOOL hasBG = [bg getRed:NULL green:NULL blue:NULL alpha:&a] && a > 0.05;
        [lines addObject:[NSString stringWithFormat:@"  %@ %.0f,%.0f %.0fx%.0f hid=%d a=%.2f bg=%d",
                          cn, f.origin.x, f.origin.y, f.size.width, f.size.height,
                          v.hidden, v.alpha, hasBG]];
        if (lines.count > 60) break;
    }
    [lines addObject:@"--- WINDOW BIG VIEWS ---"];
    for (UIView *v in Flatten(win)) {
        CGRect f = v.frame;
        if (f.size.width < 300 || f.size.height < 200) continue;
        NSString *cn = NSStringFromClass(v.class);
        [lines addObject:[NSString stringWithFormat:@"  %@ %.0f,%.0f %.0fx%.0f hid=%d a=%.2f inBar=%d",
                          cn, f.origin.x, f.origin.y, f.size.width, f.size.height,
                          v.hidden, v.alpha, (int)[v isDescendantOfView:bar]]];
        if (lines.count > 130) break;
    }
    if (lines.count < 4) return;
    written += lines.count;
    NSURL *doc = [NSFileManager.defaultManager URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask].firstObject;
    if (!doc) return;
    NSURL *url = [doc URLByAppendingPathComponent:@"GaodeClean-cover.txt"];
    NSString *text = [[lines componentsJoinedByString:@"\n"] stringByAppendingString:@"\n=====\n"];
    NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:url.path];
    if (!fh) [text writeToURL:url atomically:YES encoding:NSUTF8StringEncoding error:nil];
    else { [fh seekToEndOfFile]; [fh writeData:[text dataUsingEncoding:NSUTF8StringEncoding]]; [fh closeFile]; }
}

static void CenterTabButtons(UIView *bar) {
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
    LogCoveringViews(bar);
}

static void InstallMinimalHome(void) {
    HookVoid(@"WINTabBar", @"layoutSubviews", ^(UIView *bar) { CenterTabButtons(bar); HideDiscoverPrompt(bar); });
    HookVoid(@"WINTabBar", @"amap_relayoutTabItems", ^(UIView *bar) { CenterTabButtons(bar); HideDiscoverPrompt(bar); });

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
                id dg = self.delegate;
                if (dg && [dg isKindOfClass:mv] && op < 0.99f) op = 1.0f;
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
            if (m) Replace(vc, sl, imp_implementationWithBlock(^(id self, __unused BOOL on) {}),
                           method_getTypeEncoding(m));
            SEL sc = NSSelectorFromString(@"setMaskColor:value:");
            Method m2 = class_getInstanceMethod(vc, sc);
            if (m2) Replace(vc, sc, imp_implementationWithBlock(^(id self, __unused id ek, __unused int c) {}),
                            method_getTypeEncoding(m2));
        }
    }
    // 0.5.50：上拉手势的另一个宿主 —— 只对这两个类的【本体】摘 pan/swipe，
    // 绝不碰子树（搜索栏是 WINMultiStyleRootView 的子视图）。
    {
        static dispatch_source_t gt = nil;
        if (!gt) {
            gt = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
            dispatch_source_set_timer(gt, dispatch_time(DISPATCH_TIME_NOW, 400 * NSEC_PER_MSEC),
                                      400 * NSEC_PER_MSEC, 150 * NSEC_PER_MSEC);
            dispatch_source_set_event_handler(gt, ^{
                for (UIWindow *w in UIApplication.sharedApplication.windows) {
                    if (w.hidden) continue;
                    NSMutableArray *q = [NSMutableArray arrayWithObject:w];
                    for (NSUInteger i = 0; i < q.count && q.count < 6000; i++) {
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
            });
            dispatch_resume(gt);
        }
    }
    HookWeatherRow();
    HookRowSetters();
    HookSubsidyBanner();
    HookWeatherRowHideGuard();
    HookWeatherRowKeep();
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
            if (m) Replace(sv, ag, imp_implementationWithBlock(^(id self, __unused id g) {}),
                           method_getTypeEncoding(m));
            for (NSString *setter in @[@"setHeaderPanGestureRecognizer:",
                                       @"setMockPanGestureRecognizer:"]) {
                SEL sl = NSSelectorFromString(setter);
                Method mm = class_getInstanceMethod(sv, sl);
                if (mm) Replace(sv, sl, imp_implementationWithBlock(^(id self, __unused id g) {}),
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
        if (ColdTicks < 15) return;
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
                    if (h && ColdTicks >= 15 && CachedTabs) {
                        id sel = ObjectGetter(CachedTabs, @"selectedViewControl");
                        if ([NSStringFromClass([sel class]) isEqualToString:@"WINAmapHomeControl"]) h = NO;
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
        else if (view.window && !objc_getAssociatedObject(view, &AlignedKey) && IsRightBottomWidget(view)) {
            view.hidden = YES; [ColdWidgets addObject:view];
        }
    });
    // 0.4.41：车机圆钮冷启动先隐藏，对齐后再显示，消除跳动
    HookVoid(@"WINDeviceInterconnectWidget", @"layoutSubviews", ^(UIView *w) {
        if (w.window && !objc_getAssociatedObject(w, &AlignedKey)) { w.hidden = YES; [ColdWidgets addObject:w]; }
    });
    // 0.4.47：拦截两圆钮 setFrame:，对齐后 y 钉死，杜绝 app 挪回原生位置闪跳
    HookWidgetSetFrame(@"WINDeviceInterconnectWidget");
    HookWidgetSetFrame(@"WINAJXCombinedWidgetView");
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
        method_setImplementation(mr, imp_implementationWithBlock(^(id self, id key, id blk) {
            void (^noop)(void) = ^{};
            ((void (*)(id, SEL, id, id))origr)(self, selr, key, noop);
        }));
    }
    // 注册顺序可能晚于此处，所以在每个 item 建好后同步清一次。
    HookVoid(@"WINTabBarItem", @"initWithFrame:model:", ^(UIView *item) {
        for (NSString *setter in @[@"setAllowRepeatClick:", @"setAmap_allowRepeatClick:"]) {
            SEL s = NSSelectorFromString(setter);
            if ([item respondsToSelector:s]) ((void (*)(id, SEL, BOOL))objc_msgSend)(item, s, NO);
        }
    });
    HookVoid(@"WINTabBar", @"amap_relayoutTabItems", ^(UIView *bar) {
        for (id item in (ObjectGetter(bar, @"tabBarItems") ?: @[])) {
            if (![item isKindOfClass:UIView.class]) continue;
            for (NSString *setter in @[@"setAllowRepeatClick:", @"setAmap_allowRepeatClick:"]) {
                SEL s = NSSelectorFromString(setter);
                if ([item respondsToSelector:s]) ((void (*)(id, SEL, BOOL))objc_msgSend)(item, s, NO);
            }
        }
    });
}

__attribute__((constructor)) static void Initialize(void) {
    @autoreleasepool {
        if (![NSBundle.mainBundle.bundleIdentifier isEqualToString:@"com.autonavi.amap"]) return;
        if (![[NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"] isEqual:@"17.00.2"]) {
            NSLog(@"[GaodeClean] unsupported app version; disabled");
            return;
        }
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
            if (kept.count == 2) ((void (*)(id, SEL, id))objc_msgSend)(tabs, NSSelectorFromString(@"setViewControlParams:"), kept);
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
            Schedule();
            // 0.4.44：GCD 计时器（模式无关，比 NSTimer 更可靠；NSTimer 在 1.4s 后曾停止）
            ScheduleTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
            dispatch_source_set_timer(ScheduleTimer, dispatch_time(DISPATCH_TIME_NOW, 200 * NSEC_PER_MSEC), 200 * NSEC_PER_MSEC, 20 * NSEC_PER_MSEC);
            dispatch_source_set_event_handler(ScheduleTimer, ^{ Schedule(); });
            dispatch_resume(ScheduleTimer);
        });
        NSLog(@"[GaodeClean] loaded 0.5.1 (17.00.2 only)");
    }
}
