// ============================================================================
//  GaodeClean 0.9.117 —— 「已就位就拒绝被隐藏」安全阀单测（纯 C）
//
//  背景：探针 t=3.1s 铁证 —— 车机钮/胶囊位置**完全正确**（{10,608} / {339,667}）、
//  AlignedKey 已置、搜索栏已定型，但外层容器仍是 hid=1（App 的 NMMoveContentView
//  在冷启动时把整层搬走又搬回，顺手隐藏）。
//
//  本测试锁住 GCShouldProtectPinnedWidget 的三重安全阀与位置校验：
//    · 该保护的（位置正确 + 已钉位 + 冷启动窗口内）→ 保护
//    · 不该保护的（位置错 / 超时 / 未钉位 / 屏幕中部）→ 放行给 App
//
//  编译：gcc -O2 -Wall -Wextra -o /tmp/pinned_guard_test tests/pinned_guard_test.c -lm
// ============================================================================
#include <stdio.h>
#include <math.h>

#define COLD_LIMIT 60

typedef struct { double x, y, w, h; } R;
static R rect(double x, double y, double w, double h) { R r = {x, y, w, h}; return r; }

// 与源文件 GCShouldProtectPinnedWidget 的判据逐行对应
static int should_protect(R r, double ww, double h, int cold, int pinned, double pinBottom) {
    if (h < 1 || ww < 1) return 0;
    if (cold >= COLD_LIMIT) return 0;              // ① 冷启动窗口
    if (!pinned) return 0;                         // ② 已钉位
    if (!isfinite(r.x) || !isfinite(r.y)) return 0;
    if (r.h < 1) return 0;
    // ③ 位置：底边在 pinBottom 上方 0..200pt 带内 + 贴左/右边缘列
    double bottom = r.y + r.h;
    if (bottom > pinBottom + 4) return 0;
    if (bottom < pinBottom - 200) return 0;
    double midx = r.x + r.w / 2.0;
    int rightCol = midx > ww * 0.70;
    int leftCol  = midx < ww * 0.30;
    if (!rightCol && !leftCol) return 0;
    return 1;
}

static int Passed, Failed;
static void ck(int cond, const char *what) {
    if (cond) { Passed++; printf("  [OK]   %s\n", what); }
    else      { Failed++; printf("  [FAIL] %s\n", what); }
}

int main(void) {
    printf("═══ GaodeClean 0.9.117 安全阀单测 ═══\n");
    const double WW = 393.0, H = 852.0;
    // 实测：GCPinBottom = 755（底栏顶 768 - 13）
    const double PIN = 755.0;

    printf("\n[1] 该保护的 —— 探针实测坐标\n");
    // 胶囊：win={{339,667},{44,88}} → 底边 755 = pinBottom
    ck(should_protect(rect(339, 667, 44, 88), WW, H, 10, 1, PIN), "胶囊 {339,667,44,88} 底=755");
    // 车机钮：win={{10,608},{44,44}} → 底边 652 = 755-103
    ck(should_protect(rect(10, 608, 44, 44), WW, H, 10, 1, PIN), "车机钮 {10,608,44,44} 底=652");

    printf("\n[2] 不该保护的 —— 位置错（HISTORY §W 的钟摆场景）\n");
    // 屏幕中部裸奔：原生位置 340（屏高 40%）
    ck(!should_protect(rect(339, 340, 44, 88), WW, H, 10, 1, PIN), "中部 {339,340} 底=428 → 不保护");
    ck(!should_protect(rect(339, 400, 44, 88), WW, H, 10, 1, PIN), "中部 {339,400} 底=488 → 不保护");
    // 高于车机钮带（底边 < 555）
    ck(!should_protect(rect(10, 300, 44, 44), WW, H, 10, 1, PIN), "偏高 {10,300} 底=344 → 不保护");

    printf("\n[3] 安全阀 —— 超时 / 未钉位\n");
    ck(!should_protect(rect(339, 667, 44, 88), WW, H, 60, 1, PIN), "cold=60 已达上限 → 不保护");
    ck(should_protect(rect(339, 667, 44, 88), WW, H, 59, 1, PIN), "cold=59 仍在窗口 → 保护");
    ck(!should_protect(rect(339, 667, 44, 88), WW, H, 10, 0, PIN), "未钉位 → 不保护");

    printf("\n[4] 横向必须贴边\n");
    ck(!should_protect(rect(175, 667, 44, 88), WW, H, 10, 1, PIN), "居中 x=175 → 不保护");
    ck(should_protect(rect(339, 667, 44, 88), WW, H, 10, 1, PIN), "右侧列 → 保护");
    ck(should_protect(rect(10, 608, 44, 44), WW, H, 10, 1, PIN), "左侧列 → 保护");

    printf("\n[5] 边界\n");
    ck(!should_protect(rect(339, 760, 44, 88), WW, H, 10, 1, PIN), "底边 848 > pin+4 → 不保护");
    ck(should_protect(rect(339, 663, 44, 88), WW, H, 10, 1, PIN), "底边 751 → 保护");
    ck(!should_protect(rect(339, 667, 44, 88), 0, 0, 10, 1, PIN), "窗口尺寸非法 → 不保护");
    ck(!should_protect(rect(NAN, 667, 44, 88), WW, H, 10, 1, PIN), "NaN 坐标 → 不保护");

    printf("\n[6] 搜索栏 / 底栏不得被保护（它们在 pinBottom 附近但是横向居中）\n");
    ck(!should_protect(rect(24, 702, 345, 44), WW, H, 10, 1, PIN), "搜索栏 345 宽居中 → 不保护");
    ck(!should_protect(rect(21, 768, 351, 60), WW, H, 10, 1, PIN), "底栏 → 不保护");

    printf("\n═══════════════════════════════════════\n");
    if (!Failed) { printf("★ 全部通过：%d/%d\n", Passed, Passed); return 0; }
    printf("✗ 失败 %d 项 / 共 %d\n", Failed, Passed + Failed);
    return 1;
}
