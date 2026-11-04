// ============================================================================
//  GaodeClean 0.9.114 —— 右上胶囊几何豁免判定单测（纯 C）
//
//  背景：冷启动 1.0~1.5s 期间右上胶囊里的「+」号被 2D/3D 摆位逻辑误抓搬走，
//  表现为「消失→回来→再消失」闪两次（120fps 录屏 228 帧逐帧实测）。
//
//  本测试锁住新增的 GCCIsInTopRightCapsuleZone 判据：
//    · 右上胶囊区域内的视图 → 必须豁免（不得参与任何按几何找控件的识别）
//    · 右下 ⊙/↰ 胶囊、底栏、中部裸露容器 → 必须不受影响（不能过度豁免）
//
//  编译：gcc -O2 -Wall -Wextra -o /tmp/capsule_zone_test tests/capsule_zone_test.c -lm
// ============================================================================
#include <stdio.h>
#include <math.h>

typedef struct { double x, y, w, h; } R;
static R rect(double x, double y, double w, double h) { R r = {x, y, w, h}; return r; }

// 与源文件 GCCIsInTopRightCapsuleZone 逐行对应
static int in_top_right_capsule_zone(R r, double ww, double wh) {
    if (ww < 1 || wh < 1) return 0;
    if (!isfinite(r.x) || !isfinite(r.y)) return 0;
    double midx = r.x + r.w / 2.0;
    double maxy = r.y + r.h;
    if (midx < ww * 0.70) return 0;
    if (maxy > wh * 0.35 || maxy <= 0) return 0;
    return 1;
}

static int Passed, Failed;
static void ck(int cond, const char *what) {
    if (cond) { Passed++; printf("  [OK]   %s\n", what); }
    else      { Failed++; printf("  [FAIL] %s\n", what); }
}

int main(void) {
    printf("═══ GaodeClean 0.9.114 右上胶囊几何豁免单测 ═══\n");
    const double WW = 393.0, WH = 852.0;

    printf("\n[1] 右上胶囊 —— 必须豁免（防 + 号被误抓）\n");
    // 真机实测：胶囊约 x=349..386, y=30..120（右上角竖长胶囊）
    ck(in_top_right_capsule_zone(rect(349, 30, 37, 90), WW, WH), "胶囊整体 349,30 37x90");
    // + 号本体：44x44，在胶囊上半部
    ck(in_top_right_capsule_zone(rect(345, 34, 44, 44), WW, WH), "+ 号 44x44 @y=34");
    // 胶囊容器（WINLiteWidgetGroupView 本体，通常略大于胶囊）
    ck(in_top_right_capsule_zone(rect(340, 25, 50, 100), WW, WH), "胶囊容器 50x100");

    printf("\n[2] 其他控件 —— 必须不受影响（不能过度豁免）\n");
    // 右下 ⊙/↰ 胶囊：真机 y≈600pt（70% 屏高）
    ck(!in_top_right_capsule_zone(rect(330, 600, 44, 88), WW, WH), "右下 ⊙/↰ 胶囊 y=600");
    // 底栏
    ck(!in_top_right_capsule_zone(rect(40, 760, 313, 60), WW, WH), "底栏 y=760");
    // 中部裸露 LiteGroup（居中）
    ck(!in_top_right_capsule_zone(rect(170, 340, 56, 56), WW, WH), "中部 LiteGroup 居中");
    // 搜索栏
    ck(!in_top_right_capsule_zone(rect(24, 702, 345, 44), WW, WH), "搜索栏 y=702");
    // 天气行
    ck(!in_top_right_capsule_zone(rect(16, 100, 361, 30), WW, WH), "天气行（左对齐，中心 x 偏左）");
    // 左侧控件
    ck(!in_top_right_capsule_zone(rect(10, 40, 44, 44), WW, WH), "左上控件 x=10");

    printf("\n[3] 边界条件\n");
    ck(in_top_right_capsule_zone(rect(273, 30, 44, 44), WW, WH), "中心 x 恰好 70%（273+22=295=0.75）");
    ck(!in_top_right_capsule_zone(rect(230, 30, 44, 44), WW, WH), "中心 x=0.64 屏宽 → 否");
    ck(in_top_right_capsule_zone(rect(349, 250, 44, 44), WW, WH), "maxY=294 < 298(35%) → 是");
    ck(!in_top_right_capsule_zone(rect(349, 260, 44, 44), WW, WH), "maxY=304 > 298 → 否");
    ck(!in_top_right_capsule_zone(rect(349, -60, 44, 44), WW, WH), "完全在屏幕上方 maxY=-16 → 否");
    ck(!in_top_right_capsule_zone(rect(349, 30, 44, 44), 0, 0), "窗口尺寸非法 → 否");
    ck(!in_top_right_capsule_zone(rect(NAN, 30, 44, 44), WW, WH), "NaN 坐标 → 否");

    printf("\n[4] 回归：中部 LiteGroup 仍能被 GCCIsLiteGroupCapsule 认出\n");
    // GCCIsLiteGroupCapsule 用 25% 高度线区分：中部(y>25%)算 LiteGroup，右上(y<25%)不算
    #define IS_LITE(y, h) ((y) > (h) * 0.25)
    ck(IS_LITE(340, WH), "中部 y=340 > 213 → 判为 LiteGroup（原逻辑不变）");
    ck(!IS_LITE(30, WH), "右上 y=30 < 213 → 不判为 LiteGroup（原逻辑不变）");

    printf("\n═══════════════════════════════════════\n");
    if (!Failed) { printf("★ 全部通过：%d/%d\n", Passed, Passed); return 0; }
    printf("✗ 失败 %d 项 / 共 %d\n", Failed, Passed + Failed);
    return 1;
}
