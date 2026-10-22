// ===========================================================================
//  0.9.14-diag —— 真机事实采集（仅 -DGAODECLEAN_DIAG_LOG=1 时编译）
//
//  六轮复验（0.9.9 → 0.9.14）都在「解释现象」，从没人拿到过真机上按钮的
//  生命周期。本模块不再猜：冷启动后 15 秒内每 200ms 采样一次 ——
//    ① WINAJXCombinedWidgetView 实例的 frame(窗口系)/hidden/alpha/上窗/tag
//    ② 全窗扫描「右半侧 + 垂直 25%~70% + 小尺寸 + 可见」的视图并**点名类名**
//       （若中部裸露物根本不是我们 hook 的类，这里会第一时间暴露）
//    ③ ColdTicks / HomeSettled / SearchBarSettled / CachedCar|Right|Route 变化
//  外加事件级日志（setHidden:/setAlpha:/setFrame:/didMoveToWindow/layoutSubviews）。
//
//  日志落盘优先级：/var/mobile/Documents → /tmp → app 容器 Documents
//  文件名 gaodeclean-diag.log，Filza 直接打开即取。
// ===========================================================================

static FILE *GCDiagFP = NULL;
static NSTimeInterval GCDiagT0 = 0;
static int GCDiagLines = 0;
static int GCDiagFrameBudget = 300;
static BOOL GCDiagSampling = YES;
// 0.9.15（A6）：必须**持有强引用**。0.9.14 把它写成函数局部变量，ARC 下出作用域即释放，
// 采样定时器一次都没触发（真机日志里 0 条 Sxx 行，只能靠录屏反推 —— 这是取证的失误）。
static dispatch_source_t GCDiagTimer = NULL;

static void GCDiagOpen(void) {
    if (GCDiagFP) return;
    if (!GCDiagT0) GCDiagT0 = NSDate.date.timeIntervalSince1970;
    NSMutableArray<NSString *> *cands = [NSMutableArray array];
    [cands addObject:@"/var/mobile/Documents/gaodeclean-diag.log"];
    [cands addObject:@"/tmp/gaodeclean-diag.log"];
    NSArray *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    if (docs.count) [cands addObject:[docs.firstObject stringByAppendingPathComponent:@"gaodeclean-diag.log"]];
    for (NSString *p in cands) {
        FILE *f = fopen(p.UTF8String, "a");
        if (f) {
            GCDiagFP = f;
            fprintf(f, "\n===== GaodeClean %s DIAG 启动 %s =====\n",
                    kGCVersion.UTF8String, NSDate.date.description.UTF8String);
            fflush(f);
            NSLog(@"[GaodeClean] DIAG 日志 -> %@", p);
            return;
        }
    }
    NSLog(@"[GaodeClean] DIAG: 无可用可写路径");
}

static void GCDiag(NSString *fmt, ...) {
    if (GCDiagLines > 4000) {
        if (GCDiagFP) { fprintf(GCDiagFP, "---- 行数上限，停止 ----\n"); fclose(GCDiagFP); GCDiagFP = NULL; }
        return;
    }
    if (!GCDiagFP) GCDiagOpen();
    if (!GCDiagFP) return;
    GCDiagLines++;
    NSTimeInterval dt = NSDate.date.timeIntervalSince1970 - GCDiagT0;
    va_list ap; va_start(ap, fmt);
    NSString *s = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    fprintf(GCDiagFP, "[%7.3f] %s\n", dt, s.UTF8String);
    fflush(GCDiagFP);
}

