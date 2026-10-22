// GaodeClean 0.9.26 —— 缩窄 v5「链上全收 + 双向回补」决策仿真（纯 C，复刻源码规则）
// 编译运行：gcc -O2 -Wall -Wextra scripts/narrow_v5_sim.c -lm -o /tmp/nv5 && /tmp/nv5
//
// 依据（0.9.25 现场实测 · iPhone 393pt 屏 · 逐像素梯度定位）：
//   · 搜索栏白胶囊 [10.3, 383.3] = 原生 371.6pt 宽 ⇒ 一格没夹（用户反馈「搜索栏没有变化」）
//   · 底栏可见胶囊 [45.7, 347.0] = 301.3pt ⇒ 被多夹一层（345 − 2×21.9，双侧对称）
//   · 底栏「首页」选中块 [86.7, 186.7] 未受影响
#include <stdio.h>
#include <math.h>

#define SW        393.0                 /* 屏宽 pt */
#define INSET     24.0                  /* 两侧留白 GCBarInset */
#define TARGET    (SW - 2*INSET)        /* 目标宽 345 */
#define MINH      46.0                  /* GCBarMinH 高度下限 */
#define HMAX      (SW * 0.35)           /* 高度上限 137.55 */
#define BAND_LO   (TARGET * 0.82)       /* 回补门槛 282.9 */
#define EDGE      (SW * 0.06)           /* 出屏容差 ±6% */
#define CHAIN_LO  (SW - 120)            /* 链收编宽度下限 273 */

typedef struct {
    double w, h, x;        /* 窗口系 宽 / 高 / 左端 */
    int in_search;         /* 在「捕获的搜索栏」子树内 */
    int full_like;         /* 宽 > 屏宽-12（满宽包装容器） */
    int has_inner;         /* 有内层胶囊后代 */
    int is_inner;          /* 自己是内层胶囊口径 */
    int in_chain;          /* 在捕获链来源集（回补资格） */
    int centered;          /* 居中（≤4pt） */
    const char *name;
} V;

/* ── 源码复刻：GCNarrowClamp（hook 路径闸门） ─────────────────── */
static double clamp_w(V v) {
    if (v.in_search && v.full_like && v.has_inner) return v.w;      /* A1：只放行满宽包装 */
    int need = (v.w > TARGET + 0.5);                                /* 偏宽：收窄 */
    if (!need && v.in_search && v.is_inner && v.w < TARGET - 0.5 && v.w >= BAND_LO) need = 1;
    if (!need) return v.w;
    if (v.w < BAND_LO) return v.w;                                  /* minW */
    if (v.h < MINH || v.h > HMAX) return v.w;                       /* A2：高度闸 */
    if (v.x < -EDGE || v.x + v.w > SW + EDGE) return v.w;           /* A3：±6% 出屏 */
    if (!v.centered) return v.w;
    return TARGET;
}
/* ── 源码复刻：GCNarrowChainHit（够不够收编格） ───────────────── */
static int chain_hit(V v) {
    if (v.w < CHAIN_LO) return 0;
    if (v.h < MINH || v.h > HMAX) return 0;
    if (v.x < -EDGE || v.x + v.w > SW + EDGE) return 0;
    if (!v.centered) return 0;
    return 1;
}
/* ── 源码复刻：GCNarrowRecheck 每拍（prev=上一拍宽，0=无快照） ─── */
static double recheck_w(V v, double prev) {
    if (v.w > TARGET + 0.5) return clamp_w(v);
    if (v.w < TARGET - 0.5 && v.w >= BAND_LO && v.in_chain &&
        prev > 0 && fabs(prev - v.w) < 0.5) {
        /* GCNarrowForceTarget：高度/居中闸通过 ⇒ 直写 345（绕开 need 闸门） */
        if (v.h < MINH || v.h > HMAX) return v.w;
        if (!v.centered) return v.w;
        return TARGET;
    }
    return v.w;
}

static int fails = 0;
static void t(const char *what, double got, double want) {
    int ok = fabs(got - want) < 0.6;
    if (!ok) fails++;
    printf("  %-54s -> %7.1f (期望 %7.1f) %s\n", what, got, want, ok ? "OK" : "FAIL");
}
static void ti(const char *what, int got, int want) {
    int ok = (got == want);
    if (!ok) fails++;
    printf("  %-54s -> %7d (期望 %7d) %s\n", what, got, want, ok ? "OK" : "FAIL");
}

