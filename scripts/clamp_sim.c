/* GaodeClean 0.9.23 —— 搜索栏/底栏「缩窄」规则仿真（纯 C 复刻 src/GaodeClean.m 的几何规则）
   编译运行： gcc -O2 -Wall -Wextra scripts/clamp_sim.c -lm -o /tmp/cs && /tmp/cs
   覆盖：父级可见层 / 子级可见层 / 兄弟层 / 幂等 / 反例（整屏容器·过大面板·窄条·非居中·条带外） */
#include <stdio.h>
#include <math.h>
#define GCBarInset 24.0
#define HMAX_PICK 110.0        /* 几何发现的高度上限（严格） */
#define HMAX_CLAMP 137.6       /* 钳位的高度上限（屏宽×0.35，宽松） */
#define STRIP 0.70            /* 中线须落在屏幕下 30% 条带内 */
typedef struct { double x, w, h; const char *name; } V;
static double SW = 393.0, SH = 852.0;

static int inStrip(double y, double h) { return (y + h / 2) >= SH * STRIP; }
static V clamp(V v) {                          /* 对应 GCNarrowClamp（绝对几何、幂等） */
    double target = SW - 2 * GCBarInset;
    if (v.w <= target + 0.5) return v;
    if (v.w < SW - 60 || v.h < 20 || v.h > HMAX_CLAMP) return v;
    if (v.x < -1 || v.x + v.w > SW + 1) return v;
    if (fabs((v.x + v.w / 2) - SW * 0.5) > 4) return v;
    v.x += GCBarInset - v.x;  v.w = target;
    return v;
}
static void t(const char *tag, V v, double y, int expectMove) {
    V o = v; if (inStrip(y, v.h)) o = clamp(v);
    int moved = fabs(o.x - v.x) > 0.05 || fabs(o.w - v.w) > 0.05;
    printf("  %-40s y=%4.0f h=%3.0f → x=%6.1f w=%6.1f (L=%4.1f R=%4.1f) %s\n",
           tag, y, v.h, o.x, o.w, o.x, SW - (o.x + o.w),
           moved == expectMove ? (expectMove ? "【收窄 ✓】" : "【不动 ✓】") : "★ 不符预期");
}
int main(void) {
    printf("屏宽 %.0fpt 屏高 %.0fpt；目标宽 %.0fpt（两侧各 %.0fpt）；发现上限 %.0fpt\n\n",
           SW, SH, SW - 2 * GCBarInset, GCBarInset, HMAX_PICK);
    puts("== 正例：可见层在**任一**层级都能收到目标宽度（v1 漏在底栏的就是这一格）==");
    t("搜索栏容器（我们自己按全宽摆的）", (V){0,393,52,""}, 703, 1);
    t("搜索栏可见白胶囊（容器内缩 10.7）", (V){10.7,371.6,52,""}, 703, 1);
    t("底栏容器（父级）", (V){0,393,90,""}, 762, 1);
    t("底栏可见胶囊（父级内缩 9.5）", (V){9.5,374,50,""}, 763, 1);
    t("底栏胶囊（无合格父级，独立存在）", (V){10.7,371.6,50,""}, 763, 1);
    t("底栏高 70pt 的胶囊", (V){9.5,374,70,""}, 762, 1);
    puts("\n== 幂等：连夹两次必须完全一致 ==");
    V a = clamp((V){0,393,52,""}), b = clamp(a);
    printf("  一次 x=%.1f w=%.1f ｜ 二次 x=%.1f w=%.1f ｜ %s\n", a.x,a.w,b.x,b.w,
           (fabs(a.x-b.x)<1e-9 && fabs(a.w-b.w)<1e-9) ? "幂等 ✓" : "★ 非幂等");
    puts("\n== 反例：必须一像素不动 ==");
    t("窗口根内容视图（393×852）", (V){0,393,852,""}, 0, 0);
    t("过大面板容器（高 150pt > 钳位上限 137.6）", (V){0,393,150,""}, 730, 0);
    t("窄条（200pt 宽）", (V){96,200,44,""}, 780, 0);
    t("非居中宽条", (V){0,353,50,""}, 780, 0);
    t("条带外的宽条（屏幕中部 y=426）", (V){0,393,50,""}, 426, 0);
    t("横向出屏", (V){-20,420,50,""}, 780, 0);
    puts("\n== 0.9.24：高度上限分两条路径（搜索栏容器比可见胶囊高）==");
    {
        V cap = (V){0,393,53,""};      /* 可见白胶囊 53pt */
        V box = (V){0,393,120,""};     /* 可点区域容器 120pt */
        V r1 = clamp(cap), r2 = clamp(box);          /* 钳位用宽松上限 137.6pt */
        printf("  可见胶囊 高 53pt  → x=%.0f w=%.0f %s  | 容器 高 120pt → x=%.0f w=%.0f %s (钳位路径)\n",
               r1.x, r1.w, (r1.w<345.5)?"【收窄 ✓】":"✗", r2.x, r2.w, (r2.w<345.5)?"【收窄 ✓】":"✗");
        printf("  几何发现仍用严格上限 110pt：高 120pt 的容器不会被几何发现误收 ⇒ 必须两条路径并存\n");
        V big = (V){0,393,180,""};                    /* 更大的面板 180pt */
        V r3 = clamp(big);
        printf("  面板 高 180pt（>137.6）→ w=%.0f %s\n", r3.w, (fabs(r3.w-393)<0.5)?"【不动 ✓】":"✗");
    }
    puts("\n== 小屏 / 大屏 ==");
    SW = 320.0; printf("  320pt 屏：宽条 → x=%.1f w=%.1f（两侧各 %.0f）\n", clamp((V){0,320,48,""}).x, clamp((V){0,320,48,""}).w, GCBarInset);
    SW = 430.0; printf("  430pt 屏：宽条 → x=%.1f w=%.1f（两侧各 %.0f）\n", clamp((V){0,430,54,""}).x, clamp((V){0,430,54,""}).w, GCBarInset);
    return 0;
}
