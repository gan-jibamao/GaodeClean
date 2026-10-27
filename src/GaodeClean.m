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
static void UpdateMask(UIView *page);
static void Schedule(void);
static void LayoutMinimalHome(id handler);
// PROBE 前置声明（定义在 Initialize 之前）
static void P(NSString *fmt, ...);
static NSString *GCScanTerms(NSArray<UIView *> *nodes, NSArray<NSString *> *terms);

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
    NSData *data = [NSJSONSerialization dataWithJSONObject:@{@"version": @"0.3.2+p2", @"pages": records} options:NSJSONWritingPrettyPrinted error:nil];
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
    // PROBE: 打印所有页面路径（去重，只打前 40 个），定位 17.02.1 的真实 pagePath
    {
        static NSMutableSet *seenPaths;
        if (!seenPaths) seenPaths = [NSMutableSet set];
        if (path.length && ![seenPaths containsObject:path] && seenPaths.count < 40) {
            [seenPaths addObject:path];
            P(@"PAGE path=%@ kind=%ld", path, (long)kind);
        } else if (!path.length && seenPaths.count < 40 && ![seenPaths containsObject:@"<empty>"]) {
            [seenPaths addObject:@"<empty>"];
            P(@"PAGE path=<empty> class=%@", NSStringFromClass(page.class));
        }
    }
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
                if ([@[@"0.3.0", @"0.3.1", @"0.3.2+p2"] containsObject:report[@"version"] ?: @""] && [mine[@"matched"] boolValue]) {
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
            // 探针：打印该页实际出现的候选文案，判断服务端是否改了字
            NSArray *probeTerms = @[@"常去地点", @"回家", @"去单位", @"编辑",
                                    @"停车", @"美食", @"酒店", @"加油", @"旅游",
                                    @"家人地图", @"地图共建", @"车辆服务", @"高德运动",
                                    @"店铺入驻", @"足迹", @"推荐", @"附近", @"探索"];
            P(@"MISS page=%ld nodes=%lu terms=%@", (long)kind, (unsigned long)nodes.count,
              GCScanTerms(nodes, probeTerms));
            // 打印该页所有有文字的节点（最多 60 个），看真实文案
            NSMutableArray *texts = [NSMutableArray array];
            for (UIView *v in nodes) {
                NSString *t = NodeText(v);
                if (t.length >= 2 && t.length <= 30) {
                    [texts addObject:[NSString stringWithFormat:@"%@|%@", NSStringFromClass(v.class), t]];
                    if (texts.count >= 60) break;
                }
            }
            P(@"TEXTS page=%ld %@", (long)kind, [texts componentsJoinedByString:@" ;; "]);
        }
        if (state.attempts == 10) SaveDiagnostics(page, state, nodes);
        return;
    }
    P(@"MATCH page=%ld anchor=%@ peer=%@ boundary=%.1f", (long)kind,
      NSStringFromClass(anchor.class), peer ? NSStringFromClass(peer.class) : @"nil", boundary);
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
        for (id handler in HomeHandlers.allObjects) LayoutMinimalHome(handler);
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

static BOOL IsStreetRank(UIView *view) {
    NSMutableString *identity = [NSMutableString string];
    for (NSString *getter in @[@"getItemTag", @"iconImageName", @"accessibilityLabel"]) {
        id value = ObjectGetter(view, getter);
        if ([value isKindOfClass:NSString.class]) [identity appendFormat:@" %@", value];
    }
    NSString *lower = identity.lowercaseString;
    return [ObjectGetter(view, @"getItemTag") isEqual:@"template_rank"] || [identity containsString:@"扫街榜"] || [lower containsString:@"saojie"] || [lower containsString:@"streetrank"];
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
    sheet.hidden = YES;
    UIView *mask = ObjectGetter(handler, @"maskView");
    if ([mask isKindOfClass:UIView.class]) mask.hidden = YES;
    CALayer *bottomMask = ObjectGetter(handler, @"bottomMaskLayer");
    if ([bottomMask isKindOfClass:CALayer.class]) bottomMask.hidden = YES;
    CGRect tabFrame = [tabBar convertRect:tabBar.bounds toView:parent];
    CGFloat height = MAX(50, MIN(64, bar.bounds.size.height));
    bar.frame = CGRectMake(0, MAX(0, tabFrame.origin.y - height - 12), parent.bounds.size.width, height);
    bar.hidden = NO;
    [parent bringSubviewToFront:bar];
    LayingOutHome = NO;
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
    for (NSUInteger index = 0; index < items.count; index++) {
        UIView *item = items[index];
        if (![item isKindOfClass:UIView.class] || !item.superview) continue;
        CGPoint center = [item.superview convertPoint:item.center toView:bar];
        center.x = CGRectGetMidX(bar.bounds) + (index == 0 ? -0.5 : 0.5) * separation;
        item.center = [bar convertPoint:center toView:item.superview];
    }
    SEL sync = NSSelectorFromString(@"amap_syncLegacySelectionAnimated:");
    if ([bar respondsToSelector:sync]) ((void (*)(id, SEL, BOOL))objc_msgSend)(bar, sync, NO);
    adjusting = NO;
}