int main(void) {
    printf("屏宽 %.0fpt / 目标宽 %.0fpt / 高度窗 [%.0f, %.0f] / 回补带 [%.1f, %.1f]\n\n",
           SW, TARGET, MINH, HMAX, BAND_LO, TARGET);

    puts("== 1. 搜索栏：只放行满宽包装，白胶囊重新被夹（修「没有变化」）==");
    V wrap = (V){.w=418.0, .h=120.0, .x=-12.5, .in_search=1, .full_like=1, .has_inner=1,
                 .centered=1, .name="包装容器(418 跨屏, 含内层)"};
    V cap = (V){.w=374.0, .h=53.6, .x=10.3, .in_search=1, .is_inner=1, .in_chain=1,
                .centered=1, .name="白胶囊(原生 374, 高 53.6)"};
    ti("ChainHit 收编包装容器", chain_hit(wrap), 1);
    ti("ChainHit 收编白胶囊", chain_hit(cap), 1);
    t("包装容器 418 → 放行不动", clamp_w(wrap), 418.0);
    t("白胶囊 374 → 夹到 345 ★", clamp_w(cap), TARGET);
    V cap1 = (V){.w=TARGET, .h=53.6, .x=24.0, .in_search=1, .is_inner=1, .in_chain=1,
                 .centered=1, .name="白胶囊幂等"};
    t("白胶囊幂等（345 再夹）", clamp_w(cap1), TARGET);

    puts("\n== 2. A2 高度闸隔离文本框（不碰内部排版）==");
    V tf = (V){.w=354.0, .h=36.0, .x=19.7, .in_search=1, .is_inner=1, .in_chain=1,
               .centered=1, .name="搜索栏文本框(354x36)"};
    ti("ChainHit 拒收文本框（高 36 < 46）", chain_hit(tf), 0);
    t("文本框 354 → 不动", clamp_w(tf), 354.0);

    puts("\n== 3. 底栏可见胶囊 301.3 → 回补 345（修「被缩过头」）==");
    V tabpack = (V){.w=374.0, .h=70.0, .x=9.5, .has_inner=1, .in_chain=1, .centered=1,
                    .name="底栏包装(原生 374, 高 70)"};
    V tabcap = (V){.w=301.3, .h=58.6, .x=45.7, .in_chain=1, .centered=1,
                   .name="底栏可见胶囊(被重排 301.3)"};
    ti("ChainHit 收编底栏包装", chain_hit(tabpack), 1);
    ti("ChainHit 收编底栏胶囊（301.3 ≥ 273）", chain_hit(tabcap), 1);
    t("底栏包装 374 → 345", clamp_w(tabpack), TARGET);
    t("底栏胶囊 301.3 首拍无快照 → 暂不动", recheck_w(tabcap, 0), 301.3);
    t("底栏胶囊 301.3 次拍同值 → 回补 345 ★", recheck_w(tabcap, 301.3), TARGET);
    V tab1 = (V){.w=TARGET, .h=58.6, .x=24.0, .in_chain=1, .centered=1, .name="底栏胶囊幂等"};
    t("底栏胶囊幂等（345 再复核）", recheck_w(tab1, TARGET), TARGET);

    puts("\n== 4. 不跟正常收缩/动画抢戏（反例必须不动）==");
    V pill = (V){.w=272.0, .h=50.0, .x=60.5, .in_chain=1, .centered=1, .name="小药丸 272(<282.9)"};
    t("小药丸 272 → 不动", recheck_w(pill, 272.0), 272.0);
    V small = (V){.w=180.0, .h=44.0, .x=106.5, .in_chain=1, .centered=1, .name="小药丸 180"};
    t("小药丸 180 → 不动", clamp_w(small), 180.0);
    V outchain = (V){.w=300.0, .h=60.0, .x=46.5, .centered=1, .name="链外层 300（不在来源集）"};
    t("链外层 300 → 不动", recheck_w(outchain, 300.0), 300.0);
    V anim = (V){.w=300.0, .h=60.0, .x=46.5, .in_chain=1, .centered=1, .name="链内层 300 动态中"};
    t("链内层 300 但 prev=340（动画中）→ 不动", recheck_w(anim, 340.0), 300.0);
    V narrow = (V){.w=250.0, .h=60.0, .x=71.5, .in_chain=1, .centered=1, .name="窄条 250"};
    ti("ChainHit 拒收窄条 250（< 273）", chain_hit(narrow), 0);
    V offc = (V){.w=380.0, .h=60.0, .x=6.5, .in_chain=1, .centered=0, .name="非居中 380"};
    ti("ChainHit 拒收非居中", chain_hit(offc), 0);
    V offs = (V){.w=380.0, .h=60.0, .x=-40.0, .in_chain=1, .centered=1, .name="出屏 40pt"};
    ti("ChainHit 拒收出屏 40pt（> ±6%）", chain_hit(offs), 0);
    V tall = (V){.w=360.0, .h=200.0, .x=16.5, .in_chain=1, .centered=1, .name="过高面板 360x200"};
    t("过高面板 → 不动", clamp_w(tall), 360.0);

    puts("\n== 5. 竞态自愈：搜索栏容器被先夹窄 → 白胶囊被吃成 323.6 ==");
    V eaten = (V){.w=323.6, .h=53.6, .x=34.7, .in_search=1, .is_inner=1, .in_chain=1,
                  .centered=1, .name="白胶囊被吃窄 323.6"};
    t("白胶囊 323.6 → 就地回补 345（Clamp 通道）", clamp_w(eaten), TARGET);
    V eaten2 = (V){.w=294.0, .h=53.6, .x=34.7, .in_search=1, .is_inner=1, .in_chain=1,
                   .centered=1, .name="白胶囊 294（0.85 界）"};
    t("白胶囊 294 → 回补 345", clamp_w(eaten2), TARGET);

    puts("\n== 6. 两条栏最终等宽 ==");
    double sv = clamp_w(cap), tv = recheck_w(tabcap, 301.3);
    printf("  搜索栏可见 %.1fpt | 底栏可见 %.1fpt | 差 %.1fpt %s\n",
           sv, tv, fabs(sv - tv), (fabs(sv - tv) < 0.6) ? "OK 齐平" : "FAIL 不等宽");
    if (fabs(sv - tv) >= 0.6) fails++;

    puts("\n== 7. 屏宽自适应（inset 恒 24）==");
    printf("  320pt 屏 → 目标 %.0f | 430pt 屏 → 目标 %.0f\n", 320 - 2*INSET, 430 - 2*INSET);

    printf("\n%s（失败 %d 项）\n", fails ? "FAIL" : "PASS 全部用例通过", fails);
    return fails ? 1 : 0;
}