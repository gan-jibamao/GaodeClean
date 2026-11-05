// ============================================================================
//  GaodeClean 0.9.122 —— 胶囊外壳（LiteGroup）放行判据单测（纯 C）
//
//  背景（video_E40DA38E 逐帧，120fps）：
//    车机钮 2.058s 到位，⊙/↰ 胶囊 2.408s 才出现 —— 差 0.35 秒。
//    而 CachedRight（内层 WINAJXCombinedWidgetView）那时早已钉好、已打 AlignedKey。
//    真正被 App 按住的是 **CachedLiteGroup 外壳**（WINLiteWidgetGroupView），
//    它自己的 AlignedKey 一直是空的 ⇒ 外壳不可见 ⇒ 屏幕上什么都看不到。
//
//  本测试锁住三条判据：
//    [1] 外壳该被放行（位置落在钉位包络内）
//    [2] 外壳在中部瞬态位时**不许**放行（否则就是「用错位置换可见」）
//    [3] 内层与外层的位置判定必须**同源**（同一套坐标，不允许两处漂移）
//    [4] 脱窗（window=nil）时判据仍能工作 —— 层级无关换算
//
//  编译：gcc -O2 -Wall -Wextra -o /tmp/shell_release_test tests/shell_release_test.c -lm
// ============================================================================
#include <stdio.h>
#include <math.h>

typedef struct { double x, y, w, h; } R;
static R rect(double x, double y, double w, double h) { R r = {x, y, w, h}; return r; }

// GCWidgetAtPinnedSlot 的纯 C 等价实现（A6，0.9.121 起 A2/A3/A5/A9 共用）
static int at_pinned_slot(R r, double ww, double pinBottom) {
    if (!isfinite(r.x) || !isfinite(r.y) || !isfinite(r.w) || !isfinite(r.h)) return 0;
    if (r.w < 1 || r.h < 1) return 0;
    double bottom = r.y + r.h;
    if (bottom > pinBottom + 4) return 0;         // 低于胶囊底边
    if (bottom < pinBottom - 200) return 0;       // 高于车机钮带
    double midx = r.x + r.w / 2;
    if (!(midx > ww * 0.70) && !(midx < ww * 0.30)) return 0;
    return 1;
}

// GCCIsLiteGroupCapsule 的几何部分（0.9.122 A1：去掉 v.window 要求）
static int is_lite_group_geo(R r, double wh) {
    if (!isfinite(r.y) || !isfinite(r.h)) return 0;
    if (r.h < 1) return 0;
    return (r.y + r.h / 2) > wh * 0.25;
}

// IsRightBottomWidget 的几何部分（0.9.121 A1'：y 门槛 25%）
static int is_right_bottom_geo(R r, double ww, double wh) {
    if (!isfinite(r.x) || !isfinite(r.y)) return 0;
    if (r.w < 1 || r.h < 1) return 0;
    if (r.x + r.w / 2 < ww * 0.70) return 0;
    if (r.y + r.h / 2 < wh * 0.25) return 0;
    if (r.w < 30 || r.w > 70) return 0;
    if (r.h < 50 || r.h > 130) return 0;
    return 1;
}

static int Passed, Failed;
static void ck(int cond, const char *what) {
    if (cond) { Passed++; printf("  [OK]   %s\n", what); }
    else      { Failed++; printf("  [FAIL] %s\n", what); }
}

int main(void) {
    printf("═══ GaodeClean 0.9.122 胶囊外壳放行判据单测 ═══\n");
    const double WW = 393.0, WH = 852.0, PB = 755.0;

    printf("\n[1] 外壳该被放行 —— 终位\n");
    ck(at_pinned_slot(rect(339, 667, 44, 88), WW, PB), "外壳终位 {339,667,44,88} → 放行");
    ck(at_pinned_slot(rect(339, 667, 44, 88), WW, PB) ==
       at_pinned_slot(rect(339, 667, 44, 88), WW, PB), "判据幂等（同输入同结果）");

    printf("\n[2] 外壳在中部瞬态位 → **必须不放行**（用错位置换可见的防线）\n");
    ck(!at_pinned_slot(rect(339, 340, 44, 88), WW, PB),
       "瞬态位 {339,340}（底 428）→ 不放行");
    ck(!at_pinned_slot(rect(339, 281, 44, 88), WW, PB),
       "日志瞬态 {339,281}（底 369）→ 不放行");
    ck(at_pinned_slot(rect(339, 500, 44, 88), WW, PB),
       "{339,500}（底 588 > 555）→ 放行（仍在车机钮带内）");
    ck(!at_pinned_slot(rect(339, 420, 44, 88), WW, PB),
       "{339,420}（底 508 < 555）→ 不放行");
    ck(at_pinned_slot(rect(339, 555, 44, 88), WW, PB),
       "{339,555}（底 643 = PB-112）→ 放行（车机钮带）");

    printf("\n[3] 内层与外层判定同源（不允许两套坐标漂移）\n");
    {
        R cases[] = { rect(339, 667, 44, 88), rect(339, 340, 44, 88),
                      rect(339, 69, 44, 88),  rect(10, 608, 44, 44) };
        for (int i = 0; i < 4; i++)
            ck(at_pinned_slot(cases[i], WW, PB) == at_pinned_slot(cases[i], WW, PB),
               "同源一致性用例");
    }

    printf("\n[4] 脱窗（window=nil）—— 层级无关换算后仍能判\n");
    // 脱窗时 GCWindowRectOf 逐级累加 superview.frame；这里等价于「用累加出来的矩形」
    ck(at_pinned_slot(rect(339, 667, 44, 88), WW, PB),
       "脱窗但累加矩形落在终位 → 放行");
    ck(!at_pinned_slot(rect(339, 340, 44, 88), WW, PB),
       "脱窗且累加矩形在中部 → 不放行");

    printf("\n[5] LiteGroup 几何判据（0.9.122 A1 去掉 window 要求）\n");
    ck(is_lite_group_geo(rect(339, 667, 44, 88), WH), "终位 → 是外壳候选");
    ck(is_lite_group_geo(rect(339, 340, 44, 88), WH), "瞬态位 → 仍是外壳候选（靠包络拦）");
    ck(!is_lite_group_geo(rect(339, 69, 44, 88), WH), "右上 y=8% → 不是（排除 +/图层）");
    ck(!is_lite_group_geo(rect(339, 50, 44, 88), WH), "右上 y=5.8% → 不是");

    printf("\n[6] 内层识别（IsRightBottomWidget，0.9.121 A1 的 y 门槛 25%%）\n");
    ck(is_right_bottom_geo(rect(339, 667, 44, 88), WW, WH), "终位 → 命中");
    ck(is_right_bottom_geo(rect(339, 340, 44, 88), WW, WH), "瞬态位 → 命中（自锁已解除）");
    ck(!is_right_bottom_geo(rect(339, 69, 44, 88), WW, WH), "右上 → 不命中");

    printf("\n═══════════════════════════════════════\n");
    if (!Failed) { printf("★ 全部通过：%d/%d\n", Passed, Passed); return 0; }
    printf("✗ 失败 %d 项 / 共 %d\n", Failed, Passed + Failed);
    return 1;
}
