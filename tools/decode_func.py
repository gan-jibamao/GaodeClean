#!/usr/bin/env python3
"""decode_func.py —— iOS 主二进制「函数内 objc 调用解码器」

用途：给定一个 Mach-O（通常是高德这类被砸壳的主二进制）和一个函数地址，
把函数体内所有 bl 到 __objc_stubs 的桩调用解码成【真实 selector 名】，
从而快速看懂一个 ObjC 方法干了什么（不需要完整反编译）。

原理：
  __objc_stubs 区里每个桩形如：
      adrp x1, #selref_page ; ldr x1, [x1, #off] ; b _objc_msgSend
  桩的 selref 槽指向 __objc_selrefs 表，表中条目经 chained fixup 编码指向
  __objc_methname 里的 selector 字符串。本脚本逐条解码。

用法：
  python3 decode_func.py <macho> <func_vaddr_hex> [end_vaddr_hex]
  例：python3 decode_func.py AMapiPhone 0x106650d14 0x1066515e8

依赖：pip install capstone
"""
import struct
import sys

from capstone import Cs, CS_ARCH_ARM64, CS_MODE_ARM

TEXT_VADDR = 0x100000000  # 大多数 iOS 主二进制；dylib 也是 0x100000000 起


def parse_sections(path):
    secs = {}
    with open(path, 'rb') as f:
        hdr = f.read(0x10000)
    ncmds, = struct.unpack_from('<I', hdr, 16)
    off = 32
    for _ in range(ncmds):
        cmd, cmdsize = struct.unpack_from('<II', hdr, off)
        if cmd == 0x19:  # LC_SEGMENT_64
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
    func_va = int(sys.argv[2], 16)
    end_va = int(sys.argv[3], 16) if len(sys.argv) > 3 else func_va + 0x1000

    secs = parse_sections(path)

    def load(key):
        va, sz, o = secs[key]
        with open(path, 'rb') as f:
            f.seek(o)
            return f.read(sz), va

    selrefs, selrefs_va = load('__DATA.__objc_selrefs')
    methname, methname_va = load('__TEXT.__objc_methname')
    stubs, stubs_va = load('__TEXT.__objc_stubs')
    cstring, cstring_va = load('__TEXT.__cstring')

    def rc(buf, base, va):
        r = va - base
        if r < 0 or r >= len(buf):
            return None
        e = buf.find(b'\x00', r)
        return buf[r:e].decode('utf-8', 'replace')

    def resolve(va):
        for b, base in ((methname, methname_va), (cstring, cstring_va)):
            s = rc(b, base, va)
            if s is not None:
                return s
        return None

    # 建桩->selector 映射（逐一解码 __objc_stubs）
    stub_of = {}
    for i in range(len(stubs) // 12):
        b = stubs[i * 12:i * 12 + 12]
        if len(b) < 12:
            break
        w0, w1, w2 = struct.unpack('<III', b)
        if (w0 & 0x9F000000) != 0x90000000:
            continue
        immlo = (w0 >> 29) & 3
        immhi = (w0 >> 5) & 0x7FFFF
        imm = (immhi << 2) | immlo
        if imm & (1 << 20):
            imm -= 1 << 21
        sa = stubs_va + i * 12
        page = (sa & ~0xFFF) + (imm << 12)
        if (w1 & 0xFFC00000) != 0xF9400000:
            continue
        off12 = (w1 >> 10) & 0xFFF
        scale = (w1 >> 30) & 3
        sra = page + (off12 << scale)
        r = sra - selrefs_va
        if r < 0 or r + 8 > len(selrefs):
            continue
        ptr, = struct.unpack_from('<Q', selrefs, r)
        if (ptr >> 63) & 1:
            continue  # bind 类型无法直接解析
        tva = ptr & ((1 << 51) - 1)
        nm = resolve(tva)
        if nm:
            stub_of[sa] = nm

    print(f"__objc_stubs 解析出 {len(stub_of)} 个 selector 桩", file=sys.stderr)

    with open(path, 'rb') as f:
        f.seek(func_va - TEXT_VADDR)
        data = f.read(end_va - func_va)
    md = Cs(CS_ARCH_ARM64, CS_MODE_ARM)
    md.detail = True
    print(f"===== 函数 0x{func_va:x} 的调用解码 =====")
    for insn in md.disasm(data, func_va):
        if insn.mnemonic == 'bl':
            tgt = insn.operands[0].imm if insn.operands else None
            if tgt in stub_of:
                print(f"  0x{insn.address:x}: bl -> [{stub_of[tgt]}]")
            elif tgt is None:
                pass
        if insn.mnemonic == 'ret':
            print(f"  0x{insn.address:x}: ret")
            break


if __name__ == '__main__':
    main()
