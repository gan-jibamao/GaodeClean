// GaodeClean 0.9.28 —— 缩窄 v6「点对点夹取」几何仿真（纯 C，复刻 GCNarrowApply）
// 编译运行：gcc -O2 -Wall -Wextra scripts/narrow_v6_sim.c -lm -o /tmp/nv6 && /tmp/nv6
// 输入全部来自真机探针 dump（0.9.27+probe1，393x852pt）
#pragma GCC diagnostic ignored "-Wmissing-field-initializers"
#include <stdio.h>
#include <string.h>
#include <math.h>

#define TARGET_W 240.0
#define GAP      12.0

typedef struct { double x, w, h; int effect, image, hidden; const char *name; int standalone; } V;

static int pick_capsule(V *a, int n, double sw) {
    int best = -1; double bw = 0;
    for (int i = 0; i < n; i++) {
        if (a[i].hidden || !a[i].effect) continue;
        if (a[i].h < 40 || a[i].h > 120) continue;
        if (a[i].w < TARGET_W - 2 || a[i].w > sw - 4) continue;   // A2：下界=目标宽，防夹取后自锁
        if (fabs(a[i].x + a[i].w / 2 - sw / 2) > 10) continue;
        if (a[i].w > bw) { bw = a[i].w; best = i; }
    }
    return best;
}
static void apply(V *a, int n, double sw, int isSearch) {
    if (sw < 200) return;
    int ci = pick_capsule(a, n, sw);
    if (ci < 0) return;
    double cfw = a[ci].w, cfh = a[ci].h;
    double x = (sw - TARGET_W) / 2, right = x + TARGET_W;
    a[ci].x = x; a[ci].w = TARGET_W;
    for (int i = 0; i < n; i++) {              // A1：anchor.layer 上的独立栏级层（无对应 UIView）
        if (i == ci || !a[i].standalone || a[i].hidden) continue;
        if (a[i].h < 40 || a[i].h > 120) continue;
        if (a[i].w < TARGET_W - 2 || a[i].w > sw - 4) continue;
        if (fabs(a[i].x + a[i].w / 2 - sw / 2) > 20) continue;
        a[i].x = x; a[i].w = TARGET_W;
    }
    if (isSearch) {
        int idx[8], k = 0;
        for (int i = 0; i < n && k < 8; i++)
            if (i != ci && !a[i].hidden && a[i].w <= 60 && a[i].h <= 60 && a[i].x >= sw * 0.55) idx[k++] = i;
        for (int i = 0; i < k; i++)
            for (int j = i + 1; j < k; j++)
                if (a[idx[j]].x > a[idx[i]].x) { int t = idx[i]; idx[i] = idx[j]; idx[j] = t; }
        double cursor = right - GAP;
        for (int i = 0; i < k; i++) { double nx = cursor - a[idx[i]].w; cursor = nx; a[idx[i]].x = nx; }
    } else {
        for (int i = 0; i < n; i++) {
            if (i == ci || a[i].hidden || !a[i].image) continue;
            if (fabs(a[i].w - (cfw + 4)) > 14) continue;
            if (fabs(a[i].h - (cfh + 4)) > 14) continue;
            a[i].x = x - 2; a[i].w = TARGET_W + 4; a[i].h = cfh + 4;
        }
    }
}
static int fails = 0;
static void tv(const char *what, double got, double want) {
    int ok = fabs(got - want) < 0.6;
    if (!ok) fails++;
    printf("  %-52s -> %7.1f (期望 %7.1f) %s\n", what, got, want, ok ? "OK" : "FAIL");
}
static double get(V *a, int n, const char *name, int f) {
    for (int i = 0; i < n; i++) if (strcmp(a[i].name, name) == 0) return f ? a[i].w : a[i].x;
    return -999;
}
int main(void) {
    puts("== 1. 搜索栏（anchor 393，原生胶囊 377@8，相机 48@293，语音 32@341）==");
    V s[] = {
        {0, 377, 54, 1, 0, 0, "胶囊"},
        {293, 48, 48, 0, 0, 0, "相机"},
        {341, 32, 32, 0, 0, 0, "语音"},
    };
    apply(s, 3, 393, 1);
    tv("胶囊 x → 76.5", get(s, 3,"胶囊",0), 76.5);
    tv("胶囊 w → 240", get(s, 3,"胶囊",1), 240);
    tv("语音 x → 272.5（右缘距胶囊 12）", get(s, 3,"语音",0), 272.5);
    tv("相机 x → 224.5（紧贴语音左侧）", get(s, 3,"相机",0), 224.5);
    puts("\n== 2. 幂等：再跑一遍不应再动 ==");
    V s2[] = { {76.5,240,54,1,0,0,"胶囊"}, {224.5,48,48,0,0,0,"相机"}, {272.5,32,32,0,0,0,"语音"} };
    apply(s2, 3, 393, 1);
    tv("胶囊 x 保持 76.5", get(s2, 3,"胶囊",0), 76.5);
    tv("语音 x 保持 272.5", get(s2, 3,"语音",0), 272.5);
    puts("\n== 3. 底栏（原生胶囊 351@21，描边 355@19，环境阴影 399@-3，底衬 100@86.5，页签 84@94.5/214.5）==");
    V t[] = {
        {21, 351, 60, 1, 0, 0, "胶囊"},
        {19, 355, 64, 0, 1, 0, "描边图"},
        {-3, 399, 108, 0, 1, 0, "环境阴影"},
        {86.5, 100, 54, 0, 0, 0, "选中底衬"},
        {94.5, 84, 54, 0, 0, 0, "页签1"},
        {214.5, 84, 54, 0, 0, 0, "页签2"},
        {21, 351, 60, 0, 1, 1, "隐藏备用图"},
    };
    apply(t, 7, 393, 0);
    tv("胶囊 x → 76.5", get(t, 7,"胶囊",0), 76.5);
    tv("胶囊 w → 240", get(t, 7,"胶囊",1), 240);
    tv("描边 x → 74.5（胶囊外扩2）", get(t, 7,"描边图",0), 74.5);
    tv("描边 w → 244", get(t, 7,"描边图",1), 244);
    tv("环境阴影不动 -3", get(t, 7,"环境阴影",0), -3);
    tv("环境阴影宽不动 399", get(t, 7,"环境阴影",1), 399);
    tv("选中底衬不动 86.5", get(t, 7,"选中底衬",0), 86.5);
    tv("页签1 不动 94.5", get(t, 7,"页签1",0), 94.5);
    tv("页签2 不动 214.5", get(t, 7,"页签2",0), 214.5);
    tv("隐藏备用图不动 21", get(t, 7,"隐藏备用图",0), 21);
    puts("\n== 4. 内容边界断言（240 是否包得住底栏内容）==");
    tv("胶囊左缘 76.5 ≤ 选中底衬左缘 86.5", 86.5 - 76.5, 10.0);
    tv("胶囊右缘 316.5 ≥ 页签2右缘 298.5", 316.5 - 298.5, 18.0);
    puts("\n== 5. 其他屏宽自适应（430pt）==");
    V u[] = { {0,414,54,1,0,0,"胶囊"}, {330,48,48,0,0,0,"相机"}, {378,32,32,0,0,0,"语音"} };
    apply(u, 3, 430, 1);
    tv("430 屏胶囊 x → 95", get(u, 3,"胶囊",0), 95);
    tv("430 屏语音 x → 291", get(u, 3,"语音",0), 291);
    puts("\n== 6. 反例：没有合格胶囊时完全不动 ==");
    V z[] = { {0,393,20,1,0,0,"非栏层"}, {300,48,48,0,0,0,"按钮"} };
    apply(z, 2, 393, 1);
    tv("按钮不被挪（无胶囊即放弃）", get(z, 2,"按钮",0), 300);
    puts("\n== 7. A1：搜索栏独立白底层 + 渐变层（无对应 UIView）==");
    V w[] = {
        {8, 377, 54, 1, 0, 0, "胶囊", 0},
        {8, 377, 54, 0, 0, 0, "白底层", 1},
        {8, 377, 54, 0, 0, 0, "渐变层", 1},
        {293, 48, 48, 0, 0, 0, "相机", 0},
        {341, 32, 32, 0, 0, 0, "语音", 0},
    };
    apply(w, 5, 393, 1);
    tv("白底层 x → 76.5", get(w,5,"白底层",0), 76.5);
    tv("白底层 w → 240", get(w,5,"白底层",1), 240);
    tv("渐变层 w → 240", get(w,5,"渐变层",1), 240);
    tv("胶囊 w → 240", get(w,5,"胶囊",1), 240);
    puts("\n== 8. A1 反例：底栏环境层/隐藏层/底衬不受影响 ==");
    V e[] = {
        {21, 351, 60, 1, 0, 0, "胶囊", 0},
        {0, 393, 99.5, 0, 0, 0, "环境容器", 1},
        {-3, 399, 108, 0, 1, 0, "环境阴影", 0},
        {21, 351, 60, 0, 0, 1, "隐藏层", 1},
        {86.5, 100, 54, 0, 0, 0, "选中底衬", 0},
    };
    apply(e, 5, 393, 0);
    tv("环境容器 393 不动", get(e,5,"环境容器",1), 393);
    tv("环境阴影 399 不动", get(e,5,"环境阴影",1), 399);
    tv("隐藏层 351 不动", get(e,5,"隐藏层",1), 351);
    tv("选中底衬 100 不动", get(e,5,"选中底衬",1), 100);
    puts("\n== 9. A2 回归：胶囊已达标 + App 把白底改回原生 ⇒ 必须重新夹回（旧代码在此自锁）==");
    V r[] = {
        {76.5, 240, 54, 1, 0, 0, "胶囊", 0},
        {8, 377, 54, 0, 0, 0, "白底层", 1},
    };
    apply(r, 2, 393, 1);
    tv("已达标胶囊仍被识别（不自锁）", get(r,2,"胶囊",1), 240);
    tv("白底层被重新夹回 240", get(r,2,"白底层",1), 240);
    tv("白底层 x → 76.5", get(r,2,"白底层",0), 76.5);
    printf("\n%s（失败 %d 项）\n", fails ? "FAIL" : "PASS 全部用例通过", fails);
    return fails ? 1 : 0;
}