// 采样：每 200ms；共 75 拍 = 15 秒
static void GCDiagSample(void) {
    if (!GCDiagSampling) return;
    static int n = 0;
    if (++n > 75) {
        GCDiagSampling = NO;
        GCDiag(@"---- 采样结束（15s）----");
        return;
    }
    static __weak UIView *lastCar, *lastRight, *lastRoute;
    static BOOL lastHome = NO, lastSettled = NO;

    UIWindow *win = nil;
    NSArray *wins = GCAllWindows();
    for (UIWindow *w in wins) { if (w.isKeyWindow) { win = w; break; } }
    if (!win && wins.count) win = wins.firstObject;
    if (!win) { GCDiag(@"S%02d 无窗口", n); return; }

    NSMutableArray *widgets = [NSMutableArray array];
    NSMutableArray *suspects = [NSMutableArray array];
    NSMutableArray *lites = [NSMutableArray array];     // 0.9.16（A3）：真凶
    NSMutableArray *locates = [NSMutableArray array];   // 0.9.16（A3）：⊙ 图标
    CGSize scr = UIScreen.mainScreen.bounds.size;

    NSMutableArray *queue = [NSMutableArray arrayWithObject:win];
    NSUInteger qi = 0; int nodes = 0;
    while (qi < queue.count && nodes < 4000) {
        UIView *v = queue[qi++]; nodes++;
        NSString *cn = NSStringFromClass(v.class);
        if ([cn isEqualToString:@"WINAJXCombinedWidgetView"]) {
            if (widgets.count < 5) [widgets addObject:v];   // 0.9.15+diag：全部实例都记
        }
        if ([cn isEqualToString:@"WINLiteWidgetGroupView"] && lites.count < 4) [lites addObject:v];
        if ([cn isEqualToString:@"WINLocationView"] && locates.count < 3) [locates addObject:v];
        if (!v.hidden && v.alpha > 0.1 && v.window) {
            CGSize bs = v.bounds.size;
            if (bs.width > 30 && bs.width < 220 && bs.height > 30 && bs.height < 420) {
                CGRect r = [v convertRect:v.bounds toView:win];
                if (r.origin.x > scr.width * 0.55
                    && CGRectGetMidY(r) > scr.height * 0.25
                    && CGRectGetMidY(r) < scr.height * 0.70) {
                    // 0.9.16（A3）：补**有效可见性** —— 祖先链上任一 hidden/alpha≈0 即为「祖隐」。
                    //   上一版只看自身 hidden，导致「祖先藏着的子视图」也被当成暴露候选，
                    //   这正是本轮唯一盲点（真凶曾因此被漏看）。
                    BOOL eff = YES;
                    for (UIView *p = v; p; p = p.superview) { if (p.hidden || p.alpha < 0.1) { eff = NO; break; } }
                    NSString *sig = [NSString stringWithFormat:@"%@(%.0f,%.0f,%.0fx%.0f)%@",
                                     cn, r.origin.x, r.origin.y, r.size.width, r.size.height,
                                     eff ? @"✓可见" : @"✗祖隐"];
                    if (![suspects containsObject:sig] && suspects.count < 6) [suspects addObject:sig];
                }
            }
        }
        NSArray *subs = v.subviews;
        if (subs.count) [queue addObjectsFromArray:subs];
    }

    // 0.9.15+diag：记录**全部** WINAJXCombinedWidgetView 实例（带 tag/AlignedKey/是否被认领），
    // 上一版只记「第一个」，三个实例（rightTop/rightBottom/rank）混在一起无法分辨 —— 已修。
    NSMutableArray *wi = [NSMutableArray array];
    for (UIView *wv in widgets) {
        CGRect r = [wv convertRect:wv.bounds toView:win];
        [wi addObject:[NSString stringWithFormat:@"%@@(%.0f,%.0f,%.0fx%.0f)hid%dAl%daA%dCold%dwin%d",
                       ObjectGetter(wv, @"getItemTag") ?: @"nil",
                       r.origin.x, r.origin.y, r.size.width, r.size.height,
                       wv.hidden, (int)(wv.alpha * 100),
                       objc_getAssociatedObject(wv, &AlignedKey) != nil,
                       [ColdWidgets containsObject:wv], wv.window != nil]];
    }
    // 0.9.16（A3）：真凶全实例（带有效可见性 + 祖先链）
    {
        NSMutableArray *li = [NSMutableArray array];
        for (UIView *lv in lites) {
            CGRect r = [lv convertRect:lv.bounds toView:win];
            BOOL eff = YES;
            for (UIView *p = lv; p; p = p.superview) { if (p.hidden || p.alpha < 0.1) { eff = NO; break; } }
            NSMutableString *chain = [NSMutableString string];
            UIView *p = lv.superview;
            for (int i = 0; i < 4 && p; i++, p = p.superview)
                [chain appendFormat:@"%@>", NSStringFromClass(p.class)];
            [li addObject:[NSString stringWithFormat:@"%@(%.0f,%.0f,%.0fx%.0f)hid%d其%dtag=%@Cold%d[%@]",
                           eff ? @"✓" : @"✗", r.origin.x, r.origin.y, r.size.width, r.size.height,
                           lv.hidden, eff, ObjectGetter(lv, @"getItemTag") ?: @"nil",
                           [ColdWidgets containsObject:lv], chain]];
        }
        NSMutableArray *oi = [NSMutableArray array];
        for (UIView *ov in locates) {
            CGRect r = [ov convertRect:ov.bounds toView:win];
            BOOL eff = YES;
            for (UIView *p = ov; p; p = p.superview) { if (p.hidden || p.alpha < 0.1) { eff = NO; break; } }
            [oi addObject:[NSString stringWithFormat:@"%@(%.0f,%.0f)hid%d其%d", eff ? @"✓" : @"✗",
                           r.origin.x, r.origin.y, ov.hidden, eff]];
        }
        if (li.count || oi.count)
            GCDiag(@"   LITE: %@ | LOC: %@", li.count ? [li componentsJoinedByString:@" "] : @"-",
                   oi.count ? [oi componentsJoinedByString:@" "] : @"-");
    }
    // 0.9.18（A4）：右列视图树 dump —— 定位「2D/3D（地图类型）按钮」的类名与父链。
    //   取样：x 中心 > 屏宽 0.65 且尺寸 14..90pt 的视图（小容器/按钮），最多 14 条；
    //   子树含 "2D"/"3D" 文字的视图打 ★ 标记（A3 的识别器与这里同源）。
    {
        NSMutableArray *ri = [NSMutableArray array];
        NSMutableArray *q2 = [NSMutableArray arrayWithObject:win];
        for (NSUInteger i = 0; i < q2.count && q2.count < 1500 && ri.count < 14; i++) {
            UIView *v = q2[i];
            [q2 addObjectsFromArray:v.subviews];
            if (v == win) continue;
            CGRect r = [v convertRect:v.bounds toView:win];
            if (CGRectGetMidX(r) < win.bounds.size.width * 0.65) continue;
            if (r.size.width < 14 || r.size.height < 12) continue;
            if (r.size.width > 90 || r.size.height > 90) continue;
            BOOL hit = GCCViewTreeHasMapTypeLabel(v, 0);
            NSString *chain = @"";
            UIView *pp = v.superview;
            if (pp) chain = [NSString stringWithFormat:@"^%@", NSStringFromClass(pp.class)];
            [ri addObject:[NSString stringWithFormat:@"%@(%.0f,%.0f,%.0fx%.0f)hid%d%@%@",
                           NSStringFromClass(v.class), r.origin.x, r.origin.y,
                           r.size.width, r.size.height, v.hidden,
                           hit ? @"★" : @"", chain]];
        }
        if (ri.count) GCDiag(@"   RIGHT: %@", [ri componentsJoinedByString:@" "]);
        // 0.9.19（A4）：2D/3D 按钮识别结果（含命中档位）—— 一眼看出识别器是否命中、摆到哪
        {
            UIView *mt = (CachedRight && CachedRight.window) ? GCCFindMapTypeButton(win, CachedRight) : nil;
            if (mt) {
                CGRect r = [mt convertRect:mt.bounds toView:win];
                CGRect cap = [CachedRight convertRect:CachedRight.bounds toView:win];
                GCDiag(@"   MAPTYPE: tier=%ld %@(%.0f,%.0f,%.0fx%.0f) 目标底=%.0f",
                       (long)GCReportedMapTypeTier, NSStringFromClass(mt.class),
                       r.origin.x, r.origin.y, r.size.width, r.size.height,
                       CGRectGetMinY(cap) - GCGapMapType);
            } else {
                GCDiag(@"   MAPTYPE: 未识别到（CachedRight=%@ settled=%d）",
                       CachedRight ? NSStringFromClass(CachedRight.class) : @"nil", SearchBarSettled);
            }
        }
    }
    GCDiag(@"S%02d tick=%ld H=%d SB=%d(y=%.0f) | W%lu: %@ | mid=%s[%@]",
           n, (long)ColdTicks, HomeSettled, SearchBarSettled, SearchBarSettledY,
           (unsigned long)widgets.count, [wi componentsJoinedByString:@" "],
           suspects.count ? "" : "无", [suspects componentsJoinedByString:@" "]);

    if (CachedCar != lastCar) { GCDiag(@"   * CachedCar -> %@", CachedCar ? NSStringFromClass(CachedCar.class) : @"nil"); lastCar = CachedCar; }
    if (CachedRight != lastRight) { GCDiag(@"   * CachedRight -> %@", CachedRight ? NSStringFromClass(CachedRight.class) : @"nil"); lastRight = CachedRight; }
    if (CachedRoute != lastRoute) { GCDiag(@"   * CachedRoute -> %@", CachedRoute ? NSStringFromClass(CachedRoute.class) : @"nil"); lastRoute = CachedRoute; }
    if (HomeSettled != lastHome) { GCDiag(@"   * HomeSettled %d -> %d", lastHome, HomeSettled); lastHome = HomeSettled; }
    if (SearchBarSettled != lastSettled) { GCDiag(@"   * SearchBarSettled %d -> %d (y=%.0f)", lastSettled, SearchBarSettled, SearchBarSettledY); lastSettled = SearchBarSettled; }
}

