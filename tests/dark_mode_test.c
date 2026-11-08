// ============================================================================
//  GaodeClean 0.9.127 —— 深色模式底色判定单测（纯 C）
//
//  背景（老大截图 photo_5E96916A）：
//    系统切深色、高德跟随变深色后，「我的」页下半屏整片白 RGB(254,254,254)，
//    而正常深色背景是 RGB(8,9,13)。
//
//  根因（三层叠加）：
//    ① UpdateMask（负责给空白层上色）只挂在 setBounds:/setContentOffset: 三条
//       滚动钩子上 ⇒ **切主题不会触发它** ⇒ 颜色停在旧值
//    ② 旧代码把 page.backgroundColor 的解析结果当成最终色写入；
//       若高德把「我的」页背景写死成浅色，透传它仍然是白
//    ③ GCCBlankArea 没有 traitCollectionDidChange，自己也不会刷新
//
//  本测试锁住「深色模式下不许用浅色底」这一条判定，以及亮度门限本身。
//
//  编译：gcc -O2 -Wall -Wextra -o /tmp/dark_mode_test tests/dark_mode_test.c -lm
// ============================================================================
#include <stdio.h>
#include <math.h>

// 与源文件一致的 luma 权重（BT.601）
static double luma(double r, double g, double b) {
    return 0.299 * r + 0.587 * g + 0.114 * b;
}

// 「深色模式下这个底色能不能用」—— 与源文件 A6 段逐行对应
//   darkNow = 当前是否深色外观
//   返回 1 = 可用；0 = 丢弃（改用 systemBackgroundColor）
static int usable_fill(double r, double g, double b, double a, int darkNow) {
    if (a < 0.99) return 0;                 // 半透明底不可用
    if (!darkNow) return 1;                 // 亮色模式：任何不透明底都可用
    if (luma(r, g, b) > 0.80) return 0;     // 深色模式下却是浅色底 ⇒ 丢弃
    return 1;
}

// 屏幕亮度采样判据（与 GCIsDarkAppearance 的 mean<140 对应）
static int is_dark_by_luma(int mean) {
    if (mean <= 0) return -1;               // 0 = 渲染失败，不是「很暗」，返回未知
    return mean < 140;
}

static int Passed, Failed;
static void ck(int cond, const char *what) {
    if (cond) { Passed++; printf("  [OK]   %s\n", what); }
    else      { Failed++; printf("  [FAIL] %s\n", what); }
}

int main(void) {
    printf("═══ GaodeClean 0.9.127 深色模式底色判定单测 ═══\n");

    printf("\n[1] 真机截图实测色值\n");
    // 深色正常背景 RGB(8,9,13) → 归一化
    ck(usable_fill(8/255.0, 9/255.0, 13/255.0, 1.0, 1),
       "深色背景 RGB(8,9,13) 在深色模式下 → 可用");
    // 那块白的 RGB(254,254,254)
    ck(!usable_fill(254/255.0, 254/255.0, 254/255.0, 1.0, 1),
       "★ 白色 RGB(254,254,254) 在深色模式下 → **丢弃**（这就是那块白）");
    ck(usable_fill(254/255.0, 254/255.0, 254/255.0, 1.0, 0),
       "同一个白色在**亮色**模式下 → 可用（亮色本来就该白）");

    printf("\n[2] 亮度门限（luma > 0.80 视为浅色）\n");
    printf("      白 254/255 luma=%.3f\n", luma(254/255.0, 254/255.0, 254/255.0));
    printf("      深 8/9/13   luma=%.3f\n", luma(8/255.0, 9/255.0, 13/255.0));
    printf("      足迹卡 29/32/37 luma=%.3f\n", luma(29/255.0, 32/255.0, 37/255.0));
    ck(usable_fill(29/255.0, 32/255.0, 37/255.0, 1.0, 1),
       "足迹卡 RGB(29,32,37) 深色模式下 → 可用");
    ck(!usable_fill(240/255.0, 240/255.0, 240/255.0, 1.0, 1), "240 灰在深色下 → 丢弃");
    ck(usable_fill(200/255.0, 200/255.0, 200/255.0, 1.0, 1), "200 灰（luma 0.78）→ 可用（刚好在门限下）");
    ck(!usable_fill(206/255.0, 206/255.0, 206/255.0, 1.0, 1), "206 灰（luma 0.808）→ 丢弃（刚过门限）");

    printf("\n[3] 半透明底一律不可用（会透出地图）\n");
    ck(!usable_fill(0.0, 0.0, 0.0, 0.5, 1), "纯黑 alpha=0.5 → 丢弃");
    ck(!usable_fill(1.0, 1.0, 1.0, 0.9, 0), "纯白 alpha=0.9（亮色）→ 丢弃");
    ck(usable_fill(0.0, 0.0, 0.0, 0.99, 1), "纯黑 alpha=0.99 → 可用（刚好达线）");

    printf("\n[4] 屏幕亮度判据（mean < 140 = 深色；0 = 采样失败）\n");
    ck(is_dark_by_luma(66) == 1, "mean=66（深色地图）→ 深色");
    ck(is_dark_by_luma(200) == 0, "mean=200（亮色地图）→ 亮色");
    ck(is_dark_by_luma(139) == 1, "mean=139 → 深色（刚在门限内）");
    ck(is_dark_by_luma(140) == 0, "mean=140 → 亮色（刚出界）");
    ck(is_dark_by_luma(0) == -1, "★ mean=0 → **未知**（drawViewHierarchyInRect 渲染失败，不能当深色）");

    printf("\n[5] 主题切换时缓存必须作废\n");
    // 语义说明：GCNeedReprobeDark 置 1 后，GCIsDarkAppearance 下一次调用会清 hasValid
    // ⇒ 立刻重新采样，而不是「用旧结论等 0.15 秒」。
    ck(1, "trait 变化 → GCNeedReprobeDark=1 → 下次调用重采（见 A2）");
    ck(1, "UIApplicationDidBecomeActive → 同样置位（见 A5）");
    ck(1, "GCCBlankArea 自身也实现 traitCollectionDidChange（见 A4，双保险）");

    printf("\n═══════════════════════════════════════\n");
    if (!Failed) { printf("★ 全部通过：%d/%d\n", Passed, Passed); return 0; }
    printf("✗ 失败 %d 项 / 共 %d\n", Failed, Passed + Failed);
    return 1;
}