static void InstallMinimalHome(void) {
    HookVoid(@"WINTabBar", @"layoutSubviews", ^(UIView *bar) { CenterTabButtons(bar); });
    HookVoid(@"WINTabBar", @"amap_relayoutTabItems", ^(UIView *bar) { CenterTabButtons(bar); });

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
    HookVoid(@"WINQuickSearchBarV2", @"layoutSubviews", ^(id bar) {
        UIView *text = ObjectGetter(bar, @"verticalScrollText");
        if ([text isKindOfClass:UIView.class]) text.hidden = YES;
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


// ==================== PROBE 0.3.2+P1 ====================
// 探针：所有关键判定写入 Documents/GaodeClean-probe.log，不依赖 Console
static NSString *GCProbePath(void) {
    static NSString *p;
    if (!p) {
        NSString *dir = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
        p = [dir stringByAppendingPathComponent:@"GaodeClean-probe.log"];
    }
    return p;
}
static void P(NSString *fmt, ...) {
    va_list ap; va_start(ap, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    NSString *line = [NSString stringWithFormat:@"%@ %@\n", [NSDate date], msg];
    NSLog(@"[GaodeClean] %@", msg);
    NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:GCProbePath()];
    if (!fh) {
        [line writeToFile:GCProbePath() atomically:YES encoding:NSUTF8StringEncoding error:nil];
    } else {
        [fh seekToEndOfFile];
        [fh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
        [fh closeFile];
    }
}
// 统计视图树里出现的关键中文词，用于判断服务端文案是否变了
static NSString *GCScanTerms(NSArray<UIView *> *nodes, NSArray<NSString *> *terms) {
    NSMutableDictionary *hit = [NSMutableDictionary dictionary];
    for (NSString *t in terms) {
        NSInteger c = 0;
        for (UIView *v in nodes) {
            NSString *txt = NodeText(v);
            if (txt.length && [txt containsString:t]) c++;
        }
        if (c) hit[t] = @(c);
    }
    return [hit description];
}
// ==================== /PROBE ====================

__attribute__((constructor)) static void Initialize(void) {
    @autoreleasepool {
        if (![NSBundle.mainBundle.bundleIdentifier isEqualToString:@"com.autonavi.amap"]) return;
        // 0.3.2 (A1): 原版本硬闸门 isEqual:@"17.00.2" 已删除。
        // 高德一旦不是该版本，原代码在这里 return，零钩子安装且不打日志，
        // 用户只会看到「没效果」。现在改为全版本自适应：日志打印实际版本，
        // 不适配的类/selector 由各 Hook 的 `if (!m) return;` 静默跳过。
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
            P(@"TABPARAMS in=%lu kept=%lu list=%@", (unsigned long)[params count], (unsigned long)kept.count,
              [[params valueForKeyPath:@"className"] description]);
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
                        P(@"TABPROVIDER removed=%@", NSStringFromClass(provider));
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
        HookVoid(@"AJX3View", @"layoutSubviews", ^(id page) {
            [Pages addObject:page];
            {
                static NSMutableSet *seen2;
                if (!seen2) seen2 = [NSMutableSet set];
                NSString *pp = PagePath(page);
                NSString *key = pp.length ? pp : @"<empty>";
                if (![seen2 containsObject:key] && seen2.count < 40) {
                    [seen2 addObject:key];
                    P(@"AJX3VIEW path=%@", key);
                }
            }
            if (!Cleaning) { Cleaning = YES; CleanPage(page); Cleaning = NO; } Schedule();
        });
        HookVoid(@"AJX3View", @"didMoveToWindow", ^(id page) { [Pages addObject:page]; CleanPage(page); Schedule(); });
        HookVoid(@"AJXWINNearbyViewControl", @"viewDidLoad", ^(id controller) { [NearbyControllers addObject:controller]; Schedule(); });
        HookVoid(@"WINTabBarControl", @"viewDidLoad", ^(id tabs) { [TabControllers addObject:tabs]; Schedule(); });
        // Recheck after asynchronous cards and cell reuse; only attached target pages are scanned.
        dispatch_async(dispatch_get_main_queue(), ^{
            [NSTimer scheduledTimerWithTimeInterval:0.5 repeats:YES block:^(__unused NSTimer *timer) { Schedule(); }];
        });
        NSLog(@"[GaodeClean] loaded 0.3.2 (no version limit; appVer=%@)", appVersion);
        P(@"=== BOOT appVer=%@ bundle=%@ ===", appVersion, NSBundle.mainBundle.bundleIdentifier);
        P(@"BOOT path=%@", GCProbePath());
        // 探针：确认关键类是否存在
        for (NSString *cn in @[@"WINTabBar", @"WINTabBarItem", @"WINTabBarControl", @"WINQuickSearchBarV2",
                               @"GDMapHomeTabBarControl", @"GDTabBarItemRegistry", @"AJX3View",
                               @"WINAmapHomeControl", @"WINMineViewControl", @"GDAmapHomeHandler"]) {
            Class c = NSClassFromString(cn);
            P(@"CLASS %@ = %@", cn, c ? @"YES" : @"NO");
        }
    }
}
