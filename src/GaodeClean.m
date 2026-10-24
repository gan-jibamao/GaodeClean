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
#include "GCStr.h"
#import <objc/message.h>
#import "GCCGeometry.h"

// ---- jibamao 个人标识（编译进 dylib，可用 strings 核对）----
static NSString *const kGCAuthor      = @"jibamao";
static NSString *const kGCRepo        = @"https://gan-jibamao.github.io/";
static NSString *const kGCVersion     = @"0.9.54+trial39";

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
//   空操作 —— 定制行为的字符串不再进入发布二进制。
//   0.9.20（A2）：原「开关/版本类日志走 NSLog」的例外**已取消** —— 那 8 处 NSLog
//   一并清除，发布包内不得再出现任何 `[GaodeClean] ` 日志串（门禁第 5 条双零断言）。
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
        NSString *v = [NSBundle.mainBundle objectForInfoDictionaryKey:GCStrAt(0)] ?: GCStrAt(1);
        k = [NSString stringWithFormat:GCStrAt(2), v];
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
static __weak UIView *Cached2D;          // trial27：2D/3D 模式圆钮（缩放时 App 重排会撂回原生位）
static NSHashTable<UIView *> *GCWeatherHeldRows;   // 0.9.3：冷启动被扣留的天气行（锚点未就绪期间不显示）
static __weak id CachedTabs;
static __weak UIView *SearchBarView;   // 0.5.58   // 0.5.55：用于判断当前是否「首页」选中
static void UpdateMask(UIView *page);
static void Schedule(void);
static void LayoutMinimalHome(id handler);
static void AlignCornerWidgets(UIView *bar);
static void GCStyleDiscoverWidgets(UIWindow *win);   // trial11：实例发现独立成函数（pin 自给自足）
static void GCStylePinWidgets(UIWindow *win);        // trial25(A2)：重入守卫包装前置声明（容器钩子/驱动器用）
static NSMutableSet<NSString *> *GCStyleLayerHookedClasses(void);   // trial26：定义在后，P8 dump 段先用
static BOOL IsRightBottomWidget(UIView *v);            // trial11：前置声明（discover 用）
static BOOL GCCIsLiteGroupCapsule(UIView *v);          // trial11：前置声明（discover 用）
static BOOL FixingHintText;
static __weak UIView *CachedTabBar;

// ★trial38（probe14 日志铁证）：锚点必须**跟随底栏**，不能用窗口绝对坐标。
//   日志：祖先容器 c11:UIView 的 presentation 在 610→570→551→466→439…790→763→702→674 之间被
//   App 连续搬动；同时截图实测底栏三圆钮也从 768 上移到 610 —— 整块 UI（含底栏）一起位移。
//   我们却按 sh-97 的绝对位置往回拉 ⇒ 每帧对拉 = 老大看到的「乱跑/抖动」。
//   原生关系：胶囊底 = 底栏顶 − 13（正常态 768 − 13 = 755，与原式一致）。
// trial39：**取表现层坐标** —— probe14 流水铁证：App 用 CAAnimation 连续搬动控件
//   （py 609→582→558→525→485→451→417→388→360→336→316…），动画跑在 presentation 上；
//   我们钉的是模型层 ⇒ 视觉上永远追不上，只能靠"对拉"硬碰，于是看到抖动/乱跑。
static CGRect GCPresWinRect(UIView *v, UIWindow *win) {
    if (!v || !win) return CGRectZero;
    CALayer *pl = v.layer.presentationLayer;
    CALayer *sv = v.superview.layer.presentationLayer;
    if (pl && sv && win.layer) {
        CGRect r = [sv convertRect:pl.frame toLayer:win.layer];
        if (r.size.width > 0.5 && r.size.height > 0.5) return r;
    }
    return [v convertRect:v.bounds toView:win];
}
static CGFloat GCPinBottom(UIWindow *win) {
    CGFloat sh = win ? win.bounds.size.height : 852.0;
    CGFloat fb = sh - 81 - 16;
    UIView *tb = CachedTabBar;
    if (win && tb && tb.window == win) {
        CGRect r = GCPresWinRect(tb, win);
        if (r.size.height > 20 && r.size.height < 140 && r.origin.y > sh * 0.30)
            return r.origin.y - 13.0;
    }
    return fb;
}
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
static UIView *GCNarrowCapsule(UIView *anchor);           // 0.9.28 缩窄：取可见胶囊
static void GCNarrowTick(void);                          // 0.9.28 缩窄：tick 兜底复核
static void GCProbeTick6(void);                      // probe6：定时取证（前置声明）
#ifdef GAODECLEAN_PROBE
static void GCProbeTick7(void);                      // probe7：pin 链路取证（前置声明）
#endif
#ifdef GAODECLEAN_PROBE
// ══ probe7 全局状态（tick/pin/discover 均可见；正式包整块不编译）══
static double P7T0;
static int P7NTicks, P7DiscCalls, P7DiscSkips, P7PinCalls, P7WTicks;
static int P7Writes[6];      // 0=车机 1=右胶囊 2=路线 3=2D 4=天气行 5=保留
static int P7Solid;          // trial30：2D 钮「实心钉」触发次数（alpha/白底写入）
static CGFloat P7Dx31, P7Dy31;   // trial31：2D 钮父容器 presentation 平移差（诊断跳动来源）
typedef struct { float t, dx, dy; } P32Sample;
static P32Sample P32Dev[6];      // trial32：2D 钮逐帧偏差样本（最近 6 次）
static int P32DevN, P32DevI;     // trial32：偏差帧总数 / 环下标
static int P7WGates[3];      // 0=通过 1=bar非视图 2=评估
static double P7FirstSeen[6], P7FirstPin[6], P7FirstKey;
static __weak UIView *P7LastPW;
static CGRect P7LastCont;
static __weak UIView *P7RowMir;
static BOOL IsWeatherRowClass(NSString *cn);   // probe12：天气行类判定（定义在后）
static NSArray<UIWindow *> *GCAllWindows(void);  // probe12：全窗口枚举（定义在后）
static NSMutableString *P7Log;
static int P7LogN;
static double P7Now(void) { if (!P7T0) P7T0 = CACurrentMediaTime(); return CACurrentMediaTime() - P7T0; }
__attribute__((format(NSString, 1, 2)))
static void P7Note(NSString *fmt, ...) {
    va_list ap; va_start(ap, fmt);
    NSString *m = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    if (!P7Log) P7Log = [NSMutableString string];
    if (P7LogN > 240) { [P7Log deleteCharactersInRange:NSMakeRange(0, P7Log.length / 2)]; P7LogN /= 2; }
    [P7Log appendFormat:@"[%6.1fs] %@\n", P7Now(), m];
    P7LogN++;
}
static CGRect P7WR(UIView *v) {
    if (!v || !v.window) return CGRectNull;
    @try { return [v convertRect:v.bounds toView:nil]; } @catch (__unused NSException *e) { return CGRectNull; }
}
static void P7Write(int idx, CGRect before, CGRect after, CGRect contWin) {
    P7Writes[idx]++;
    if (!P7FirstPin[idx]) P7FirstPin[idx] = P7Now();
    if (P7Writes[idx] <= 8 || P7Writes[idx] % 40 == 0)
        P7Note(@"WRITE#%d n=%d before=%@ after=%@ cont=%@", idx, P7Writes[idx],
               NSStringFromCGRect(before), NSStringFromCGRect(after), NSStringFromCGRect(contWin));
}
#ifdef GAODECLEAN_PROBE
// ★trial34：消失事件哨兵 —— 车机/胶囊/2D 任一「不可见」状态翻转都记一条（时间/原因/坐标）。
//   老大不记得触发时机 ⇒ 让程序自己记：下次 dump 直接给到消失时刻与原因。
typedef struct { float t; int tag, alive, why; float x, y, w, h; } P33Ev;
static P33Ev P33Evs[12];
static int P33EvI, P33EvTotal, P33LastAlive[3] = {-1, -1, -1};
static const char *P33TagName(int tag) { return tag == 0 ? "车机" : (tag == 1 ? "胶囊" : "2D钮"); }
static const char *P33WhyName(int why) {
    switch (why) {
        case 1: return "脱窗"; case 2: return "hidden"; case 3: return "alpha0"; case 4: return "出屏";
        default: return "正常";
    }
}
static void P33Watch(UIView *v, int tag) {
    if (!v) return;
    int alive = 1, why = 0;
    if (!v.window) { alive = 0; why = 1; }
    else if (v.hidden) { alive = 0; why = 2; }
    else if (v.alpha < 0.05f) { alive = 0; why = 3; }
    else {
        CGRect r0 = [v convertRect:v.bounds toView:v.window];
        if (r0.origin.y < -40 || r0.origin.y > v.window.bounds.size.height - 10) { alive = 0; why = 4; }
    }
    if (alive != P33LastAlive[tag]) {
        P33LastAlive[tag] = alive;
        CGRect r = v.window ? [v convertRect:v.bounds toView:v.window] : CGRectZero;
        P33Evs[P33EvI].t = (float)P7Now();
        P33Evs[P33EvI].tag = tag;
        P33Evs[P33EvI].alive = alive;
        P33Evs[P33EvI].why = why;
        P33Evs[P33EvI].x = (float)r.origin.x; P33Evs[P33EvI].y = (float)r.origin.y;
        P33Evs[P33EvI].w = (float)r.size.width; P33Evs[P33EvI].h = (float)r.size.height;
        P33EvI = (P33EvI + 1) % 12;
        P33EvTotal++;
    }
}
// ══ probe11：全局逐帧轨迹取证（纯只读，不写任何几何/透明度/动画）══
//   probe10 教训：3 个事件名额全被冷启动抖动（t<2s）占满，用户点击时刻没记到；
//   「换实例」计数被自身重扫污染。probe11 修正：
//   ① 冷启动豁免 t<8s 不记事件  ② 名额 6、环 120 帧
//   ③ 新增「跳变流水」40 条（每起都记，永不丢）  ④ 天气行升为固定目标
//   ⑤ 实例更换只对固定目标统计，重扫时重置基线
#define P37_MAX 12
#define P37_RING 120
#define P37_EVN 6
#define P37_EVF 40
#define P37_LOG 40
typedef struct { float mx, my, px, py, a; short hid; short idx; } P37Cell;
typedef struct { float t; short tag, from, to, a0, a1; } P37Jmp;   // from/to 为 pt（×1）
static P37Cell P37Ring[P37_RING][P37_MAX];
static float P37RT[P37_RING];
static int P37RingI, P37RingN;
static P37Cell P37Ev[P37_EVN][P37_EVF][P37_MAX];
static float P37EvT[P37_EVN][P37_EVF];
static int P37EvN[P37_EVN], P37EvCnt, P37EvTarget[P37_EVN];
static P37Jmp P37JmpLog[P37_LOG];
static int P37JmpI, P37JmpTotal;
static char P37Name[P37_MAX][72];
static __weak UIView *P37V[P37_MAX];
static int P37N, P37ScanTick, P37PtrSwap;
static void *P37LastPtr[P37_MAX];
static float P37LastPy[P37_MAX], P37LastPx[P37_MAX], P37Jumps[P37_MAX];
static int P37Fixed = 5;   // 前 5 个为固定目标（车机/胶囊/路线/2D钮/天气行）

static void P37RefreshTargets(void) {
    int n = 0;
    UIView *cap = (CachedLiteGroup && CachedLiteGroup.window) ? (UIView *)CachedLiteGroup : (UIView *)CachedRight;
    UIView *fixed[5] = { CachedCar, cap, CachedRoute, Cached2D, P7RowMir };
    const char *fn[5] = { "车机", "胶囊", "路线", "2D钮", "天气行" };
    for (int i = 0; i < 5 && n < P37_MAX; i++) {
        if (!fixed[i]) continue;
        P37V[n] = fixed[i];
        snprintf(P37Name[n], sizeof(P37Name[n]), "%s", fn[i]);
        n++;
    }
    P37Fixed = n;
    // 容器子树补抓（MapWidgetContainerView 及同层），深度 ≤3、尺寸合理、去重
    UIView *seed = CachedCar ? CachedCar.superview : nil;
    if (!seed) seed = cap ? cap.superview : nil;
    if (seed) {
        NSMutableArray *q = [NSMutableArray arrayWithObject:seed];
        int depthGuard = 0;
        while (q.count && n < P37_MAX && depthGuard++ < 400) {
            UIView *v = q.firstObject; [q removeObjectAtIndex:0];
            CGRect r = [v convertRect:v.bounds toView:v.window];
            BOOL dup = NO;
            for (int i = 0; i < n; i++) if (P37V[i] == v) { dup = YES; break; }
            if (!dup && v.window && r.size.width >= 16 && r.size.width <= 420 &&
                r.size.height >= 14 && r.size.height <= 160 && n < P37_MAX) {
                P37V[n] = v;
                snprintf(P37Name[n], sizeof(P37Name[n]), "c%d:%s", n, NSStringFromClass(v.class).UTF8String ?: "?");
                n++;
            }
            if (q.count + v.subviews.count < 120) [q addObjectsFromArray:v.subviews];
        }
    }
    for (int i = n; i < P37_MAX; i++) { P37V[i] = nil; P37Name[i][0] = 0; }
    // ⑤ 重扫后目标换了 ⇒ 重置位置/指针基线，避免把「我自己换目标」记成「App 换实例」
    for (int i = 0; i < P37_MAX; i++) { P37LastPy[i] = 0; P37LastPx[i] = 0; P37LastPtr[i] = NULL; }
    P37N = n;
}
static void P37Sample(void) {
    if (++P37ScanTick >= 15 || P37N == 0) { P37ScanTick = 0; P37RefreshTargets(); }
    float t = (float)P7Now();
    int jumpIdx = -1; float jumpFrom = 0, jumpTo = 0; float jumpA0 = 0, jumpA1 = 0;
    for (int i = 0; i < P37N; i++) {
        UIView *v = P37V[i];
        P37Cell *c = &P37Ring[P37RingI][i];
        memset(c, 0, sizeof(*c));
        c->idx = (short)i;
        if (!v) continue;
        c->hid = (short)v.hidden;
        c->a = (float)v.alpha;
        if (v.window && v.superview) {
            CGRect mr = [v convertRect:v.bounds toView:v.window];
            c->mx = (float)mr.origin.x; c->my = (float)mr.origin.y;
            CALayer *pl = v.layer.presentationLayer;
            CALayer *svp = v.superview.layer.presentationLayer;
            if (pl && svp && v.window.layer) {
                CGRect pr = [svp convertRect:pl.frame toLayer:v.window.layer];
                c->px = (float)pr.origin.x; c->py = (float)pr.origin.y;
            } else { c->px = c->mx; c->py = c->my; }
            void *p = (__bridge void *)v;
            if (i < P37Fixed && P37LastPtr[i] && P37LastPtr[i] != p) {
                P37PtrSwap++;
                if (jumpIdx < 0) { jumpIdx = i; jumpFrom = -1; jumpTo = -1; jumpA0 = c->a; jumpA1 = c->a; }
            }
            P37LastPtr[i] = p;
            if (P37LastPy[i] > 0 && fabsf(c->py - P37LastPy[i]) > 6.0f) {
                P37Jumps[i]++;
                if (jumpIdx < 0) { jumpIdx = i; jumpFrom = P37LastPy[i]; jumpTo = c->py; jumpA0 = c->a; jumpA1 = c->a; }
            }
            if (P37LastPx[i] > 0 && fabsf(c->px - P37LastPx[i]) > 6.0f) {
                P37Jumps[i]++;
                if (jumpIdx < 0) { jumpIdx = i; jumpFrom = P37LastPy[i]; jumpTo = c->py; jumpA0 = c->a; jumpA1 = c->a; }
            }
            P37LastPy[i] = c->py; P37LastPx[i] = c->px;
        }
    }
    P37RT[P37RingI] = t;
    P37RingI = (P37RingI + 1) % P37_RING;
    if (P37RingN < P37_RING) P37RingN++;
    // ③ 跳变流水：t≥8s 后每一跳都记（永不因名额满丢失）
    if (jumpIdx >= 0 && t >= 8.0f) {
        P37JmpLog[P37JmpI].t = t;
        P37JmpLog[P37JmpI].tag = (short)jumpIdx;
        P37JmpLog[P37JmpI].from = (short)(jumpFrom < -32000 ? -32000 : (jumpFrom > 32000 ? 32000 : jumpFrom));
        P37JmpLog[P37JmpI].to = (short)(jumpTo < -32000 ? -32000 : (jumpTo > 32000 ? 32000 : jumpTo));
        P37JmpLog[P37JmpI].a0 = (short)(jumpA0 * 100);
        P37JmpLog[P37JmpI].a1 = (short)(jumpA1 * 100);
        P37JmpI = (P37JmpI + 1) % P37_LOG;
        P37JmpTotal++;
        // ① 事件快照同样 8s 后、名额 6
        if (P37EvCnt < P37_EVN && P37RingN >= 10) {
            int n = P37RingN < P37_EVF ? P37RingN : P37_EVF;
            for (int f = 0; f < n; f++) {
                int idx = (P37RingI - n + f + P37_RING * 2) % P37_RING;
                P37EvT[P37EvCnt][f] = P37RT[idx];
                for (int i = 0; i < P37_MAX; i++) P37Ev[P37EvCnt][f][i] = P37Ring[idx][i];
            }
            P37EvN[P37EvCnt] = n;
            P37EvTarget[P37EvCnt] = jumpIdx;
            P37EvCnt++;
        }
    }
}
// ══ probe12：状态触发取证（纯只读，不写任何几何/透明度）══
//   probe11 教训：故障态只出现在特定时刻，固定时间采样永远错过（5 段采样全是 735/实心）。
//   A1 天气行偏移看门狗：|行顶-735|>8 持续 0.2s ⇒ 当场把「祖先链 model/pres + 对齐计数 +
//      全部天气类实例坐标」拼成快照字符串存下（最多 3 份）。
//   A2 2D 钮「无墨」看门狗：每帧算墨量（自身 bgA + 子树每层 alpha/opacity/contents/hidden），
//      状态翻转 ⇒ 当场把完整子树拼成快照（最多 3 份）。
static NSMutableArray<NSString *> *P39Wx, *P39Ink;
static int P39WxBadFrames, P39LastInkBad = -1;
static double P39WxSince;
static int P39AlignCalls, P39AlignWrites, P39AlignSkipCar, P39AlignSkipReenter;
static int P37ParentFix, P37FreeFix;   // trial37：父容器拉回次数 / 游离天气实例归位次数