// ============================================================================
// 0.9.16（A3）：App 原生组容器的事件探针（七轮误靶的真凶）
//   与主类同一套动作，但不依赖 getItemTag（该类的 tag 恒为 nil）。
// ============================================================================
static void GCDiagHookLiteClass(Class c) {
    if (!c) return;
    Method m; IMP prev; const char *types;

    // setFrame:（抓「谁把它摆到中部」的调用栈）
    SEL sel = @selector(setFrame:);
    m = class_getInstanceMethod(c, sel);
    if (m) {
        prev = method_getImplementation(m);
        types = method_getTypeEncoding(m);
        Replace(c, sel, imp_implementationWithBlock(^(UIView *self, CGRect r) {
            if (GCDiagFrameBudget > 0) {
                GCDiagFrameBudget--;
                UIView *win = self.window;
                CGRect w = win ? [self convertRect:r toView:win] : r;
                CGSize scr = UIScreen.mainScreen.bounds.size;
                GCDiag(@"  L.setFrame:->(%.0f,%.0f,%.0fx%.0f) win系(%.0f,%.0f) hid=%d win=%d",
                       r.origin.x, r.origin.y, r.size.width, r.size.height,
                       w.origin.x, w.origin.y, self.hidden, self.window != nil);
                BOOL isMid = (w.origin.y + w.size.height / 2.0) > scr.height * 0.25 &&
                             (w.origin.y + w.size.height / 2.0) < scr.height * 0.70;
                static int liteStackBudget = 6;
                if (isMid && liteStackBudget > 0) {
                    liteStackBudget--;
                    NSArray *bt = [NSThread callStackSymbols];
                    NSMutableString *keep = [NSMutableString string];
                    for (NSString *fr in bt) {
                        if ([fr containsString:@"GaodeClean"] || [fr containsString:@"Gaode"] ||
                            [fr containsString:@"WIN"] || [fr containsString:@"AJX"] ||
                            [fr containsString:@"Align"] || [fr containsString:@"Layout"]) {
                            [keep appendFormat:@"\n                      | %@", fr];
                            if (keep.length > 900) break;
                        }
                    }
                    GCDiag(@"  ★L 写入中部(%.0f) — 调用栈:%@", w.origin.y, keep.length ? keep : @"(无 Gaode/WIN 帧)");
                }
            }
            ((void (*)(id, SEL, CGRect))prev)(self, sel, r);
        }), types);
    }
    // setHidden:
    sel = @selector(setHidden:);
    m = class_getInstanceMethod(c, sel);
    if (m) {
        prev = method_getImplementation(m);
        types = method_getTypeEncoding(m);
        Replace(c, sel, imp_implementationWithBlock(^(UIView *self, BOOL hidden) {
            CGRect w = self.window ? [self convertRect:self.bounds toView:self.window] : self.frame;
            GCDiag(@"  L.setHidden:%d @win系(%.0f,%.0f,%.0fx%.0f) hid(旧)=%d win=%d",
                   hidden, w.origin.x, w.origin.y, w.size.width, w.size.height,
                   self.hidden, self.window != nil);
            ((void (*)(id, SEL, BOOL))prev)(self, sel, hidden);
        }), types);
    }
    // didMoveToWindow
    sel = @selector(didMoveToWindow);
    m = class_getInstanceMethod(c, sel);
    if (m) {
        prev = method_getImplementation(m);
        types = method_getTypeEncoding(m);
        Replace(c, sel, imp_implementationWithBlock(^(UIView *self) {
            CGRect w = self.window ? [self convertRect:self.bounds toView:self.window] : self.frame;
            GCDiag(@"  L.didMoveToWindow win=%d hid=%d @win系(%.0f,%.0f,%.0fx%.0f)",
                   self.window != nil, self.hidden, w.origin.x, w.origin.y, w.size.width, w.size.height);
            ((void (*)(id, SEL))prev)(self, sel);
        }), types);
    }
    // layoutSubviews（节流）
    sel = @selector(layoutSubviews);
    m = class_getInstanceMethod(c, sel);
    if (m) {
        prev = method_getImplementation(m);
        types = method_getTypeEncoding(m);
        Replace(c, sel, imp_implementationWithBlock(^(UIView *self) {
            static NSTimeInterval lastL = 0;
            NSTimeInterval now = NSDate.date.timeIntervalSince1970;
            if (now - lastL > 0.1) {
                lastL = now;
                UIView *win = self.window;
                CGRect w = win ? [self convertRect:self.bounds toView:win] : self.frame;
                NSMutableString *chain = [NSMutableString string];
                UIView *p = self.superview;
                for (int i = 0; i < 4 && p; i++, p = p.superview)
                    [chain appendFormat:@"%@ > ", NSStringFromClass(p.class)];
                GCDiag(@"  L.layoutSubviews @win系(%.0f,%.0f,%.0fx%.0f) hid=%d win=%d 祖先链=%@",
                       w.origin.x, w.origin.y, w.size.width, w.size.height,
                       self.hidden, self.window != nil, chain.length ? chain : @"(无)");
            }
            ((void (*)(id, SEL))prev)(self, sel);
        }), types);
    }
}

