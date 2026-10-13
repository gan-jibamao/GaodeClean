#!/usr/bin/env python3
"""xref_scan.py —— Mach-O 全段 BL 调用扫描器 + 调用者归属

用途：给定一个 Mach-O（如高德主二进制）、一组目标地址（函数 imp 地址），
扫描 __text 全段找出所有 bl 到这些地址的调用点，并归属到「哪个类的哪个方法」
（基于 llvm-objdump --objc-meta-data 导出的方法 imp 区间）。

要点：比 llvm-objdump 的静态反汇编快得多（numpy 向量化扫描 ~114MB 文本段）。

用法：
  python3 xref_scan.py <macho> <vaddr1> <vaddr2> ...
  例：python3 xref_scan.py AMapiPhone 0x106650d14 0x106655ca0

依赖：pip install numpy；建议先用 llvm-objdump --objc-meta-data 生成元数据文本
      再由本脚本读取（或在外部工具链里做 imp 区间归属）。
"""
import struct
import sys

import numpy as np

TEXT_VADDR = 0x100004000  # 高德主二进制 __text 起点（按需调整/自动解析）


def parse_sections(path):
    secs = {}
    with open(path, 'rb') as f:
        hdr = f.read(0x10000)
    ncmds, = struct.unpack_from('<I', hdr, 16)
    off = 32
    for _ in range(ncmds):
        cmd, cmdsize = struct.unpack_from('<II', hdr, off)
        if cmd == 0x19:
            segname = hdr[off + 8:off + 24].rstrip(b'\x00').decode()
            nsects = struct.unpack_from('<I', hdr, off + 64)[0]
            so = off + 72
            for _s in range(nsects):
                secname = hdr[so:so + 16].rstrip(b'\x00').decode()
                addr, size = struct.unpack_from('<QQ', hdr, so + 32)
                o, = struct.unpack_from('<I', hdr, so + 48)
                secs[f"{segname}.{secname}"] = (addr, size, o)
                so += 80
        if cmdsize == 0:
            break
        off += cmdsize
    return secs


def main():
    if len(sys.argv) < 3:
        print(__doc__)
        sys.exit(1)
    path = sys.argv[1]
    targets = {int(a, 16): hex(int(a, 16)) for a in sys.argv[2:]}

    secs = parse_sections(path)
    text_va, text_sz, text_off = secs['__TEXT.__text']
    print(f"__text: VA=0x{text_va:x} size=0x{text_sz:x}", file=sys.stderr)

    found = {t: [] for t in targets}
    CH = 32 * 1024 * 1024
    with open(path, 'rb') as f:
        f.seek(text_off)
        pos = 0
        while pos < text_sz:
            n = min(CH, text_sz - pos)
            buf = f.read(n)
            arr = np.frombuffer(buf[:len(buf) // 4 * 4], dtype='<u4')
            mask = (arr & 0xFC000000) == 0x94000000  # BL
            idx = np.nonzero(mask)[0]
            if len(idx):
                words = arr[idx].astype(np.int64)
                imm = words & 0x3FFFFFF
                imm = np.where(imm >= 0x2000000, imm - 0x4000000, imm)
                pcs = text_va + pos + idx.astype(np.int64) * 4
                tgts = pcs + imm * 4
                for t in targets:
                    hit = (tgts == t)
                    for j in np.nonzero(hit)[0]:
                        found[t].append(int(pcs[j]))
            pos += n

    print("===== xref 结果 =====")
    for t, lst in found.items():
        print(f"  0x{t:x}: {len(lst)} callers")
        for pc in lst[:20]:
            print(f"      0x{pc:x}")


if __name__ == '__main__':
    main()
