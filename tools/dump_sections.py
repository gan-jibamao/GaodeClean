#!/usr/bin/env python3
"""dump_sections.py —— Mach-O ObjC 元数据导出器

用途（每次高德升级后的必跑体检）：
  1. 导出 __objc_classname / __objc_methname / __cstring 到 txt 文件
  2. 用 rg 与旧版 diff，即可快速判定「某个类/selector/字符串在新版是否还存在」
  3. 直接给定一批待查名称，输出每个的命中数

用法：
  python3 dump_sections.py <macho> <outdir>
  python3 dump_sections.py <macho> <outdir> --check WINTabBar,layoutSubviews,...

产出：
  <outdir>/cls.txt     —— 全部类名
  <outdir>/sel.txt     —— 全部 selector
  <outdir>/cstring.txt —— 全部 C 字符串

依赖：pip install lief（或纯手工解析；本脚本用 lief）
"""
import os
import sys

import lief


def extract(sec):
    data = bytes(sec.content)
    return [x.decode('utf-8', 'replace') for x in data.split(b'\x00') if x]


def main():
    if len(sys.argv) < 3:
        print(__doc__)
        sys.exit(1)
    path, outdir = sys.argv[1], sys.argv[2]
    os.makedirs(outdir, exist_ok=True)

    b = lief.MachO.parse(path).at(0)
    got = {}
    for seg in b.segments:
        for s in seg.sections:
            key = f"{seg.name}.{s.name}"
            if s.name in ('__objc_classname', '__objc_methname', '__cstring'):
                got[s.name] = s
                print(f"{key}: off=0x{s.offset:x} size=0x{s.size:x}")

    names = {
        '__objc_classname': 'cls.txt',
        '__objc_methname': 'sel.txt',
        '__cstring': 'cstring.txt',
    }
    for secname, fname in names.items():
        if secname not in got:
            print(f"! 缺少 {secname}")
            continue
        items = extract(got[secname])
        fp = os.path.join(outdir, fname)
        with open(fp, 'w', encoding='utf-8') as f:
            f.write('\n'.join(items))
        print(f"-> {fp} ({len(items)} 条)")

    # --check 模式：批量验证待查名称
    if '--check' in sys.argv:
        idx = sys.argv.index('--check')
        names_to_check = sys.argv[idx + 1].split(',')
        alltext = {}
        for secname in names:
            if secname in got:
                alltext[secname] = set(extract(got[secname]))
        print("\n===== 待查名称 =====")
        for n in names_to_check:
            loc = [k for k, v in alltext.items() if n in v]
            print(f"  {'✓' if loc else '✗'} {n}  {loc}")


if __name__ == '__main__':
    main()
