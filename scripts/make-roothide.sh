#!/bin/bash
# RootHide 转包脚本
# 把 Dopamine rootless deb（data 里带 /var/jb 前缀）转成 RootHide jbroot 布局 deb。
#
# 原理（已对照 RootHide 官方兼容包 FiveIconDock / Uptime 核实）：
#   - RootHide 的 jbroot 不是 /var/jb，它的 dpkg 直接以 bootstrap 根为安装根，
#     所以 data.tar 里必须是 /Library/...，不能是 /var/jb/Library/...。
#   - GaodeClean 是纯 ObjC runtime hook（method_setImplementation），不链 libsubstrate，
#     所以 dylib 的 load command 无需改动（系统框架路径 RootHide 运行时会自动重写）。
#   - control 的 Depends 参照官方兼容包补 oldabi（arm64 deb 兼容 arm64e 设备）。
#
# 依赖：macOS 自带 ar / tar / gzip / sed，无需 dpkg-deb。
#
# 用法：./make-roothide.sh packages/xxx_0.4.0_iphoneos-arm64.deb [输出.deb]
set -euo pipefail

in="${1:?用法: $0 <input.rootless.deb> [output.deb]}"
out="${2:-${in%.deb}-roothide.deb}"

abs_in="$(cd "$(dirname "$in")" && pwd)/$(basename "$in")"
[ -f "$abs_in" ] || { echo "找不到 $in"; exit 1; }

work="$(mktemp -d /tmp/rh.XXXXXX)"
trap 'rm -rf "$work"' EXIT
cd "$work"

echo "[1/4] 拆包 $abs_in"
ar x "$abs_in"
mkdir -p ctrl data
tar -C ctrl -xf control.tar.*
tar -C data -xf data.tar.*

echo "[2/4] 去除 /var/jb 前缀"
if [ -d data/var/jb ]; then
  (cd data && cp -a var/jb/. . && rm -rf var)
else
  echo "    （未发现 var/jb，可能已是 RootHide 布局，跳过）"
fi

echo "[3/4] 调整 Depends"
if grep -q '^Depends:' ctrl/control; then
  # 仅当 Depends 里有 mobilesubstrate 且尚未带 oldabi 时补入，避免重复
  if grep -q 'mobilesubstrate' ctrl/control && ! grep -q 'oldabi' ctrl/control; then
    sed -i.bak -E 's/mobilesubstrate([^,]*)/mobilesubstrate\1, oldabi/g' ctrl/control
    rm -f ctrl/control.bak
  fi
  echo "    $(grep '^Depends:' ctrl/control)"
fi

echo "[4/4] 重新打包 $out"
tar -C ctrl -czf control.tar.gz .
tar -C data -czf data.tar.gz .
printf '2.0\n' > debian-binary
rm -f "$out"
ar rc "$out" debian-binary control.tar.gz data.tar.gz

echo "完成: $out"