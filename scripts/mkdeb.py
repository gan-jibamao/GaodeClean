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
  经典 LC_DYLD_INFO_ONLY 绑定。两者都由 tools/fixarch.py 收尾：改 subtype + 重算签名页哈希。
"""
import io, os, tarfile

MTIME = 1759600000
OUT = '/tmp/gcbuild/dist'
PLIST = '/tmp/gclean/GaodeClean.plist'
CTRL = '/tmp/gcbuild/control'
LIBSUB = 'Library/MobileSubstrate/DynamicLibraries'
VERSION = '0.7.3'

# (dylib 路径, deb 架构名, 是否 RootHide)
TARGETS = [
    ('/tmp/gcbuild/GaodeClean.dylib',        'iphoneos-arm64',  False),
    ('/tmp/gcbuild/GaodeClean-arm64e.dylib', 'iphoneos-arm64e', True),
]


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


def control_text(arch, roothide):
    txt = open(CTRL, encoding='utf-8').read().rstrip('\n')
    txt = txt.replace('Architecture: iphoneos-arm64', 'Architecture: ' + arch)
    if roothide:
        txt = txt.replace('mobilesubstrate', 'mobilesubstrate, oldabi')
    return txt.encode('utf-8')


def build(dylib, arch, roothide):
    prefix = '' if roothide else 'var/jb/'
    suffix = '-roothide' if roothide else ''
    name = f'com.jibamao.gaodeclean_{VERSION}_{arch}{suffix}.deb'
    path = os.path.join(OUT, name)

    data_entries = [
        (PLIST, './' + prefix + LIBSUB + '/GaodeClean.plist', 0o644),
        (dylib, './' + prefix + LIBSUB + '/GaodeClean.dylib', 0o755),
    ]
    cb = control_text(arch, roothide)
    ctrl_buf = io.BytesIO()
    with tarfile.open(fileobj=ctrl_buf, mode='w:gz', format=tarfile.GNU_FORMAT) as t:
        ti = tarfile.TarInfo('./control')
        ti.size = len(cb); ti.mode = 0o644; ti.uid = ti.gid = 0
        ti.uname = ti.gname = 'root'; ti.mtime = MTIME
        t.addfile(ti, io.BytesIO(cb))

    with open(path, 'wb') as out:
        out.write(b'!<arch>\n')
        ar_member('debian-binary', b'2.0\n', out)
        ar_member('control.tar.gz', ctrl_buf.getvalue(), out)
        ar_member('data.tar.gz', tar_bytes(data_entries), out)
    print(f'[deb] {name}  {os.path.getsize(path)} B   ({arch}{" / RootHide" if roothide else " / rootless"})')
    return path


if __name__ == '__main__':
    os.makedirs(OUT, exist_ok=True)
    for d, a, r in TARGETS:
        build(d, a, r)
