#!/usr/bin/env python3
"""只读辅助：把 src/GaodeClean.m 里的 GCStrAt(n) 还原成明文，便于阅读/定位。
用法：python3 scripts/obf_read.py [起行 止行]"""
import re, sys
lines = [l.rstrip('\n') for l in open('scripts/obf_strings.txt', encoding='utf-8')]
src = open('src/GaodeClean.m', encoding='utf-8').read().split('\n')
a = int(sys.argv[1]) if len(sys.argv) > 1 else 1
b = int(sys.argv[2]) if len(sys.argv) > 2 else len(src)
for i in range(a-1, min(b, len(src))):
    out = re.sub(r'GCStrAt\((\d+)\)', lambda m: '"%s"' % lines[int(m.group(1))], src[i])
    print('%5d  %s' % (i+1, out))
