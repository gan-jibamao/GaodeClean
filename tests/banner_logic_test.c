// ============================================================================
//  GaodeClean 0.9.99 —— 顶部横幅判定的主机单测（纯 C，无 Foundation）
//
//  源文件里的判据是「纯几何 + 纯文本匹配」，这里以纯 C 复刻同一套算法，
//  喂合成数据验证「该中的必中、不该中的必不中」。可在 iSH 里一键跑。
//
//  编译：gcc -O2 -Wall -Wextra -o /tmp/banner_logic_test tests/banner_logic_test.c -lm
//  运行：/tmp/banner_logic_test
// ============================================================================
#include <stdio.h>
#include <string.h>
#include <math.h>
#include <ctype.h>

// ── 广告角标词表（与源文件 GCAdBadgeTexts 对应）──────────────────────────
static const char *kAdBadges[] = {"广告", "广告 ", " 广告", "广告推广", "赞助", "推广"};
static const int kAdBadgeCount = 6;

// ── UTF-8 字符数（源文件用 NSString.length，即 UTF-16 码元数；
//    「广告」= 2 字符，判据上限 6，这里按 UTF-8 码点计更保守）─────────────
static int utf8_chars(const char *s) {
    int n = 0;
    for (; *s; s++) if (((unsigned char)*s & 0xC0) != 0x80) n++;
    return n;
}

// 去首尾空白（半角 + 全角空格），写入 out
static void trim_ws(const char *in, char *out, size_t cap) {
    size_t i = 0, len = strlen(in);
    // 半角空白
    while (i < len && isspace((unsigned char)in[i])) i++;
    // 全角空格 U+3000 = E3 80 80
    while (i + 2 < len && (unsigned char)in[i] == 0xE3 &&
           (unsigned char)in[i+1] == 0x80 && (unsigned char)in[i+2] == 0x80) i += 3;
    size_t j = len;
    while (j > i && isspace((unsigned char)in[j-1])) j--;
    while (j >= i + 3 && (unsigned char)in[j-3] == 0xE3 &&
           (unsigned char)in[j-2] == 0x80 && (unsigned char)in[j-1] == 0x80) j -= 3;
    size_t n = (j > i) ? (j - i) : 0;
    if (n >= cap) n = cap - 1;
    memcpy(out, in + i, n);
    out[n] = 0;
}

// 独立广告角标：总字符数 ≤6 且 trim 后与词表**完全相等**
static int is_independent_ad_mark(const char *txt) {
    if (!txt || !*txt) return 0;
    if (utf8_chars(txt) > 6) return 0;
    char buf[128];
    trim_ws(txt, buf, sizeof(buf));
    for (int i = 0; i < kAdBadgeCount; i++) {
        char bad[128];
        trim_ws(kAdBadges[i], bad, sizeof(bad));
        if (strcmp(buf, bad) == 0) return 1;
    }
    return 0;
}

// 关闭控件：类名/无障碍标签含 close / dismiss / 关闭 / 不感兴趣
static int looks_like_close(const char *cn, const char *al, int interactive) {
    if (cn && *cn && !interactive) return 0;
    if (cn && (strstr(cn, "close") || strstr(cn, "Close") ||
               strstr(cn, "dismiss") || strstr(cn, "Dismiss"))) return 1;
    if (al && *al) {
        if (strstr(al, "关闭") || strstr(al, "不感兴趣")) return 1;
        if (strstr(al, "close") || strstr(al, "Close") ||
            strstr(al, "dismiss") || strstr(al, "Dismiss")) return 1;
    }
    return 0;
}

typedef struct { double x, y, w, h; } R;
static R rect(double x, double y, double w, double h) { R r = {x, y, w, h}; return r; }

// 形状判据（与源文件 GCCIsTopBannerShape 逐行对应）
static int is_top_banner_shape(R r, double ww, double wh) {
    double w = r.w, h = r.h;
    if (ww < 1 || wh < 1) return 0;
    if (!isfinite(w) || !isfinite(h)) return 0;
    if (w < 120 || h < 28) return 0;
    if (w < ww * 0.60) return 0;
    if (h > wh * 0.18 || h > 190) return 0;
    if (r.y > wh * 0.33) return 0;
    if (w >= ww * 0.6 && h >= wh * 0.6) return 0;
    return 1;
}

// ── 单测 ────────────────────────────────────────────────────────────────────
static int Passed, Failed;
static void ck(int cond, const char *what) {
    if (cond) { Passed++; printf("  [OK]   %s\n", what); }
    else      { Failed++; printf("  [FAIL] %s\n", what); }
}

