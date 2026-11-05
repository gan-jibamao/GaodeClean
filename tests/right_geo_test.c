// ============================================================================
//  GaodeClean 0.9.121 —— 右下胶囊几何兜底判据单测（纯 C）
//
//  背景：IsRightBottomWidget 原来只认 getItemTag（AJX 数据字段，晚于视图上屏
//  才写入）。tag 没写进来之前 CachedRight 恒为 nil，胶囊打不上 AlignedKey，
//  被 setHidden: 拦截按住 —— 真机实测车机钮 0.975s 出现、胶囊要 2.375s。
//
//  ★0.9.121 的两个关键修正（本测试锁住的就是它们）：
//
//    ① y 门槛 60% → 25%（自锁解除）
//       未钉位的胶囊被 App 摆在瞬态位 (339,340)，即屏高 40%。
//       旧判据 40% < 60% ⇒「不是它」⇒ 永远打不上 AlignedKey ⇒ 永远被按住
//       ⇒ 永远到不了 60% 以下的终止位。**死循环**，0.9.120 的兜底因此全程空转。
//       25% 与 GCCIsLiteGroupCapsule 排除右上「+/图层」胶囊用的是同一个界（y≈8%）。
//
//    ② 不再要求 v.window 非空（脱窗期也要能认）
//       冷启动期胶囊可能「已上屏但脱窗」（HISTORY §Z / trial25(A3)），
//       旧写法 `if (!win) return NO` 让兜底整条退出。
//
//  编译：gcc -O2 -Wall -Wextra -o /tmp/right_geo_test tests/right_geo_test.c -lm
// ============================================================================
#include <stdio.h>
#include <math.h>

typedef struct { double x, y, w, h; } R;
static R rect(double x, double y, double w, double h) { R r = {x, y, w, h}; return r; }

// 与源文件 IsRightBottomWidget 几何兜底分支逐行对应
static int is_right_bottom_geo(R r, double ww, double wh) {
    if (ww < 1 || wh < 1) return 0;
    if (!isfinite(r.x) || !isfinite(r.y)) return 0;
    if (!isfinite(r.w) || !isfinite(r.h)) return 0;
    if (r.w < 1 || r.h < 1) return 0;
    if (r.x + r.w / 2 < ww * 0.70) return 0;      // 右列
    if (r.y + r.h / 2 < wh * 0.25) return 0;      // 底部带（25%：排除右上，容纳瞬态位）
    if (r.w < 30 || r.w > 70) return 0;
    if (r.h < 50 || r.h > 130) return 0;
    return 1;
}

// A6：钉位包络判据（GCWidgetAtPinnedSlot 的纯 C 等价实现）
static int at_pinned_slot(R r, double ww, double wh, double pinBottom) {
    (void)wh;   // 包络判据只用宽（列判据），高度由 pinBottom 带覆盖
    if (!isfinite(r.x) || !isfinite(r.y) || !isfinite(r.w) || !isfinite(r.h)) return 0;
    if (r.w < 1 || r.h < 1) return 0;
    double bottom = r.y + r.h;
    if (bottom > pinBottom + 4) return 0;
    if (bottom < pinBottom - 200) return 0;
    double midx = r.x + r.w / 2;
    if (!(midx > ww * 0.70) && !(midx < ww * 0.30)) return 0;
    return 1;
}

static int Passed, Failed;
static void ck(int cond, const char *what) {
    if (cond) { Passed++; printf("  [OK]   %s\n", what); }
    else      { Failed++; printf("  [FAIL] %s\n", what); }
}

