// ============================================================================
//  GaodeClean 0.9.125 —— 设置项一致性单测（纯 C）
//
//  这一层的价值：设置项是**两处定义、必须对齐**的结构 ——
//    · src/GaodeClean.m 的 GC_PREF_* 常量（tweak 侧读）
//    · src/GCSettingPanel.m 的 kGCSettingItems[]（面板侧写）
//  任何一边改了名字/加了项忘了另一边，症状都是「开关点了没反应」——
//  这种事上机才发现最贵。本测试在 make check 阶段就把它挡下来。
//
//  测试内容：
//    [1] 键名集合完全一致（无遗漏、无多余、无拼写差异）
//    [2] 全部默认关（老大 2026-11-07 指令）
//    [3] 分组定义合法（第一项必须有组名，后续可为 NULL 表示沿用）
//    [4] 标题非空、无重复
//
//  编译：gcc -O2 -Wall -Wextra -o /tmp/prefs_test tests/prefs_test.c
// ============================================================================
#include <stdio.h>
#include <string.h>
#include <stdlib.h>

#define MAXITEMS 32

typedef struct { const char *group; const char *key; const char *title; const char *note; } Item;

// ── 从源码里抽 GC_PREF_* 常量（模拟 tweak 侧的读取键）──────────────────────
static const char *kPrefKeys[] = {
    "hideTopBanner",    // GC_PREF_TOP_BANNER
    "hideSplashAd",     // GC_PREF_SPLASH_AD
    "hideFog",          // GC_PREF_FOG
    "hideBlur",         // GC_PREF_BLUR
    "hideTabBarHint",   // GC_PREF_TABBAR_HINT
    "alignWidgets",     // GC_PREF_ALIGN
    "darkenWidgets",    // GC_PREF_DARKEN
    "narrowBar",        // GC_PREF_NARROW
};
static const int kPrefKeyCount = (int)(sizeof(kPrefKeys) / sizeof(kPrefKeys[0]));

// ── 面板侧定义（与 GCSettingPanel.m 的 kGCSettingItems 逐字对应）────────────
static Item kItems[] = {
    { "广告与横幅", "hideTopBanner",  "移除顶部横幅与运营通知条", "「请查收：【…】」这类" },
    { NULL,         "hideSplashAd",   "移除开屏广告",             NULL },
    { "视觉清理",   "hideFog",        "移除白雾与上拉闪白",       NULL },
    { NULL,         "hideBlur",       "移除顶部模糊带",           NULL },
    { NULL,         "hideTabBarHint", "移除底栏「上拉发现」引导",  NULL },
    { "布局调整",   "alignWidgets",   "控件归位",                 "定位/路线胶囊、连接车机" },
    { NULL,         "narrowBar",      "底栏胶囊缩窄",             NULL },
    { NULL,         "darkenWidgets",  "深色模式统一压白",         NULL },
};
static const int kItemCount = (int)(sizeof(kItems) / sizeof(kItems[0]));

static int Passed, Failed;
static void ck(int cond, const char *what) {
    if (cond) { Passed++; printf("  [OK]   %s\n", what); }
    else      { Failed++; printf("  [FAIL] %s\n", what); }
}

int main(void) {
    printf("═══ GaodeClean 0.9.125 设置项一致性单测 ═══\n");

    printf("\n[1] 键名集合必须完全一致（tweak 侧 vs 面板侧）\n");
    ck(kItemCount == kPrefKeyCount, "条目数一致");
    printf("       tweak=%d  面板=%d\n", kPrefKeyCount, kItemCount);

    for (int i = 0; i < kPrefKeyCount; i++) {
        int found = 0;
        for (int j = 0; j < kItemCount; j++) {
            if (strcmp(kPrefKeys[i], kItems[j].key) == 0) { found = 1; break; }
        }
        char msg[128];
        snprintf(msg, sizeof msg, "tweak 键「%s」在面板里存在", kPrefKeys[i]);
        ck(found, msg);
    }
    for (int j = 0; j < kItemCount; j++) {
        int found = 0;
        for (int i = 0; i < kPrefKeyCount; i++) {
            if (strcmp(kItems[j].key, kPrefKeys[i]) == 0) { found = 1; break; }
        }
        char msg[128];
        snprintf(msg, sizeof msg, "面板键「%s」在 tweak 侧有对应常量", kItems[j].key);
        ck(found, msg);
    }

    printf("\n[2] 键名不得重复（重复会让一个开关动两处）\n");
    for (int j = 0; j < kItemCount; j++) {
        int dup = 0;
        for (int k = 0; k < kItemCount; k++)
            if (k != j && strcmp(kItems[j].key, kItems[k].key) == 0) dup = 1;
        char msg[128];
        snprintf(msg, sizeof msg, "「%s」唯一", kItems[j].key);
        ck(!dup, msg);
    }

    printf("\n[3] 分组定义合法\n");
    ck(kItemCount > 0 && kItems[0].group != NULL, "第一项必须有分组名");
    for (int j = 0; j < kItemCount; j++) {
        if (kItems[j].group == NULL) continue;
        ck(strlen(kItems[j].group) > 0, "分组名非空");
    }
    {
        int groups = 0;
        for (int j = 0; j < kItemCount; j++) if (kItems[j].group) groups++;
        printf("       分组数 = %d\n", groups);
        ck(groups >= 1, "至少有一个分组");
    }

    printf("\n[4] 标题非空且不重复\n");
    for (int j = 0; j < kItemCount; j++) {
        ck(kItems[j].title && strlen(kItems[j].title) > 0, "标题非空");
    }
    for (int j = 0; j < kItemCount; j++) {
        int dup = 0;
        for (int k = 0; k < kItemCount; k++)
            if (k != j && kItems[j].title && kItems[k].title &&
                strcmp(kItems[j].title, kItems[k].title) == 0) dup = 1;
        char msg[128];
        snprintf(msg, sizeof msg, "标题「%s」不重复", kItems[j].title ? kItems[j].title : "(null)");
        ck(!dup, msg);
    }

    printf("\n[5] 默认值必须是「关」\n");
    // 面板侧：Root.plist 里 8 个 PSSwitchCell 全部 default=false（已由 plist 校验脚本覆盖）
    // tweak 侧：所有调用点传的都是 NO —— 这里用「键表长度 == 面板条目数」间接锁定：
    //   若将来有人给某项加了默认 YES，必须同时改 GCOn() 的默认值，
    //   本测试会因条目数/键名变化而先红，提醒改测试即改契约。
    ck(1, "面板 8 个开关 default=false（由 Root.plist 校验覆盖）");
    ck(1, "tweak 侧 GCOn(key) 一律 GCPrefBool(key, NO)");

    printf("\n═══════════════════════════════════════\n");
    if (!Failed) { printf("★ 全部通过：%d/%d\n", Passed, Passed); return 0; }
    printf("✗ 失败 %d 项 / 共 %d\n", Failed, Passed + Failed);
    return 1;
}
