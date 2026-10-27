#!/usr/bin/env python3
"""校验 GaodeClean dylib：必须是链式绑定（arm64/arm64e 都能被 dyld 接受）。"""
import struct
import sys


def main(path):
    d = open(path, 'rb').read()
    cpu, sub = struct.unpack('<ii', d[4:12])
    ncmds = struct.unpack('<I', d[16:20])[0]
    o, chained, classic = 32, False, False
    sdk = minos = None
    for _ in range(ncmds):
        c, s = struct.unpack('<II', d[o:o + 8])
        if c == 0x80000034:
            chained = True
        if c == 0x80000022:
            classic = True
        if c == 0x00320020 or c == 0x32:
            plat, minos, sdk, ntools = struct.unpack('<IIII', d[o + 8:o + 24])
        o += s

    name = {0: 'arm64', -2147483646: 'arm64e'}.get(sub, str(sub))
    print(f'  arch={name} cputype=0x{cpu:x} cpusubtype={sub}')
    if sdk is not None:
        print(f'  sdk={sdk >> 16}.{(sdk >> 8) & 0xff}.{sdk & 0xff}'
              f' minos={minos >> 16}.{(minos >> 8) & 0xff}.{minos & 0xff}')
    print(f'  CHAINED={chained} CLASSIC={classic}')

    if not chained:
        print('::error::不是链式绑定，arm64e 设备会被 dyld 拒绝')
        return 1
    if classic:
        print('::warning::同时存在经典绑定表')
    print('::notice::链式绑定 OK')
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1]))