int main(void) {
    printf("═══ GaodeClean 0.9.121 右下胶囊几何兜底单测 ═══\n");
    const double WW = 393.0, WH = 852.0;   // iPhone 15 Pro 逻辑分辨率
    const double PB = 755.0;               // GCPinBottom 实测值

    printf("\n[1] 该命中的 —— 右下胶囊本体（终位）\n");
    ck(is_right_bottom_geo(rect(339, 667, 44, 88), WW, WH), "真机实测 {339,667,44,88}");
    ck(is_right_bottom_geo(rect(349, 690, 40, 60), WW, WH), "稍小的变体 {349,690,40,60}");
    ck(is_right_bottom_geo(rect(330, 620, 60, 120), WW, WH), "大机型变体 {330,620,60,120}");

    printf("\n[2] ★关键 —— 瞬态位必须命中（0.9.120 的自锁就在这里）\n");
    ck(is_right_bottom_geo(rect(339, 340, 44, 88), WW, WH),
       "中部瞬态位 {339,340}（y=40%）→ **必须命中**，否则死循环");
    ck(is_right_bottom_geo(rect(339, 281, 44, 88), WW, WH),
       "日志实测瞬态 {339,281} → 必须命中");
    ck(is_right_bottom_geo(rect(339, 213, 44, 88), WW, WH),
       "y=25% 边界（213+44=257，中心 257 > 213）→ 命中");
    ck(is_right_bottom_geo(rect(339, 600, 44, 88), WW, WH), "接近终位 {339,600} → 命中");

    printf("\n[3] 绝不能误伤 —— 右上「+/图层」同类胶囊\n");
    ck(!is_right_bottom_geo(rect(339, 69, 44, 88), WW, WH), "右上 {339,69}（y=8% 屏高）");
    ck(!is_right_bottom_geo(rect(339, 25, 44, 100), WW, WH), "右上扩展 {339,25,44,100}");
    ck(!is_right_bottom_geo(rect(339, 100, 44, 88), WW, WH), "右上偏下 {339,100}（中心 y=17%）");
    ck(!is_right_bottom_geo(rect(339, 150, 44, 88), WW, WH), "y=150（中心 194 < 213）→ 排除");

    printf("\n[4] 绝不能误伤 —— 其它首页控件\n");
    ck(!is_right_bottom_geo(rect(10, 608, 44, 44), WW, WH), "左侧车机钮 {10,608,44,44}");
    ck(!is_right_bottom_geo(rect(24, 702, 345, 44), WW, WH), "搜索栏 {24,702,345,44}");
    ck(!is_right_bottom_geo(rect(21, 768, 351, 60), WW, WH), "底栏 {21,768,351,60}");
    ck(!is_right_bottom_geo(rect(160, 640, 44, 88), WW, WH), "居中同尺寸 {160,640}");

    printf("\n[5] 尺寸边界\n");
    ck(!is_right_bottom_geo(rect(339, 667, 20, 88), WW, WH), "宽 20（<30）→ 否");
    ck(!is_right_bottom_geo(rect(339, 667, 90, 88), WW, WH), "宽 90（>70）→ 否");
    ck(!is_right_bottom_geo(rect(339, 667, 44, 40), WW, WH), "高 40（<50）→ 否");
    ck(!is_right_bottom_geo(rect(339, 667, 44, 150), WW, WH), "高 150（>130）→ 否");
    ck(is_right_bottom_geo(rect(339, 667, 30, 50), WW, WH), "边界 30x50 → 是");
    ck(is_right_bottom_geo(rect(339, 667, 70, 130), WW, WH), "边界 70x130 → 是");

    printf("\n[6] 异常输入\n");
    ck(!is_right_bottom_geo(rect(339, 667, 44, 88), 0, 0), "窗口尺寸非法 → 否");
    ck(!is_right_bottom_geo(rect(NAN, 667, 44, 88), WW, WH), "NaN 坐标 → 否");
    ck(!is_right_bottom_geo(rect(339, 667, NAN, 88), WW, WH), "NaN 宽度 → 否");

    printf("\n[7] A6 钉位包络 —— A3/A5 共用判据\n");
    ck(at_pinned_slot(rect(339, 667, 44, 88), WW, WH, PB),
       "胶囊终位 {339,667,44,88}（底 755）→ 在包络内");
    ck(at_pinned_slot(rect(10, 608, 44, 44), WW, WH, PB),
       "车机钮终位 {10,608,44,44}（底 652）→ 在包络内");
    ck(!at_pinned_slot(rect(339, 340, 44, 88), WW, WH, PB),
       "★中部瞬态位（底 428 < 555）→ **不在包络**（A3 不许点亮它）");
    ck(!at_pinned_slot(rect(339, 69, 44, 88), WW, WH, PB),
       "右上 +/图层 {339,69}（底 157）→ 不在包络");
    ck(!at_pinned_slot(rect(24, 702, 345, 44), WW, WH, PB),
       "搜索栏 → 不在包络（居中列）");
    ck(!at_pinned_slot(rect(160, 640, 44, 88), WW, WH, PB),
       "居中 {160,640} → 不在包络");

    printf("\n═══════════════════════════════════════\n");
    if (!Failed) { printf("★ 全部通过：%d/%d\n", Passed, Passed); return 0; }
    printf("✗ 失败 %d 项 / 共 %d\n", Failed, Passed + Failed);
    return 1;
}
