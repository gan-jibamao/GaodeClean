// ============================================================================
//  GaodeClean 0.9.120 —— 右下胶囊几何兜底判据单测（纯 C）
//
//  背景：IsRightBottomWidget 原来只认 getItemTag（AJX 数据字段，晚于视图上屏
//  才写入）。tag 没写进来之前 CachedRight 恒为 nil，胶囊打不上 AlignedKey，
//  被 setHidden: 拦截按住 —— 真机实测车机钮 1.05s 出现、胶囊要 2.50s。
//
//  本测试锁住新增的几何兜底：
//    · 右下胶囊本体 → 命中（tag 未到时也能认出来）
//    · 右上「+/图层」胶囊 → 必须不命中（同类不同位置，最容易误伤）
//    · 中部裸奔位 / 左侧车机钮 / 搜索栏 / 底栏 → 必须不命中
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
    if (r.x + r.w / 2 < ww * 0.70) return 0;      // 右列
    if (r.y + r.h / 2 < wh * 0.60) return 0;      // 底部带（排除右上）
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
    printf("═══ GaodeClean 0.9.120 右下胶囊几何兜底单测 ═══\n");
    const double WW = 393.0, WH = 852.0;   // iPhone 15 Pro 逻辑分辨率

    printf("\n[1] 该命中的 —— 右下胶囊本体\n");
    ck(is_right_bottom_geo(rect(339, 667, 44, 88), WW, WH), "真机实测 {339,667,44,88}");
    ck(is_right_bottom_geo(rect(349, 690, 40, 60), WW, WH), "稍小的变体 {349,690,40,60}");
    ck(is_right_bottom_geo(rect(330, 620, 60, 120), WW, WH), "大机型变体 {330,620,60,120}");

    printf("\n[2] 绝不能误伤 —— 右上「+/图层」同类胶囊\n");
    ck(!is_right_bottom_geo(rect(339, 69, 44, 88), WW, WH), "右上 {339,69}（y=8% 屏高）");
    ck(!is_right_bottom_geo(rect(339, 25, 44, 100), WW, WH), "右上扩展 {339,25,44,100}");
    ck(!is_right_bottom_geo(rect(339, 300, 44, 88), WW, WH), "中部 {339,300}（y=40%）");
    ck(!is_right_bottom_geo(rect(339, 400, 44, 88), WW, WH), "中部偏下 {339,400}（y=52%）");

    printf("\n[3] 绝不能误伤 —— 其它首页控件\n");
    ck(!is_right_bottom_geo(rect(10, 608, 44, 44), WW, WH), "左侧车机钮 {10,608,44,44}");
    ck(!is_right_bottom_geo(rect(24, 702, 345, 44), WW, WH), "搜索栏 {24,702,345,44}");
    ck(!is_right_bottom_geo(rect(21, 768, 351, 60), WW, WH), "底栏 {21,768,351,60}");
    ck(!is_right_bottom_geo(rect(160, 640, 44, 88), WW, WH), "居中同尺寸 {160,640}");

    printf("\n[4] 尺寸边界\n");
    ck(!is_right_bottom_geo(rect(339, 667, 20, 88), WW, WH), "宽 20（<30）→ 否");
    ck(!is_right_bottom_geo(rect(339, 667, 90, 88), WW, WH), "宽 90（>70）→ 否");
    ck(!is_right_bottom_geo(rect(339, 667, 44, 40), WW, WH), "高 40（<50）→ 否");
    ck(!is_right_bottom_geo(rect(339, 667, 44, 150), WW, WH), "高 150（>130）→ 否");
    ck(is_right_bottom_geo(rect(339, 667, 30, 50), WW, WH), "边界 30x50 → 是");
    ck(is_right_bottom_geo(rect(339, 667, 70, 130), WW, WH), "边界 70x130 → 是");

    printf("\n[5] 异常输入\n");
    ck(!is_right_bottom_geo(rect(339, 667, 44, 88), 0, 0), "窗口尺寸非法 → 否");
    ck(!is_right_bottom_geo(rect(NAN, 667, 44, 88), WW, WH), "NaN 坐标 → 否");

    printf("\n═══════════════════════════════════════\n");
    if (!Failed) { printf("★ 全部通过：%d/%d\n", Passed, Passed); return 0; }
    printf("✗ 失败 %d 项 / 共 %d\n", Failed, Passed + Failed);
    return 1;
}