int main(void) {
    printf("═══ GaodeClean 0.9.99 顶部横幅判定单测 ═══\n");
    const double WW = 393.0, WH = 852.0;   // iPhone 15 Pro 逻辑分辨率

    printf("\n[1] 形状判据 —— 该中的必中\n");
    ck(is_top_banner_shape(rect(40.15, 50.3, 312.7, 56.3), WW, WH),
       "真机实测横幅 312.7x56.3 @y=50.3 → 命中");
    ck(is_top_banner_shape(rect(78.6, 60, 235.8, 28), WW, WH),
       "边界 60%宽 x 28高 → 命中");
    ck(is_top_banner_shape(rect(0, 44, 393, 60), WW, WH),
       "全宽通栏 393x60 @y=44 → 命中");

    printf("\n[2] 形状判据 —— 不该中的必不中\n");
    ck(!is_top_banner_shape(rect(40, 50, 200, 56), WW, WH), "窄卡 200x56（51%宽）→ 否");
    ck(!is_top_banner_shape(rect(40, 50, 312, 20), WW, WH), "扁条 312x20（高<28）→ 否");
    ck(!is_top_banner_shape(rect(40, 50, 312, 200), WW, WH), "高块 312x200（>190）→ 否");
    ck(!is_top_banner_shape(rect(40, 400, 312, 56), WW, WH), "同尺寸 @y=400（>33%）→ 否");
    ck(!is_top_banner_shape(rect(0, 0, 393, 852), WW, WH), "全屏 → 否（归开屏守卫）");
    ck(!is_top_banner_shape(rect(0, 0, 393, 600), WW, WH), "大面积 393x600 → 否（归开屏守卫）");

    printf("\n[3] 搜索栏不得误伤\n");
    ck(!is_top_banner_shape(rect(24, 702, 345, 44), WW, WH),
       "搜索栏 345x44 @y=702 → 否（不在顶部带）");
    ck(is_top_banner_shape(rect(24, 60, 345, 44), WW, WH),
       "搜索栏挪到顶部 → 形状通过（故必须有内容判据兜底）");
    ck(!is_independent_ad_mark("搜索 广告 附近"), "长文本含「广告」→ 非独立角标");
    ck(!is_independent_ad_mark("广告位招租请联系我们"), "9 字长文本 → 非独立角标");
    ck(is_independent_ad_mark("广告"), "单独「广告」→ 独立角标");
    ck(is_independent_ad_mark(" 广告 "), "「 广告 」带空格 → 独立角标");
    ck(is_independent_ad_mark("广告推广"), "「广告推广」→ 独立角标");
    ck(is_independent_ad_mark("\u3000广告\u3000"), "全角空格包裹 → 独立角标");

    printf("\n[4] 关闭控件识别\n");
    ck(looks_like_close("AdCloseButton", "", 1), "AdCloseButton → 是");
    ck(looks_like_close("UIButton", "关闭广告", 1), "无障碍「关闭广告」→ 是");
    ck(looks_like_close("UIButton", "不感兴趣", 1), "无障碍「不感兴趣」→ 是");
    ck(looks_like_close("UIImageView", "close", 1), "label=close → 是");
    ck(!looks_like_close("UILabel", "广告", 1), "普通「广告」label → 否");
    ck(!looks_like_close("AdCloseButton", "", 0), "不可交互 → 否");

    printf("\n[5] 组合判据（形状 + 广告角标 + 关闭控件）\n");
    int shape = is_top_banner_shape(rect(40.15, 50.3, 312.7, 56.3), WW, WH);
    int mark  = is_independent_ad_mark("广告");
    int clos  = looks_like_close("AdCloseButton", "关闭", 1);
    ck(shape && mark && clos, "实测横幅三项齐备 → 拦截");
    ck(!(shape && mark && !clos), "缺关闭控件 → 不拦截（宁可漏）");
    ck(!(shape && !mark && clos), "缺广告角标 → 不拦截（宁可漏）");
    ck(!is_independent_ad_mark("广告xxx"), "角标位出现「广告xxx」长文 → 非独立角标");
    ck(!(shape && is_independent_ad_mark("广告xxx") && clos), "长文角标 → 不拦截");

    // 反例矩阵：模拟各类真实视图，全部必须否
    printf("\n[6] 反例矩阵（真实可能出现的非广告视图）\n");
    struct { const char *name; R r; const char *badge; const char *close; int inter; } neg[] = {
        {"首页搜索栏",        {24, 60, 345, 44}, NULL,     NULL,      1},
        {"天气行（顶部标题）", {16, 100, 361, 30}, "晴",    NULL,      0},
        {"连接车机按钮",      {24, 160, 345, 44}, NULL,    NULL,      1},
        {"2D/3D 圆钮",        {330, 60, 44, 44},  NULL,    NULL,      1},
        {"图层胶囊",          {330, 60, 44, 90},  NULL,    NULL,      1},
        {"运营通栏（无角标）", {40, 50, 313, 56},  NULL,    "close",   1},
        {"通栏（角标在长文里）",{40, 50, 313, 56}, "限时活动广告位", "close", 1},
    };
    int n = (int)(sizeof(neg)/sizeof(neg[0]));
    for (int i = 0; i < n; i++) {
        int s = is_top_banner_shape(neg[i].r, WW, WH);
        int m = neg[i].badge ? is_independent_ad_mark(neg[i].badge) : 0;
        int c = neg[i].close ? looks_like_close(neg[i].close, "", neg[i].inter) : 0;
        char msg[160];
        snprintf(msg, sizeof(msg), "%-18s shape=%d mark=%d close=%d → %s",
                 neg[i].name, s, m, c, (s && m && c) ? "误伤!!" : "正确放行");
        ck(!(s && m && c), msg);
    }

    printf("\n═══════════════════════════════════════\n");
    if (!Failed) { printf("★ 全部通过：%d/%d\n", Passed, Passed); return 0; }
    printf("✗ 失败 %d 项 / 共 %d\n", Failed, Passed + Failed);
    return 1;
}
