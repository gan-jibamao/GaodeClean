#!/usr/bin/env python3
"""
GaodeClean 打包 —— 两种架构分别对应：
  rootless / Dopamine  → arm64  切片 + Architecture: iphoneos-arm64
  RootHide             → arm64e 切片 + Architecture: iphoneos-arm64e

arm64e 的由来（重要）：
  clang 的 arm64e 后端是对的（.o 里 cpusubtype=2），但 **lld 的 Mach-O 写出器会把
  输出的 cpusubtype 写成 0**。dyld 用 (cpusubtype & ~CPU_SUBTYPE_MASK) == CPU_SUBTYPE_ARM64E
  判断「这是不是 arm64e 映像」，判错就会把链式修复里的认证指针按普通 arm64 处理。
  另外 lld 不支持 arm64e 的 -fixup_chains（只支持 x86_64 与 arm64），所以 arm64e 走
  经典 LC_DYLD_INFO_ONLY 绑定。两者都由 scripts/fixarch.py 收尾：改 subtype + 重算签名页哈希。

0.9.8（A15）：去掉全部硬编码。
  · VERSION 从 control 的 Version 字段读（单一真源）
  · 输入 / 输出路径全部走命令行参数（默认 dist/）
  · Installed-Size 按真实载荷（plist + dylib）向上取整到 KB，不再写死 160

用法：
  python3 scripts/mkdeb.py \
      --dist dist --control control --plist GaodeClean.plist \
      --dylib-arm64 dist/GaodeClean-arm64.dylib \
      --dylib-arm64e dist/GaodeClean-arm64e.dylib
"""
import argparse
import io
import os
import re
import tarfile

MTIME = 1760976000
LIBSUB = 'Library/MobileSubstrate/DynamicLibraries'


def tar_bytes(entries):
    buf = io.BytesIO()
    with tarfile.open(fileobj=buf, mode='w:gz', format=tarfile.GNU_FORMAT) as t:
        for src, arc, mode in entries:
            ti = tarfile.TarInfo(arc)
            ti.size = os.path.getsize(src)
            ti.mode = mode
            ti.uid = ti.gid = 0
            ti.uname = ti.gname = 'root'
            ti.mtime = MTIME
            with open(src, 'rb') as fh:
                t.addfile(ti, fh)
    return buf.getvalue()


def ar_member(name, data, out):
    hdr = (name + '/').ljust(16) + str(MTIME).ljust(12) + '0'.ljust(6) + '0'.ljust(6) \
        + '100644'.ljust(8) + str(len(data)).ljust(10) + '`\n'
    out.write(hdr.encode())
    out.write(data)
    if len(data) % 2:
        out.write(b'\n')


def read_version(control_path):
    with open(control_path, encoding='utf-8') as fh:
        for line in fh:
            if line.startswith('Version:'):
                return line.split(':', 1)[1].strip()
    raise SystemExit('control 缺少 Version 字段：' + control_path)


def control_text(control_path, arch, roothide, installed_kb):
    # dpkg 严格要求控制文件以换行结尾（rstrip 后必须补回，
    # 否则 Sileo / dpkg-deb 报 "end of file during value of field"）。
    txt = open(control_path, encoding='utf-8').read().rstrip('\n') + '\n'
    txt = txt.replace('Architecture: iphoneos-arm64', 'Architecture: ' + arch)
    txt = re.sub(r'(?m)^Installed-Size:.*$', 'Installed-Size: %d' % installed_kb, txt)
    if roothide:
        txt = txt.replace('mobilesubstrate', 'mobilesubstrate, oldabi')
    return txt.encode('utf-8')


def build(dylib, arch, roothide, version, plist, control, out_dir):
    prefix = '' if roothide else 'var/jb/'
    suffix = '-roothide' if roothide else ''
    name = 'com.jibamao.gaodeclean_%s_%s%s.deb' % (version, arch, suffix)
    path = os.path.join(out_dir, name)

    data_entries = [
        (plist, './' + prefix + LIBSUB + '/GaodeClean.plist', 0o644),
        (dylib, './' + prefix + LIBSUB + '/GaodeClean.dylib', 0o755),
    ]
    payload = os.path.getsize(plist) + os.path.getsize(dylib)
    installed_kb = (payload + 1023) // 1024

    cb = control_text(control, arch, roothide, installed_kb)
    ctrl_buf = io.BytesIO()
    with tarfile.open(fileobj=ctrl_buf, mode='w:gz', format=tarfile.GNU_FORMAT) as t:
        ti = tarfile.TarInfo('./control')
        ti.size = len(cb)
        ti.mode = 0o644
        ti.uid = ti.gid = 0
        ti.uname = ti.gname = 'root'
        ti.mtime = MTIME
        t.addfile(ti, io.BytesIO(cb))

    with open(path, 'wb') as out:
        out.write(b'!<arch>\n')
        ar_member('debian-binary', b'2.0\n', out)
        ar_member('control.tar.gz', ctrl_buf.getvalue(), out)
        ar_member('data.tar.gz', tar_bytes(data_entries), out)
    print('[deb] %s  %d B  (%s%s, Installed-Size=%d KB)'
          % (name, os.path.getsize(path), arch,
             ' / RootHide' if roothide else ' / rootless', installed_kb))
    return path


def main():
    ap = argparse.ArgumentParser(description='GaodeClean deb 打包')
    ap.add_argument('--dist', default='dist', help='输出目录（默认 dist）')
    ap.add_argument('--control', default='control', help='control 文件路径')
    ap.add_argument('--plist', default='GaodeClean.plist', help='MobileSubstrate plist 路径')
    ap.add_argument('--dylib-arm64', default=None, help='arm64/rootless dylib')
    ap.add_argument('--dylib-arm64e', default=None, help='arm64e/RootHide dylib')
    ap.add_argument('--version', default=None, help='覆盖 version（默认读 control）')
    args = ap.parse_args()

    dist = args.dist
    a64 = args.dylib_arm64 or os.path.join(dist, 'GaodeClean-arm64.dylib')
    a64e = args.dylib_arm64e or os.path.join(dist, 'GaodeClean-arm64e.dylib')
    for p in (args.control, args.plist, a64, a64e):
        if not os.path.isfile(p):
            raise SystemExit('找不到文件：' + p)

    version = args.version or read_version(args.control)
    os.makedirs(dist, exist_ok=True)
    build(a64, 'iphoneos-arm64', False, version, args.plist, args.control, dist)
    build(a64e, 'iphoneos-arm64e', True, version, args.plist, args.control, dist)


if __name__ == '__main__':
    main()
