// GaodeClean 0.9.25 —— 缩窄 v4「只夹内层胶囊」决策仿真（纯 C，复刻源码规则）
// 编译运行：gcc -O2 -Wall -Wextra scripts/narrow_v4_sim.c -lm -o /tmp/v4 && /tmp/v4
// 目的：把「包装容器 / 内层白胶囊 / 底栏 / 普通层」四类对象的决策逐条断言，
//       并验证「容器已被夹窄」的竞态下，内层胶囊能自愈回 345。
#include <stdio.h>
#include <math.h>

#define SW        393.0            /* 屏宽 pt */
#define INSET     24.0             /* 两侧留白（GCBarInset） */
#define TARGET    (SW - 2*INSET)   /* 345.0 */
#define FULLW     SW               /* 满宽容器 */

typedef struct {
    double w;                /* 窗口系宽度 pt */
    int    in_search;        /* 是否在「捕获的搜索栏」子树内 */
    int    has_inner;        /* 是否有内层胶囊后代（即自己是包装容器） */
    int    is_inner;         /* 自己就是内层胶囊 */
    const char *name;
} V;

/* ── 源码规则复刻 ─────────────────────────────────────────────── */
static double clamp_w(V v) {
    if (v.in_search && v.has_inner) return v.w;                     /* 包装容器：整体放行 */
    int need = (v.w > TARGET + 0.5);
    if (!need && v.is_inner && v.w < TARGET - 0.5 && v.w >= TARGET * 0.85) need = 1;  /* 回补通道 */
    if (!need) return v.w;
    double minW = v.is_inner ? TARGET * 0.8 : SW - 60;
    if (v.w < minW) return v.w;
    if (v.w > SW - 12 && v.is_inner) return v.w;
    return TARGET;
}
/* recheck 每拍：偏宽收窄 / 内层胶囊偏窄回补 */
static double recheck_w(V v) {
    if (v.w > TARGET + 0.5) return clamp_w(v);
    if (v.in_search && v.is_inner && v.w < TARGET - 0.5 && v.w >= TARGET * 0.85) return clamp_w(v);
    return v.w;
}
static int fails = 0;
static void t(const char *what, double got, double want) {
    int ok = fabs(got - want) < 0.6;
    if (!ok) fails++;
    printf("  %-46s → %7.1f pt  (期望 %6.1f) %s\n", what, got, want, ok ? "✔" : "✘");
}

int main(void) {
    printf("屏宽 %.0fpt / GCBarInset %.0f / 目标宽 %.0fpt\n\n", SW, INSET, TARGET);

    puts("== 1. 搜索栏：不碰包装容器，只夹白胶囊 ==");
    V wrap = {FULLW, 1, 1, 0, "包装容器(393, 内含白胶囊)"};
    V cap  = {371.6, 1, 0, 1, "内层白胶囊(原生 371.6)"};
    t("包装容器 393 → 不动（放过）", clamp_w(wrap), FULLW);
    t("白胶囊 371.6 → 夹到 345", clamp_w(cap), TARGET);
    t("白胶囊幂等（已 345 再夹）", clamp_w((V){TARGET,1,0,1,""}), TARGET);

    puts("\n== 2. 竞态自愈：容器先被夹窄 → 胶囊被吃成 323.6 ==");
    V cap_eaten = {323.6, 1, 0, 1, "白胶囊被内缩吃窄(323.6)"};
    t("App 写 323.6 → 直接回补 345", clamp_w(cap_eaten), TARGET);
    t("recheck 每拍也能回补（自愈）", recheck_w(cap_eaten), TARGET);
    t("被吃窄到 0.85 边界内(293.3) → 回补", clamp_w((V){294.0,1,0,1,""}), TARGET);

    puts("\n== 3. 不跟 App 正常收缩抢戏（低于 0.85·目标 不碰）==");
    t("白胶囊 280pt（< 293.3）→ 不动", clamp_w((V){280.0,1,0,1,""}), 280.0);
    t("白胶囊 180pt（小药丸）→ 不动", clamp_w((V){180.0,1,0,1,""}), 180.0);

    puts("\n== 4. 底栏不受影响（不在搜索子树，走原规则）==");
    V tab = {374.0, 0, 0, 0, "底栏可见胶囊(原生 374)"};
    t("底栏 374 → 345（与 0.9.24 一致）", clamp_w(tab), TARGET);
    V tab_inner = {350.0, 0, 0, 0, "底栏内部容器(350)"};
    t("底栏内部容器 一点点收 → 345", clamp_w(tab_inner), TARGET);
    t("底栏幂等", clamp_w((V){TARGET,0,0,0,""}), TARGET);

    puts("\n== 5. 安全边界（反例必须不动）==");
    t("普通层 300pt（< 屏宽-60）→ 不动", clamp_w((V){300.0,0,0,0,""}), 300.0);
    t("满宽容器但不在搜索子树 → 345（原行为）", clamp_w((V){FULLW,0,0,0,""}), TARGET);
    t("搜索栏子树里的窄条 200pt → 不动", clamp_w((V){200.0,1,0,0,""}), 200.0);
    t("非搜索子树的内层标记但只有 320 → 不动", clamp_w((V){320.0,0,1,0,""}), 320.0);

    puts("\n== 6. 两条栏最终一致 ==");
    double search_visible = clamp_w(cap);                       /* 345 */
    double tab_visible    = clamp_w(tab);                       /* 345 */
    printf("  搜索栏可见 %.1fpt  |  底栏可见 %.1fpt  |  差 %.1fpt %s\n",
           search_visible, tab_visible, fabs(search_visible - tab_visible),
           (fabs(search_visible - tab_visible) < 0.6) ? "✔ 齐平" : "✘ 不等宽");
    if (fabs(search_visible - tab_visible) >= 0.6) fails++;

    printf("\n%s（失败 %d 项）\n", fails ? "FAIL" : "PASS 全部用例通过", fails);
    return fails ? 1 : 0;
}