static NSString *P39Chain(UIView *v) {
    NSMutableString *s = [NSMutableString string];
    int n = 0;
    for (UIView *p = v; p && p != p.window && n < 12; p = p.superview, n++) {
        CALayer *pl = p.layer.presentationLayer;
        [s appendFormat:@"%@ model=%@ pres=%@ a=%.2f h=%d | ",
            NSStringFromClass(p.class), NSStringFromCGRect(p.layer.frame),
            pl ? NSStringFromCGRect(pl.frame) : @"(nil)", p.alpha, (int)p.hidden];
    }
    return s;
}
static NSString *P39Subtree(UIView *v) {
    NSMutableString *s = [NSMutableString string];
    NSMutableArray *q = [NSMutableArray array];
    if (v) [q addObject:v];
    int n = 0;
    while (q.count && n < 40) {
        UIView *x = q.firstObject; [q removeObjectAtIndex:0]; n++;
        [s appendFormat:@"%@ f=%@ a=%.2f op=%.2f h=%d cts=%d bgA=%.2f | ",
            NSStringFromClass(x.class), NSStringFromCGRect(x.frame), x.alpha,
            x.layer.opacity, (int)x.hidden, x.layer.contents ? 1 : 0,
            x.backgroundColor ? CGColorGetAlpha(x.backgroundColor.CGColor) : 0];
        [q addObjectsFromArray:x.subviews];
    }
    return s;
}
static void P39Store(NSMutableArray *arr, NSString *s) {
    if (!arr) return;
    [arr addObject:s];
    while (arr.count > 3) [arr removeObjectAtIndex:0];
}
static void P39Sample(void) {
    double t = P7Now();
    if (!P39Wx) P39Wx = [NSMutableArray array];
    if (!P39Ink) P39Ink = [NSMutableArray array];
    // ── A1 天气行偏移看门狗
    UIView *row = P7RowMir;
    CGFloat y = -1;
    if (row && row.window) y = [row convertRect:row.bounds toView:row.window].origin.y;
    BOOL wxBad = (y > 0 && fabs(y - 735.0) > 8.0);
    if (wxBad) {
        if (P39WxBadFrames == 0) P39WxSince = t;
        P39WxBadFrames++;
        if (t - P39WxSince > 0.2 && (P39WxBadFrames % 30) == 0) {
            NSMutableString *s = [NSMutableString stringWithFormat:
                @"t=%.1f 行顶=%.0f(目标735) row=%@ chain: ", t, y, NSStringFromClass(row.class)];
            [s appendString:P39Chain(row)];
            [s appendFormat:@"| align 调=%d 写=%d 无车机=%d 重入=%d | 天气类实例: ",
                P39AlignCalls, P39AlignWrites, P39AlignSkipCar, P39AlignSkipReenter];
            for (UIWindow *w in GCAllWindows()) {
                NSMutableArray *q = [NSMutableArray arrayWithObject:w];
                for (NSUInteger i = 0; i < q.count && q.count < 1500; i++) {
                    UIView *v = q[i];
                    [q addObjectsFromArray:v.subviews];
                    if (v.window && IsWeatherRowClass(NSStringFromClass(v.class)))
                        [s appendFormat:@"%@ %@ a=%.2f h=%d / ",
                            NSStringFromClass(v.class),
                            NSStringFromCGRect([v convertRect:v.bounds toView:nil]),
                            v.alpha, (int)v.hidden];
                }
            }
            P39Store(P39Wx, s);
        }
    } else {
        P39WxBadFrames = 0;
    }
    // ── A2 2D 钮「无墨」看门狗
    UIView *b = Cached2D;
    if (b && b.window) {
        CGFloat bgA = b.backgroundColor ? CGColorGetAlpha(b.backgroundColor.CGColor) : 0;
        BOOL anyContent = NO;
        NSMutableArray *q = [NSMutableArray arrayWithObject:b];
        for (NSUInteger i = 0; i < q.count && i < 40; i++) {
            UIView *x = q[i];
            [q addObjectsFromArray:x.subviews];
            if (x.layer.contents && x.alpha > 0.05 && !x.hidden && x.layer.opacity > 0.05) anyContent = YES;
        }
        int inkBad = anyContent ? 0 : 1;   // probe13：只看内容层（bgA 是我们写的白底，不算墨）
        if (inkBad != P39LastInkBad) {
            P39LastInkBad = inkBad;
            NSMutableString *s = [NSMutableString stringWithFormat:
                @"t=%.1f 状态=%@ 按钮=%@ win=%@ a=%.2f bgA=%.2f 子树: ",
                t, inkBad ? @"无墨透明" : @"有墨可见", NSStringFromClass(b.class),
                NSStringFromCGRect([b convertRect:b.bounds toView:nil]), b.alpha, bgA];
            [s appendString:P39Subtree(b)];
            P39Store(P39Ink, s);
        }
    }
}
// ══ probe14：真身定位（纯只读）══
//   矛盾铁证：2D 钮自身 {{339,609.7}} a=1.00 h=0，父容器 h=1 恒被 App 藏起；
//   我们每帧拉回 1009+ 次仍 h=1 ⇒ 屏幕上那颗钮是**另一份绘制**（别的 window / 快照层）。
//   A2：遍历全部 window 找所有 LOTAnimationView / WINAJXCombinedItemView，打印归属与祖先异常。
//   A3：记录 App 对天气类实例的 setFrame:/setCenter: 写入（只记不改）。
static void Replace(Class cls, SEL sel, IMP replacement, const char *types);   // probe14：定义在后
typedef struct { float t; char cls[28]; char sel[12]; float x, y, w, h; int mine; } P41Wr;
static P41Wr P41Wrs[20];
static int P41WrI, P41WrN;
static int P41InAlign;
static void P41Rec(const char *cls, const char *sel, CGRect r, int mine) {
    P41Wr *p = &P41Wrs[P41WrI];
    p->t = (float)P7Now();
    strncpy(p->cls, cls, 27); p->cls[27] = 0;
    strncpy(p->sel, sel, 11); p->sel[11] = 0;
    p->x = (float)r.origin.x; p->y = (float)r.origin.y;
    p->w = (float)r.size.width; p->h = (float)r.size.height;
    p->mine = mine;
    P41WrI = (P41WrI + 1) % 20;
    if (P41WrN < 20) P41WrN++;
}
static NSMutableSet<NSString *> *P41Hooked(void) {
    static NSMutableSet *s;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [NSMutableSet set]; });
    return s;
}
static void P41HookWeatherWrites(void) {
    // 类名必须走混淆表（门禁：明文命中即 FAIL）——113=WINGroupMapWidget
    //   115=WINWeatherLimitView、114=WINScaleLineLogoMapWidget（索引=表行号-1）
    NSArray *names = @[GCStrAt(113), GCStrAt(115), GCStrAt(114)];
    for (NSString *nm in names) {
        Class rc = NSClassFromString(nm);
        if (!rc || [P41Hooked() containsObject:nm]) continue;
        [P41Hooked() addObject:nm];
        Method mf = class_getInstanceMethod(rc, @selector(setFrame:));
        if (mf) {
            IMP o = method_getImplementation(mf);
            const char *t = method_getTypeEncoding(mf);
            Replace(rc, @selector(setFrame:), imp_implementationWithBlock(^(UIView *self, CGRect f) {
                ((void (*)(id, SEL, CGRect))o)(self, @selector(setFrame:), f);
                P41Rec([nm UTF8String], "setFrame:", self.frame, P41InAlign);
            }), t);
        }
        Method mc = class_getInstanceMethod(rc, @selector(setCenter:));
        if (mc) {
            IMP o2 = method_getImplementation(mc);
            const char *t2 = method_getTypeEncoding(mc);
            Replace(rc, @selector(setCenter:), imp_implementationWithBlock(^(UIView *self, CGPoint c) {
                ((void (*)(id, SEL, CGPoint))o2)(self, @selector(setCenter:), c);
                P41Rec([nm UTF8String], "setCenter:", self.frame, P41InAlign);
            }), t2);
        }
    }
}
// 全窗口找「2D/3D 钮真身」：任何含 LOTAnimationView / WINAJXCombinedItemView 的方形视图
static NSString *P41LottieList(void) {
    NSMutableString *s = [NSMutableString string];
    Class cItem = NSClassFromString(@"WINAJXCombinedItemView");
    Class cLot = NSClassFromString(@"LOTAnimationView");
    int wi = 0, cnt = 0;
    for (UIWindow *w in GCAllWindows()) {
        wi++;
        NSMutableArray *q = [NSMutableArray arrayWithObject:w];
        for (NSUInteger i = 0; i < q.count && q.count < 3000; i++) {
            UIView *v = q[i];
            [q addObjectsFromArray:v.subviews];
            if (!v.window) continue;
            if (!((cItem && [v isKindOfClass:cItem]) || (cLot && [v isKindOfClass:cLot]))) continue;
            cnt++;
            CGRect r = [v convertRect:v.bounds toView:nil];
            // 祖先链第一个异常层
            NSString *bad = @"";
            int n = 0;
            for (UIView *p = v.superview; p && n < 12; p = p.superview, n++) {
                if (p.hidden || p.alpha < 0.05f || p.layer.opacity < 0.05f) {
                    bad = [NSString stringWithFormat:@" 祖先%@(h=%d,a=%.2f,op=%.2f)",
                           NSStringFromClass(p.class), (int)p.hidden, p.alpha, p.layer.opacity];
                    break;
                }
                if (p == p.window) break;
            }
            [s appendFormat:@"[w%d]%@ %@ a=%.2f h=%d%@%@ / ", wi,
                NSStringFromClass(v.class), NSStringFromCGRect(r),
                v.alpha, (int)v.hidden,
                (v.window == Cached2D.window && Cached2D && CGRectEqualToRect(r, [Cached2D convertRect:Cached2D.bounds toView:nil])) ? @"★同位" : @"",
                bad];
        }
    }
    if (!cnt) [s appendString:@"(无)"];
    return s;
}
// ══ probe13：替身/可见性取证（纯只读）══
//   probe12 教训：墨量判据把「我们自己写的白底」当成墨 ⇒ 永远判不出透明；
//   且未检查祖先与 window 可见性、未查是否存在第二个实例。
static NSString *P40WeatherList(void) {
    NSMutableString *s = [NSMutableString string];
    for (UIWindow *w in GCAllWindows()) {
        NSMutableArray *q = [NSMutableArray arrayWithObject:w];
        for (NSUInteger i = 0; i < q.count && q.count < 2000; i++) {
            UIView *v = q[i];
            [q addObjectsFromArray:v.subviews];
            if (!v.window) continue;
            if (!IsWeatherRowClass(NSStringFromClass(v.class))) continue;
            [s appendFormat:@"%@ %@ a=%.2f h=%d%@ winh=%d wina=%.2f / ",
                NSStringFromClass(v.class), NSStringFromCGRect([v convertRect:v.bounds toView:nil]),
                v.alpha, (int)v.hidden, (v == P7RowMir) ? @"★缓存" : @"",
                (int)v.window.hidden, v.window.alpha];
        }
    }
    return s.length ? s : @"(无)";
}
static NSString *P40BtnInfo(void) {
    NSMutableString *s = [NSMutableString string];
    UIView *b = Cached2D;
    if (!b) return @"Cached2D=nil";
    [s appendString:@"祖先链: "];
    int n = 0;
    for (UIView *p = b; p && n < 14; p = p.superview, n++) {
        [s appendFormat:@"%@ h=%d a=%.2f op=%.2f | ",
            NSStringFromClass(p.class), (int)p.hidden, p.alpha, p.layer.opacity];
        if (p == p.window) break;
    }
    UIWindow *w = b.window;
    if (w) [s appendFormat:@"window h=%d a=%.2f bounds=%@ key=%d | ",
        (int)w.hidden, w.alpha, NSStringFromCGRect(w.bounds), (int)w.isKeyWindow];
    [s appendString:@"候选: "];
    Class cItem = NSClassFromString(@"WINAJXCombinedItemView");
    Class cLot = NSClassFromString(@"LOTAnimationView");
    int cnt = 0;
    for (UIWindow *ww in GCAllWindows()) {
        NSMutableArray *q = [NSMutableArray arrayWithObject:ww];
        for (NSUInteger i = 0; i < q.count && q.count < 2000; i++) {
            UIView *v = q[i];
            [q addObjectsFromArray:v.subviews];
            if (!v.window) continue;
            CGRect r = [v convertRect:v.bounds toView:nil];
            if (r.size.width < 30 || r.size.width > 60) continue;
            if (fabs(r.size.width - r.size.height) > 10) continue;
            if (CGRectGetMidX(r) < v.window.bounds.size.width - 64) continue;
            BOOL hit = NO;
            NSMutableArray *qq = [NSMutableArray arrayWithObject:v];
            for (NSUInteger k = 0; k < qq.count && k < 20; k++) {
                UIView *x = qq[k];
                [qq addObjectsFromArray:x.subviews];
                if ((cItem && [x isKindOfClass:cItem]) || (cLot && [x isKindOfClass:cLot])) { hit = YES; break; }
            }
            if (!hit) continue;
            cnt++;
            [s appendFormat:@"%@ %@ a=%.2f h=%d%@ / ", NSStringFromClass(v.class), NSStringFromCGRect(r),
                v.alpha, (int)v.hidden, (v == b) ? @"★我们盯的" : @""];
        }
    }
    if (!cnt) [s appendString:@"(无)"];
    return s;
}
#endif
#endif

#ifdef GAODECLEAN_PROBE
// ══ probe8：2D/3D 切换车机位漂移定罪（帧级 presentation 分歧 + 驱动率 + 容器钩子）══
static long P8Fires, P8Busy, P8NoWin, P8ContHooks, P8Diverge;
static long P8LayerFires, P8LayerFixes;   // trial26：layer setter 钩子命中/纠偏计数
static double P8CarMinY = 1e9, P8CarMaxY = -1e9, P8LastDvLog = -100;
static NSMutableSet<NSString *> *GCStylePosHookedClasses(void);   // dump 打印前置声明（定义在后）
__attribute__((unused)) static void P8Trace(void) {
    P8Fires++;
    UIView *car = CachedCar;
    if (!car || !car.window) return;
    double y = P7WR(car).origin.y;
    if (y < P8CarMinY) P8CarMinY = y;
    if (y > P8CarMaxY) P8CarMaxY = y;
    // 分歧检测：车机自身 layer + 祖先链 —— presentationLayer.frame ≠ layer.frame
    //   ⇒ 该层正被动画/过渡驱动（写模型层拦不住显示层），当场抓出类名与动画键
    for (UIView *v = car; v && v != v.window; v = v.superview) {
        CALayer *pl = v.layer.presentationLayer;
        if (pl && !CGRectEqualToRect(pl.frame, v.layer.frame)) {
            P8Diverge++;
            if (P7Now() - P8LastDvLog > 0.4) {
                P8LastDvLog = P7Now();
                P7Note(@"P8DIVERGE %@ model=%@ pres=%@ keys=%@", NSStringFromClass(v.class),
                       NSStringFromCGRect(v.layer.frame), NSStringFromCGRect(pl.frame), v.layer.animationKeys ?: @[]);
            }
            break;
        }
    }
}
#endif
static void GCNarrowApply(UIView *anchor, BOOL isSearch); // 0.9.28 缩窄：点对点夹取
static long GCNarrowBorderFixes;                 // 诊断计数（定义在缩窄模块，此处暂定声明）
static long GCNarrowAmbFixes;                  // 诊断计数（暂定声明）
static long GCNarrowHairHits;                  // 诊断计数（暂定声明）
static CGFloat GCNarrowTargetWidth(void);        // 目标宽访问器（探针在缩窄模块之前，需前置）
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
    id path = ObjectGetter(page, GCStrAt(3));
    return [path isKindOfClass:NSString.class] ? path : @"";
}

