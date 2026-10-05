#!/usr/bin/env python3
"""
修 cpusubtype 并重算 ad-hoc 签名的页哈希。

为什么需要：clang 的 arm64e 后端是对的（.o 的 cpusubtype=2），但 lld 的
Mach-O 写出器会把输出头的 cpusubtype 写成 0（CPU_SUBTYPE_ARM64_ALL）。
dyld 用 `(cpusubtype & ~CPU_SUBTYPE_MASK) == CPU_SUBTYPE_ARM64E` 判断
"这是不是 arm64e 映像"，判断错了就会把链式修复里的认证指针按普通 arm64
处理 —— 第一次调用 __got 槽就崩。所以必须在签名之前把 subtype 摆正。

cpusubtype 在 header 偏移 8，落在第 0 页里，改完必须重算签名页哈希。
CodeDirectory 是 lld -adhoc_codesign 已经建好的，原地重写全部 code slot 即可。

用法： fixarch.py <macho> <subtype>        # arm64e → 2，arm64 → 0（不改）
"""
import hashlib
import struct
import sys

MH_MAGIC_64 = 0xFEEDFACF
CPU_TYPE_ARM64 = 0x0100000C
LC_CODE_SIGNATURE = 0x1D
CSMAGIC_EMBEDDED = 0xFADE0CC0
CSMAGIC_CODEDIRECTORY = 0xFADE0C02


def main(path, subtype):
    d = bytearray(open(path, 'rb').read())
    magic, cput, csub, ftype, ncmds = struct.unpack_from('<5I', d, 0)
    if magic != MH_MAGIC_64 or cput != CPU_TYPE_ARM64:
        print(f'{path}: 不是 arm64 Mach-O（magic={magic:#x} cputype={cput:#x}）')
        return 1

    off, cs = 32, None
    for _ in range(ncmds):
        cmd, size = struct.unpack_from('<2I', d, off)
        if cmd == LC_CODE_SIGNATURE:
            cs = struct.unpack_from('<2I', d, off + 8)
        off += size
    if not cs:
        print(f'{path}: 没有 LC_CODE_SIGNATURE，先用 -Wl,-adhoc_codesign 链接')
        return 1

    old = csub
    struct.pack_into('<I', d, 8, subtype)

    o, sz = cs
    magic2, length, count = struct.unpack_from('>III', d, o)
    if magic2 != CSMAGIC_EMBEDDED:
        print(f'{path}: SuperBlob 头不对 {magic2:#x}')
        return 1
    base = None
    for i in range(count):
        t, bo = struct.unpack_from('>II', d, o + 12 + i * 8)
        if struct.unpack_from('>I', d, o + bo)[0] == CSMAGIC_CODEDIRECTORY:
            base = o + bo
    if base is None:
        print(f'{path}: 没有 CodeDirectory')
        return 1

    ver, flags, hash_off, ident_off, n_special, n_code, code_limit = \
        struct.unpack_from('>IIIIIII', d, base + 8)
    hash_size, hash_type, platform, page_size = struct.unpack_from('>BBBB', d, base + 8 + 28)
    if hash_type != 2 or hash_size != 32:
        print(f'{path}: 只支持 SHA256 签名（hashType={hash_type}）')
        return 1
    psz = 1 << page_size

    for i in range(n_code):
        start = i * psz
        end = min(start + psz, code_limit)
        h = hashlib.sha256(bytes(d[start:end])).digest()
        d[base + hash_off + i * hash_size: base + hash_off + (i + 1) * hash_size] = h

    open(path, 'wb').write(d)
    print(f'{path}: cpusubtype {old:#010x} → {subtype:#010x}，'
          f'{n_code} 页哈希已重算，覆盖 {code_limit:#x}/{len(d):#x}')
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1], int(sys.argv[2], 0)))