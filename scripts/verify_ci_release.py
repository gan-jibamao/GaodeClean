#!/usr/bin/env python3
"""CI 产物本地核验（iSH 无 lipo/plutil，用 python 等价实现）
用法: verify_ci_release.py <目录> <deb:scheme> ...
"""
import sys, os, re, struct, subprocess, plistlib

def macho_slices(path):
    """返回 [(cputype, cpusubtype)]，支持 fat"""
    with open(path, 'rb') as f:
        data = f.read(8)
    magic = struct.unpack('>I', data[:4])[0]
    out = []
    if magic in (0xcafebabe, 0xcafebabf):  # FAT / FAT64
        step = 20 if magic == 0xcafebabe else 32
        with open(path, 'rb') as f:
            f.seek(4)
            n = struct.unpack('>I', f.read(4))[0]
            for _ in range(n):
                # 必须按**无符号**读：arm64e 的 cpusubtype 是 0x80000002（ABI64_PAC 标志）
                cpu, sub = struct.unpack('>II', f.read(8))
                f.read(step - 8)
                out.append((cpu, sub))
    else:
        with open(path, 'rb') as f:
            magic_le, cpu, sub = struct.unpack('<III', f.read(12))
        out.append((cpu, sub))
    return out

def _name(cpu, sub):
    # arm64e 与 arm64 的 cputype 相同（0x0100000c），靠 cpusubtype 区分：
    #   2 = CPU_SUBTYPE_ARM64E，0x80000002 = 带 ABI/PAC 标志的 arm64e
    if cpu == 0x0100000c:
        return 'arm64e' if sub in (2, 0x80000002) else 'arm64'
    return {0x0100000d: 'arm64e'}.get(cpu, hex(cpu))


def fmt(slices):
    return ' '.join('%s(sub=0x%x)' % (_name(c, s), s) for c, s in slices)

def plist_check(p):
    with open(p, 'rb') as f:
        d = plistlib.load(f)
    return d.get('Filter', {}).get('Bundles', [])

def main():
    root = sys.argv[1]
    fail = 0
    for spec in sys.argv[2:]:
        deb, scheme = spec.split(':')
        deb = os.path.join(root, deb)
        print('== %s (%s)' % (os.path.basename(deb), scheme))
        if not os.path.exists(deb):
            print('   [FAIL] 文件不存在'); fail = 1; continue
        info = subprocess.run(['dpkg-deb', '-f', deb, 'Package', 'Version', 'Architecture'],
                              capture_output=True, text=True).stdout.strip().split('\n')
        print('   control:', info)
        arch = info[-1]
        if scheme == 'rootless' and arch != 'iphoneos-arm64':
            print('   [FAIL] rootless 架构标签应为 iphoneos-arm64'); fail = 1
        if scheme == 'roothide' and 'arm64e' not in arch:
            print('   [FAIL] roothide 架构标签应含 arm64e'); fail = 1
        listing = subprocess.run(['dpkg-deb', '-c', deb], capture_output=True, text=True).stdout
        want = ('var/jb/Library/MobileSubstrate/DynamicLibraries/GaodeClean.dylib' if scheme == 'rootless'
                else 'Library/MobileSubstrate/DynamicLibraries/GaodeClean.dylib')
        # homebrew dpkg 的 -c 输出不带 "./" 前缀，两种都接受
        ok = any(re.sub(r'^\./', '', l.split()[-1]) == want for l in listing.splitlines() if l.split())
        print('   %s 载荷 %s' % ('[OK]' if ok else '[FAIL]', want))
        if not ok:
            fail = 1
            print('   ', [l for l in listing.splitlines() if 'GaodeClean' in l])
        if 'GaodeClean.plist' not in listing:
            print('   [FAIL] 缺过滤器 plist'); fail = 1
        # 维护脚本
        tmp = '/tmp/vdeb_%s' % scheme
        subprocess.run(['rm', '-rf', tmp]); os.makedirs(tmp, exist_ok=True)
        subprocess.run(['dpkg-deb', '-e', deb, tmp], capture_output=True)
        scripts = [f for f in os.listdir(tmp) if f in ('preinst', 'postinst', 'prerm', 'postrm')]
        if scripts:
            print('   维护脚本:', scripts)
            for s in scripts:
                body = open(os.path.join(tmp, s), errors='ignore').read()
                if scheme == 'rootless' and ('/var/jb' not in body and 'killall' in body):
                    pass
                if 'GaodeClean' in body:
                    for line in body.splitlines():
                        if 'GaodeClean' in line:
                            print('      |', line.strip()[:120])
        else:
            print('   [OK] 无维护脚本')
        # dylib 切片
        ex = '/tmp/vex_%s' % scheme
        subprocess.run(['rm', '-rf', ex]); os.makedirs(ex, exist_ok=True)
        subprocess.run(['dpkg-deb', '-x', deb, ex], capture_output=True)
        dyl = None
        for dp, _, fs in os.walk(ex):
            for f in fs:
                if f == 'GaodeClean.dylib':
                    dyl = os.path.join(dp, f)
        if not dyl:
            print('   [FAIL] 解包后找不到 dylib'); fail = 1; continue
        sl = macho_slices(dyl)
        print('   切片: %s   (%d 字节)' % (fmt(sl), os.path.getsize(dyl)))
        have = {_name(c, s) for c, s in sl}
        if 'arm64' not in have:
            print('   [FAIL] 缺 arm64 切片'); fail = 1
        if scheme == 'roothide' and 'arm64e' not in have:
            print('   [FAIL] roothide 缺 arm64e 切片'); fail = 1
        # 日志哨兵
        st = subprocess.run(['strings', '-a', dyl], capture_output=True, text=True).stdout
        logonly = ['blocked tab guide lottie', 'page=%ld anchor=pending', 'splash ad hidden',
                   'weather row released', 'fog sweep hides']
        hit = [x for x in logonly if x in st]
        if hit:
            print('   [FAIL] 正式包残留 GCLog 诊断串:', hit); fail = 1
        else:
            print('   [OK] GCLog 已剥空（保留 NSLog 计数 %d，预期 8）' % st.count('[GaodeClean] '))
        # 过滤器
        for dp, _, fs in os.walk(ex):
            for f in fs:
                if f == 'GaodeClean.plist':
                    print('   过滤器 Bundles:', plist_check(os.path.join(dp, f)))
    print('== 结论:', '全部通过' if fail == 0 else '存在失败项')
    return fail

sys.exit(main())