static NSInteger PageKind(NSString *path) {
    // Exact page allowlist: other pages in these bundles remain untouched.
    NSString *p = [[path componentsSeparatedByString:GCStrAt(1)] firstObject];
    if ([p hasSuffix:GCStrAt(4)]) return 1;
    if ([p hasSuffix:GCStrAt(5)]) return 2;
    if ([p hasSuffix:GCStrAt(6)]) return 2;
    if ([p hasSuffix:GCStrAt(7)]) return 3;
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
    UIView *view = ObjectGetter(controller, GCStrAt(8)) ?: ObjectGetter(controller, GCStrAt(9));
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
    BOOL is = [cn hasPrefix:GCStrAt(10)];
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
        dispatch_once(&once, ^{ getters = @[GCStrAt(11), GCStrAt(12), GCStrAt(13)]; });
        for (NSString *getter in getters) {
            id value = ObjectGetter(v, getter);
            if ([value isKindOfClass:NSAttributedString.class]) value = [value string];
            if ([value isKindOfClass:NSString.class] && [value length] < 160) [s appendFormat:GCStrAt(14), value];
        }
    }
    NSString *label = v.accessibilityLabel;
    if (label.length < 160) [s appendFormat:GCStrAt(14), label ?: @""];
    NSString *meta = objc_getAssociatedObject(v, &TextKey);
    if (meta) [s appendFormat:GCStrAt(14), meta];
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
    NSArray *primary = kind == 1 ? @[GCStrAt(15)] : kind == 2 ? @[GCStrAt(16), GCStrAt(17), GCStrAt(18), GCStrAt(19), GCStrAt(20)] : @[GCStrAt(21), GCStrAt(22)];
    NSArray *secondary = kind == 1 ? @[GCStrAt(23), GCStrAt(24), GCStrAt(25)] : kind == 2 ? @[GCStrAt(17), GCStrAt(18), GCStrAt(19), GCStrAt(20)] : @[GCStrAt(26), GCStrAt(27), GCStrAt(28)];
    UIView *anchor = nil, *peer = nil;
    CGFloat boundary = 0;
    if (kind == 3) {
        for (UIView *node in nodes) {
            if (!Visible(node) || ![NodeText(node) containsString:GCStrAt(29)] || node.bounds.size.height > 80) continue;
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
            CGFloat bottom = [cached[GCStrAt(30)] doubleValue];
            if (fabs([cached[GCStrAt(31)] doubleValue] - page.bounds.size.width) < 1 && bottom > 100 && bottom < page.bounds.size.height) {
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
            GCLog(GCStrAt(32), (long)kind);
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
        if (fabs([cached[GCStrAt(30)] doubleValue] - boundary) > 0.5 || fabs([cached[GCStrAt(31)] doubleValue] - page.bounds.size.width) > 0.5)
            [NSUserDefaults.standardUserDefaults setObject:@{GCStrAt(31):@(page.bounds.size.width), GCStrAt(30):@(boundary)} forKey:GCBoundaryKey()];
    }
    BindBoundary(page, anchor, peer, boundary, state);
    if (!state.reportedMatch) {
        GCLog(GCStrAt(33), (long)kind, (unsigned long)state.scrolls.count);
        state.reportedMatch = YES;
    }
}

#if GCC_DEVICE_TEST
// Built only for this SSH regression session; absent from the delivery package.
static void RunDeviceCheck(void) {
    NSString *dir = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    NSString *request = [dir stringByAppendingPathComponent:GCStrAt(34)];
    NSString *pageName = [[NSString stringWithContentsOfFile:request encoding:NSUTF8StringEncoding error:nil]
                         stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (!pageName) return;
    [NSFileManager.defaultManager removeItemAtPath:request error:nil];
    NSInteger index = [pageName isEqual:GCStrAt(35)] ? 1 : ([@[GCStrAt(36), GCStrAt(37)] containsObject:pageName] ? 0 : -1);
    if (index < 0) return;
    for (id tabs in TabControllers.allObjects) {
        id params = ObjectGetter(tabs, GCStrAt(38));
        UIView *view = ObjectGetter(tabs, GCStrAt(9));
        if (![params isKindOfClass:NSArray.class] || [params count] < 2 || !view.window) continue;
        NSMutableArray *tabNames = [NSMutableArray array];
        for (NSUInteger i = 0; i < [params count]; i++) {
            id item = params[i];
            NSString *className = ObjectGetter(item, GCStrAt(39));
            [tabNames addObject:className ?: GCStrAt(40)];
            if ([pageName isEqual:GCStrAt(35)] && [className isEqual:GCStrAt(41)]) index = i;
        }
        SEL select = NSSelectorFromString(GCStrAt(42));
        if (![tabs respondsToSelector:select]) continue;
        if (![pageName isEqual:GCStrAt(37)]) ((void (*)(id, SEL, NSInteger, id))objc_msgSend)(tabs, select, index, nil);
        if ([pageName isEqual:GCStrAt(37)]) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 500 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
                for (id handler in HomeHandlers.allObjects) {
                    UIView *bar = ObjectGetter(handler, GCStrAt(43));
                    SEL tap = NSSelectorFromString(GCStrAt(44));
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
            UIView *actualTab = ObjectGetter(tabs, GCStrAt(45));
            if (actualTab) [widgets addObject:@{GCStrAt(46):GCStrAt(47), GCStrAt(48):@(actualTab.hidden), GCStrAt(49):@(actualTab.alpha), GCStrAt(50):NSStringFromClass(actualTab.superview.class) ?: GCStrAt(51), GCStrAt(52):@(actualTab.window != nil), GCStrAt(53):NSStringFromCGRect(actualTab.frame)}];
            for (UIView *v in Flatten(window)) {
                NSString *cls = NSStringFromClass(v.class);
                if ([cls containsString:GCStrAt(54)] || [cls containsString:GCStrAt(55)] || [cls containsString:GCStrAt(56)] || [cls containsString:GCStrAt(57)]) {
                    NSMutableDictionary *entry = [@{GCStrAt(46):cls, GCStrAt(53):NSStringFromCGRect([v convertRect:v.bounds toView:window]), GCStrAt(48):@(v.hidden)} mutableCopy];
                    for (NSString *key in @[GCStrAt(58), GCStrAt(59), GCStrAt(60)] ) {
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
                [results addObject:@{GCStrAt(61): @(Kind(page)), GCStrAt(53): NSStringFromCGRect(blank.frame),
                                     GCStrAt(62): hit ? NSStringFromClass(hit.class) : GCStrAt(51), GCStrAt(63): @(blank.opaque),
                                     GCStrAt(64): @(blank.gestureRecognizers.count)}];
            }
            NSData *json = [NSJSONSerialization dataWithJSONObject:@{GCStrAt(65):pageName, GCStrAt(66):results, GCStrAt(67):widgets, GCStrAt(68):tabNames} options:NSJSONWritingPrettyPrinted error:nil];
            [json writeToFile:[dir stringByAppendingPathComponent:[NSString stringWithFormat:GCStrAt(69),pageName]] atomically:YES];
            if (window) {
                UIGraphicsBeginImageContextWithOptions(window.bounds.size, NO, 1);
                [window drawViewHierarchyInRect:window.bounds afterScreenUpdates:YES];
                UIImage *image = UIGraphicsGetImageFromCurrentImageContext();
                UIGraphicsEndImageContext();
                [UIImagePNGRepresentation(image) writeToFile:[dir stringByAppendingPathComponent:[NSString stringWithFormat:GCStrAt(70),pageName]] atomically:YES];
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
            id selected = ObjectGetter(tabs, GCStrAt(71));
            id params = ObjectGetter(tabs, GCStrAt(38));
            if ([params isKindOfClass:NSArray.class]) for (id item in params) {
                if (selected && ObjectGetter(item, GCStrAt(72)) == selected) {
                    id title = ObjectGetter(item, GCStrAt(73));
                    id label = ObjectGetter(item, GCStrAt(60));
                    static NSArray<NSString *> *nearbyTitles;
                    static dispatch_once_t once;
                    dispatch_once(&once, ^{ nearbyTitles = @[GCStrAt(74), GCStrAt(75)]; });
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
            UIView *hb = ObjectGetter(handler, GCStrAt(43));
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
            UIView *bar = ObjectGetter(handler, GCStrAt(43));
            if ([bar isKindOfClass:UIView.class]) {
                AlignCornerWidgets(bar);
                AlignWeatherRowTick(bar.window);
#ifdef GAODECLEAN_PROBE
                P7WTicks++;
#endif
            }
#ifdef GAODECLEAN_PROBE
            else P7WGates[1]++;
#endif
        }
        // 0.7.0：开屏广告兜底（有界窗口内）
        SplashAdTick();
        // 0.6.7：底栏「上拉发现」提示的周期通道 —— 引导态常常晚于最后一次布局才落地，
        // 只挂 layout 就是这个 bug 偶发的根因。扫描范围只有底栏子树，开销可忽略。
        // 0.7.4(A6)：「上拉发现」是 200ms~1s 级的异步引导态，5Hz 采样过剩，降到 2.5Hz。
        if (CachedTabBar && TickCount % 2 == 0) SweepTabBarHints(CachedTabBar);
        if (TickCount % 5 == 0 || TickCount < 40) GCNarrowTick();   // 0.9.28 兜底复核（幂等）；trial12(B1)：冷启动头 8s 每拍都跑，闪变窗口压到 ≤1 拍
#ifdef GAODECLEAN_PROBE
        GCProbeTick6();   // probe6：5/15/30s 取证
        GCProbeTick7();   // probe7：5/15/30/45/60s pin 取证
#endif
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
    id render = ObjectGetter(element, GCStrAt(76)) ?: ObjectGetter(element, GCStrAt(77));
    UIView *page = ObjectGetter(render, GCStrAt(78));
    if (![page isKindOfClass:UIView.class] || !Kind(page)) return;
    [Pages addObject:page];
    UIView *view = ObjectGetter(element, GCStrAt(9));
    if ([view isKindOfClass:UIView.class]) {
        id model = ObjectGetter(element, GCStrAt(79));
        id attrs = ObjectGetter(model, GCStrAt(80));
        NSMutableString *text = [NSMutableString string];
        if ([attrs isKindOfClass:NSDictionary.class]) {
            for (NSString *key in @[GCStrAt(13), GCStrAt(73), GCStrAt(81), GCStrAt(82), GCStrAt(60), GCStrAt(83)]) {
                id value = attrs[key];
                if ([value isKindOfClass:NSString.class] && [value length] < 160)
                    [text appendFormat:GCStrAt(14), value];
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

// 目的：一次拿到搜索栏 / 底栏的真实视图层级 + 规则 dry-run 判定 ——
//       终结「靠截图反推层级」（0.9.22~0.9.26 五版全部栽在层级猜错上）。
// 取数据：最新全文自动写入**系统剪贴板**（回聊天直接粘贴给我）；同时写
//         Documents/GaodeClean-probe.txt，并 NSLog 出完整路径作后备。

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
        return;
    }
    IMP original = method_getImplementation(m);
    IMP imp = imp_implementationWithBlock(^(id self) {
        ((void (*)(id, SEL))original)(self, sel);
        after(self);
    });
    Replace(cls, sel, imp, method_getTypeEncoding(m));
}

// ══════════════════════════════════════════════════════════════════════════
//  缩窄 v6（0.9.28 试验版）—— 依据 0.9.27+probe1 真机层级实测，点对点夹取
// ───────────────────────────────────────────────────────────────────────────
//  实测结构（393×852pt，探针 dump #2）：
//   · 搜索栏 anchor = WINQuickSearchBarV2  win=[0,702,393,54]（满宽、透明）
//       └ 可见白胶囊 = 直接子层 UIVisualEffectView win=[8,702,377,54] corner=27
//       └ 相机 UIButton own=[293,3,48,48]、语音 LTMVUIEmojiView own=[341,11,32,32]
//         （两枚按钮浮在胶囊上、挂在 anchor 上，右缘距胶囊右缘 12pt、彼此相邻）
//   · 底栏 anchor = WINTabBar  win=[0,768,393,60]（满宽、透明）
//       └ 可见胶囊 = 直接子层 UIVisualEffectView win=[21,768,351,60] corner=30
//       └ 描边高亮图 UIImageView own=[19,-2,355,64]（= 胶囊外扩 2pt）
//       └ 环境阴影图 own=[-3,-24,399,108]（整条栏的，不属于胶囊 ⇒ 不动）
//       └ 页签 WINTabBarItem 中心 ±60、选中底衬 [86.5,771,100,54]
//         都在 anchor 上、不在胶囊内 ⇒ 改胶囊宽度不会拽动页签，无需动按钮。
//  策略：只 hook 这两个 anchor 类的 layoutSubviews（App 具体类，作用域天然受限），
//        原实现执行完后按**绝对几何**写胶囊 x/w；全程幂等、不 hook 任何系统类。
//  定值：目标可见宽 240pt —— 由内容边界决定的最小等宽值：
//        底栏必须包住「页签 94.5..298.5 + 选中底衬 86.5..186.5」= 并集 86.5..298.5，
//        居中后最小 236pt，取整 240（选中底衬距胶囊边留 10pt）。
// ══════════════════════════════════════════════════════════════════════════
static const CGFloat GCNarrowTargetW = 240.0;   // 两条栏的目标可见宽
__attribute__((unused)) static CGFloat GCNarrowTargetWidth(void) { return GCNarrowTargetW; }
__attribute__((unused)) static const CGFloat GCNarrowBtnGap  = 12.0;    // 原生：最右按钮右缘距胶囊右缘 12pt
__attribute__((unused)) static const CGFloat GCNarrowAmbPad  = 24.0;    // 底栏环境层原生比胶囊每侧外扩 ~24pt（399 vs 351）
__attribute__((unused)) static long GCNarrowBorderFixes = 0;      // 诊断：描边同步累计写入次数
__attribute__((unused)) static long GCNarrowAmbFixes = 0;         // 诊断：环境层同步累计写入次数
__attribute__((unused)) static long GCNarrowHairHits = 0;       // 诊断：发丝线处理累计次数
static BOOL GCNarrowSearchHooked = NO;

// 取 anchor 的「可见胶囊」：毛玻璃层 + 栏级尺寸 + 居中
__attribute__((unused)) static UIView *GCNarrowCapsule(UIView *anchor) {
    if (!anchor) return nil;
    CGFloat sw = anchor.bounds.size.width;
    if (sw < 200) return nil;
    UIView *best = nil; CGFloat bw = 0;
    for (UIView *v in anchor.subviews) {
        if (v.hidden || v.alpha < 0.05) continue;
        if (![v isKindOfClass:UIVisualEffectView.class]) continue;
        CGRect f = v.frame;
        if (f.size.height < 40 || f.size.height > 120) continue;
        // ★A2：下界不能是 sw-140 —— 夹取后胶囊宽 240 会掉出判据，导致下一拍再也找不到胶囊、
        //   GCNarrowApply 直接 return，App 把伴生层改回原生时我们永久失去纠正能力（trial1 教训）。
        if (f.size.width < GCNarrowTargetW - 2 || f.size.width > sw - 4) continue;
        if (fabs(CGRectGetMidX(f) - sw * 0.5) > 10) continue;
        if (f.size.width > bw) { best = v; bw = f.size.width; }
    }
    return best;
}
// 胶囊内部的满幅背景层（防 autoresizing 未生效）：x≈0 且宽超出胶囊的，收进胶囊
__attribute__((unused)) static void GCNarrowInnerFix(UIView *v, CGFloat capW, int depth, NSInteger *budget) {
    if (!v || depth > 3 || *budget <= 0) return;
    (*budget)--;
    for (UIView *c in v.subviews) {
        CGRect f = c.frame;
        if (f.origin.x <= 2 && f.size.width > capW + 8) { f.size.width = capW; c.frame = f; }
        GCNarrowInnerFix(c, capW, depth + 1, budget);
    }
}
// ★trial8：全窗口 layer 扫荡 —— 收两种漏网形态：
//   A 透明填充+有边(border/shadow/corner/位图)+高44~64+宽≥0.6sw+同带 ⇒ 夹到胶囊几何
//     （若为某 UIView 的 backing layer，改写属主 view 的 frame，防被其布局改回）
//   B 高≤3 的发丝线层+宽≥0.6sw+落在搜索栏带内(±30) ⇒ 只夹宽到 240
//   已知好层天然不命中：白底(α0.9 不透明)、胶囊/内图(已 240，宽差=0 跳过)、
//   渐变(无边)、底栏各层(midY 不在带内)。
__attribute__((unused)) static void GCNarrowHairWalk(CALayer *la, CGRect band, CGFloat midY, CGFloat sw, CGFloat x, int depth, NSInteger *budget) {
    if (!la || depth > 12 || *budget <= 0) return;
    (*budget)--;
    CGRect wr = CGRectNull;
    @try { wr = [la convertRect:la.bounds toLayer:nil]; } @catch (__unused NSException *e) { return; }
    CGFloat al = la.backgroundColor ? CGColorGetAlpha(la.backgroundColor) : 0.0;
    BOOL inBandY = fabs(CGRectGetMidY(wr) - midY) <= 6;
    BOOL wideEnough = (wr.size.width >= sw * 0.6 && wr.size.width <= sw + 10);
    BOOL edged = (la.borderWidth > 0.01 || la.shadowOpacity > 0.01 || la.cornerRadius > 0.01 || la.contents != nil);
    BOOL shapeA = (!la.hidden && wideEnough && inBandY && wr.size.height >= 44 && wr.size.height <= 64
                   && al <= 0.05 && edged && fabs(wr.size.width - GCNarrowTargetW) > 0.5);
    // trial9：形态B 放宽 —— 发丝线可能只是 76pt 短线段（trial8 的 ≥0.6sw 漏掉）；
    //   高≤4 + 宽≥30 + 带内±34 ⇒ 直接隐藏（alpha=0）。带外（home 指示条/底栏）天然不命中。
    BOOL shapeB = (!la.hidden && wr.size.height <= 4 && wr.size.width >= 30
                   && fabs(CGRectGetMidY(wr) - midY) <= 34 && fabs(wr.size.width - GCNarrowTargetW) > 0.5);
    // ★trial11 形态C：原生尺寸"快照/描边残留"（probe 取证 5s 之后才出现、不属任何正常层）：
    //   带位图或描边（contents!=nil 或 borderWidth>0.1）+ 高40~130 + 宽280~屏宽 + 带心±45 ⇒ 直接隐藏。
    //   白底/胶囊/描边图均 contents=nil 且 bw=0 ⇒ 天然不命中；图标宽<280；地图 Metal 层高852。
    BOOL shapeC = (!la.hidden && la.opacity > 0.02f && (la.contents != nil || la.borderWidth > 0.1)
                   && wr.size.height >= 40 && wr.size.height <= 130
                   && wr.size.width >= 280 && wr.size.width <= sw + 10
                   && fabs(CGRectGetMidY(wr) - midY) <= 45
                   && fabs(wr.size.width - GCNarrowTargetW) > 0.5);
    // trial9 的形态B 曾被错嵌在 if(shapeA) 内 ⇒ 死代码；trial11 修正为独立分支。
    if (shapeB || shapeC) { if (la.opacity > 0.01f) { la.opacity = 0; GCNarrowHairHits++; } }
    if (shapeA) {
        CGRect target = CGRectMake(x, band.origin.y, GCNarrowTargetW, band.size.height);
        UIView *owner = [la.delegate isKindOfClass:UIView.class] ? (UIView *)la.delegate : nil;
        if (owner && owner.superview) {
            CGRect local = [owner.superview convertRect:target fromView:nil];
            if (!CGRectEqualToRect(local, owner.frame)) owner.frame = local;
        } else if (la.superlayer) {
            CGRect local = [la.superlayer convertRect:target fromLayer:nil];
            if (!CGRectEqualToRect(local, la.frame)) { [la removeAllAnimations]; la.frame = local; }
        }
    }
    for (CALayer *c in [la.sublayers copy]) GCNarrowHairWalk(c, band, midY, sw, x, depth + 1, budget);
}
__attribute__((unused)) static void GCNarrowHairlineSweep(UIView *anchor, CGFloat sw, CGFloat x) {
    CGRect band = [anchor convertRect:anchor.bounds toView:nil];
    CGFloat midY = CGRectGetMidY(band);
    for (UIWindow *w in GCAllWindows()) {
        if (w.hidden || w.bounds.size.width < 200) continue;
        NSInteger budget = 600;
        GCNarrowHairWalk(w.layer, band, midY, sw, x, 0, &budget);
    }
}
// ★trial10（probe5 定罪）：白底层 shd=0.20/shr=20 —— 带阴影的层在 frame 被夹窄后，
//   显式 shadowPath / shouldRasterize 缓存**不会自动跟随** ⇒ 阴影仍按原生 377 圆角矩形绘制
//   ⇒ 顶/底切线处的"发丝线"（右到 385、左 8pt 那条被裁图裁掉）。每次写完 frame 必须失效缓存。
static void GCNarrowInvalidateRender(CALayer *la) {
    if (!la) return;
    @try {
        la.shadowPath = nil;
        if (la.shouldRasterize) la.shouldRasterize = NO;
        [la setNeedsDisplay];
        [la setNeedsLayout];
    } @catch (__unused NSException *e) {}
}
// ★A1（probe3 破案）：App 把搜索栏白底画成**直接挂在 anchor.layer 上的独立 CALayer**，
//   没有对应 UIView —— 只夹 UIVisualEffectView 时它原地不动，于是"图标缩了、白底还是 377 宽"。
//   实测：CALayer win=[8,702,377,54] corner=27 bg=rgba(1,1,1,0.90) + 同尺寸 CAGradientLayer。
//   底栏无此类层（白来自胶囊内部 UICABackdropLayer）⇒ 本函数在底栏天然空转。
__attribute__((unused)) static void GCNarrowStandaloneLayers(UIView *anchor, CGFloat sw, CGFloat x) {
    NSArray *layers = [anchor.layer.sublayers copy];
    for (CALayer *la in layers) {
        if (la.hidden || la.opacity < 0.02f) continue;
        BOOL backing = NO;
        for (UIView *v in anchor.subviews) if (v.layer == la) { backing = YES; break; }
        if (backing) continue;                       // 子视图的 backing layer 已由 UIView 路径处理
        CGRect f = la.frame;
        if (f.size.height < 40 || f.size.height > 120) continue;
        if (f.size.width < GCNarrowTargetW - 2 || f.size.width > sw - 4) continue;
        if (fabs(CGRectGetMidX(f) - sw * 0.5) > 20) continue;
        CGRect g = f; g.origin.x = x; g.size.width = GCNarrowTargetW;
        if (!CGRectEqualToRect(g, f)) { la.frame = g; GCNarrowInvalidateRender(la); }
    }
}
// ★trial13（0.9.30+trial1）：圆形悬浮钮统一风格 —— 幂等、绝对几何
static void GCStyleCenterIcon(UIView *root, CGFloat d, CGFloat icon, int depth) {
    if (!root || depth > 4) return;
    for (UIView *w in root.subviews) {
        CGRect f = w.frame;
        if ([w isKindOfClass:UIImageView.class] && fabs(f.size.width - icon) < 1.5 && fabs(f.size.height - icon) < 1.5) {
            CGRect g = CGRectMake((d - icon) * 0.5, (d - icon) * 0.5, icon, icon);
            if (!CGRectEqualToRect(g, f)) w.frame = g;
            continue;
        }
        GCStyleCenterIcon(w, d, icon, depth + 1);
    }
}
// 搜索栏 → 单枚 54pt 圆钮（anchor 保持原生满宽，**不碰 anchor 几何** —— trial2 的
//   anchor 缩尺寸/移位与 App 启动期布局对撞导致卡启动，trial3 回退）。
//   圆外触摸由 GCStyleHookSearchHitTest 返回 nil ⇒ 只点圆钮才进搜索。
// ★trial4：圆形风格专用胶囊匹配 —— 旧 GCNarrowCapsule 下界 238 会让 54 圆钮掉出判据
//   （hitTest 钩子拿不到圆 ⇒ 全宽放行 = 「左右还能进搜索」真凶）。下界改 40。
static UIView *GCStyleCapsule(UIView *anchor) {
    if (!anchor) return nil;
    CGFloat sw = anchor.bounds.size.width;
    if (sw < 100) return nil;
    UIView *best = nil; CGFloat bw = 0;
    for (UIView *v in anchor.subviews) {
        if (v.hidden || v.alpha < 0.05) continue;
        if (![v isKindOfClass:UIVisualEffectView.class]) continue;
        CGRect f = v.frame;
        if (f.size.height < 40 || f.size.height > 120) continue;
        if (f.size.width < 40 || f.size.width > sw - 4) continue;
        if (fabs(CGRectGetMidX(f) - sw * 0.5) > 10) continue;
        if (f.size.width > bw) { best = v; bw = f.size.width; }
    }
    return best;
}
static void GCStyleHookSearchHitTest(void) {
    static BOOL done = NO;
    if (done) return;
    Class cls = NSClassFromString(@"WINQuickSearchBarV2");
    if (!cls) return;
    done = YES;
    SEL sel = @selector(hitTest:withEvent:);
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) return;
    IMP original = method_getImplementation(m);
    Replace(cls, sel, imp_implementationWithBlock(^UIView *(UIView *self, CGPoint point, UIEvent *event) {
        UIView *cap = GCStyleCapsule(self);
        if (cap && !CGRectContainsPoint(cap.frame, point)) return nil;   // 圆外：不响应、不挡地图
        return ((UIView *(*)(id, SEL, CGPoint, id))original)(self, sel, point, event);
    }), method_getTypeEncoding(m));
}
// ★trial6：祖先 hitTest 路由 —— 搜索圆钮下移后，anchor 原生行不再响应、圆钮矩形内触摸直达胶囊
//   （触摸命中胶囊后 anchor 的 tap 手势随冒泡触发 ⇒ 搜索照开；其余区域原样返回）。
static void GCStyleHookAncestorHitTest(UIView *anchor) {
    static NSHashTable *hooked = nil;
    UIView *sup = anchor.superview;
    UIWindow *win = anchor.window;
    if (!sup || !win) return;
    if (!hooked) hooked = [NSHashTable weakObjectsHashTable];
    Class cls = sup.class;
    if ([hooked containsObject:cls]) return;
    [hooked addObject:cls];
    SEL sel = @selector(hitTest:withEvent:);
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) return;
    IMP original = method_getImplementation(m);
    Replace(cls, sel, imp_implementationWithBlock(^UIView *(UIView *self, CGPoint p, UIEvent *e) {
        UIView *r = ((UIView *(*)(id, SEL, CGPoint, id))original)(self, sel, p, e);
        // trial7：改用全局弱引用判定（同名 RootView 嵌套两层，superview==self 会被短路）：任何一层祖先都路由。
        UIView *bar = SearchBarView;
        UIView *tb = CachedTabBar;
        if ((bar && !bar.hidden) || (tb && !tb.hidden)) {
            CGPoint pw = [self convertPoint:p toView:nil];
            CGFloat cw = win.bounds.size.width, ch = win.bounds.size.height;
            if (bar && !bar.hidden) {
                CGRect circleW = CGRectMake((cw - 54) * 0.5, ch - 81, 54, 54);
                if (CGRectContainsPoint(circleW, pw)) {
                    UIView *cap = GCStyleCapsule(bar);
                    if (cap) return cap;
                }
                if (r == bar || [r isDescendantOfView:bar]) return nil;   // 旧搜索行/anchor 其余：不进搜索
            }
            // ★trial8：底栏同样收圆 —— App 底栏 tap 手势按 x 判页（首页圆左=首页、我的圆右=我的）。
            //   两圆之外、落到底栏 anchor/子树的触摸一律 nil（不切页、不挡地图）。
            if (tb && !tb.hidden && (r == tb || [r isDescendantOfView:tb])) {
                CGRect hR = CGRectMake(cw * 0.5 - 72 - 27, ch - 81, 54, 54);
                CGRect mR = CGRectMake(cw * 0.5 + 72 - 27, ch - 81, 54, 54);
                if (!CGRectContainsPoint(hR, pw) && !CGRectContainsPoint(mR, pw)) return nil;
            }
        }
        return r;
    }), method_getTypeEncoding(m));
}
static void GCStyleSearch(UIView *anchor) {
    GCStyleHookSearchHitTest();
    GCStyleHookAncestorHitTest(anchor);
    CGFloat sw = anchor.bounds.size.width;
    if (sw < 100) return;
    const CGFloat d = 54.0, x = (sw - d) * 0.5;
    const CGFloat rowDy = 69.0;   // trial6：搜索行 702 → 底栏行 771（三圆钮同行）；只写 subview center，anchor 零几何改动
    UIView *cap = GCStyleCapsule(anchor);
    if (cap) {
        CGPoint ct = CGPointMake(x + d * 0.5, d * 0.5 + rowDy);
        if (!CGPointEqualToPoint(ct, cap.center)) cap.center = ct;
        CGRect bd = CGRectMake(0, 0, d, d);
        if (!CGRectEqualToRect(bd, cap.bounds)) cap.bounds = bd;
        cap.layer.cornerRadius = d * 0.5;
        GCStyleCenterIcon(cap, d, 24.0, 0);   // 放大镜居中
    }
    for (CALayer *la in [anchor.layer.sublayers copy]) {   // 独立白底/渐变层同夹成圆
        if (la.hidden || la.opacity < 0.02f) continue;
        BOOL backing = NO;
        for (UIView *v in anchor.subviews) if (v.layer == la) { backing = YES; break; }
        if (backing) continue;
        CGRect f = la.frame;
        if (f.size.height < 40 || f.size.height > 120) continue;
        CGRect g = CGRectMake(x, f.origin.y + rowDy, d, f.size.height);
        if (!CGRectEqualToRect(g, f)) { la.frame = g; GCNarrowInvalidateRender(la); }
        la.cornerRadius = f.size.height * 0.5;
    }
    CALayer *mk = anchor.layer.mask;   // mask 保圆
    if (!mk) { mk = [CALayer layer]; anchor.layer.mask = mk; }
    mk.frame = CGRectMake(x, rowDy, d, d);
    mk.cornerRadius = d * 0.5;
    mk.backgroundColor = [UIColor blackColor].CGColor;
    for (UIView *v in anchor.subviews) {   // 拍照/语音隐藏
        if ([v isKindOfClass:UIButton.class] ||
            [NSStringFromClass(v.class) isEqualToString:@"LTMVUIEmojiView"]) v.hidden = YES;
    }
}
// ★trial4：底栏子树递归杀阴影 —— 不论 App 把阴影挂在哪一层（item/subitem/图标/底衬），
//   一次扫净；每 tick 重扫防 App 选中态回挂（首页旁灰影真凶族）。
static void GCStyleKillShadows(CALayer *la, int depth) {
    if (!la || depth > 5) return;
    if (la.shadowOpacity > 0.001f) { la.shadowOpacity = 0; }
    la.shadowPath = nil;
    for (CALayer *c in la.sublayers) GCStyleKillShadows(c, depth + 1);
}
// 底栏 → 两枚 54pt 圆钮（中心 c±33，总占地 120 = 原 240 的一半）；pill 族全隐藏
static void GCStyleTab(UIView *anchor) {
    CGFloat sw = anchor.bounds.size.width;
    if (sw < 100) return;
    const CGFloat d = 54.0, c = sw * 0.5, off = 72.0;   // trial6：三圆钮同行 @ c-72 / c / c+72（间隙18）
    GCStyleKillShadows(anchor.layer, 0);   // trial4：子树阴影一次扫净
    for (UIView *v in [anchor.subviews copy]) {
        if ([v isKindOfClass:UIVisualEffectView.class] || [v isKindOfClass:UIImageView.class]) { v.hidden = YES; continue; }
        CGRect f = v.frame;
        // trial5（probe6 定罪）：选中底衬被 App 改成 70×54 且切页回显 —— 旧宽窗 [90,110] 漏配 = 重影圆真凶。
        //   改判据：背景α∈(0.01,0.2) + 宽[40,120] + 高(40,60]（圆钮α0.92 天然排除）；每 tick 重隐。
        CGFloat ba = v.backgroundColor ? CGColorGetAlpha(v.backgroundColor.CGColor) : 0;
        if (f.size.height > 40 && f.size.height <= 60 && f.size.width >= 40 && f.size.width <= 120
            && ba > 0.01 && ba < 0.2 && !v.hidden && ![v isKindOfClass:UIControl.class]) v.hidden = YES;
        // trial5：渐变环境容器（满宽普通 UIView，trial6 逻辑随旧体退役）回补隐藏，防地球视图硬边白带
        if (f.size.width >= sw - 8 && f.size.height >= 60 && f.size.height <= 160
            && v.alpha > 0.01 && ![v isKindOfClass:UIControl.class]
            && ![NSStringFromClass(v.class) isEqualToString:@"WINTabBarItem"]) v.alpha = 0;
    }
    NSMutableArray *items = [NSMutableArray array];
    for (UIView *v in anchor.subviews)
        if ([NSStringFromClass(v.class) isEqualToString:@"WINTabBarItem"]) [items addObject:v];
    [items sortUsingComparator:^NSComparisonResult(UIView *a, UIView *b) {
        return a.frame.origin.x < b.frame.origin.x ? NSOrderedAscending : NSOrderedDescending;
    }];
    for (NSUInteger i = 0; i < items.count && i < 2; i++) {
        UIView *it = items[i];
        CGFloat cx = c + (i == 0 ? -off : off);
        CGRect g = CGRectMake(cx - d * 0.5, it.frame.origin.y, d, d);
        if (!CGRectEqualToRect(g, it.frame)) it.frame = g;
        it.layer.cornerRadius = d * 0.5;
        it.layer.masksToBounds = YES;
        it.layer.shadowOpacity = 0; it.layer.shadowPath = nil;   // trial14：杀 App 遗留阴影（首页左侧灰影真凶）
        if (!it.backgroundColor) it.backgroundColor = [UIColor colorWithWhite:0.96 alpha:0.92];
        for (UIView *si in it.subviews) {   // subitem 同步 54；图标居中；标签隐藏
            CGRect sf = CGRectMake(0, 0, d, d);
            if (!CGRectEqualToRect(sf, si.frame)) si.frame = sf;
            si.layer.shadowOpacity = 0; si.layer.shadowPath = nil;
            for (UIView *w in si.subviews) {
                if ([w isKindOfClass:UIImageView.class]) {
                    CGRect wf = w.frame;
                    CGRect wg = CGRectMake((d - wf.size.width) * 0.5, (d - wf.size.height) * 0.5, wf.size.width, wf.size.height);
                    if (!CGRectEqualToRect(wg, wf)) w.frame = wg;
                } else if ([w isKindOfClass:UILabel.class]) w.hidden = YES;
            }
        }
    }
}
// ══ probe6（仅 -DGAODECLEAN_PROBE=1 编译）：底栏/搜索栏全参数取证 ══
static NSMutableString *GCProbeBuf6;
static BOOL GCProbeBusy6;
static NSString *GCProbeColor6(CGColorRef cg) {
    if (!cg) return @"nil";
    size_t n = CGColorGetNumberOfComponents(cg);
    const CGFloat *c = CGColorGetComponents(cg);
    if (n >= 4) return [NSString stringWithFormat:@"rgba(%.2f,%.2f,%.2f,%.2f)", c[0], c[1], c[2], c[3]];
    if (n >= 1) return [NSString stringWithFormat:@"w(%.2f,%.2f)", c[0], n > 1 ? c[1] : 1.0];
    return @"?";
}
static void GCProbeView6(NSMutableString *o, UIView *v, int depth) {
    if (!v || depth > 4) return;
    CALayer *la = v.layer;
    CGRect wr = CGRectNull;
    @try { wr = [v convertRect:v.bounds toView:nil]; } @catch (__unused NSException *e) {}
    [o appendFormat:@"%*sV %@ own=%@ win=%@ hid=%d a=%.2f bg=%@ corner=%.1f clip=%d bw=%.2f shd=%.2f shr=%.1f off=(%.1f,%.1f) cts=%@ sub=%lu\n",
        depth * 2, "", NSStringFromClass(v.class), NSStringFromCGRect(v.frame), NSStringFromCGRect(wr),
        v.hidden, v.alpha, GCProbeColor6(la.backgroundColor), la.cornerRadius, la.masksToBounds, la.borderWidth,
        la.shadowOpacity, la.shadowRadius, la.shadowOffset.width, la.shadowOffset.height,
        la.contents ? NSStringFromClass([la.contents class]) : @"nil", (unsigned long)v.subviews.count];
    for (UIView *c in v.subviews) GCProbeView6(o, c, depth + 1);
}
static void GCProbeLayer6(NSMutableString *o, CALayer *la, int depth) {
    if (!la || depth > 4) return;
    CGRect wr = CGRectNull;
    @try { wr = [la convertRect:la.bounds toLayer:nil]; } @catch (__unused NSException *e) {}
    [o appendFormat:@"%*sL %@ win=%@ op=%.2f hid=%d bg=%@ corner=%.1f bw=%.2f shd=%.2f shr=%.1f off=(%.1f,%.1f) cts=%@ mob=%d\n",
        depth * 2, "", NSStringFromClass(la.class), NSStringFromCGRect(wr), la.opacity, la.hidden,
        GCProbeColor6(la.backgroundColor), la.cornerRadius, la.borderWidth, la.shadowOpacity, la.shadowRadius,
        la.shadowOffset.width, la.shadowOffset.height, la.contents ? NSStringFromClass([la.contents class]) : @"nil",
        la.masksToBounds];
    for (CALayer *c in la.sublayers) GCProbeLayer6(o, c, depth + 1);
}
static void GCProbeDump6(NSString *reason) {
    if (GCProbeBusy6) return;
    GCProbeBusy6 = YES;
    NSMutableString *o = [NSMutableString stringWithString:GCProbeBuf6 ?: @""];
    [o appendFormat:@"\n===== dump reason=%@ t=%.1fs build=%@ =====\n", reason,
        CACurrentMediaTime(), kGCVersion];
    UIView *tab = CachedTabBar, *bar = SearchBarView;
    [o appendString:@"---[tab anchor view tree]---\n"];
    if (tab) GCProbeView6(o, tab, 0); else [o appendString:@"  (nil)\n"];
    [o appendString:@"---[tab anchor layer tree]---\n"];
    if (tab) GCProbeLayer6(o, tab.layer, 0); else [o appendString:@"  (nil)\n"];
    [o appendString:@"---[search anchor view tree]---\n"];
    if (bar) GCProbeView6(o, bar, 0); else [o appendString:@"  (nil)\n"];
    [o appendString:@"---[search anchor layer tree]---\n"];
    if (bar) GCProbeLayer6(o, bar.layer, 0); else [o appendString:@"  (nil)\n"];
    GCProbeBuf6 = o;
    @try { [UIPasteboard generalPasteboard].string = o; } @catch (__unused NSException *e) {}
    @try {
        NSString *dir = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
        [o writeToFile:[dir stringByAppendingPathComponent:@"GaodeClean-probe.txt"]
            atomically:YES encoding:NSUTF8StringEncoding error:nil];
    } @catch (__unused NSException *e) {}
    GCProbeBusy6 = NO;
}
__attribute__((unused)) static void GCProbeTick6(void) {
    static double t0 = 0;
    static int stage = 0;
    if (!t0) t0 = CACurrentMediaTime();
    double dt = CACurrentMediaTime() - t0;
    int want = (dt > 30) ? 3 : (dt > 15) ? 2 : (dt > 5) ? 1 : 0;
    if (want > stage) { stage = want; GCProbeDump6([NSString stringWithFormat:@"timer%d", want]); }
}
#ifdef GAODECLEAN_PROBE
// ══ probe7：pin 链路取证（dump/扫描）══
static BOOL IsWeatherRowClass(NSString *cn);   // 定义在后，冗余前置声明合法
static NSString *P7Chain(UIView *v) {
    NSMutableString *o = [NSMutableString string];
    UIView *p = v.superview;
    for (int i = 0; i < 4 && p; i++, p = p.superview)
        [o appendFormat:@"←%@ ", NSStringFromClass(p.class)];
    return o;
}
static void P7Inst(NSMutableString *o, const char *tag, UIView *v) {
    [o appendFormat:@"  %-10s ptr=%p alive=%d win=%@ hid=%d a=%.2f key=%d chain=%@\n",
        tag, (void *)v, v != nil, NSStringFromCGRect(P7WR(v)), v.hidden, v.alpha,
        (v && objc_getAssociatedObject(v, &AlignedKey)) ? 1 : 0, v ? P7Chain(v) : @"-"];
}
static void P7LiveScan(NSMutableString *o) {
    NSArray *wins = GCAllWindows();
    int budget = 3000, found = 0;
    [o appendString:@"---[probe7 全窗口活实例扫描]---\n"];
    for (UIWindow *w in wins) {
        if (![w isKindOfClass:UIWindow.class] || w.hidden) continue;
        NSMutableArray *q = [NSMutableArray arrayWithObject:w];
        while (q.count && budget-- > 0) {
            UIView *v = q.firstObject; [q removeObjectAtIndex:0];
            NSString *cn = NSStringFromClass(v.class);
            BOOL mCar = [cn isEqualToString:GCStrAt(140)];
            BOOL mRou = [cn isEqualToString:GCStrAt(141)];
            BOOL mRight = IsRightBottomWidget(v);
            BOOL mLite = GCCIsLiteGroupCapsule(v);
            BOOL mWea = IsWeatherRowClass(cn);
            BOOL mCont = [cn isEqualToString:@"MapWidgetContainerView"] || [cn isEqualToString:@"WINMapSideBarWidgetContainerView"] || [cn isEqualToString:@"GDTransparentView"];
            if (mCar || mRou || mRight || mLite || mWea || mCont) {
                const char *tag = mCar ? "车机" : mRou ? "路线胶囊" : mRight ? "右下控件" : mLite ? "LiteGroup" : mWea ? "天气行" : "容器";
                BOOL cached = (v == CachedCar) || (v == CachedRight) || (v == CachedRoute) || (v == CachedLiteGroup) || (v == P7RowMir);
                [o appendFormat:@"  %-12s %@ win=%@ hid=%d a=%.2f key=%d %@sub=%lu chain=%@\n",
                    tag, cn, NSStringFromCGRect(P7WR(v)), v.hidden, v.alpha,
                    objc_getAssociatedObject(v, &AlignedKey) ? 1 : 0,
                    cached ? @"★缓存 " : @"", (unsigned long)v.subviews.count, P7Chain(v)];
                if (++found > 60) { [o appendString:@"  ...(截断)\n"]; return; }
            }
            [q addObjectsFromArray:v.subviews];
        }
    }
    if (!found) [o appendString:@"  (0 命中)\n"];
}
static void GCProbeDump7(NSString *reason) {
    NSMutableString *o = [NSMutableString string];
    [o appendFormat:@"\n########## probe7 dump reason=%@ t=%.1fs 构建=%@ ##########\n", reason, P7Now(), kGCVersion];
    [o appendFormat:@"TickCount=%d settled=%d | pin调=%d discover调=%d(早退%d) narrowTick=%d 天气tick=%d\n",
        TickCount, SearchBarSettled, P7PinCalls, P7DiscCalls, P7DiscSkips, P7NTicks, P7WTicks];
    [o appendFormat:@"天气行门: 评估=%d 通过=%d bar非视图=%d\n", P7WGates[2], P7WGates[0], P7WGates[1]];
    [o appendFormat:@"写入次数: 车机=%d 胶囊=%d 路线=%d 2D=%d\n", P7Writes[0], P7Writes[1], P7Writes[2], P7Writes[3]];
    [o appendFormat:@"时间线(s): 车机 见=%.1f 钉=%.1f | 胶囊 %.1f/%.1f | 路线 %.1f/%.1f | 天气门首过=%.1f | KEY=%.1f\n",
        P7FirstSeen[0], P7FirstPin[0], P7FirstSeen[1], P7FirstPin[1], P7FirstSeen[2], P7FirstPin[2], P7FirstSeen[4], P7FirstKey];
    [o appendFormat:@"P8驱动: fires=%ld(%.0f/s) busySkip=%ld noWin=%ld 容器钩=%ld 分歧帧=%ld 车机Y[min=%.1f max=%.1f 跨度=%.1f]\n",
        P8Fires, P8Fires / (P7Now() > 0.5 ? P7Now() : 0.5), P8Busy, P8NoWin, P8ContHooks, P8Diverge,
        P8CarMinY > 1e8 ? -1.0 : P8CarMinY, P8CarMaxY < -1e8 ? -1.0 : P8CarMaxY,
        (P8CarMinY > 1e8 || P8CarMaxY < -1e8) ? -1.0 : P8CarMaxY - P8CarMinY];
    [o appendFormat:@"P8 layerフック: fires=%ld fixes=%ld フック済みレイヤークラス=%@\n",
        P8LayerFires, P8LayerFixes, [GCStyleLayerHookedClasses() allObjects]];
    // ★probe9：右侧带候选全扫描 —— 2D/3D 钮真身与文字绘制方式一次定罪
    //   （trial28 dump 铁证：label text="2D"/"3D" 假设不成立，2D钮行消失+2D=0）
    {
        UIView *cap9 = (CachedLiteGroup && CachedLiteGroup.window) ? (UIView *)CachedLiteGroup : (UIView *)CachedRight;
        UIWindow *w9m = cap9.window ?: CachedCar.window;
        if (cap9 && w9m) {
            CGRect capw9 = [cap9 convertRect:cap9.bounds toView:nil];
            CGFloat sw9 = w9m.bounds.size.width;
            [o appendFormat:@"---[右侧带候选 30~60pt正方 midX>%.0f midY∈(%.0f,%.0f)]---\n",
                sw9 - 64, capw9.origin.y - 200, capw9.origin.y + 120];
            for (UIWindow *w9 in GCAllWindows()) {
                NSMutableArray *q9 = [NSMutableArray arrayWithObject:w9];
                int n9 = 0;
                while (q9.count && n9 < 3000) {
                    UIView *v9 = q9.firstObject; [q9 removeObjectAtIndex:0]; n9++;
                    CGRect r9 = [v9 convertRect:v9.bounds toView:nil];
                    CGFloat ww9 = r9.size.width, hh9 = r9.size.height;
                    if (ww9 >= 30 && ww9 <= 60 && hh9 >= 30 && hh9 <= 60 && fabs(ww9 - hh9) <= 10 &&
                        CGRectGetMidX(r9) > sw9 - 64 &&
                        CGRectGetMidY(r9) > capw9.origin.y - 200 && CGRectGetMidY(r9) < capw9.origin.y + 120) {
                        [o appendFormat:@"%@ win=%@ hid=%d a=%.2f sub=%lu cr=%.1f\n",
                            NSStringFromClass(v9.class), NSStringFromCGRect(r9), v9.hidden, v9.alpha,
                            (unsigned long)v9.subviews.count, v9.layer.cornerRadius];
                        for (UIView *s9 in v9.subviews) {
                            NSMutableString *d9 = [NSMutableString stringWithFormat:@"    sub %@ own=%@ hid=%d",
                                NSStringFromClass(s9.class), NSStringFromCGRect(s9.frame), s9.hidden];
                            if ([s9 isKindOfClass:[UILabel class]]) {
                                UILabel *l9 = (UILabel *)s9;
                                [d9 appendFormat:@" text='%@' attr=%@", l9.text ?: @"", l9.attributedText ? @"Y" : @"N"];
                                if (l9.attributedText) [d9 appendFormat:@" attrStr='%@'", l9.attributedText.string ?: @""];
                            }
                            if ([s9 isKindOfClass:[UIImageView class]])
                                [d9 appendFormat:@" img=%@", ((UIImageView *)s9).image ? @"Y" : @"N"];
                            if (s9.layer.contents)
                                [d9 appendFormat:@" lcts=%@", NSStringFromClass([s9.layer.contents class])];
                            [o appendFormat:@"%@\n", d9];
                            for (UIView *t9 in s9.subviews) {
                                NSMutableString *e9 = [NSMutableString stringWithFormat:@"      sub2 %@ own=%@",
                                    NSStringFromClass(t9.class), NSStringFromCGRect(t9.frame)];
                                if ([t9 isKindOfClass:[UILabel class]])
                                    [e9 appendFormat:@" text='%@' attr=%@", ((UILabel *)t9).text ?: @"",
                                        ((UILabel *)t9).attributedText ? @"Y" : @"N"];
                                if ([t9 isKindOfClass:[UIImageView class]])
                                    [e9 appendFormat:@" img=%@", ((UIImageView *)t9).image ? @"Y" : @"N"];
                                if (t9.layer.contents)
                                    [e9 appendFormat:@" lcts=%@", NSStringFromClass([t9.layer.contents class])];
                                [o appendFormat:@"%@\n", e9];
                            }
                        }
                    }
                    [q9 addObjectsFromArray:v9.subviews];
                }
            }
        }
    }
    if (Cached2D)   // trial27：2D 钮自证行；trial30 补 alpha/白底α/实心钉；trial31 补父容器 Δ 与父类名
        [o appendFormat:@"2D钮 %@ win=%@ hid=%d a=%.2f bgA=%.2f 实心=%d sup=%@ d=(%.1f,%.1f)\n",
            NSStringFromClass(Cached2D.class),
            NSStringFromCGRect([Cached2D convertRect:Cached2D.bounds toView:nil]), Cached2D.hidden,
            Cached2D.alpha,
            Cached2D.backgroundColor ? CGColorGetAlpha(Cached2D.backgroundColor.CGColor) : 0,
            P7Solid, NSStringFromClass(Cached2D.superview.class), P7Dx31, P7Dy31];
#ifdef GAODECLEAN_PROBE
    if (Cached2D) {   // trial32：跳动取证 —— 偏差帧总数 + 最近 6 个样本（t=秒, dx/dy=偏离目标的 pt）
        NSMutableString *p32s = [NSMutableString string];
        for (int i32 = 0; i32 < 6; i32++) {
            if (P32Dev[i32].t <= 0) continue;
            [p32s appendFormat:@"(t=%.1f dx=%.1f dy=%.1f) ", P32Dev[i32].t, P32Dev[i32].dx, P32Dev[i32].dy];
        }
        [o appendFormat:@"P32偏差: 帧数=%d 最近=%@\n", P32DevN, p32s.length ? p32s : @"(无)"];
    }
    {   // trial34：消失事件（时间 / 哪个钮 / 现或隐 / 原因 / 当时窗口系坐标）
        NSMutableString *e34 = [NSMutableString string];
        for (int i34 = 0; i34 < 12; i34++) {
            if (P33Evs[i34].t <= 0) continue;
            [e34 appendFormat:@"(t=%.1f %s%s %s r=(%.0f,%.0f,%.0f,%.0f)) ",
                P33Evs[i34].t, P33TagName(P33Evs[i34].tag), P33Evs[i34].alive ? "现" : "隐",
                P33WhyName(P33Evs[i34].why), P33Evs[i34].x, P33Evs[i34].y,
                P33Evs[i34].w, P33Evs[i34].h];
        }
        [o appendFormat:@"P33事件: 总数=%d 最近=%@\n", P33EvTotal, e34.length ? e34 : @"(无)"];
    }
    {   // probe10：全局逐帧轨迹（目标清单 + 每目标跳变次数 + 跳变事件的全目标快照）
        NSMutableString *tl = [NSMutableString string];
        for (int i = 0; i < P37N; i++)
            [tl appendFormat:@"[%d]%s(跳%.0f) ", i, P37Name[i], P37Jumps[i]];
        [o appendFormat:@"P37目标(%d): %@ 换实例=%d 帧数=%d\n", P37N, tl, P37PtrSwap, P37RingN];
        for (int e = 0; e < P37EvCnt; e++) {
            int tg = P37EvTarget[e];
            int n = P37EvN[e];
            [o appendFormat:@"  [跳变%d 目标=%d:%s 帧=%d] ", e + 1, tg,
                (tg >= 0 && tg < P37_MAX) ? P37Name[tg] : "?", n];
            for (int f = 0; f < n; f++)
                [o appendFormat:@"(t=%.2f mx=%.0f my=%.0f px=%.0f py=%.0f a=%.2f h=%d) ",
                    P37EvT[e][f], P37Ev[e][f][tg].mx, P37Ev[e][f][tg].my,
                    P37Ev[e][f][tg].px, P37Ev[e][f][tg].py,
                    P37Ev[e][f][tg].a, P37Ev[e][f][tg].hid];
            [o appendString:@"\n"];
            // 同帧其它目标的首末变化（谁跟它一起动）
            NSMutableString *others = [NSMutableString string];
            for (int i = 0; i < P37_MAX; i++) {
                if (i == tg || P37Name[i][0] == 0) continue;
                float d0 = P37Ev[e][0][i].py, d1 = P37Ev[e][n - 1][i].py;
                if (fabsf(d1 - d0) > 3.0f)
                    [others appendFormat:@"%s:%.0f→%.0f ", P37Name[i], d0, d1];
            }
            if (others.length) [o appendFormat:@"    同步位移: %@\n", others];
        }
        // probe11：跳变流水（t≥8s 起每一起都记，40 条环，永不因名额满丢失）
        [o appendFormat:@"P37流水: 总数=%d\n", P37JmpTotal];
        for (int i = 0; i < P37_LOG; i++) {
            P37Jmp *j = &P37JmpLog[i];
            if (j->t <= 0) continue;
            [o appendFormat:@"  (t=%.2f 目标=%d:%s py %d→%d a %.2f→%.2f) ", j->t, j->tag,
                (j->tag >= 0 && j->tag < P37_MAX) ? P37Name[j->tag] : "?",
                (int)j->from, (int)j->to, j->a0 / 100.0, j->a1 / 100.0];
        }
        [o appendString:@"\n"];
    }
    {   // probe12：状态触发快照（故障态当场记录，不依赖采样时刻）
        [o appendFormat:@"P39天气行快照(%lu份) 对齐: 调=%d 写=%d 无车机=%d 重入=%d\n",
            (unsigned long)(P39Wx ? P39Wx.count : 0), P39AlignCalls, P39AlignWrites,
            P39AlignSkipCar, P39AlignSkipReenter];
        for (NSString *s39 in P39Wx) [o appendFormat:@"  · %@\n", s39];
        [o appendFormat:@"P39墨量快照(%lu份)\n", (unsigned long)(P39Ink ? P39Ink.count : 0)];
        for (NSString *s39 in P39Ink) [o appendFormat:@"  · %@\n", s39];
        [o appendFormat:@"P40修正: 父容器=%d 游离实例=%d\n", P37ParentFix, P37FreeFix];
        [o appendFormat:@"P41 Lottie真身: %@\n", P41LottieList()];
        [o appendString:@"P41 天气写入: "];
        for (int i41 = 0; i41 < 20; i41++) {
            P41Wr *p41 = &P41Wrs[(P41WrI - 20 + i41 + 40) % 20];
            if (p41->t <= 0) continue;
            [o appendFormat:@"(t=%.1f %s %s y=%.0f %@) ", p41->t, p41->cls, p41->sel,
                p41->y, p41->mine ? @"我方" : @"App"];
        }
        [o appendString:@"\n"];
        [o appendFormat:@"P40天气实例: %@\n", P40WeatherList()];
        [o appendFormat:@"P40 2D钮: %@\n", P40BtnInfo()];
    }
#endif
    if (CachedCar) {
        CALayer *p8pl = CachedCar.layer.presentationLayer;
        NSMutableString *p8tf = [NSMutableString string];
        for (UIView *v = CachedCar; v && v != v.window; v = v.superview)
            if (!CGAffineTransformIsIdentity(v.transform))
                [p8tf appendFormat:@"%@=%@ ", NSStringFromClass(v.class), NSStringFromCGAffineTransform(v.transform)];
        [o appendFormat:@"P8车机: ptr=%p win=%@ a=%.2f model=%@ pres=%@ animKeys=%@ transform=%@ 祖先变换=%@ sup=%@\n",
            (__bridge void *)CachedCar, NSStringFromCGRect(P7WR(CachedCar)), CachedCar.alpha,
            NSStringFromCGRect(CachedCar.layer.frame),
            p8pl ? NSStringFromCGRect(p8pl.frame) : @"(无分歧)",
            CachedCar.layer.animationKeys ?: @[],
            NSStringFromCGAffineTransform(CachedCar.transform),
            p8tf.length ? p8tf : @"(全identity)",
            NSStringFromClass(CachedCar.superview.class)];
    } else {
        [o appendString:@"P8车机: CachedCar=nil\n"];
    }
    [o appendFormat:@"P8容器类: MapWidget=%d SideBar=%d GDTrans=%d 已挂=%@\n",
        NSClassFromString(@"MapWidgetContainerView") != nil,
        NSClassFromString(@"WINMapSideBarWidgetContainerView") != nil,
        NSClassFromString(@"GDTransparentView") != nil,
        [GCStylePosHookedClasses() allObjects]];
    [o appendString:@"---[缓存实例现状]---\n"];
    P7Inst(o, "车机", CachedCar);
    P7Inst(o, "右下", CachedRight);
    P7Inst(o, "路线", CachedRoute);
    P7Inst(o, "LiteGrp", CachedLiteGroup);
    P7Inst(o, "天气行", P7RowMir);
    P7LiveScan(o);
    [o appendString:@"---[事件日志(近段)]---\n"];
    [o appendString:P7Log ?: @"(空)\n"];
    P8CarMinY = 1e9; P8CarMaxY = -1e9;   // probe8：每段 dump 的车机 Y 跨度独立统计
    NSMutableString *full = [NSMutableString string];
    if (GCProbeBuf6.length > 100000)
        [full appendString:[GCProbeBuf6 substringFromIndex:GCProbeBuf6.length - 100000]];
    else if (GCProbeBuf6) [full appendString:GCProbeBuf6];
    [full appendString:o];
    GCProbeBuf6 = full;
    @try { [UIPasteboard generalPasteboard].string = full; } @catch (__unused NSException *e) {}
    @try {
        NSString *dir = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
        [full writeToFile:[dir stringByAppendingPathComponent:@"GaodeClean-probe.txt"] atomically:YES encoding:NSUTF8StringEncoding error:nil];
    } @catch (__unused NSException *e) {}
}
__attribute__((unused)) static void GCProbeTick7(void) {
    static int stage = 0;
    double dt = P7Now();
    int want = (dt > 120) ? 7 : (dt > 90) ? 6 : (dt > 60) ? 5 : (dt > 45) ? 4 : (dt > 30) ? 3 : (dt > 15) ? 2 : (dt > 5) ? 1 : 0;
    if (want > stage) { stage = want; GCProbeDump7([NSString stringWithFormat:@"p7定时%d", want]); }
}
#endif

// trial11：实例发现（缓存失效才 BFS）—— 从 AlignCornerWidgets 收归，pin 自给自足
// ★trial27：2D/3D 模式圆钮识别 —— 录屏铁证：缩放地图时 App 重排把 2D 钮撂回原生相对位
//   （下移 ~58pt 叠到胶囊顶、盖住定位图标）。特征：右侧带内 36~56pt 近正方、非隐藏、
//   不在四个已缓存控件的子树内（路线胶囊 44×44 同带同侧，必须靠祖先链排除）。
static BOOL GCStyleIs2DBtn(UIView *v, UIWindow *win) {
    if (!v || !win) return NO;                            // hidden/alpha 判据在 pin 侧（2D 模式 App 藏钮仍缓存）
    CGRect wr = [v convertRect:v.bounds toView:win];
    CGFloat w = wr.size.width, h = wr.size.height;
    if (w < 36 || w > 56 || h < 36 || h > 56 || fabs(w - h) > 6) return NO;
    if (CGRectGetMidX(wr) < win.bounds.size.width - 64) return NO;
    for (UIView *p = v.superview; p; p = p.superview)
        if (p == CachedRight || p == CachedRoute || p == CachedCar || p == CachedLiteGroup) return NO;
    UIView *cap = (CachedLiteGroup && CachedLiteGroup.window) ? (UIView *)CachedLiteGroup : (UIView *)CachedRight;
    CGFloat capTop;
    if (cap) capTop = [cap convertRect:cap.bounds toView:win].origin.y;
    else capTop = win.bounds.size.height - 97 - 88;      // 兜底：pinBottom - 胶囊高
    CGFloat cy = CGRectGetMidY(wr);
    if (cy < capTop - 160 || cy > capTop + 80) return NO;   // 竖带：正常位(帽上~42pt)与叠帽态都覆盖
    if (v == CachedCar || v == CachedRight || v == CachedRoute || v == CachedLiteGroup) return NO;
    // ★trial29（probe9 定罪）：决定性特征 = 子树含 WINAJXCombinedItemView（兜底 LOTAnimationView）。
    //   probe9 dump 铁证：2D/3D 钮真身 = UIView(cr=100) > WINAJXCombinedItemView >
    //   GDDesignTokenImageView(3D 模式 hid=1) + LOTAnimationView ——「2D」文字是 Lottie 动画，
    //   不是 UILabel（trial28 label 判据永远打不中 ⇒ 2D=0 从未发现）。
    //   定位钮(WINLocationView>UIImageView+NMBaseButton)、路线(WINRouteLineWidgetView)、
    //   罗盘(WINPermanentCompassView>UIVisualEffectView) 子树均无这两类 ⇒ 永不误认。
    BOOL has2DLabel = NO;
    @try {
        Class cItem = NSClassFromString(@"WINAJXCombinedItemView");
        Class cLottie = NSClassFromString(@"LOTAnimationView");
        NSMutableArray<UIView *> *q = [NSMutableArray arrayWithArray:v.subviews];
        while (q.count) {
            UIView *s = q.firstObject; [q removeObjectAtIndex:0];
            if ((cItem && [s isKindOfClass:cItem]) || (cLottie && [s isKindOfClass:cLottie])) { has2DLabel = YES; break; }
            [q addObjectsFromArray:s.subviews];
        }
    } @catch (NSException *e28) {}
    if (!has2DLabel) return NO;
    return YES;
}
static void GCStyleDiscoverWidgets(UIWindow *win) {
    if (!win) return;
#ifdef GAODECLEAN_PROBE
    P7DiscCalls++;
    __weak UIView *p7oc = CachedCar;
    __weak UIView *p7or_ = CachedRight;
    __weak UIView *p7ort = CachedRoute;
    __weak UIView *p7ol = CachedLiteGroup;
#endif
    // ★trial25(A3)：失窗不再立即弃缓存 —— probe7 铁证：点定位/切3D 时容器被摘下窗口链
    //   1~3s（DISC old→new=0x0、CONTMOVE→{{inf,inf}}）后同实例重挂。立即弃 ⇒ 重挂后要等
    //   BFS 重新发现，期间无人钉 = 上飘空窗。__weak 对真销毁天然归零；此处仅对"活着但
    //   脱窗"的实例给 1s 宽限，超时（App 真重建）才弃掉交给 BFS 重发现。
    static CFAbsoluteTime GCStyleGoneAt[4];
    CFAbsoluteTime gnow = CFAbsoluteTimeGetCurrent();
    if (CachedCar && !CachedCar.window) {
        if (!GCStyleGoneAt[0]) GCStyleGoneAt[0] = gnow;
        if (gnow - GCStyleGoneAt[0] > 1.0) { CachedCar = nil; GCStyleGoneAt[0] = 0; }
    } else GCStyleGoneAt[0] = 0;
    if (CachedRight && !CachedRight.window) {
        if (!GCStyleGoneAt[1]) GCStyleGoneAt[1] = gnow;
        if (gnow - GCStyleGoneAt[1] > 1.0) { CachedRight = nil; GCStyleGoneAt[1] = 0; }
    } else GCStyleGoneAt[1] = 0;
    if (CachedRoute && !CachedRoute.window) {
        if (!GCStyleGoneAt[2]) GCStyleGoneAt[2] = gnow;
        if (gnow - GCStyleGoneAt[2] > 1.0) { CachedRoute = nil; GCStyleGoneAt[2] = 0; }
    } else GCStyleGoneAt[2] = 0;
    if (CachedLiteGroup && !CachedLiteGroup.window) {
        if (!GCStyleGoneAt[3]) GCStyleGoneAt[3] = gnow;
        if (gnow - GCStyleGoneAt[3] > 1.0) { CachedLiteGroup = nil; GCStyleGoneAt[3] = 0; }
    } else GCStyleGoneAt[3] = 0;
    if (Cached2D && !Cached2D.window) Cached2D = nil;   // trial27：2D 钮断链即清（App 真删时 BFS 重发现）
#ifdef GAODECLEAN_PROBE
    if (CachedCar && CachedRight && CachedRoute && CachedLiteGroup) P7DiscSkips++;
#endif
    if (CachedCar && CachedRight && CachedRoute && CachedLiteGroup && Cached2D) return;   // trial27：2D 钮入齐套条件
    // ★trial25(A4)：BFS 节流 ≥100ms —— display-link 60fps 驱动下，缓存缺员（dump 铁证：
    //   LiteGroup 0.8s 丢失后 ptr=0x0 长期为 nil）时每帧全树 BFS（预算 2000 节点）白烧。
    static CFAbsoluteTime GCStyleLastBFS = 0;
    CFAbsoluteTime bnow = CFAbsoluteTimeGetCurrent();
    if (bnow - GCStyleLastBFS < 0.1) return;
    GCStyleLastBFS = bnow;
    NSMutableArray<UIView *> *queue = [NSMutableArray arrayWithObject:win];
    for (NSUInteger i = 0; i < queue.count && queue.count < 2000; i++) {
        UIView *v = queue[i];
        [queue addObjectsFromArray:v.subviews];
        NSString *cn = NSStringFromClass(v.class);
        if ([cn isEqualToString:GCStrAt(140)]) CachedCar = v;
        else if (IsRightBottomWidget(v)) CachedRight = v;
        else if ([cn isEqualToString:GCStrAt(141)]) CachedRoute = v;
        else if (GCCIsLiteGroupCapsule(v)) CachedLiteGroup = v;
        else if (!Cached2D && GCStyleIs2DBtn(v, win)) Cached2D = v;   // trial27
        if (CachedCar && CachedRight && CachedRoute && CachedLiteGroup && Cached2D) break;
    }
#ifdef GAODECLEAN_PROBE
    if (CachedCar != p7oc)     P7Note(@"DISC 车机→新实例 old=%p(%@) new=%p(%@)", (__bridge void *)p7oc, NSStringFromCGRect(P7WR(p7oc)), (__bridge void *)CachedCar, NSStringFromCGRect(P7WR(CachedCar)));
    if (CachedRight != p7or_)  P7Note(@"DISC 右下→新实例 old=%p(%@) new=%p(%@)", (__bridge void *)p7or_, NSStringFromCGRect(P7WR(p7or_)), (__bridge void *)CachedRight, NSStringFromCGRect(P7WR(CachedRight)));
    if (CachedRoute != p7ort)  P7Note(@"DISC 路线→新实例 old=%p(%@) new=%p(%@)", (__bridge void *)p7ort, NSStringFromCGRect(P7WR(p7ort)), (__bridge void *)CachedRoute, NSStringFromCGRect(P7WR(CachedRoute)));
    if (CachedLiteGroup != p7ol) P7Note(@"DISC Lite→新实例 old=%p(%@) new=%p(%@)", (__bridge void *)p7ol, NSStringFromCGRect(P7WR(p7ol)), (__bridge void *)CachedLiteGroup, NSStringFromCGRect(P7WR(CachedLiteGroup)));
    if (CachedCar && !P7FirstSeen[0]) P7FirstSeen[0] = P7Now();
    if ((CachedRight || CachedLiteGroup) && !P7FirstSeen[1]) P7FirstSeen[1] = P7Now();
    if (CachedRoute && !P7FirstSeen[2]) P7FirstSeen[2] = P7Now();
#endif
}
// ★trial24：单控件实时钳位（setFrame:/setCenter: 钩子专用，轻量：无 BFS、不全量 pin）。
//   probe7 铁证：App 布局系统直接写 frame、不走控件自身 layoutSubviews（trial10 钩子因此空转），
//   我们 11Hz tick 追写 60fps 的 App ⇒ before=608/after=673 每拍拉锯、dump 瞬间停在 App 位。
//   此函数在 App 每次写位置后同事务内改回 pin 目标 ⇒ 零拉锯零闪烁。
static BOOL GCStylePinOneBusy = NO;
static void GCStylePinOne(UIView *v) {
    if (!v || GCStylePinOneBusy) return;                 // 防重入：钳位自身写 frame 会再触发钩子
    UIWindow *win = v.window;
    if (!win || !v.superview) return;                    // 断链期间无窗口，重挂后由 tick/layoutSubviews 兜底
    UIView *capNow = (CachedLiteGroup && CachedLiteGroup.window) ? CachedLiteGroup : CachedRight;
    BOOL isCar = (v == CachedCar);
    BOOL isCap = (capNow && v == capNow);
    BOOL is2D = (v == Cached2D);                          // trial27
    // trial37（probe13 铁证）：hidden 期间**照钉几何**，只跳过可见性写入 ——
    //   旧 return 让 App 藏钮期间把它漂到 167/69（P37 流水 WINAJXCombinedWidgetView:167→69→667），
    //   复现时从错位跳回 = 老大说的「乱跑」。

    //   （旧守卫 alpha<0.5 就整帧跳过 ⇒ 切换时 App 淡出+下滑无人拦，视频 11.0s 铁证）
    if (!isCar && !isCap && !is2D) return;
    GCStylePinOneBusy = YES;
    @try {
        CGFloat sw = win.bounds.size.width;
        const CGFloat pinBottom = GCPinBottom(win);          // 与 GCStylePinWidgets 同源
        CGRect wr = [v convertRect:v.bounds toView:win];
        CGRect g;
        if (isCar) {
            g = CGRectMake(10, pinBottom - 20 - 18 - wr.size.height, wr.size.width, wr.size.height);
            // ★trial35（P33 哨兵铁证：车机钮每 ~20s 被 App 把 alpha 清 0，坐标恒在 (10,673)）：
            //   位置钉住 ≠ 看得见。可见性同钉，幂等（达标即不写）。
            if (!v.hidden && v.alpha < 0.999f) {
                [CATransaction begin]; [CATransaction setDisableActions:YES];
                v.alpha = 1.0f;
                [CATransaction commit];
#ifdef GAODECLEAN_PROBE
                P7Solid++;
#endif
            }
        }
        else if (is2D) {                                  // trial29：帽顶上方 57.3pt = App 原生相对位
            //   probe9 铁证：原生 win y=609.7 = capTop(667)-57.3；trial27 用 capTop-15-44=608
            //   与原生差 1.7pt > 幂等容差 0.6 ⇒ 每帧拉锯（2D=198）。改用原生间距 ⇒ 收敛零拉锯，
            //   缩放撂回叠帽态（top=capTop+33）时照样纠回。
            CGRect capw = GCPresWinRect(capNow, win);   // trial39：用胶囊表现层，跟随 App 动画
            g = CGRectMake(CGRectGetMidX(capw) - wr.size.width / 2,
                           capw.origin.y - 57.3, wr.size.width, wr.size.height);
            // ★trial30（老大 12:59 截图铁证：44pt 位置精准、内部全透明只剩 1px 环）：
            //   钮的可见内容 = 自身 backgroundColor + Lottie 动画，App 在加载/切换态会淡掉或清底，
            //   trial29 只钉几何 ⇒ 透明态无人纠正。这里补「实心钉」，幂等（达标即不写）。
            if (!v.hidden) {
                if (v.alpha < 0.999f) {
                    [CATransaction begin]; [CATransaction setDisableActions:YES];
                    v.alpha = 1.0f;
                    [CATransaction commit];
#ifdef GAODECLEAN_PROBE
                    P7Solid++;
#endif
                }
                CGFloat ba30 = v.backgroundColor ? CGColorGetAlpha(v.backgroundColor.CGColor) : 0;
                if (ba30 < 0.9f) {
                    [CATransaction begin]; [CATransaction setDisableActions:YES];
                    v.backgroundColor = [UIColor whiteColor];
                    [CATransaction commit];
#ifdef GAODECLEAN_PROBE
                    P7Solid++;
#endif
                }
            }
            // ★trial38（probe13/14 铁证）：trial37 的「父容器拉回可见」已撤。
            //   实测我们每帧拉回 1009~1878 次，App 每帧又藏回去（dump 恒 h=1）——
            //   说明我们钉的是**被 App 藏起来的替身**，这场争夺只会造成闪烁。
            //   真身定位改由 probe14 的全窗口 Lottie 清单负责。
        } else g = CGRectMake(sw - 10 - wr.size.width, pinBottom - wr.size.height, wr.size.width, wr.size.height);
        CGRect local = [v.superview convertRect:g fromView:win];
        // ★trial33（老大：完全乱了，车机钮与 2D 钮不见）：trial32 的链式补偿被整体撤掉。
        //   判定：dump 采样时刻一切正常（车机 673 / 2D 609.7 / 天气 735），乱是采样之后才发生；
        //   trial32 唯一新增的写入路径就是这里 ⇒ 先撤写入，改为「只读取证」。
        //   本块不写任何几何/动画，物理上不可能影响布局。
#ifdef GAODECLEAN_PROBE
        if (is2D) {
            CALayer *pl33 = v.layer.presentationLayer;
            CALayer *svp33 = v.superview.layer.presentationLayer;
            if (pl33 && svp33 && win.layer) {
                CGRect presWin = [svp33 convertRect:pl33.frame toLayer:win.layer];
                CGFloat dx33 = presWin.origin.x - g.origin.x;
                CGFloat dy33 = presWin.origin.y - g.origin.y;
                P7Dx31 = dx33; P7Dy31 = dy33;
                if ((fabs(dx33) > 1.0 || fabs(dy33) > 1.0) && fabs(dx33) < 400 && fabs(dy33) < 400) {
                    P32DevN++;
                    P32Dev[P32DevI].t = (float)P7Now();
                    P32Dev[P32DevI].dx = (float)dx33;
                    P32Dev[P32DevI].dy = (float)dy33;
                    P32DevI = (P32DevI + 1) % 6;
                }
            }
        }
#endif
        if (!CGRectEqualToRect(local, v.frame)) {
            [CATransaction begin]; [CATransaction setDisableActions:YES];
            [v.layer removeAllAnimations]; v.frame = local;
            [CATransaction commit];
#ifdef GAODECLEAN_PROBE
            if (is2D) {
                CGRect c2 = capNow ? [capNow convertRect:capNow.bounds toView:win] : CGRectNull;
                P7Write(3, wr, local, c2);
            }
#endif
        }
    } @catch (__unused NSException *e) {}
    GCStylePinOneBusy = NO;
}

// ★trial24：给 rc 挂 setFrame:/setCenter: 实时钳位。必须走 Replace+imp_implementationWithBlock
//   （0.6.2 天气行先例的 ABI 正确通道）—— HookVoid 有"恰 2 参"硬门（L693），setFrame: 会被
//   静默跳过；这正是 trial10 layoutSubviews 钩子拦不住 App 直写 frame 的另一半原因。
// ★trial25(A5)：容器类 setFrame:/setCenter: 钩子 —— probe7 CONTMOVE 铁证：App 点定位/切3D
//   搬的是容器，子控件 setFrame 不触发（trial24 盲区）；容器钩子内同事务全量回钉。
//   与 GCStyleHookSetPos 共用已挂类集合，防同类双挂。
static NSMutableSet<NSString *> *GCStylePosHookedClasses(void) {
    static NSMutableSet *s;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [NSMutableSet set]; });
    return s;
}
static void GCStyleHookContainerPos(Class rc) {
    if (!rc) return;
    NSString *nm = NSStringFromClass(rc);
    if (!nm || [GCStylePosHookedClasses() containsObject:nm]) return;
    [GCStylePosHookedClasses() addObject:nm];
    Method mf = class_getInstanceMethod(rc, @selector(setFrame:));
    if (mf) {
        IMP o = method_getImplementation(mf);
        const char *t = method_getTypeEncoding(mf);
        Replace(rc, @selector(setFrame:), imp_implementationWithBlock(^(UIView *self, CGRect f) {
            ((void (*)(id, SEL, CGRect))o)(self, @selector(setFrame:), f);
#ifdef GAODECLEAN_PROBE
            P8ContHooks++;
#endif
            GCStylePinWidgets(self.window);
        }), t);
    }
    Method mc = class_getInstanceMethod(rc, @selector(setCenter:));
    if (mc) {
        IMP o2 = method_getImplementation(mc);
        const char *t2 = method_getTypeEncoding(mc);
        Replace(rc, @selector(setCenter:), imp_implementationWithBlock(^(UIView *self, CGPoint c) {
            ((void (*)(id, SEL, CGPoint))o2)(self, @selector(setCenter:), c);
            GCStylePinWidgets(self.window);
        }), t2);
    }
}
static void GCStyleHookSetPos(Class rc) {
    if (!rc) return;
    NSString *nm25 = NSStringFromClass(rc);   // trial25：与容器钩子共用登记表
    if (nm25) [GCStylePosHookedClasses() addObject:nm25];
    Method mf = class_getInstanceMethod(rc, @selector(setFrame:));
    if (mf) {
        IMP o = method_getImplementation(mf);
        const char *t = method_getTypeEncoding(mf);
        Replace(rc, @selector(setFrame:), imp_implementationWithBlock(^(UIView *self, CGRect f) {
            ((void (*)(id, SEL, CGRect))o)(self, @selector(setFrame:), f);
            GCStylePinOne(self);
        }), t);
    }
    Method mc = class_getInstanceMethod(rc, @selector(setCenter:));
    if (mc) {
        IMP o2 = method_getImplementation(mc);
        const char *t2 = method_getTypeEncoding(mc);
        Replace(rc, @selector(setCenter:), imp_implementationWithBlock(^(UIView *self, CGPoint c) {
            ((void (*)(id, SEL, CGPoint))o2)(self, @selector(setCenter:), c);
            GCStylePinOne(self);
        }), t2);
    }
}
// ★trial26(A1)：layer 几何同栈纠偏 —— probe8 铁证：车机类 view 钩子已挂但 WRITE
//   拉锯 66/s 不停、model 帧帧停 App 位 ⇒ App 走 AutoLayout 内部通道/layer 直写，
//   绕过 view setFrame/setCenter 选择器；一切几何写入最终汇到 CALayer setter，
//   在写入的同一调用栈内纠回 = 最后写的人永远是我们，拉锯物理终结。
static BOOL GCStyleLayerFixBusy = NO;
static void GCStyleLayerFix(CALayer *la) {
    if (GCStyleLayerFixBusy || !la) return;
    UIView *capNow = (CachedLiteGroup && CachedLiteGroup.window) ? CachedLiteGroup : CachedRight;
    UIView *v = nil;
    if (CachedCar && la == CachedCar.layer) v = CachedCar;
    else if (capNow && la == capNow.layer) v = capNow;
    if (!v || !v.window || !v.superview) return;
    GCStyleLayerFixBusy = YES;
    @try {
        UIWindow *win = v.window;
        CGFloat sw = win.bounds.size.width;
        const CGFloat pinBottom = GCPinBottom(win);
        CGRect wr = [v convertRect:v.bounds toView:win];
        CGRect g;
        if (v == CachedCar) {
            g = CGRectMake(10, pinBottom - 20 - 18 - wr.size.height, wr.size.width, wr.size.height);
        } else {
            g = CGRectMake(sw - 10 - wr.size.width, pinBottom - wr.size.height, wr.size.width, wr.size.height);
        }
        CGRect local = [v.superview convertRect:g fromView:win];
        if (!CGRectEqualToRect(local, la.frame)) {
            [CATransaction begin];
            [CATransaction setDisableActions:YES];
            [la removeAllAnimations];
            la.frame = local;
            [CATransaction commit];
#ifdef GAODECLEAN_PROBE
            P8LayerFixes++;
#endif
        }
    } @catch (__unused NSException *e) {}
    GCStyleLayerFixBusy = NO;
}
static NSMutableSet<NSString *> *GCStyleLsHooked26(void) {   // trial26(A2)：layoutSubviews 已挂类
    static NSMutableSet *s26b = nil;
    static dispatch_once_t once26b;
    dispatch_once(&once26b, ^{ s26b = [NSMutableSet set]; });
    return s26b;
}
static NSMutableSet<NSString *> *GCStyleLayerHookedClasses(void) {
    static NSMutableSet *s26 = nil;
    static dispatch_once_t once26;
    dispatch_once(&once26, ^{ s26 = [NSMutableSet set]; });
    return s26;
}
static void GCStyleHookLayerGeo(UIView *v) {
    if (!v || !v.layer) return;
    Class lc = v.layer.class;
    NSString *nm = NSStringFromClass(lc);
    if (!nm || !lc || [GCStyleLayerHookedClasses() containsObject:nm]) return;
    [GCStyleLayerHookedClasses() addObject:nm];
    Method mf = class_getInstanceMethod(lc, @selector(setFrame:));
    if (mf) {
        IMP o = method_getImplementation(mf);
        const char *t = method_getTypeEncoding(mf);
        Replace(lc, @selector(setFrame:), imp_implementationWithBlock(^(CALayer *self, CGRect f) {
            ((void (*)(id, SEL, CGRect))o)(self, @selector(setFrame:), f);
#ifdef GAODECLEAN_PROBE
            P8LayerFires++;
#endif
            GCStyleLayerFix(self);
        }), t);
    }
    Method mp = class_getInstanceMethod(lc, @selector(setPosition:));
    if (mp) {
        IMP o2 = method_getImplementation(mp);
        const char *t2 = method_getTypeEncoding(mp);
        Replace(lc, @selector(setPosition:), imp_implementationWithBlock(^(CALayer *self, CGPoint p) {
            ((void (*)(id, SEL, CGPoint))o2)(self, @selector(setPosition:), p);
#ifdef GAODECLEAN_PROBE
            P8LayerFires++;
#endif
            GCStyleLayerFix(self);
        }), t2);
    }
    Method mb = class_getInstanceMethod(lc, @selector(setBounds:));
    if (mb) {
        IMP o3 = method_getImplementation(mb);
        const char *t3 = method_getTypeEncoding(mb);
        Replace(lc, @selector(setBounds:), imp_implementationWithBlock(^(CALayer *self, CGRect b) {
            ((void (*)(id, SEL, CGRect))o3)(self, @selector(setBounds:), b);
#ifdef GAODECLEAN_PROBE
            P8LayerFires++;
#endif
            GCStyleLayerFix(self);
        }), t3);
    }
}


// ★trial9：角控件绝对钉死（不再对表搜索栏）—— 右胶囊右10/底755；车机钮左10、
//   天气行原生关系（钮下18、左对齐）⇒ 行底=755 ⇒ 钮底=755-20-18。每 tick/布局钩子覆写 ⇒ 不漂。
static void GCStylePinWidgetsInner(UIWindow *win) {   // trial25(A2)：原体改名，对外经重入守卫包装
    if (!win) return;
    GCStyleDiscoverWidgets(win);   // trial11：自给自足（3D 模式 handler/bar 链断也能发现+钉）
#ifdef GAODECLEAN_PROBE
    P7PinCalls++;
    if (win != P7LastPW) {
        P7Note(@"PW pin窗口→%@ cls=%@ bounds=%@", NSStringFromCGRect(P7WR(win)), NSStringFromClass(win.class), NSStringFromCGRect(win.bounds));
        P7LastPW = win;
    }
    UIView *p7cap = (CachedLiteGroup && CachedLiteGroup.window) ? CachedLiteGroup : CachedRight;
    CGRect p7oc = CGRectNull;
    for (UIView *av = p7cap; av; av = av.superview) {
        if (av == win) break;
        CGRect p7or2 = P7WR(av);
        if (CGRectGetMinX(p7or2) != 0 || CGRectGetMinY(p7or2) != 0) p7oc = p7or2;
    }
    if (!CGRectEqualToRect(p7oc, P7LastCont)) {
        P7Note(@"CONTMOVE 容器win系 %@ → %@", NSStringFromCGRect(P7LastCont), NSStringFromCGRect(p7oc));
        P7LastCont = p7oc;
    }
#endif
    CGFloat sw = win.bounds.size.width;
    const CGFloat pinBottom = GCPinBottom(win);   // trial38：跟随底栏（圆钮行顶 771 上 16pt）
    UIView *cap = (CachedLiteGroup && CachedLiteGroup.window) ? CachedLiteGroup : CachedRight;
    if (cap && cap.window && cap.superview) {
        CGRect wr = [cap convertRect:cap.bounds toView:win];
        CGRect g = CGRectMake(sw - 10 - wr.size.width, pinBottom - wr.size.height, wr.size.width, wr.size.height);
        CGRect local = [cap.superview convertRect:g fromView:win];
        if (!CGRectEqualToRect(local, cap.frame)) {
#ifdef GAODECLEAN_PROBE
            CGRect p7b = P7WR(cap);
#endif
            [CATransaction begin]; [CATransaction setDisableActions:YES];
            [cap.layer removeAllAnimations]; cap.frame = local;
            [CATransaction commit];
#ifdef GAODECLEAN_PROBE
            P7Write(1, p7b, local, p7oc);
#endif
        }
    }
    UIView *car = CachedCar;
    if (car && car.window && car.superview) {
        CGRect wr = [car convertRect:car.bounds toView:win];
        CGFloat carY = pinBottom - 20 - 18 - wr.size.height;   // 天气行高20 + 原生间隙18
        CGRect g = CGRectMake(10, carY, wr.size.width, wr.size.height);
        CGRect local = [car.superview convertRect:g fromView:win];
        if (!CGRectEqualToRect(local, car.frame)) {
#ifdef GAODECLEAN_PROBE
            CGRect p7b = P7WR(car);
#endif
            [CATransaction begin]; [CATransaction setDisableActions:YES];
            [car.layer removeAllAnimations]; car.frame = local;
            [CATransaction commit];
#ifdef GAODECLEAN_PROBE
            P7Write(0, p7b, local, p7oc);
#endif
        }
    }
    // trial10：钉完即放行扣留（AlignedKey），控件首 tick 就出现，不再等 settle
    if (car) objc_setAssociatedObject(car, &AlignedKey, @(1), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (cap) objc_setAssociatedObject(cap, &AlignedKey, @(1), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (CachedRight) objc_setAssociatedObject(CachedRight, &AlignedKey, @(1), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (CachedRoute) objc_setAssociatedObject(CachedRoute, &AlignedKey, @(1), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
#ifdef GAODECLEAN_PROBE
    if (CachedRoute && !P7FirstKey) { P7FirstKey = P7Now(); P7Note(@"KEY 路线胶囊 AlignedKey 置位"); }
#endif
    // trial10：车机钮/胶囊容器类的 layoutSubviews 钩子 —— App 重排（点定位切3D等）落地的
    //   同一布局事务内回钉 ⇒ 零可见跳变。
    // ★trial26(A2)：carHooked/capHooked 一次性标志废除 —— probe8 dump 铁证：Lite 1.6s 死亡后
    //   cap 回退 WINAJXCombinedWidgetView，但一次性标志已置位 ⇒ 胶囊真身类从未挂上钩。
    //   改为按当前实例类名动态登记；三类钩子（layoutSubviews/setPos/layerGeo）均类级去重。
    {
        UIView *w26[3] = { car, cap, Cached2D };   // trial27：2D 钮入三件套挂钩（类级去重天然防重挂）
        // ★trial29：通用基类黑名单 —— probe9 铁证：2D 钮类 = 裸 UIView，trial27 把
        //   layoutSubviews/setFrame:/setCenter: 挂到了全 App 的 UIView 基类上 ⇒ 每个视图
        //   每次布局都进块 ⇒ 定位按钮触摸布局被干扰失效（点定位无法定位）。
        //   基类实例只走帧级主动钉（下方 Cached2D 行）+ 容器钩兜底，绝不挂基类钩。
        //   （CALayer 基类的 layer 钩 trial26 起已挂且录屏验证无副作用，指针过滤放行非目标。）
        static NSSet *bl29; static dispatch_once_t t29;
        dispatch_once(&t29, ^{ bl29 = [NSSet setWithObjects:@"UIView", @"UILabel", @"UIImageView",
            @"UIControl", @"UIButton", @"UIVisualEffectView", @"UIScrollView", @"UIStackView", nil]; });
        for (int i26 = 0; i26 < 3; i26++) {
            UIView *v26 = w26[i26];
            if (!v26) continue;
            NSString *cn26 = NSStringFromClass(v26.class);
            if (cn26 && [bl29 containsObject:cn26]) continue;
            if (cn26 && ![GCStyleLsHooked26() containsObject:cn26]) {
                [GCStyleLsHooked26() addObject:cn26];
                HookVoid(cn26, @"layoutSubviews", ^(UIView *v) { GCStylePinWidgets(v.window); });
            }
            GCStyleHookSetPos(v26.class);   // 内部 GCStylePosHookedClasses 去重
            GCStyleHookLayerGeo(v26);       // trial26(A1)：layer setter 钩（按 layer 类去重）
        }
    }
    if (Cached2D) GCStylePinOne(Cached2D);   // trial27：帧级主动钉（钩子通道只拦 App 写入，发现即纠）
}
// ★trial25(A2)：重入守卫包装 —— pin 现有帧级驱动/容器钩子/子控件钩子/layoutSubviews 钩子
//   四路并发，写 frame 会级联触发钩子，无守卫有自激风暴风险。
static BOOL GCStylePinBusy = NO;
static void GCStylePinWidgets(UIWindow *win) {
    if (GCStylePinBusy) {
#ifdef GAODECLEAN_PROBE
        P8Busy++;
#endif
        return;
    }
    GCStylePinBusy = YES;
    GCStylePinWidgetsInner(win);
#ifdef GAODECLEAN_PROBE
    P33Watch(CachedCar, 0);
    P33Watch((UIView *)(CachedLiteGroup && CachedLiteGroup.window ? CachedLiteGroup : CachedRight), 1);
    P33Watch(Cached2D, 2);
    P37Sample();
    P39Sample();
    P41HookWeatherWrites();
#endif
    GCStylePinBusy = NO;
}
// ★trial25(A1)：帧级钉位驱动器。probe7 铁证：①慢出现——车机 见=1.0/钉=1.0，tick 仅 5Hz，
//   发现+钉+放行串行叠加；②上飘——WRITE before=608 after=614 拉锯 + CONTMOVE 容器摘挂，
//   5Hz 追写追不上 App 60fps。CADisplayLink 与刷新同步：任何通道动控件，下一帧提交前纠回；
//   发现延迟 ≤200ms→≤16ms。后台 RunLoop 停 ⇒ 自动暂停零耗。
@interface GCStylePinDriver : NSObject
- (void)fire;
@end
@implementation GCStylePinDriver
- (void)fire {
#ifdef GAODECLEAN_PROBE
    P8Trace();
#endif
    UIView *av = CachedCar ?: CachedRight ?: CachedRoute;
    UIWindow *pw = av.window ?: CachedTabBar.window ?: SearchBarView.window;
    if (!pw) {
        for (UIWindow *x in GCAllWindows()) {
            if (!x.hidden && x.bounds.size.width >= 200) { pw = x; break; }
        }
    }
    if (!pw) {
#ifdef GAODECLEAN_PROBE
        P8NoWin++;
#endif
        return;
    }
    GCStylePinWidgets(pw);
    AlignWeatherRowTick(pw);   // 天气行同享帧级跟随（probe7：天气门首过=1.2s 慢门）
}
@end
static GCStylePinDriver *GCStylePinDrv = nil;
// 夹取主函数：只动胶囊 x/w（y/h 不动），伴生物按绝对几何同步 —— 幂等
static void GCNarrowApply(UIView *anchor, BOOL isSearch) {
    if (!anchor || !anchor.window) return;
    // trial14：圆形风格全权接管；旧 240 夹取体退役（#if 0 保留备查）
    if (isSearch) GCStyleSearch(anchor); else GCStyleTab(anchor);
    return;
#if 0
    CGFloat sw = anchor.bounds.size.width;
    UIView *cap = GCNarrowCapsule(anchor);
    if (!cap) return;
    CGRect cf = cap.frame;                       // 写之前的原帧（App 刚布完的原生态或已达状态）
    CGFloat x = (sw - GCNarrowTargetW) * 0.5;
    CGFloat right = x + GCNarrowTargetW;
    CGRect g = cf;
    g.origin.x = x; g.size.width = GCNarrowTargetW;
    if (!CGRectEqualToRect(g, cf)) {
        cap.frame = g;
        // ★trial9：UIVisualEffectView 的 backdrop 是 blur 缓存；改尺寸后旧缓存可能仍按
        //   原生宽度画残留边（"幽灵发丝线"，layer 树里查无此层）⇒ 脉冲 effect 强制重建。
        if ([cap isKindOfClass:UIVisualEffectView.class]) {
            UIVisualEffect *fx = ((UIVisualEffectView *)cap).effect;
            ((UIVisualEffectView *)cap).effect = nil;
            ((UIVisualEffectView *)cap).effect = fx;
        }
        GCNarrowInvalidateRender(cap.layer);   // trial10：清 shadowPath/光栅缓存
    }
    NSInteger budget = 24;
    GCNarrowInnerFix(cap, GCNarrowTargetW, 0, &budget);
    GCNarrowStandaloneLayers(anchor, sw, x);   // A1：独立白底/渐变层一并夹到目标宽
    if (isSearch) {
        // 浮在胶囊右侧的按钮：按绝对几何重排 —— 最右按钮右缘 = 胶囊右缘 - 12，
        // 其余向左依次相邻贴放（与原生排布关系完全一致，天然幂等、与谁最后布局无关）
        NSMutableArray *btns = [NSMutableArray array];
        for (UIView *v in anchor.subviews) {
            if (v == cap || v.hidden || v.alpha < 0.05) continue;
            CGRect f = v.frame;
            if (f.size.width > 60 || f.size.height > 60) continue;
            if (f.origin.x < sw * 0.55) continue;
            [btns addObject:v];
        }
        [btns sortUsingComparator:^NSComparisonResult(UIView *a, UIView *b) {
            CGFloat ax = a.frame.origin.x, bx = b.frame.origin.x;
            if (ax > bx) return NSOrderedAscending;
            if (ax < bx) return NSOrderedDescending;
            return NSOrderedSame;
        }];
        GCNarrowHairlineSweep(anchor, sw, x);   // trial8：全窗口发丝线/透明描边层扫荡
        // ★trial11：给 anchor 加圆角 mask —— 把 anchor 子树画在胶囊矩形外的一切残留
        //   （原生尺寸描边/快照/残余阴影、切线上下的角弧）一次性裁掉；
        //   胶囊/放大镜/相机/麦克风全在胶囊矩形内 ⇒ 零影响；mask 只裁渲染、不影响命中。
        CALayer *mk = anchor.layer.mask;
        if (!mk) { mk = [CALayer layer]; anchor.layer.mask = mk; }
        mk.frame = CGRectMake(x, 0, GCNarrowTargetW, anchor.bounds.size.height);
        mk.cornerRadius = anchor.bounds.size.height * 0.5;
        mk.backgroundColor = [UIColor blackColor].CGColor;
        GCStyleSearch(anchor);   // trial13：搜索栏最后夹成 54 圆钮 + 隐藏拍照/语音
        CGFloat cursor = right - GCNarrowBtnGap;
        for (UIView *v in btns) {
            CGRect f = v.frame;
            CGFloat nx = cursor - f.size.width;
            cursor = nx;
            if (fabs(f.origin.x - nx) > 0.5) { f.origin.x = nx; v.frame = f; }
        }
    } else {
        // ★trial4（老大截图指出"还有一层透明的没缩"）：描边/高亮图匹配改为**绝对特征**。
        //   trial1~3 的真 bug：旧匹配依赖「胶囊写前帧 cf + 4」。App 在某时刻把描边图
        //   重建/重排回原生 355 宽时，胶囊已是 240 ⇒ |355-244|=111>14 永远落空
        //   ⇒ 描边图钉死在原生宽度，即胶囊外那圈透明圆角矩形（实测 ~355pt）。
        //   绝对特征：非隐藏 UIImageView + 高 56~72 + 宽 [240,380] + 居中 ⇒ 写成胶囊外扩 2pt；
        //   环境阴影图(高108/宽399)、页签(84)、隐藏备用图(hidden) 全部天然不命中。
        for (UIView *v in anchor.subviews) {
            if (v == cap || v.hidden || v.alpha < 0.05) continue;
            if (![v isKindOfClass:UIImageView.class]) continue;
            CGRect f = v.frame;
            if (f.size.height < 56 || f.size.height > 72) continue;
            if (f.size.width < GCNarrowTargetW || f.size.width > 380) continue;
            if (fabs(CGRectGetMidX(f) - sw * 0.5) > 20) continue;
            CGRect s = g; s.origin.x -= 2; s.origin.y = f.origin.y; s.size.width += 4; s.size.height += 4;
            if (!CGRectEqualToRect(s, f)) {
                [v.layer removeAllAnimations];   // 防 App 用动画把描边拽回原生宽
                v.frame = s; GCNarrowBorderFixes++;
                GCNarrowInvalidateRender(v.layer);
            }
        }
        // ★trial5（probe4 干跑定罪）：底栏全宽环境层是**真实 UIView 的 backing layer** ——
        //     UIView(渐变容器) own=[0,-15.5,393,99.5] + 其子 CAGradientLayer 同尺寸
        //     UIImageView(柔光位图) own=[-3,-24,399,108]（可见核心≈355 = 老大看到的透明圈）
        //   trial3 在 CALayer 层找它们并跳过所有 backing layer ⇒ 两条全被跳过 ⇒ 死代码。
        //   （搜索栏白底是"独立层"所以 A1 那套对；底栏环境层是"真视图"必须走 UIView 路径。）
        //   绝对匹配：非隐藏、非胶囊、全宽(≥sw-8)、高 60~160、居中±20 ⇒ 写成胶囊+24pt/侧；
        //   容器内满宽渐变子层同步；已达标(288)时 w<sw-8 天然跳过 ⇒ 幂等。
        {
            CGFloat ambW = GCNarrowTargetW + 2 * GCNarrowAmbPad;
            for (UIView *v in anchor.subviews) {
                if (v == cap || v.hidden || v.alpha < 0.05) continue;
                if ([v isKindOfClass:UIVisualEffectView.class]) continue;
                CGRect f = v.frame;
                if (f.size.width < sw - 8) continue;
                if (f.size.height < 60 || f.size.height > 160) continue;
                if (fabs(CGRectGetMidX(f) - sw * 0.5) > 20) continue;
                // ★trial6（老大地球视图截图定罪）：无位图的全宽层 = 渐变容器（子 CAGradientLayer
                //   白→透明竖渐变）。亮地图上白叠白不可见；地球/暗色视图下是**硬边白带**，
                //   夹成 288 更糟（硬边白矩形）⇒ 直接隐藏（alpha=0，布局不动，可逆）。
                //   有位图的全宽层（柔光阴影 399）才夹到 288（软边光晕，暗底下读作胶囊的光）。
                if (!v.layer.contents) {
                    if (v.alpha > 0.01) { v.alpha = 0; GCNarrowAmbFixes++; }
                    continue;
                }
                CGRect gg = f; gg.origin.x = x - GCNarrowAmbPad; gg.size.width = ambW;
                if (!CGRectEqualToRect(gg, f)) {
                    [v.layer removeAllAnimations];
                    v.frame = gg; GCNarrowAmbFixes++;
                    GCNarrowInvalidateRender(v.layer);
                    for (CALayer *c in [v.layer.sublayers copy]) {
                        CGRect cf2 = c.frame;
                        if (cf2.size.width < f.size.width - 8) continue;
                        CGRect g2 = cf2; g2.origin.x = 0; g2.size.width = ambW;
                        if (!CGRectEqualToRect(g2, cf2)) c.frame = g2;
                    }
                }
            }
        }
    }
#endif
}
// 搜索栏 anchor 类只 hook 一次；命中通用基类则放弃钩子（改由 tick 兜底），避免波及全局
static void GCNarrowEnsureSearchHook(void) {
    if (GCNarrowSearchHooked) return;
    UIView *bar = SearchBarView;
    if (!bar) return;
    GCNarrowSearchHooked = YES;
    NSString *nm = NSStringFromClass(bar.class);
    static NSSet *deny;
    if (!deny) deny = [NSSet setWithObjects:@"UIView", @"UIResponder", @"LTMBaseView",
                       @"NMMoveContentView", @"WINRootView", @"WINMultiStyleRootView",
                       @"AMCommonContentBackgroundView", nil];
    if ([deny containsObject:nm]) return;
    HookVoid(nm, @"layoutSubviews", ^(UIView *anchor) { GCNarrowApply(anchor, YES); });
}
// ★trial12(B3)：ctor 期按类名预挂搜索栏 anchor 的 layoutSubviews。
//   懒钩子要等 LayoutMinimalHome 捕获到实例才装（最坏慢一个 tick 周期），冷启动表现为
//   "原生宽栏可见约 0.3s 再 snap 到 240"（录屏帧 26–28 铁证：370.8pt 宽栏 3 帧）。
//   ctor 期挂上 ⇒ 第一次 layoutSubviews 就在同一事务内被夹取 ⇒ 零宽帧。
//   类未加载/类名不存在 ⇒ 静默跳过，懒钩子 + 快窗照旧兜底（GCNarrowSearchHooked 不置位）。
static void GCNarrowCtorHook(void) {
    if (GCNarrowSearchHooked) return;
    Class c = NSClassFromString(@"WINQuickSearchBarV2");
    if (!c) return;
    GCNarrowSearchHooked = YES;
    HookVoid(@"WINQuickSearchBarV2", @"layoutSubviews", ^(UIView *anchor) { GCNarrowApply(anchor, YES); });
}
// tick 兜底：每 5 拍复核一次（App 重建视图/漏排时拉回）
static void GCNarrowTick(void) {
    GCNarrowEnsureSearchHook();
    UIView *bar = SearchBarView;
    if (bar) GCNarrowApply(bar, YES);
    UIView *tb = CachedTabBar;
    if (tb) GCNarrowApply(tb, NO);
#ifdef GAODECLEAN_PROBE
    P7NTicks++;
#endif
    // trial11：pin 脱离 bar/handler 链（3D 模式该链可能断 ⇒ pin 停跑 = 漂移根因）：每 tick 直钉
    UIWindow *pw = tb.window ?: bar.window;
    if (!pw) {
        for (UIWindow *x in GCAllWindows()) {
            if (!x.hidden && x.bounds.size.width >= 200) { pw = x; break; }
        }
    }
    GCStylePinWidgets(pw);
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
    Class sv = NSClassFromString(GCStrAt(84));
    if (!sv) return;
    for (UIWindow *w in GCAllWindows()) {
        if (w.hidden) continue;
        NSMutableArray *q = [NSMutableArray arrayWithObject:w];
        for (NSUInteger i = 0; i < q.count && q.count < 1200; i++) {
            UIView *v = q[i];
            for (UIView *sub in v.subviews) [q addObject:sub];
            if (![v isKindOfClass:sv]) continue;
            for (NSString *prop in @[GCStrAt(85), GCStrAt(86)]) {
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
                GCLog(GCStrAt(87), NSStringFromClass(v.class), a);
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
            if (![cn isEqualToString:GCStrAt(88)] &&
                ![cn isEqualToString:GCStrAt(89)]) continue;
            for (UIGestureRecognizer *g in [v.gestureRecognizers copy])
                if ([g isKindOfClass:UIPanGestureRecognizer.class] ||
                    [g isKindOfClass:UISwipeGestureRecognizer.class])
                    [v removeGestureRecognizer:g];
        }
    }
}

static void SealBlurOverlay(void) {
    Class mask = NSClassFromString(GCStrAt(90));
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
        HookVoid(GCStrAt(90), GCStrAt(91), ^(UIView *v) { v.hidden = YES; v.alpha = 0; });
    }
    // AUGlobalBlurService 往窗口加的全屏模糊视图同样封死。
    // 0.9.8（A3-2/3）：valueForKey:/clearBlurViews 都是**裸调用**。
    //   · `maskViews` 属性被删/改名 → NSUnknownKeyException（uncaught 崩溃）；
    //     返回非数组（NSNull/NSSet）→ makeObjectsPerformSelector: 崩。
    //   · `clearBlurViews` 不存在 → unrecognized selector 崩。
    //   两条都在 App 启动路径上（startService 由高德自己调），必须防御。
    HookVoid(GCStrAt(92), GCStrAt(93), ^(id s) {
        id mv = nil;
        @try { mv = [s valueForKey:GCStrAt(94)]; }
        @catch (__unused NSException *e) { mv = nil; }
        if ([mv isKindOfClass:NSArray.class]) {
            for (id v in (NSArray *)mv)
                if ([v isKindOfClass:UIView.class]) [v removeFromSuperview];
        } else if ([mv isKindOfClass:NSSet.class]) {
            for (id v in [(NSSet *)mv allObjects])
                if ([v isKindOfClass:UIView.class]) [v removeFromSuperview];
        }
    });
    HookVoid(GCStrAt(92), GCStrAt(95), ^(id s) {
        SEL clr = NSSelectorFromString(GCStrAt(96));
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
        Class vc = NSClassFromString(GCStrAt(97));
        SEL sl = NSSelectorFromString(GCStrAt(98));
        Method mm = class_getInstanceMethod(vc, sl);
        if (mm) Replace(vc, sl, imp_implementationWithBlock(^(__unused id self) { return NO; }),
                        method_getTypeEncoding(mm));
        SEL rl = NSSelectorFromString(GCStrAt(99));
        Method rm = class_getInstanceMethod(vc, rl);
        if (rm) Replace(vc, rl, imp_implementationWithBlock(^(__unused id self) {}),
                        method_getTypeEncoding(rm));
        SEL sl2 = NSSelectorFromString(GCStrAt(100));
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
    id tag = ObjectGetter(view, GCStrAt(58));
    if ([tag isEqual:GCStrAt(101)] || [tag isEqual:GCStrAt(102)]) return YES;
    NSMutableString *identity = [NSMutableString string];
    static NSArray<NSString *> *getters;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ getters = @[GCStrAt(59), GCStrAt(60)]; });
    for (NSString *getter in getters) {
        id value = ObjectGetter(view, getter);
        if ([value isKindOfClass:NSString.class]) [identity appendFormat:GCStrAt(14), value];
    }
    NSString *lower = identity.lowercaseString;
    return [identity containsString:GCStrAt(103)] || [lower containsString:GCStrAt(104)] || [lower containsString:GCStrAt(105)];
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
        if ([cn containsString:GCStrAt(106)] || [cn containsString:GCStrAt(107)] ||
            [cn containsString:GCStrAt(108)] || [cn containsString:GCStrAt(109)] ||
            [cn containsString:GCStrAt(110)]) return YES;
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
            GCLog(GCStrAt(111),
                  NSStringFromClass(v.class));
        }
    }
    v.hidden = YES;
    return YES;
}
static BOOL IsWeatherRowClass(NSString *cn);   // trial37：多实例归位要用（非探针口径也需要）
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
    GCLog(GCStrAt(112), (unsigned long)all.count);
}

static void AlignWeatherRow(UIView *row) {
    // 0.5.33：把「天气+LOGO」行对齐到车机钮右边。用坐标转换 + center 写入
    // （transform 安全、幂等，不累积误差）。
    static BOOL inAlign = NO;
#ifdef GAODECLEAN_PROBE
    P39AlignCalls++;
#endif
    if (inAlign) {
#ifdef GAODECLEAN_PROBE
        P39AlignSkipReenter++;
#endif
        return;
    }
    if (!row || !row.window || !row.superview) return;
    UIView *car = CachedCar;
    if (!car || !car.window) {
#ifdef GAODECLEAN_PROBE
        P39AlignSkipCar++;
#endif
        return;
    }
    inAlign = YES;
#ifdef GAODECLEAN_PROBE
    P41InAlign = 1;
#endif
    UIWindow *win = row.window;
    CGRect carRect = [car convertRect:car.bounds toView:win];
    // 0.9.18（A2）：对表原生 —— 车机钮在上、天气行在**正下方**且左对齐。
    //   0.5.33 起这里写的是「搬到车机钮右侧」，那是当年的假设，从没对过表；
    //   原生实测（原生录屏 vs 我们逐元素比对）：车机钮 616..652、天气行 670..690、
    //   两者 x 均为 10 ⇒ 关系是「上下 + 左对齐」，间隙 18pt。
    // trial24：y 不再读车机钮实际位（拉锯期 608↔673 ⇒ 天气行镜像跳 65pt，probe7 三段
    //   快照 735/670 铁证）—— 改与 GCStylePinWidgets 同源纯公式：
    //   车机钮目标 y = sh-97-20-18-44，行顶 = 其底 + 18 ⇒ 行顶恒 = sh-117（钉死）。
    CGFloat carTgtTop = GCPinBottom(win) - 20 - 18 - 44;   // trial38：与 pin 同源跟随底栏
    CGPoint wantWin = CGPointMake(carRect.origin.x,
                                  carTgtTop + 44 + 18);
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
#ifdef GAODECLEAN_PROBE
        P39AlignWrites++;
#endif
        [CATransaction commit];
    }
    // ★trial37（probe13 铁证）：同一行可能有**多个实例** ——
    //   WINGroupMapWidget@735 被 App 淡成 alpha=0，另有游离的
    //   WINScaleLineLogoMapWidget@788 在显示（就是老大看到压在底栏上的 LOGO）。
    //   只钉缓存那一个 ⇒ 游离实例永远在 788。这里把所有可见天气类实例统一钉到行顶，只改 y。
    CGFloat rowTop37 = carTgtTop + 44 + 18;
    NSMutableArray *q37 = [NSMutableArray arrayWithObject:win];
    for (NSUInteger i37 = 0; i37 < q37.count && q37.count < 2000; i37++) {
        UIView *v37 = q37[i37];
        [q37 addObjectsFromArray:v37.subviews];
        if (v37 == row || !v37.window || v37.hidden || v37.alpha < 0.05f) continue;
        if (!IsWeatherRowClass(NSStringFromClass(v37.class))) continue;
        if (v37.bounds.size.width < 60 || v37.bounds.size.height >= 40) continue;
        CGRect r37 = [v37 convertRect:v37.bounds toView:win];
        if (fabs(r37.origin.y - rowTop37) < 0.5) continue;
        CGPoint wp37 = [v37.superview convertPoint:CGPointMake(r37.origin.x, rowTop37) fromView:win];
        [CATransaction begin];
        [CATransaction setDisableActions:YES];
        [v37.layer removeAllAnimations];
        v37.frame = CGRectMake(wp37.x, wp37.y, v37.bounds.size.width, v37.bounds.size.height);
        [CATransaction commit];
#ifdef GAODECLEAN_PROBE
        P37FreeFix++;
#endif
    }
    GCWeatherReleaseHeld();   // 0.9.3：对齐完成 → 恢复扣留的天气行（出现在正确位置）
#ifdef GAODECLEAN_PROBE
    P41InAlign = 0;
#endif
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
    if ([cn isEqualToString:GCStrAt(113)]
        || [cn isEqualToString:GCStrAt(114)]
        || [cn isEqualToString:GCStrAt(115)]
        || [cn isEqualToString:GCStrAt(116)]   // 0.9.5：17.01.1 冷启动 Lite 版 LOGO 视图
        || [cn isEqualToString:GCStrAt(117)]            // 0.9.5：引擎内 LOGO 视图
        || [cn isEqualToString:GCStrAt(118)])             // 0.9.5：引擎内比例尺
        hit = YES;
    else
        hit = [cn containsString:GCStrAt(119)] || [cn containsString:GCStrAt(120)];
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
    Class cls = NSClassFromString(GCStrAt(113));
    if (!cls) return;
    // 0.6.5：**关键** —— WINGroupMapWidget 自己有一个 `-layout` 方法（不是 layoutSubviews），
    // app 走的是它。原来的钩子挂 layoutSubviews，冷启动时根本不触发；
    // 只有切页等个别路径才会连带跑到一次 → 表现为「冷启动后不归位，切一次页才对」。
    // 两个方法都挂。
    HookVoid(GCStrAt(113), GCStrAt(121), ^(id v) {
        UIView *win = nil;
        if ([v isKindOfClass:UIView.class]) {
            win = ((UIView *)v).window;
            if (!win || !CachedCar || !CachedCar.window) return;
            if (!IsWeatherRowView(v)) return;
            objc_setAssociatedObject(v, &AlignedKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            AlignWeatherRow(v);
        }
    });
    HookVoid(GCStrAt(113), GCStrAt(91), ^(UIView *v) {
        // 0.6.1：原来这里写的是 if (!AlignedKey) return —— 依赖「缓存实例 + 一次性标记」。
        // 但切换 2D/3D 时 app 会重建地图控件树，**新实例没有 AlignedKey**，
        // 钩子直接 return，天气行就退回 app 的原生位置 ——
        // 逐帧实测：切到 3D 后 ☁ 云 −13pt、30°C −11pt、🔷高德地图 −13pt（比例尺不动），
        // 就是「切 2D/3D 时天气和 LOGO 位置跳一下」。
        // 现在改为按尺寸自识别，任何实例都能立即对齐，不再依赖缓存命中。
        UIView *win = v.window;
        if (!win || !CachedCar || !CachedCar.window) return;
        if (CachedTabs) {
            id sel = ObjectGetter(CachedTabs, GCStrAt(71));
            if (sel && ![NSStringFromClass([sel class]) isEqualToString:GCStrAt(122)]) return;
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
        Class rc = NSClassFromString(GCStrAt(113));
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
    for (NSString *cn in @[GCStrAt(113), GCStrAt(114), GCStrAt(115),
                           GCStrAt(116), GCStrAt(117), GCStrAt(118)]) {
        Class c = NSClassFromString(cn);
        if (!c) continue;
        // ① 上窗
        HookVoid(cn, GCStrAt(123), ^(UIView *v) {
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
        if (![cn isEqualToString:GCStrAt(113)]) {
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
    UIView *bar = ObjectGetter(handler, GCStrAt(43));
    UIView *sheet = ObjectGetter(handler, GCStrAt(124));
    id tabs = ObjectGetter(handler, GCStrAt(125));
    if (tabs) CachedTabs = tabs;
    if ([bar isKindOfClass:UIView.class]) SearchBarView = bar;
    id selected = ObjectGetter(tabs, GCStrAt(71));
    if (![bar isKindOfClass:UIView.class] || ![sheet isKindOfClass:UIView.class] || !sheet.superview) return;
    BOOL home = [NSStringFromClass([selected class]) isEqualToString:GCStrAt(122)];
    if (!home) { if (!bar.hidden) { bar.hidden = YES; BarFixIdle = 0; } return; }
    UIView *tabBar = ObjectGetter(tabs, GCStrAt(45));
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
    UIView *mask = ObjectGetter(handler, GCStrAt(126));
    if ([mask isKindOfClass:UIView.class] && !mask.hidden) { mask.hidden = YES; BarFixIdle = 0; }
    CALayer *bottomMask = ObjectGetter(handler, GCStrAt(127));
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
                        if (!CachedRow || [NSStringFromClass(v.class) isEqualToString:GCStrAt(113)]
                            || v.bounds.size.width > CachedRow.bounds.size.width) CachedRow = v;
                        if ([NSStringFromClass(v.class) isEqualToString:GCStrAt(113)]) break;
                    }
                }
            }
        }
#ifdef GAODECLEAN_PROBE
        P7RowMir = CachedRow;
        P7WGates[2]++;
        if (!(CachedRow && CachedRow.window && !CachedRow.hidden && CachedCar && CachedCar.window && bar.window && CachedRow.superview) && P7WGates[2] % 100 == 1)
            P7Note(@"WGATE 跳过 row=%d rowWin=%d rowHid=%d car=%d carWin=%d barWin=%d sup=%d",
                CachedRow != nil, CachedRow.window != nil, CachedRow.hidden,
                CachedCar != nil, CachedCar.window != nil, bar.window != nil, CachedRow.superview != nil);
#endif
        if (CachedRow && CachedRow.window && !CachedRow.hidden
            && CachedCar && CachedCar.window && bar.window && CachedRow.superview) {
#ifdef GAODECLEAN_PROBE
            P7WGates[0]++;
            if (!P7FirstSeen[4]) { P7FirstSeen[4] = P7Now(); P7Note(@"WGATE 首过 天气行放行对齐"); }
            if (P7WGates[0] % 50 == 1) P7Note(@"WGATE 通过#%d row win=%@", P7WGates[0], NSStringFromCGRect(P7WR(CachedRow)));
#endif
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
    if (![NSStringFromClass(v.class) isEqualToString:GCStrAt(128)]) return NO;
    id tag = ObjectGetter(v, GCStrAt(58));
    if (![tag isKindOfClass:NSString.class]) return NO;
    NSString *t = [(NSString *)tag lowercaseString];
    return [t containsString:GCStrAt(129)] || [t containsString:GCStrAt(130)] || [t containsString:GCStrAt(131)];
}

// 0.9.16（A1）：App 原生「轻量控件组」容器的识别与排除判定。
//   中部裸露胶囊的真身（diag2 铁证）；右上「+/图层」胶囊用的是同一类，
//   但它出生就在窗口顶部（y≈69 ≈ 窗高 3.6%），故用 25% 高度线排除。
static BOOL GCCIsLiteGroupCapsule(UIView *v) {
    if (![NSStringFromClass(v.class) isEqualToString:GCStrAt(132)]) return NO;
    UIView *win = v.window;
    if (!win) return NO;
    CGFloat y = [v convertPoint:CGPointZero toView:win].y;
    return y > win.bounds.size.height * 0.25;
}

__attribute__((unused)) static void AlignOneWidget(UIView *bar, UIView *w, CGFloat barTop, CGFloat gap) {
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
            if (( [vcn isEqualToString:GCStrAt(113)]
                || [vcn isEqualToString:GCStrAt(114)]
                || [vcn isEqualToString:GCStrAt(115)])
                && IsWeatherRowView(v)) {
                // 优先外层容器（WINGroupMapWidget 存在时它就是整行）；
                // 否则取最宽的那个候选（冷启动时是 WINScaleLineLogoMapWidget，188pt）
                if (!Row || [vcn isEqualToString:GCStrAt(113)]
                    || v.bounds.size.width > Row.bounds.size.width) Row = v;
                if ([vcn isEqualToString:GCStrAt(113)]) break;
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
            if ([s isEqualToString:GCStrAt(133)] || [s isEqualToString:GCStrAt(134)]) return YES;
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
        if ([cn containsString:GCStrAt(135)] || [cn containsString:GCStrAt(136)] ||
            [cn containsString:GCStrAt(137)] || [cn containsString:GCStrAt(138)]) {
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
    // trial10：settle 前若已钉过（AlignedKey 已置）也放行 —— pin 为绝对坐标无瞬态风险 ⇒ 控件首 tick 出现
    if (!SearchBarSettled && !objc_getAssociatedObject(capsule, &AlignedKey)) return;
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
            GCLog(GCStrAt(139),
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
    // trial10：settle 门删除 —— pin 为绝对坐标（无瞬态位置风险），且该门是
    //   ①点定位切 3D 后 pin 停跑（控件停 App 原生位 = 「没固定」）②启动出现慢 的同一根因。

    GCStyleDiscoverWidgets(win);   // trial11：发现收归独立函数
    // trial9：圆形风格 —— 角控件不再对表搜索栏（bar 位置已不代表视觉重心），改绝对钉死；
    //   实例发现/扣留/放行逻辑保留，只替换摆位。
    GCStylePinWidgets(win);
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
    return [text containsString:GCStrAt(142)];
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
        for (NSString *getter in @[GCStrAt(13), GCStrAt(12), GCStrAt(11),
                                   GCStrAt(73), GCStrAt(143), GCStrAt(144)]) {
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
    id model = ObjectGetter(item, GCStrAt(145));
    for (NSString *getter in @[GCStrAt(73), GCStrAt(13), GCStrAt(146), GCStrAt(147), GCStrAt(148)]) {
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
        if ([NSStringFromClass(item.class) isEqualToString:GCStrAt(149)]) break;
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
            if ([cn isEqualToString:GCStrAt(88)] || [cn isEqualToString:GCStrAt(149)]) break;
            if (![cn containsString:GCStrAt(150)] && ![cn containsString:GCStrAt(151)] &&
                ![cn containsString:GCStrAt(152)] && ![cn containsString:GCStrAt(153)] &&
                ![cn containsString:GCStrAt(154)]) break;
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
    id selected = ObjectGetter(tabs, GCStrAt(71));
    if (!selected) return;
    BOOL home = [NSStringFromClass([selected class]) isEqualToString:GCStrAt(122)];
    id prev = LastSelected;
    LastSelected = selected;
    if (!prev || prev == selected) return;          // 第一次见到 / 没变
    BOOL prevHome = [NSStringFromClass([prev class]) isEqualToString:GCStrAt(122)];
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
        Class tbc = NSClassFromString(GCStrAt(155));
        SEL ss = NSSelectorFromString(GCStrAt(156));
        Method m = tbc ? class_getInstanceMethod(tbc, ss) : NULL;
        if (m) {
            IMP o = method_getImplementation(m);
            const char *t = method_getTypeEncoding(m);
            Replace(tbc, ss, imp_implementationWithBlock(^(id self, id vc) {
                ((void (*)(id, SEL, id))o)(self, ss, vc);
                if ([NSStringFromClass([vc class]) isEqualToString:GCStrAt(122)]
                    && ColdTicks >= 15)
                    KickBarFixFor(0.32);
            }), t);
        }
    }
    HookVoid(GCStrAt(149), GCStrAt(123), ^(UIView *item) {
        // 0.9.8（A4）：原「initWithFrame:model: 建好后关掉重复点击」的钩子，
        // 被 HookVoid 的签名守卫（只接受 2 参 + 返回 void）静默跳过 ——
        // 真实签名是 4 参、返回 @。这里迁到 didMoveToWindow（v16@0:8）：
        // 同一语义、零 ABI 风险；WINTabBarItem 固定两个、不复用，时机等价。
        for (NSString *setter in @[GCStrAt(157), GCStrAt(158)]) {
            SEL s = NSSelectorFromString(setter);
            if ([item respondsToSelector:s]) ((void (*)(id, SEL, BOOL))objc_msgSend)(item, s, NO);
        }
        for (UIView *p = item.superview; p; p = p.superview)
            if ([NSStringFromClass(p.class) isEqualToString:GCStrAt(88)]) { SweepTabBarHints(p); break; }
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
    Class cls = NSClassFromString(GCStrAt(149));
    SEL sel = NSSelectorFromString(GCStrAt(159));
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
            GCLog(GCStrAt(160), (long)viewState);
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
    NSArray *items = ObjectGetter(bar, GCStrAt(161));
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
    SEL sync = NSSelectorFromString(GCStrAt(162));
    if ([bar respondsToSelector:sync]) ((void (*)(id, SEL, BOOL))objc_msgSend)(bar, sync, NO);
    UIView *pill = ObjectGetter(bar, GCStrAt(163));
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
        kw = @[GCStrAt(164), GCStrAt(165), GCStrAt(166), GCStrAt(167), GCStrAt(168),
               GCStrAt(169), GCStrAt(170), GCStrAt(171), GCStrAt(172),
               GCStrAt(173), GCStrAt(174), GCStrAt(175), GCStrAt(176),
               GCStrAt(177), GCStrAt(178), GCStrAt(179), GCStrAt(180),
               GCStrAt(181), GCStrAt(182), GCStrAt(183), GCStrAt(184),
               GCStrAt(185), GCStrAt(186), GCStrAt(187)];
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
        own = @[GCStrAt(188), GCStrAt(189), GCStrAt(190),
                GCStrAt(191), GCStrAt(192), GCStrAt(193)];
    });
    for (NSString *p in own) if ([cn hasPrefix:p]) return YES;
    return NO;
}

static BOOL GCCIsSplashAd(UIView *v, UIWindow *win) {
    if (!v || v.hidden) return NO;
    NSString *cn = NSStringFromClass(v.class);
    if ([cn hasPrefix:GCStrAt(194)]) return NO;                    // 自己的视图
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
    GCLog(GCStrAt(195),
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
            continue;
        }
        GCCSplashWindow = w;
        GCCSplashUntil = TickCount + 300;                    // 0.7.5(B2)：60s 后自动失效
        w.hidden = YES;
            GCLog(GCStrAt(196), wcn);
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
                if (GCCIsSplashAd(v, owner)) { GCCHideSplashAd(v, GCStrAt(197)); return; }
            }
            [q addObjectsFromArray:v.subviews];
        }
    }
    // 主窗口里也可能直接盖了一层全屏广告（不走独立窗口）
    if (GCCMainWindow) {
        NSArray *subs = [GCCMainWindow.subviews copy];
        for (UIView *v in subs) {
            if (GCCIsSplashAd(v, GCCMainWindow)) { GCCHideSplashAd(v, GCStrAt(198)); return; }
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
        prefixes = @[GCStrAt(199), GCStrAt(200), GCStrAt(201), GCStrAt(202),
                     GCStrAt(203), GCStrAt(204),
                     GCStrAt(205), GCStrAt(206), GCStrAt(207),
                     GCStrAt(208), GCStrAt(209), GCStrAt(210),
                     // 0.8.0 新增：17.01.0 自研开屏广告体系
                     GCStrAt(211), GCStrAt(212), GCStrAt(213),
                     GCStrAt(214), GCStrAt(215), GCStrAt(216),
                     GCStrAt(217), GCStrAt(218), GCStrAt(219),
                     GCStrAt(220), GCStrAt(221), GCStrAt(222),
                     GCStrAt(223), GCStrAt(224), GCStrAt(225),
                     GCStrAt(226)];
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
    NSArray<NSString *> *showSels = @[GCStrAt(227), GCStrAt(228), GCStrAt(229),
                                      GCStrAt(230), GCStrAt(231),
                                      GCStrAt(232), GCStrAt(233),
                                      GCStrAt(234)];
    // 「判定」——返回 NO。只接受返回 BOOL/char 的。
    NSArray<NSString *> *boolSels = @[GCStrAt(235), GCStrAt(236), GCStrAt(237), GCStrAt(238),
                                      GCStrAt(239), GCStrAt(240), GCStrAt(241),
                                      // 0.8.0：17.01.0 自研体系（语义明确：返回 NO = 不展示广告）
                                      // ★ 不碰 present* 展示层 —— 它带 4 个 completion block，
                                      //   置空会让启动流程等不到 playFinish/animationFinish，
                                      //   高概率卡白屏（0.7.4 黑屏事故同源）。
                                      GCStrAt(242),
                                      GCStrAt(243)];
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
            [hooked addObject:[NSString stringWithFormat:GCStrAt(244), cn, name]];
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
            [hooked addObject:[NSString stringWithFormat:GCStrAt(244), cn, name]];
        }
    }
    free(all);
}

static void InstallSplashAdGuard(void) {
    GCCHookAdClasses();
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
                if (GCCIsSplashAd(sub, self)) GCCHideSplashAd(sub, GCStrAt(245));
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
                            GCCHideSplashAd(pv, GCStrAt(246));
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
        SEL mk = NSSelectorFromString(GCStrAt(247));
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
        });
    }
}

static void InstallMinimalHome(void) {
    // 0.7.0：开屏广告移除
    InstallSplashAdGuard();
    HookVoid(GCStrAt(88), GCStrAt(91), ^(UIView *bar) { CachedTabBar = bar; CenterTabButtons(bar); SweepTabBarHints(bar);
        GCNarrowApply(bar, NO);   // 0.9.28 缩窄：底栏重排后立即夹回
    });
    InstallTabBarHintHooks();
    // 0.9.1：「上拉发现」引导 Lottie 拦截（17.01.1 GuideLottie 机制）
    InstallTabBarGuideLottieBlock();

    HookVoid(GCStrAt(248), GCStrAt(249), ^(id handler) {
        [HomeHandlers addObject:handler];
        // 0.4.41：冷启动先隐藏搜索栏，LayoutMinimalHome 定位到最终位置后再显示，消除跳动
        UIView *bar = ObjectGetter(handler, GCStrAt(43));
        if ([bar isKindOfClass:UIView.class]) bar.hidden = YES;
    });
    HookVoid(GCStrAt(248), GCStrAt(250), ^(id handler) { [HomeHandlers addObject:handler]; LayoutMinimalHome(handler); });
    HookVoid(GCStrAt(248), GCStrAt(251), ^(id handler) { [HomeHandlers addObject:handler]; LayoutMinimalHome(handler); });
    // 0.5.32：移除「上拉发现」——把 sheet 的手势/交互彻底关掉，
    // 上拉不再弹出发现面板（面板本身也被 sheet.hidden 挡着）。
    SealBlurOverlay();
    // 0.5.47：MapWidgetContainerView 被 app 在滑动时淡到 0（实测 a=0.00，弹簧过冲到 -2.33）
    // → 控件整片消失。这里把它的 alpha 恒定为 1（不动 setHidden:，避免按死搜索栏）。
    {
        Class mc = NSClassFromString(GCStrAt(252));
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
        Class mv = NSClassFromString(GCStrAt(253));
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
        Class vc = NSClassFromString(GCStrAt(254));
        if (vc) {
            SEL sl = NSSelectorFromString(GCStrAt(255));
            Method m = class_getInstanceMethod(vc, sl);
            if (m) Replace(vc, sl, imp_implementationWithBlock(^(__unused id self, __unused BOOL on) {}),
                           method_getTypeEncoding(m));
            SEL sc = NSSelectorFromString(GCStrAt(256));
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
    HookVoid(GCStrAt(84), GCStrAt(123), ^(UIView *v) {
        v.userInteractionEnabled = NO;
        v.hidden = YES;
    });
    HookVoid(GCStrAt(84), GCStrAt(91), ^(UIView *v) {
        v.hidden = YES;
        v.userInteractionEnabled = NO;
    });
    // 0.5.45：压白雾的最小组合 —— 只断「上拉」这条路。
    // 绝不碰 setHidden:（那是按死搜索页的元凶：高德搜索页本身就是这个面板）。
    {
        Class sv = NSClassFromString(GCStrAt(84));
        if (sv) {
            SEL ag = @selector(addGestureRecognizer:);
            Method m = class_getInstanceMethod(sv, ag);
            if (m) Replace(sv, ag, imp_implementationWithBlock(^(__unused id self, __unused id g) {}),
                           method_getTypeEncoding(m));
            for (NSString *setter in @[GCStrAt(257),
                                       GCStrAt(258)]) {
                SEL sl = NSSelectorFromString(setter);
                Method mm = class_getInstanceMethod(sv, sl);
                if (mm) Replace(sv, sl, imp_implementationWithBlock(^(__unused id self, __unused id g) {}),
                                method_getTypeEncoding(mm));
            }
        }
    }
    Class cls = NSClassFromString(GCStrAt(259));
    SEL sel = NSSelectorFromString(GCStrAt(260));
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
            if ([name containsString:GCStrAt(153)]) {
                id cur = ObjectGetter(self, GCStrAt(261));
                if (cur) replacement = cur;
            }
            if ([name containsString:GCStrAt(262)] && ![name containsString:GCStrAt(263)]) {
                id empty = nil;
                if ([name containsString:GCStrAt(264)]) empty = ObjectGetter(self, GCStrAt(265));
                if ([name containsString:GCStrAt(266)]) empty = ObjectGetter(self, GCStrAt(267));
                if (!empty) empty = ObjectGetter(self, GCStrAt(265));
                if (empty) replacement = empty;
            }
            ((void (*)(id, SEL, id))original)(self, sel, replacement);
        }), method_getTypeEncoding(method));
    }
    sel = NSSelectorFromString(GCStrAt(268));
    method = class_getInstanceMethod(cls, sel);
    if (method) {
        IMP original = method_getImplementation(method);
        Replace(cls, sel, imp_implementationWithBlock(^(id self, __unused BOOL show, BOOL animated) {
            ((void (*)(id, SEL, BOOL, BOOL))original)(self, sel, YES, animated);
        }), method_getTypeEncoding(method));
    }
    cls = NSClassFromString(GCStrAt(269));
    sel = NSSelectorFromString(GCStrAt(270));
    method = class_getInstanceMethod(cls, sel);
    if (method) {
        IMP original = method_getImplementation(method);
        Replace(cls, sel, imp_implementationWithBlock(^(id self, __unused id text, __unused id left, __unused id right, __unused id words, __unused BOOL animated) {
            ((void (*)(id, SEL, id, id, id, id, BOOL))original)(self, sel, @"", nil, nil, nil, NO);
        }), method_getTypeEncoding(method));
    }
    HookVoid(GCStrAt(269), GCStrAt(91), ^(id bar) {
        UIView *text = ObjectGetter(bar, GCStrAt(271));
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
            id t = ObjectGetter(v, GCStrAt(13));
            if ([t isKindOfClass:NSString.class] && [(NSString *)t length]) { v.hidden = YES; continue; }
            id a = ObjectGetter(v, GCStrAt(12));
            if ([a isKindOfClass:NSAttributedString.class] && [(NSAttributedString *)a length]) v.hidden = YES;
        }
    });
    // 0.4.46：拦截 setFrame:，settled 后把搜索栏 y 钉死，杜绝 app 动画/布局拉回原生 447 造成闪跳
    {
        Class barCls = NSClassFromString(GCStrAt(269));
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
        Class barCls = NSClassFromString(GCStrAt(269));
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
    HookVoid(GCStrAt(269), GCStrAt(272), ^(UIView *b) {
        if (!SearchBarSettled || !BarParent || b.superview == BarParent) return;
        // 0.9.2：冷启动后段保护 —— 已显示过一次且仍可见的搜索栏被摘掉时也立即挂回；
        // 未显示过 / 已隐藏（切「我的」的正常摘除）/ 非首页选中 → 维持原早退。
        if (ColdTicks < 15) {
            if (!BarShownOnce || b.hidden) return;
            if (CachedTabs) {
                id sel = ObjectGetter(CachedTabs, GCStrAt(71));
                if (![NSStringFromClass([sel class]) isEqualToString:GCStrAt(122)]) return;
            }
            static NSInteger GCBarReattach = 0;
            if (GCBarReattach < 5) {
                GCBarReattach++;
                GCLog(GCStrAt(273));
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
        Class bc = NSClassFromString(GCStrAt(269));
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
                        id sel = ObjectGetter(CachedTabs, GCStrAt(71));
                        if ([NSStringFromClass([sel class]) isEqualToString:GCStrAt(122)]) {
                            if (ColdTicks < 15) {
                                static NSInteger GCBarHideRefused = 0;
                                if (GCBarHideRefused < 5) {
                                    GCBarHideRefused++;
                                    GCLog(GCStrAt(274));
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
    HookVoid(GCStrAt(275), GCStrAt(91), ^(id view) { if (IsHiddenMapPromo(view)) [view setHidden:YES]; });
    cls = NSClassFromString(GCStrAt(275));
    sel = @selector(setHidden:);
    method = class_getInstanceMethod(cls, sel);
    if (method) {
        IMP original = method_getImplementation(method);
        Replace(cls, sel, imp_implementationWithBlock(^(UIView *self, BOOL hidden) {
            ((void (*)(id, SEL, BOOL))original)(self, sel, hidden || IsHiddenMapPromo(self));
        }), method_getTypeEncoding(method));
    }
    HookVoid(GCStrAt(128), GCStrAt(91), ^(UIView *view) {
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
    HookVoid(GCStrAt(128), GCStrAt(123), ^(UIView *view) {
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
    HookVoid(GCStrAt(132), GCStrAt(123), ^(UIView *v) {
        if (v.window && !SearchBarSettled && GCCIsLiteGroupCapsule(v)) {
            v.hidden = YES; [ColdWidgets addObject:v];
        }
    });
    HookVoid(GCStrAt(132), GCStrAt(91), ^(UIView *v) {
        // 锚点（搜索栏）未定格 = 冷启动未完成：按住它，不让它停在中部位显示。
        // 定格后交回给 A2（与我们的右下控件同一时刻放行）。
        if (!GCCIsLiteGroupCapsule(v)) return;
        if (!SearchBarSettled) { v.hidden = YES; [ColdWidgets addObject:v]; }
    });
    // 0.4.41：车机圆钮冷启动先隐藏，对齐后再显示，消除跳动
    HookVoid(GCStrAt(140), GCStrAt(91), ^(UIView *w) {
        if (w.window && !objc_getAssociatedObject(w, &AlignedKey)) { w.hidden = YES; [ColdWidgets addObject:w]; }
    });
    // 0.9.14（A6 回退）：0.9.9（A3）给车机圆钮补的 setHidden:/setAlpha: 两条拦截已移除。
    //   与右下钮同源的「未对齐拒绝显示」逻辑 —— 车机钮虽然靠类名能被 CachedCar 稳定找到
    //   （不像右下钮依赖 getItemTag），但压 alpha 的自伤点（A2/A3 时报过「hidden 放行了、
    //   控件仍全透明」）与拦截带来的显示时序扰动没有存在必要。0.9.7 只挂 layoutSubviews
    //   一条，实测无跳动、无裸奔，恢复原样。
    // 0.4.47：拦截两圆钮 setFrame:，对齐后 y 钉死，杜绝 app 挪回原生位置闪跳
    HookWidgetSetFrame(GCStrAt(140), GCGapCar);
    HookWidgetSetFrame(GCStrAt(128), GCGapCapsule);
    // ---- 0.9.19（A3）：2D/3D（地图类型）圆钮 --------------------------------------
    // 本机实测类名 = WINPermanentCompassView（Amap 17.00.2，44x44，父类 MapWidgetContainerView）。
    // 真机 diag 铁证：App 只布局一次，且把它锚在**胶囊的冷启动瞬态位**(339,340) 上
    //   ⇒ 按钮被摆到 y=283（原生 536.7），与「胶囊顶 − 57.3」的原生关系刚好差 254pt。
    // 这里在它每次布局/上窗后立刻按「胶囊顶 − GCGapMapType」纠正，不必等 200ms 轮询；
    //   未定格期间由 AlignMapTypeButton 内部判空返回（绝不拿瞬态位当锚）。
    HookVoid(GCStrAt(276), GCStrAt(91), ^(UIView *v) {
        AlignMapTypeButton(CachedRight);
    });
    HookVoid(GCStrAt(276), GCStrAt(123), ^(UIView *v) {
        AlignMapTypeButton(CachedRight);
    });
    // 0.5.19：拦截天气行 setFrame:，对齐后钉死到车机钮右边
    // 0.5.1：线路按钮原生 hid=1，setHidden: 强制 NO，app 再藏也压不住
    {
        Class rc = NSClassFromString(GCStrAt(141));
        SEL sh = @selector(setHidden:);
        Method sm = class_getInstanceMethod(rc, sh);
        if (sm) {
            IMP so = method_getImplementation(sm);
            Replace(rc, sh, imp_implementationWithBlock(^(UIView *self, __unused BOOL hidden) {
                ((void (*)(id, SEL, BOOL))so)(self, sh, NO);
            }), method_getTypeEncoding(sm));
        }
    }
    cls = NSClassFromString(GCStrAt(128));
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
    for (NSString *cn in @[GCStrAt(277), GCStrAt(278)]) {
        Class tb = NSClassFromString(cn);
        if (!tb) continue;
        SEL selr = NSSelectorFromString(GCStrAt(279));
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
    HookVoid(GCStrAt(88), GCStrAt(280), ^(UIView *bar) {
        // 0.6.7：这个 selector 在本文件被装了两次，而 Replace() 走
        // method_setImplementation —— 后装的那次会把先装的顶掉（CenterTabButtons 失效）。
        // 两条路径各自带上，谁后装都不丢功能。
        CachedTabBar = bar;
        CenterTabButtons(bar);
        SweepTabBarHints(bar);
        for (id item in (ObjectGetter(bar, GCStrAt(161)) ?: @[])) {
            if (![item isKindOfClass:UIView.class]) continue;
            for (NSString *setter in @[GCStrAt(157), GCStrAt(158)]) {
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

__attribute__((constructor)) static void Initialize(void) {
    @autoreleasepool {
        // 0.9.20（A3）加固连带修复：-Wl,-dead_strip 会把「无人引用」的静态常量
        // 整段移除，kGCVersion 只被已废弃的 GaodeCleanSignature() 引用 ⇒ 体内版本串
        // 被删，门禁「版本串一致性」与装机核对双双失效。此处用内存屏障把该串钉住，
        // 保证 strings 可见、但不涉及任何功能路径（不产生日志、不改变行为）。
        __asm__ volatile("" :: "r"(kGCVersion.UTF8String) : "memory");
        if (![NSBundle.mainBundle.bundleIdentifier isEqualToString:GCStrAt(281)]) return;
        AjxCache = [NSMutableDictionary dictionary];
        Pages = [NSHashTable weakObjectsHashTable];
        NearbyControllers = [NSHashTable weakObjectsHashTable];
        TabControllers = [NSHashTable weakObjectsHashTable];
        HomeHandlers = [NSHashTable weakObjectsHashTable];
        ColdWidgets = [NSHashTable weakObjectsHashTable];
        InstallScrollHooks();
        GCNarrowCtorHook();   // trial12(B3)：ctor 期预挂搜索栏锚点类，冷启动零宽帧
        InstallMinimalHome();
        HookVoid(GCStrAt(277), GCStrAt(282), ^(id tabs) {
            id params = ObjectGetter(tabs, GCStrAt(38));
            if (![params isKindOfClass:NSArray.class]) return;
            NSMutableArray *kept = [NSMutableArray array];
            for (id item in params) {
                if ([@[GCStrAt(122), GCStrAt(41)] containsObject:ObjectGetter(item, GCStrAt(39)) ?: @""])
                    [kept addObject:item];
            }
            // 0.9.8（A3-4）：setViewControlParams: 是裸 objc_msgSend，方法被改名即崩。
            // 加存在性 + 签名（应为 void, 1 对象参数）。
            if (kept.count == 2) {
                SEL svp = NSSelectorFromString(GCStrAt(283));
                if ([tabs respondsToSelector:svp]) {
                    NSMethodSignature *sig = [tabs methodSignatureForSelector:svp];
                    if (sig.numberOfArguments == 3) {
                        ((void (*)(id, SEL, id))objc_msgSend)(tabs, svp, kept);
                    }
                }
            }
        });
        HookHitTest(UIView.class);
        HookHitTest(NSClassFromString(GCStrAt(284)));
        Class registry = NSClassFromString(GCStrAt(285));
        SEL sel = NSSelectorFromString(GCStrAt(286));
        Method m = class_getInstanceMethod(registry, sel);
        if (m) {
            NSMethodSignature *s = [NSMethodSignature signatureWithObjCTypes:method_getTypeEncoding(m)];
            if (s.numberOfArguments == 3 && s.methodReturnType[0] == 'v' && [s getArgumentTypeAtIndex:2][0] == '#') {
                IMP original = method_getImplementation(m);
                IMP imp = imp_implementationWithBlock(^(id self, Class provider) {
                    if (![@[GCStrAt(287), GCStrAt(288)] containsObject:NSStringFromClass(provider) ?: @""]) {
                        GCLog(GCStrAt(289), NSStringFromClass(provider));
                        return;
                    }
                    ((void (*)(id, SEL, Class))original)(self, sel, provider);
                });
                Replace(registry, sel, imp, method_getTypeEncoding(m));
            }
        }
        HookVoid(GCStrAt(290), GCStrAt(291), ^(id e) { Capture(e); });
        // 0.9.8（A5）：这里原本是 GCStrAt(292)（大写 V）—— ObjC/UIKit 惯例是
        // layoutSubviews（小写 v），自定义方法一律带 amap_ 前缀，所以这一行几乎可以
        // 断定从未命中过，是纯死代码。
        // **不能**改成 layoutSubviews：0.7.3 的实测结论就写在下面 —— 它在滚动动画里
        // 每帧触发，当事件源会让 fullClean 几乎每拍成立，把 0.7.2 的 CleanPage 降频
        // 整个抵消掉。删除即可，Capture 的事件源由 reloadView /
        // updateVoiceOverIDAndLabel / AJX3View-didMoveToWindow 三条承担。
        HookVoid(GCStrAt(290), GCStrAt(293), ^(id e) { Capture(e); });
        // 0.7.3：layoutSubviews 在滚动动画里**每帧都触发**，把它当事件源会让
        // fullClean 几乎每拍成立 —— 0.7.2 的 CleanPage 降频实际上被它抵消了。
        // 只保留 didMoveToWindow（真正的页面挂载）。
        HookVoid(GCStrAt(284), GCStrAt(123), ^(id page) {
            [Pages addObject:page]; CleanForce = YES; GCCActiveUntil = TickCount + 8; Schedule();
        });
        HookVoid(GCStrAt(294), GCStrAt(249), ^(id controller) { [NearbyControllers addObject:controller]; Schedule(); });
        HookVoid(GCStrAt(155), GCStrAt(249), ^(id tabs) { [TabControllers addObject:tabs]; Schedule(); });
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
            // ★trial25(A5)：预挂 probe7 活体扫描锁定的三个容器类（类不存在静默跳过，
            //   trial12 先例）；dylib ctor 时主二进制已加载，类均已注册。
            GCStyleHookContainerPos(NSClassFromString(@"MapWidgetContainerView"));
            GCStyleHookContainerPos(NSClassFromString(@"WINMapSideBarWidgetContainerView"));
            GCStyleHookContainerPos(NSClassFromString(@"GDTransparentView"));
            GCStyleHookContainerPos(NSClassFromString(@"NMMoveContentView"));   // trial26：车机链祖先（probe8 dump 链），CONTMOVE 监测盲区
            // ★trial25(A1)：帧级钉位循环（详见 GCStylePinDriver 注释）。RunLoop 持有 link，
            //   static 强引用持有 target；CommonModes 保证滚动/手势 tracking 期间照跑。
            if (!GCStylePinDrv) {
                GCStylePinDrv = [GCStylePinDriver new];
                CADisplayLink *pdl = [CADisplayLink displayLinkWithTarget:GCStylePinDrv selector:@selector(fire)];
                [pdl addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
            }
        });

    }
}