static void GCDiagInstall(void) {
    GCDiagOpen();
    GCDiag(@"install: %@ | screen %.0fx%.0f | abi=%s", kGCVersion,
           UIScreen.mainScreen.bounds.size.width, UIScreen.mainScreen.bounds.size.height,
#if defined(__arm64e__)
           "arm64e"
#else
           "arm64"
#endif
           );
    Class cls = NSClassFromString(@"WINAJXCombinedWidgetView");
    // 0.9.16（A3）：真凶是 App 原生组容器 —— 纳入同一套事件探针。
    //   （diag2 铁证：中部胶囊 = WINLiteWidgetGroupView + 毛玻璃 + WINLocationView(⊙)）
    Class clsLite = NSClassFromString(@"WINLiteWidgetGroupView");
    GCDiag(@"probe: WINAJXCombinedWidgetView=%@ WINLiteWidgetGroupView=%@ WINLocationView=%@",
           cls ? @"yes" : @"NO", clsLite ? @"yes" : @"NO",
           NSClassFromString(@"WINLocationView") ? @"yes" : @"NO");
    if (!cls) {
        GCDiag(@"!! WINAJXCombinedWidgetView 类不存在 —— 显示拦截从第一步就是空转");
    } else {
        struct { SEL sel; const char *name; } sels[] = {
            { @selector(setHidden:), "setHidden:" },
            { @selector(setAlpha:), "setAlpha:" },
            { @selector(setFrame:), "setFrame:" },
            { @selector(didMoveToWindow), "didMoveToWindow" },
            { @selector(layoutSubviews), "layoutSubviews" },
        };
        for (unsigned i = 0; i < sizeof(sels) / sizeof(sels[0]); i++) {
            SEL sel = sels[i].sel;
            Method m = class_getInstanceMethod(cls, sel);
            if (!m) { GCDiag(@"install: %s 不存在", sels[i].name); continue; }
            GCDiag(@"install: %s 已挂钩", sels[i].name);
        }
        // setHidden:
        SEL sel = @selector(setHidden:);
        Method m = class_getInstanceMethod(cls, sel);
        if (m) {
            IMP prev = method_getImplementation(m);
            const char *types = method_getTypeEncoding(m);
            Replace(cls, sel, imp_implementationWithBlock(^(UIView *self, BOOL hidden) {
                CGRect r = self.window ? [self convertRect:self.bounds toView:self.window] : self.frame;
                GCDiag(@"  setHidden:%d @(%.0f,%.0f,%.0fx%.0f) hid(旧)=%d a=%.2f win=%d tag=%@",
                       hidden, r.origin.x, r.origin.y, r.size.width, r.size.height,
                       self.hidden, self.alpha, self.window != nil,
                       ObjectGetter(self, @"getItemTag") ?: @"nil");
                ((void (*)(id, SEL, BOOL))prev)(self, sel, hidden);
            }), types);
        }
        // setAlpha:
        sel = @selector(setAlpha:);
        m = class_getInstanceMethod(cls, sel);
        if (m) {
            IMP prev = method_getImplementation(m);
            const char *types = method_getTypeEncoding(m);
            Replace(cls, sel, imp_implementationWithBlock(^(UIView *self, CGFloat a) {
                GCDiag(@"  setAlpha:%.2f (旧 %.2f) frame=(%.0f,%.0f) tag=%@ aligned=%d",
                       a, self.alpha, self.frame.origin.x, self.frame.origin.y,
                       ObjectGetter(self, @"getItemTag") ?: @"nil",
                       objc_getAssociatedObject(self, &AlignedKey) != nil);
                ((void (*)(id, SEL, CGFloat))prev)(self, sel, a);
            }), types);
        }
        // setFrame:（限前 300 次，动画期间调用密集）
        sel = @selector(setFrame:);
        m = class_getInstanceMethod(cls, sel);
        if (m) {
            IMP prev = method_getImplementation(m);
            const char *types = method_getTypeEncoding(m);
            Replace(cls, sel, imp_implementationWithBlock(^(UIView *self, CGRect rect) {
                if (GCDiagFrameBudget > 0) {
                    CGRect r = self.window ? [self.superview convertRect:rect toView:self.window] : rect;
                    id tag = ObjectGetter(self, @"getItemTag");
                    GCDiag(@"  setFrame:->(%.0f,%.0f,%.0fx%.0f) win系(%.0f,%.0f) hid=%d a=%.2f tag=%@ aligned=%d",
                           rect.origin.x, rect.origin.y, rect.size.width, rect.size.height,
                           r.origin.x, r.origin.y, self.hidden, self.alpha, tag ?: @"nil",
                           objc_getAssociatedObject(self, &AlignedKey) != nil);
                    GCDiagFrameBudget--;
                    // ★ 决定性：写入「中部位置」的那一刻抓调用栈 —— 直接点名是谁写的
                    //   （我们自己的 AlignOneWidget / 钳位，还是 app 的原生布局）
                    CGSize scr = UIScreen.mainScreen.bounds.size;
                    BOOL isMid = self.window && r.origin.y > scr.height * 0.25 && r.origin.y < scr.height * 0.70;
                    BOOL isBtn = tag && [tag isKindOfClass:NSString.class] && [tag rangeOfString:@"RightBottom"].location != NSNotFound;
                    // 0.9.16（A3）：App 原生组容器没有 getItemTag —— 按类名放行，
                    //   中间裸露物就是它，必须抓到「谁把它摆到中部」的调用栈。
                    BOOL isLite = [NSStringFromClass(self.class) isEqualToString:@"WINLiteWidgetGroupView"];
                    static int midStackBudget = 6;
                    if (isMid && (isBtn || isLite) && midStackBudget > 0 && r.size.height > 40) {
                        midStackBudget--;
                        NSArray<NSString *> *st = [NSThread callStackSymbols];
                        NSMutableArray *keep = [NSMutableArray array];
                        for (NSUInteger i = 1; i < st.count && keep.count < 14; i++) {
                            NSString *line = st[i];
                            // 只留我们自己、app 关键类与 ObjC 派发行，压掉系统噪音
                            if ([line rangeOfString:@"GaodeClean"].location != NSNotFound
                                || [line rangeOfString:@"Gaode"].location != NSNotFound
                                || [line rangeOfString:@"WIN"].location != NSNotFound
                                || [line rangeOfString:@"AJX"].location != NSNotFound
                                || [line rangeOfString:@"Align"].location != NSNotFound
                                || [line rangeOfString:@"Layout"].location != NSNotFound
                                || [line rangeOfString:@"objc_msgSend"].location != NSNotFound) {
                                [keep addObject:[line stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet]];
                            }
                        }
                        GCDiag(@"  ★★ 中部写入栈(tag=%@, win系 y=%.0f):", tag, r.origin.y);
                        for (NSString *k in keep) GCDiag(@"       | %@", k);
                    }
                }
                ((void (*)(id, SEL, CGRect))prev)(self, sel, rect);
            }), types);
        }
        // didMoveToWindow
        sel = @selector(didMoveToWindow);
        m = class_getInstanceMethod(cls, sel);
        if (m) {
            IMP prev = method_getImplementation(m);
            const char *types = method_getTypeEncoding(m);
            Replace(cls, sel, imp_implementationWithBlock(^(UIView *self) {
                GCDiag(@"  didMoveToWindow win=%d hid=%d a=%.2f tag=%@ frame=(%.0f,%.0f)",
                       self.window != nil, self.hidden, self.alpha,
                       ObjectGetter(self, @"getItemTag") ?: @"nil",
                       self.frame.origin.x, self.frame.origin.y);
                ((void (*)(id, SEL))prev)(self, sel);
            }), types);
        }
        // layoutSubviews（节流 100ms）
        sel = @selector(layoutSubviews);
        m = class_getInstanceMethod(cls, sel);
        if (m) {
            IMP prev = method_getImplementation(m);
            const char *types = method_getTypeEncoding(m);
            Replace(cls, sel, imp_implementationWithBlock(^(UIView *self) {
                static NSTimeInterval last = 0;
                NSTimeInterval now = NSDate.date.timeIntervalSince1970;
                if (now - last > 0.1) {
                    last = now;
                    id tag = ObjectGetter(self, @"getItemTag");
                    GCDiag(@"  layoutSubviews frame=(%.0f,%.0f,%.0fx%.0f) hid=%d win=%d tag=%@ 精确判定=%d",
                           self.frame.origin.x, self.frame.origin.y, self.frame.size.width, self.frame.size.height,
                           self.hidden, self.window != nil, tag ?: @"nil",
                           IsRightBottomWidget(self));
                }
                ((void (*)(id, SEL))prev)(self, sel);
            }), types);
        }
    }
    // 0.9.16（A3）：真凶纳入探针
    GCDiagHookLiteClass(NSClassFromString(@"WINLiteWidgetGroupView"));
    // 采样定时器（200ms）—— 必须存进文件级变量持住，否则 ARC 立即释放
    GCDiagTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    dispatch_source_set_event_handler(GCDiagTimer, ^{ GCDiagSample(); });
    dispatch_source_set_timer(GCDiagTimer, dispatch_time(DISPATCH_TIME_NOW, 200 * NSEC_PER_MSEC),
                              200 * NSEC_PER_MSEC, 20 * NSEC_PER_MSEC);
    dispatch_resume(GCDiagTimer);
    GCDiag(@"采样定时器已启动（200ms x 75 = 15s）");
}