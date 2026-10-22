#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""GaodeClean 0.9.21（A2）—— 字符串面混淆生成器

把 src/GaodeClean.m 里的 Objective-C 字符串字面量 @"..."
改成 运行时解密 的 GCStrAt(<idx>)，
并生成 src/GCStrData.h（加密字节 + 索引表）。

跳过规则：
  · 行首为 static 的声明（编译期常量初始化，不能换成函数调用）
  · 空字面量 @""

用法：python3 scripts/gen_obf.py [--check]
"""
import re
import sys
import os

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC = os.path.join(ROOT, 'src', 'GaodeClean.m')
DATA = os.path.join(ROOT, 'src', 'GCStrData.h')
MAXLEN = 96
LIST = 'scripts/obf_strings.txt'

LIT = re.compile(r'@"((?:[^"\\]|\\.)*)"')
UNESC = {'n': '\n', 't': '\t', 'r': '\r', '"': '"', '\\': '\\', '0': '\0'}
def unescape(s):
    out = []
    i = 0
    while i < len(s):
        c = s[i]
        if c != '\\':
            out.append(c)
            i += 1
            continue
        n = s[i + 1]
        if n in UNESC:
            out.append(UNESC[n])
        else:
            raise SystemExit('未支持的转义: \\%s' % n)
        i += 2
    return ''.join(out)


def rotl(v, n):
    n &= 7
    return ((v << n) | (v >> ((8 - n) & 7))) & 0xFF


def encode(bs, key, base):
    out = []
    for i, b in enumerate(bs):
        t = (b ^ key) & 0xFF
        u = (t + (17 * (base + i) + 3)) & 0xFF
        out.append(rotl(u, (base + i) % 8))
    return out
def fnv1a64(items):
    """与 src/GCObfMath.h 中 GCObfDigest() 完全一致的校验摘要。"""
    h = 1469598103934665603
    M = (1 << 64) - 1
    for s in items:
        for b in s.encode('utf-8'):
            h = ((h ^ b) * 1099511628211) & M
        h = ((h ^ 0x1F) * 1099511628211) & M
    return h


def emit_header(order, path):
    blob, table = [], []
    for i, content in enumerate(order):
        bs = content.encode('utf-8')
        if len(bs) > MAXLEN:
            raise SystemExit('字面量超长: %r' % content)
        key = (0xA7 + i * 31) & 0xFF
        if key == 0:
            key = 0x5D
        table.append((len(blob), len(bs), key, i))
        blob.extend(encode(bs, key, i))
    with open(path, 'w', encoding='utf-8') as f:
        f.write('// 自动生成于 scripts/gen_obf.py —— 请勿手改\n')
        f.write('#ifndef GCSTRDATA_H\n#define GCSTRDATA_H\n\n')
        f.write('#define GC_OBF_COUNT %d\n' % len(order))
        f.write('#define GC_OBF_MAXLEN %d\n' % MAXLEN)
        f.write('#define GC_OBF_FNV 0x%016Xull\n\n' % fnv1a64(order))
        f.write('typedef struct { unsigned int off; unsigned int len; unsigned int idx; unsigned char key; } gcObfEnt;\n\n')
        f.write('static const unsigned char gcObfBytes[%d] = {\n' % len(blob))
        for i in range(0, len(blob), 16):
            f.write('    ' + ','.join('0x%02X' % b for b in blob[i:i + 16]) + ',\n')
        f.write('};\n\n')
        f.write('static const gcObfEnt gcObfTab[%d] = {\n' % len(table))
        for off, ln, key, idx in table:
            f.write('    {%d,%d,%d,0x%02X},\n' % (off, ln, idx, key))
        f.write('};\n\n#endif\n')
    return blob, table


def main():
    check = '--check' in sys.argv
    from_list = '--from-list' in sys.argv
    if from_list:
        order = [l for l in open(LIST, encoding='utf-8').read().split('\n') if l]
        blob, table = emit_header(order, DATA)
        print('从清单复现：%d 条 / 字节表 %d / 数据头 %d 字节' % (len(order), len(blob), os.path.getsize(DATA)))
        return
    src = open(SRC, encoding='utf-8').read()

    # 行号索引
    line_of = []
    n = 0
    for ch in src:
        line_of.append(n)
        if ch == '\n':
            n += 1
    starts = [0]
    for i, ch in enumerate(src):
        if ch == '\n':
            starts.append(i + 1)

    def line_no(pos):
        lo, hi = 0, len(starts) - 1
        while lo < hi:
            mid = (lo + hi + 1) // 2
            if starts[mid] <= pos:
                lo = mid
            else:
                hi = mid - 1
        return lo

    def line_text(pos):
        ln = line_no(pos)
        end = starts[ln + 1] - 1 if ln + 1 < len(starts) else len(src)
        return src[starts[ln]:end]

    order = []          # 唯一字面量顺序
    idx_of = {}
    spans = []          # (start, end, content)
    for m in LIT.finditer(src):
        content = unescape(m.group(1))
        if content == '':
            continue
        if line_text(m.start()).lstrip().startswith('static'):
            continue
        spans.append((m.start(), m.end(), content))
        if content not in idx_of:
            idx_of[content] = len(order)
            order.append(content)

    blob = []
    table = []
    for i, content in enumerate(order):
        bs = content.encode('utf-8')
        if len(bs) > MAXLEN:
            raise SystemExit('字面量超长: %r' % content)
        key = (0xA7 + i * 31) & 0xFF
        if key == 0:
            key = 0x5D
        table.append((len(blob), len(bs), key, i))
        blob.extend(encode(bs, key, i))

    print('唯一字面量 %d / 替换点 %d / 字节表 %d' % (len(order), len(spans), len(blob)))

    if check:
        return

    # 生成数据头（含明文校验摘要）
    emit_header(order, DATA)

    # 回写源码：从后往前替换，避免位移
    out = src
    for s, e, content in reversed(spans):
        out = out[:s] + ('GCStrAt(%d)' % idx_of[content]) + out[e:]
    if '#include "GCStr.h"' not in out:
        anchor = '#import <objc/runtime.h>'
        if anchor in out:
            out = out.replace(anchor, anchor + '\n#include "GCStr.h"', 1)
        else:
            raise SystemExit('找不到插入锚点 objc/runtime.h')
    open(SRC, 'w', encoding='utf-8').write(out)
    print('源码已回写；数据头 %d 字节' % os.path.getsize(DATA))


main()