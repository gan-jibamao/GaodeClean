#!/usr/bin/env python3
"""校验 GaodeClean dylib 能被真机 dyld 接受。

2026-10-28 真机崩溃实证（AMapiPhone 17.02.2 / iOS 16.2）：
  termination.namespace = DYLD
  reasons = ["bad bind opcode 0x00"]
  usedImages 只有 /usr/lib/dyld（主程序未加载）
  procLaunch → captureTime 仅 88 ms

根因：本机 ld64.lld 生成的 chained fixups 用的是
  DYLD_CHAINED_PTR_64            (pointer_format = 2)
而 Apple ld64 生成的是
  DYLD_CHAINED_PTR_ARM64E        (pointer_format = 6)
同一台设备上，fmt=6 的历史包（Theos/Apple ld64 构建）能正常加载，
fmt=2 的 lld 产物一律在 dyld4::prepare 阶段中止。
所以门禁必须同时校验「是链式绑定」和「指针格式 = 6」，只查前者会漏。
"""
import struct
import sys

LC_CHAINED = 0x80000034
LC_DYLD_INFO = 0x80000022

PTR_FMT_OK = 6  # DYLD_CHAINED_PTR_ARM64E


def main(path):
    raw = open(path, 'rb').read()
    # fat 包：逐切片校验
    if struct.unpack_from('>I', raw, 0)[0] == 0xCAFEBABE:
        n = struct.unpack_from('>I', raw, 4)[0]
        rc = 0
        for i in range(n):
            cput, csub, off, size, _al = struct.unpack_from('>IIIII', raw, 8 + i * 20)
            print(f'--- slice {i}: cputype=0x{cput:x} cpusubtype={csub & 0xffffffff}')
            rc |= check(raw[off:off + size])
        return rc
    return check(raw)


def check(d):
    cpu, sub = struct.unpack('<ii', d[4:12])
    ncmds = struct.unpack('<I', d[16:20])[0]
    o, chained, classic, cho, chs = 32, False, False, 0, 0
    sdk = minos = None
    for _ in range(ncmds):
        c, s = struct.unpack('<II', d[o:o + 8])
        if c == LC_CHAINED:
            chained = True
            cho, chs = struct.unpack('<II', d[o + 8:o + 16])
        if c == LC_DYLD_INFO:
            classic = True
        if c in (0x32, 0x00320020):
            plat, minos, sdk, ntools = struct.unpack('<IIII', d[o + 8:o + 24])
        o += s

    name = {0: 'arm64', -2147483646: 'arm64e'}.get(sub, str(sub))
    print(f'  arch={name} cputype=0x{cpu:x} cpusubtype={sub}')
    if sdk is not None:
        print(f'  sdk={sdk >> 16}.{(sdk >> 8) & 0xff}.{sdk & 0xff}')

    fmt = None
    if chained and chs:
        blob = d[cho:cho + chs]
        starts_off = struct.unpack_from('<I', blob, 4)[0]
        seg_count = struct.unpack_from('<I', blob, starts_off)[0]
        q = starts_off + 4
        for _ in range(seg_count):
            soff = struct.unpack_from('<I', blob, q)[0]
            q += 4
            if not soff:
                continue
            _, _, f = struct.unpack_from('<IHH', blob, starts_off + soff)
            if fmt is None:
                fmt = f
            elif f != fmt:
                print(f'::error::同一 dylib 内 pointer_format 不一致: {fmt} vs {f}')
                return 1
    print(f'  CHAINED={chained} CLASSIC={classic} pointer_format={fmt}')

    # 架构 → 期望的 pointer_format（2026-10-28 用 0.3.1 可运行产物实测得出）
    #   arm64  : 6  = DYLD_CHAINED_PTR_ARM64E
    #   arm64e : 12 = DYLD_CHAINED_PTR_ARM64E_USERLAND24
    expect = {0: 6, 2: 12}.get(sub)
    if not chained:
        print('::error::不是链式绑定，dyld 会拒绝')
        return 1
    if expect is not None and fmt != expect:
        print(f'::error::cpu_subtype={sub} 需要 pointer_format={expect}，实际 {fmt}。'
              f'lld 出的是 2（DYLD_CHAINED_PTR_64），真机 dyld4::prepare 会报'
              f' "bad bind opcode 0x00" 直接中止 —— 必须用 Apple ld64 / Theos 构建')
        return 1
    if classic:
        print('::warning::同时存在经典绑定表')
    print(f'::notice::链式绑定 OK，pointer_format={fmt}')
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1]))
