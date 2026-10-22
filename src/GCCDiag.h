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

    UIView *widget = nil;
    NSMutableArray *suspects = [NSMutableArray array];
    CGSize scr = UIScreen.mainScreen.bounds.size;

    NSMutableArray *queue = [NSMutableArray arrayWithObject:win];
    NSUInteger qi = 0; int nodes = 0;
    while (qi < queue.count && nodes < 4000) {
        UIView *v = queue[qi++]; nodes++;
        NSString *cn = NSStringFromClass(v.class);
        if ([cn isEqualToString:@"WINAJXCombinedWidgetView"]) {
            if (!widget) widget = v;
            if (v.hidden || v.alpha < 0.1 || CGSizeEqualToSize(v.bounds.size, CGSizeZero)) {
                // 即便隐藏也记录首个实例（截满 3 个）
            }
        }
        if (!v.hidden && v.alpha > 0.1 && v.window) {
            CGSize bs = v.bounds.size;
            if (bs.width > 30 && bs.width < 220 && bs.height > 30 && bs.height < 420) {
                CGRect r = [v convertRect:v.bounds toView:win];
                if (r.origin.x > scr.width * 0.55
                    && CGRectGetMidY(r) > scr.height * 0.25
                    && CGRectGetMidY(r) < scr.height * 0.70) {
                    NSString *sig = [NSString stringWithFormat:@"%@(%.0f,%.0f,%.0fx%.0f)",
                                     cn, r.origin.x, r.origin.y, r.size.width, r.size.height];
                    if (![suspects containsObject:sig] && suspects.count < 6) [suspects addObject:sig];
                }
            }
        }
        NSArray *subs = v.subviews;
        if (subs.count) [queue addObjectsFromArray:subs];
    }

    NSString *wi = @"none";
    if (widget) {
        CGRect r = [widget convertRect:widget.bounds toView:win];
        wi = [NSString stringWithFormat:@"(%.0f,%.0f,%.0fx%.0f) hid=%d a=%.2f win=%d tag=%@ sup=%@",
              r.origin.x, r.origin.y, r.size.width, r.size.height,
              widget.hidden, widget.alpha, widget.window != nil,
              ObjectGetter(widget, @"getItemTag") ?: @"nil",
              NSStringFromClass(widget.superview.class)];
    }
    GCDiag(@"S%02d tick=%ld H=%d SB=%d(%0.f) | W=%@ | mid=%s[%@]",
           n, (long)ColdTicks, HomeSettled, SearchBarSettled, SearchBarSettledY,
           wi, suspects.count ? "" : "无", [suspects componentsJoinedByString:@" "]);

    if (CachedCar != lastCar) { GCDiag(@"   * CachedCar -> %@", CachedCar ? NSStringFromClass(CachedCar.class) : @"nil"); lastCar = CachedCar; }
    if (CachedRight != lastRight) { GCDiag(@"   * CachedRight -> %@", CachedRight ? NSStringFromClass(CachedRight.class) : @"nil"); lastRight = CachedRight; }
    if (CachedRoute != lastRoute) { GCDiag(@"   * CachedRoute -> %@", CachedRoute ? NSStringFromClass(CachedRoute.class) : @"nil"); lastRoute = CachedRoute; }
    if (HomeSettled != lastHome) { GCDiag(@"   * HomeSettled %d -> %d", lastHome, HomeSettled); lastHome = HomeSettled; }
    if (SearchBarSettled != lastSettled) { GCDiag(@"   * SearchBarSettled %d -> %d (y=%.0f)", lastSettled, SearchBarSettled, SearchBarSettledY); lastSettled = SearchBarSettled; }
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
                GCDiag(@"  setAlpha:%.2f (旧 %.2f) frame=(%.0f,%.0f)",
                       a, self.alpha, self.frame.origin.x, self.frame.origin.y);
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
                    GCDiag(@"  setFrame:->(%.0f,%.0f,%.0fx%.0f) win系(%.0f,%.0f) hid=%d a=%.2f",
                           rect.origin.x, rect.origin.y, rect.size.width, rect.size.height,
                           r.origin.x, r.origin.y, self.hidden, self.alpha);
                    GCDiagFrameBudget--;
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
    // 采样定时器（200ms）—— 必须存进文件级变量持住，否则 ARC 立即释放
    GCDiagTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    dispatch_source_set_event_handler(GCDiagTimer, ^{ GCDiagSample(); });
    dispatch_source_set_timer(GCDiagTimer, dispatch_time(DISPATCH_TIME_NOW, 200 * NSEC_PER_MSEC),
                              200 * NSEC_PER_MSEC, 20 * NSEC_PER_MSEC);
    dispatch_resume(GCDiagTimer);
    GCDiag(@"采样定时器已启动（200ms x 75 = 15s）");
}