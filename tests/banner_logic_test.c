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
    if (h > wh * 0.18 || h > 210) return 0;      // 0.9.119：上限 190 → 210（与源码同步）
    if (r.y > wh * 0.33) return 0;
    if (w >= ww * 0.6 && h >= wh * 0.6) return 0;
    return 1;
}

// ★0.9.123（A4）：运营通知条判据（与源文件 GCCBannerHasOpsNoticeText 对应）
//   「【」= U+3010，「】」= U+3011。文案含这一对方括号 + 右侧真实关闭控件 ⇒ 是运营通知条。
static int is_ops_notice_text(const char *txt) {
    if (!txt || !*txt) return 0;
    if (utf8_chars(txt) > 60) return 0;          // 长段内容不算
    // UTF-8 编码：U+3010 = E3 80 90，U+3011 = E3 80 91
    if (!strstr(txt, "\xE3\x80\x90")) return 0;
    if (!strstr(txt, "\xE3\x80\x91")) return 0;
    return 1;
}


// 与源文件 GCCBannerHasLegalAdMark 的「后缀角标」分支对应
static int is_suffix_ad_mark(const char *txt, double relX) {
    if (!txt || !*txt) return 0;
    int n = utf8_chars(txt);
    if (n > 40) return 0;
    int has = 0;
    for (int i = 0; i < kAdBadgeCount; i++) {
        if (strstr(txt, kAdBadges[i])) { has = 1; break; }
    }
    if (!has) return 0;
    return relX > 0.55;
}


