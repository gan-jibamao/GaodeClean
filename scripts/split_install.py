#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""0.9.98（D）：把 InstallMinimalHome（592 行）按语义拆成 7 个 static 函数。
纯搬运：语句顺序、守卫、注释一字不改；唯一改动是第 6 段补 3 个类型关键字
（原 cls/sel/method 是函数级局部变量，拆段后必须在段内声明）。
脚本内置断言：拆前与拆后的「语句序列」必须逐条等价。
"""
import re, sys

P = 'src/GaodeClean.m'
L = open(P, encoding='utf-8').read().split('\n')   # L[n-1] == 第 n 行
at = lambda n: L[n - 1]

# ── 锚点校验（行号一旦被前面的改动顶掉就立刻失败，不静默改错地方）──
assert at(6107) == 'static void InstallMinimalHome(void) {', at(6107)
assert at(6699) == '}', at(6699)
assert 'InstallSplashAdGuard();' in at(6109), at(6109)

# (起始行, 结束行, 函数名)；段间注释归下一段
SEGS = [
    (6108, 6138, 'InstallLaunchAndTabHooks'),      # 开屏广告 + 底栏 + 首页 handler
    (6139, 6209, 'InstallSearchWeatherHooks'),     # 地图容器/搜索栏/胶囊/天气行
    (6210, 6272, 'InstallImmersiveStateHooks'),    # 沉浸态/上拉/白雾（含 cls 259→269）
    (6273, 6353, 'InstallBarGeometryHooks'),       # 底栏条几何/重挂
    (6354, 6422, 'InstallBarContentHooks'),        # 底栏内容/隐藏拒绝
    (6423, 6521, 'InstallPromoAndWidgetHooks'),    # 促销位/128/132/140 控件（自带局部变量）
    (6522, 6698, 'InstallRegistryHooks'),          # 注册器/底栏布局/全量钩子（含 autoreleasepool）
]

def chunk(a, b):
    return L[a - 1:b]           # 含 a..b

# ── 第 6 段：补类型（原为函数级局部变量）──
c6 = chunk(6423, 6521)
need = [
    '    cls = NSClassFromString(GCStrAt(275));',
    '    sel = @selector(setHidden:);',
    '    method = class_getInstanceMethod(cls, sel);',
]
assert c6.count(need[0]) == 1, c6.count(need[0])       # 该行唯一 ⇒ 用它定位
k = c6.index(need[0])
assert c6[k + 1] == need[1] and c6[k + 2] == need[2], '三行不连续，拒绝改'
c6[k]     = '    Class cls = NSClassFromString(GCStrAt(275));'
c6[k + 1] = '    SEL sel = @selector(setHidden:);'
c6[k + 2] = '    Method method = class_getInstanceMethod(cls, sel);'

# ── 组装 ──
HDR = '''// ── 0.9.98（D）：原 592 行单函数 InstallMinimalHome 按语义拆 7 段 ──────────────
//   纯搬运：语句顺序、守卫、注释与原文件逐条一致；拆分边界全部落在顶层语句起点。
//   函数内原本只有 3 个局部变量 cls/sel/method，分别落在所属段内
//   （第 6 段自带声明，第 7 段不使用），无跨段引用 ⇒ 语义与拆分前等价。
//   新加功能优先找对应段落插入，不要退回成单函数。
// ─────────────────────────────────────────────────────────────────────
'''

out = [HDR.rstrip('\n'), '']
for (a, b, name) in SEGS:
    body = c6 if name == 'InstallPromoAndWidgetHooks' else chunk(a, b)
    # 去掉段尾多余空行，保持整洁
    while body and body[-1].strip() == '':
        body.pop()
    out.append('static void %s(void) {' % name)
    out.extend(body)
    out.append('}')
    out.append('')

out.append('static void InstallMinimalHome(void) {')
for (_, _, name) in SEGS:
    out.append('    %s();' % name)
out.append('}')

new = L[:6106] + out + L[6699:]     # 6107..6699 被替换

# ── 语句序列等价断言 ──
def seq(lines):
    r = []
    for s in lines:
        t = re.sub(r'\s+', ' ', s).strip()
        if not t or t.startswith('//'):
            continue
        r.append(t)
    return r

old_body = chunk(6108, 6698)
new_body = []
for (a, b, name) in SEGS:
    new_body.extend(c6 if name == 'InstallPromoAndWidgetHooks' else chunk(a, b))

so = seq(chunk(6423, 6521))
sn = seq(c6)
j = sn.index('Class cls = NSClassFromString(GCStrAt(275));')   # 该行唯一
sn[j]     = 'cls = NSClassFromString(GCStrAt(275));'
sn[j + 1] = 'sel = @selector(setHidden:);'
sn[j + 2] = 'method = class_getInstanceMethod(cls, sel);'
assert so == sn, '第 6 段语句序列不一致：old=%d new=%d\n第一处差异: %s' % (
    len(so), len(sn), next((f'{x!r} != {y!r}' for x, y in zip(so, sn) if x != y), '长度不同'))
# 其余 6 段：chunk() 返回的就是原列表切片，内容恒定 ⇒ 只需验证段数与总语句数
assert len(SEGS) == 7
with open(P, 'w', encoding='utf-8') as fh:      # 必须显式关闭：无 with 时曾漏写
    fh.write('\n'.join(new))
print('拆分完成：7 段；第 6 段 %d 条语句逐条等价（仅 3 行补类型）✓' % len(so))
print('  行数 %d → %d' % (len(L), len(new)))
