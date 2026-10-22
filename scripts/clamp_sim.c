#include <stdio.h>
#include <math.h>
#define GCBarInset 24.0
typedef struct { double x, w, h; } R;         // 窗口坐标下的 rect
static R clamp(double screenW, R in, int isRoot, int isWindow) {
    R f = in;
    if (screenW < 200 || isWindow) return f;
    if (isRoot) return f;
    double target = screenW - 2 * GCBarInset;
    if (f.w <= target + 0.5) return f;                 // 幂等闸门
    if (f.w < screenW - 60) return f;
    if (f.h < 20 || f.h > screenW * 0.35) return f;
    if (f.x < -1 || f.x + f.w > screenW + 1) return f;
    if (f.x > 40 || screenW - (f.x + f.w) > 40) return f;
    if (fabs((f.x + f.w / 2) - screenW * 0.5) > 4) return f;
    f.x += GCBarInset - f.x;  f.w = target;
    return f;
}
static void show(const char*name, R r, R o) {
    printf("  %-34s → x=%.1f w=%.1f (边距 L=%.1f R=%.1f) %s\n", name, o.x, o.w,
           o.x, 393 - (o.x + o.w), (fabs(o.x-r.x)>0.05||fabs(o.w-r.w)>0.05) ? "【已收窄】":"【不动】");
}
int main(void){
    double S = 393.0; R r;
    printf("屏宽 %.0fpt，目标宽 %.0fpt（两侧各 %.0fpt）\n", S, S-2*GCBarInset, GCBarInset);
    puts("== 正例（应收到 24 / 369）==");
    r=(R){0,393,52};       show("搜索栏容器（满屏宽）", r, clamp(S,r,0,0));
    r=(R){10.7,371.6,52};  show("搜索栏可见胶囊（内缩10.7）", r, clamp(S,r,0,0));
    r=(R){0,393,50};       show("底栏容器（满屏宽）", r, clamp(S,r,0,0));
    r=(R){9.5,374,50};     show("底栏可见胶囊（内缩9.5）", r, clamp(S,r,0,0));
    r=(R){0,393,70};       show("底栏高70pt", r, clamp(S,r,0,0));
    puts("== 幂等（连夹两次，第二次必须不变）==");
    r=(R){0,393,52}; R a=clamp(S,r,0,0); R b=clamp(S,a,0,0);
    printf("  一次: x=%.1f w=%.1f ｜ 二次: x=%.1f w=%.1f ｜ %s\n", a.x,a.w,b.x,b.w,
           (fabs(a.x-b.x)<1e-9&&fabs(a.w-b.w)<1e-9)?"幂等 ✓":"★ 非幂等");
    puts("== 反例（必须一像素都不动）==");
    r=(R){0,393,852};      show("窗口根内容视图（393×852）", r, clamp(S,r,1,0));
    r=(R){0,393,852};      show("窗口自身", r, clamp(S,r,0,1));
    r=(R){0,200,40};       show("窄视图 200pt", r, clamp(S,r,0,0));
    r=(R){100,193,40};     show("非居中宽视图", r, clamp(S,r,0,0));
    r=(R){0,393,200};      show("过高视图（200pt > 屏宽×0.35）", r, clamp(S,r,0,0));
    r=(R){0,500,40};       show("超出屏幕宽", r, clamp(S,r,0,0));
    r=(R){60,313,40};      show("端头太靠里（L=60）", r, clamp(S,r,0,0));
    puts("== 小屏（320pt）==");
    r=(R){0,320,48};       printf("  320pt 屏容器 → x=%.1f w=%.1f\n", clamp(320,r,0,0).x, clamp(320,r,0,0).w);
    return 0;
}