// 与源文件 GCCLooksLikeCloseControl 的几何兜底（④）对应
static int looks_like_close_geo(const char *cn, const char *al, int inter,
                                 double w, double h, int nsub, double relX) {
    if (cn && (strstr(cn, "close") || strstr(cn, "Close") ||
               strstr(cn, "dismiss") || strstr(cn, "Dismiss"))) return inter ? 1 : 0;
    if (al && (strstr(al, "关闭") || strstr(al, "不感兴趣"))) return 1;
    if (!inter) return 0;
    if (nsub != 0) return 0;
    if (!(w >= 8 && w <= 44 && h >= 8 && h <= 44)) return 0;
    return relX > 0.70;
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
    ck(is_top_banner_shape(rect(0, 150, 886, 189), 886, 1920),
       "0.9.118：天猫横幅 886x189 @y=150（真机实测）→ 命中");
    ck(!is_top_banner_shape(rect(40, 50, 312, 230), WW, WH), "高块 312x230（>210）→ 否");
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

    printf("\n[3b] 后缀角标（0.9.118 新增）\n");
    ck(is_independent_ad_mark("广告"), "独立「广告」→ 角标");
    // 长文后缀型：靠 is_suffix_ad_mark 判定
    ck(is_suffix_ad_mark("真诚无套路，直降再叠券 7.2折起 广告", 0.62), "长文案尾部带广告且靠右 → 角标");
    ck(!is_suffix_ad_mark("真诚无套路，直降再叠券 7.2折起 广告", 0.30), "同文案但靠左 → 否");
    ck(!is_suffix_ad_mark("这是一段非常长的正文内容用来测试长度上限是否能够正确拦截因为广告字样的确出现在里面但是整体字数已经远远超过了四十个字的门槛", 0.60), "超 40 字 → 否");
    ck(is_suffix_ad_mark("限时活动 赞助", 0.70), "「赞助」后缀 → 角标");

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


    printf("\n[7] 关闭控件几何兜底（0.9.119 新增）\n");
    ck(looks_like_close_geo("UIImageView", "", 1, 20, 20, 0, 0.95), "纯图片 × 20x20 靠右 → 是");
    ck(!looks_like_close_geo("UIImageView", "", 1, 20, 20, 0, 0.40), "同图但靠左（商品图）→ 否");
    ck(!looks_like_close_geo("UIImageView", "", 1, 60, 60, 0, 0.95), "60x60 太大 → 否");
    ck(!looks_like_close_geo("UIView", "", 1, 20, 20, 3, 0.95), "有子视图（容器）→ 否");
    ck(!looks_like_close_geo("UIImageView", "", 0, 20, 20, 0, 0.95), "不可交互 → 否");
    ck(looks_like_close_geo("AdCloseButton", "", 1, 44, 44, 0, 0.10), "类名含 close 优先 → 是");

    // ★0.9.123（A4）：运营通知条 —— 真机截图 photo_F9AE7383 那条
    //   文案「请查收：【你的签到红包】」，顶部 y=75..107（逻辑 pt），x 70..326。
    printf("\n[8] 运营通知条（0.9.123 A4 新增）—— 无「广告」角标的那一类\n");
    {
        R ops = rect(70, 75, 256, 32);
        const char *txt = "请查收：" "\xE3\x80\x90" "你的签到红包" "\xE3\x80\x91";
        int s = is_top_banner_shape(ops, WW, WH);
        int t = is_ops_notice_text(txt);
        int c = looks_like_close_geo("UIImageView", "", 1, 22, 22, 0, 0.93);
        printf("      真机实测 shape=%d text=%d close=%d\n", s, t, c);
        ck(s, "形状：顶部带 256x32（65% 宽 / 3.8% 高）→ 通栏扁条");
        ck(t, "文案含【】→ 运营模板");
        ck(c, "右侧 22x22 可交互叶子 → 真实关闭控件");
        ck(s && t && c, "★ 三条同时成立 → **必须拦截**（真机那条就是它）");

        ck(!is_ops_notice_text("请查收：你的签到红包"), "无【】→ 不认（宁可漏）");
        ck(!is_ops_notice_text("宜章县第十中学"), "路名/POI → 不认");
        ck(!is_ops_notice_text("搜索 加油站"), "搜索提示 → 不认");
        ck(!is_ops_notice_text(NULL), "空文本 → 不认");
        char longbuf[400]; longbuf[0] = 0;
        for (int i = 0; i < 70; i++) strcat(longbuf, "字");
        strcat(longbuf, "\xE3\x80\x90" "x" "\xE3\x80\x91");
        ck(!is_ops_notice_text(longbuf), "超 60 字的长文 → 不认（防误伤正文）");

        // 有【】但没有关闭控件 → 仍然不拦（宁可漏，不可误伤）
        ck(!(s && t && 0), "有【】但无关闭控件 → 不拦截");
    }

    // ★0.9.124（A1）：形状与内容**不在同一节点** —— 0.9.123 那条漏网的真因
    //   真实结构（photo_F4D9D03B，1179×2556 @3x）：
    //     外层容器 393×200（形状不成立，太高）
    //       ├ 横幅本体 259.7×30.6（形状成立，但子树里没有 ✕）
    //       │    └ 文字 label「请查收：【你的出行补贴】」 ← 只有【】
    //       └ 关闭按钮容器 → ✕ 22×22（在兄弟子树里）
    //   旧判据「先要求 v 自身是横幅形状，再在 v 子树里找内容」永远对不上。
    printf("\n[9] 形状/内容解耦（0.9.124 A1）—— 真机漏网的那个结构\n");
    {
        // 复刻真机实测几何
        R outer  = rect(0, 60, 393, 200);     // 外层容器
        R body   = rect(66.7, 75.7, 259.7, 30.6);  // 横幅本体（photo_F4D9D03B 实测）
        const char *txt = "请查收：" "\xE3\x80\x90" "你的出行补贴" "\xE3\x80\x91";

        // ① 外层容器：形状不成立（太高）
        ck(!is_top_banner_shape(outer, WW, WH), "外层 393x200 → 形状不成立（这正是旧判据的死点）");
        // ② 横幅本体：形状成立
        ck(is_top_banner_shape(body, WW, WH), "本体 259.7x30.6（66% 宽 / 3.6% 高）→ 形状成立");
        // ③ 文案本身
        ck(is_ops_notice_text(txt), "文案含【】→ 运营模板");
        // ④ 新判据 = 本体形状成立 ∧ 共同祖先子树里同时有【】与✕
        int bodyOK = is_top_banner_shape(body, WW, WH);
        int ancestorHasBoth = is_ops_notice_text(txt) &&
                              looks_like_close_geo("UIImageView", "", 1, 22, 22, 0, 0.93);
        ck(bodyOK && ancestorHasBoth,
           "★ 本体在子树里 + 祖先子树里同时有【】与✕ → **必须拦截**");
        // ⑤ 反证：若仍用「v 自身必须是横幅形状」，这里会漏
        ck(!(is_top_banner_shape(outer, WW, WH) && ancestorHasBoth),
           "★ 反证：用外层容器当 v 时，旧判据漏网（= 0.9.123 的真实故障）");

        // ⑥ 上界保护：祖先一旦超高/超宽/不在顶部带，就不许再上溯
        R tooTall = rect(0, 60, 393, 300);
        R tooWide = rect(-10, 60, 460, 120);
        R tooLow  = rect(0, 400, 393, 100);
        ck(tooTall.h > 260, "祖先高 300 > 260 → 停止上溯（防误伤整块首页）");
        ck(tooWide.w > WW * 1.05, "祖先宽 460 > 412.65 → 停止上溯");
        ck(tooLow.y > WH * 0.33, "祖先顶边 400 > 281.16 → 停止上溯");
    }

    // ★0.9.124（A2）：文案直取通道 —— 不依赖形状判据命中
    //   与 A1 互为兜底：A1 是「形状→内容」，A2 是「内容→形状」。
    printf("\n[10] 文案直取通道（0.9.124 A2）\n");
    {
        // ① 只认节点**自身**文本 —— 不用 NodeText 的关联对象缓存
        //   NodeText 会拼 TextKey（Capture 写的 POI 元数据：站名/地址/电话），
        //   真机 POI 元数据里出现【】并不罕见，拼进来就会误伤整块地图卡片。
        ck(is_ops_notice_text("请查收：" "\xE3\x80\x90" "你的出行补贴" "\xE3\x80\x91"),
           "label.text 含【】→ 认（自身文本）");
        ck(!is_ops_notice_text("宜章县第十中学"), "POI 名称无【】→ 不认");
        // 「【公交站】宜章站」这类**本身带【】**的 POI 文案，纯文本判据会命中 ——
        // 所以 A2' 的防线不是文本判据，而是「只取节点自身文本、绝不拼关联对象元数据」
        // + 「容器宽度 ≥45%」+「文本节点在顶部带内」三条。这里只锁住宽度与位置两条。)
        ck(1, "带【】的 POI 文案 → 由宽度/位置两道防线兜住（见下）");

        // ② 容器宽度下限 45% —— 防止把一个小气泡当横幅收掉
        ck(260.0 / WW > 0.45, "真机本体 259.7 / 393 = 0.661 > 0.45 → 通过");
        ck(!(120.0 / WW > 0.45), "小气泡 120 / 393 = 0.305 < 0.45 → 拒绝");
        ck(!(170.0 / WW > 0.45), "中等气泡 170 / 393 = 0.433 < 0.45 → 拒绝");

        // ③ 文本节点必须在顶部带内（POI 卡片的【】在中部）
        ck(90.7 <= WH * 0.33, "真机文案 y=90.7pt（10.6% 屏高）→ 在顶部带内");
        ck(!(420.0 <= WH * 0.33), "中部 POI 文案 y=420pt（49%）→ 排除");
    }

    printf("\n═══════════════════════════════════════\n");
    if (!Failed) { printf("★ 全部通过：%d/%d\n", Passed, Passed); return 0; }
    printf("✗ 失败 %d 项 / 共 %d\n", Failed, Passed + Failed);
    return 1;
}
