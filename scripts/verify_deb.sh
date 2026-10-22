#!/bin/bash
# ============================================================================
#  GaodeClean deb 核验门禁（CI 与本地通用）
#
#  用法：scripts/verify_deb.sh <deb 文件> <rootless|roothide>
#
#  断言项（任一条不满足即 exit 1）：
#    1. control 的 Package / Version / Architecture 与 scheme 对应
#    2. 载荷路径前缀正确（rootless=/var/jb/... ，roothide=/Library/...）
#    3. dylib 含 arm64 切片；roothide 包另需 arm64e 切片
#    4. 无维护脚本硬编码路径问题（本工程不产出维护脚本，出现即告警）
#    5. 正式包（FINALPACKAGE=1）体内不得残留 GCLog 诊断串 "[GaodeClean] "
#    6. 注入过滤器 plist 存在且 Bundles=com.autonavi.amap
# ============================================================================
set -euo pipefail

DEB="${1:?用法: verify_deb.sh <deb> <rootless|roothide>}"
SCHEME="${2:?用法: verify_deb.sh <deb> <rootless|roothide>}"
FAIL=0

say()  { printf '%s\n' "$*"; }
ok()   { printf '  [OK]   %s\n' "$*"; }
bad()  { printf '  [FAIL] %s\n' "$*"; FAIL=1; }

[ -f "$DEB" ] || { say "找不到 deb: $DEB"; exit 1; }

say "== $DEB  (scheme=$SCHEME)"
PKG=$(dpkg-deb -f "$DEB" Package)
VER=$(dpkg-deb -f "$DEB" Version)
ARCH=$(dpkg-deb -f "$DEB" Architecture)
say "  Package=$PKG Version=$VER Architecture=$ARCH"

# --- 1. 身份与架构标签 ---
[ "$PKG" = "com.jibamao.gaodeclean" ] && ok "包名正确" || bad "包名异常: $PKG"
case "$SCHEME" in
  rootless)
    case "$ARCH" in
      iphoneos-arm64) ok "架构标签 iphoneos-arm64" ;;
      *) bad "rootless 架构标签应为 iphoneos-arm64，实际 $ARCH" ;;
    esac ;;
  roothide)
    case "$ARCH" in
      *arm64e*) ok "架构标签含 arm64e ($ARCH)" ;;
      *) bad "roothide 架构标签应含 arm64e，实际 $ARCH" ;;
    esac ;;
  *) bad "未知 scheme: $SCHEME" ;;
esac

# --- 2. 载荷路径 ---
LIST=$(dpkg-deb -c "$DEB")
case "$SCHEME" in
  rootless) WANT="var/jb/Library/MobileSubstrate/DynamicLibraries/GaodeClean.dylib" ;;
  roothide) WANT="Library/MobileSubstrate/DynamicLibraries/GaodeClean.dylib" ;;
esac
if printf '%s\n' "$LIST" | grep -q "\./$WANT\$"; then
  ok "载荷路径 ./$WANT"
else
  bad "载荷路径不符合预期 ./$WANT"
  printf '%s\n' "$LIST" | grep -i gaodeclean || true
fi
printf '%s\n' "$LIST" | grep -q 'GaodeClean.plist' && ok "过滤器 plist 已随包" || bad "缺少 GaodeClean.plist"

# --- 3. 维护脚本（本工程不应有；有则必须检查路径前缀） ---
TMP=$(mktemp -d)
dpkg-deb -e "$DEB" "$TMP/DEBIAN"
SCRIPTS=$(ls "$TMP/DEBIAN" | grep -E '^(preinst|postinst|prerm|postrm)$' || true)
if [ -z "$SCRIPTS" ]; then
  ok "无维护脚本（无需路径转换）"
else
  say "  维护脚本: $(echo $SCRIPTS | tr '\n' ' ')"
  for s in $SCRIPTS; do
    if [ "$SCHEME" = "rootless" ]; then
      grep -qE '^/(Applications|Library)' "$TMP/DEBIAN/$s" && bad "$s 出现未转换的根路径（rootless 应为 /var/jb/...）"
    fi
    [ -x "$TMP/DEBIAN/$s" ] || bad "$s 不可执行"
  done
  ok "维护脚本路径已核验"
fi

# --- 4. dylib 切片 ---
dpkg-deb -x "$DEB" "$TMP/root"
DYL=$(find "$TMP/root" -name 'GaodeClean.dylib' | head -1)
[ -n "$DYL" ] || { bad "解包后找不到 dylib"; exit 1; }
SLICES=$(lipo -info "$DYL" 2>/dev/null || file "$DYL")
say "  $SLICES"
case "$SLICES" in
  *arm64e*) ok "含 arm64e 切片" ;;
  *) case "$SCHEME" in
       roothide) bad "roothide 包缺 arm64e 切片" ;;
       *) say "  [note] 无 arm64e 切片（rootless 允许）" ;;
     esac ;;
esac
case "$SLICES" in
  *arm64*) ok "含 arm64 切片" ;;
  *) bad "缺 arm64 切片" ;;
esac

# --- 5. FINALPACKAGE 剥离哨兵 ---
if strings -a "$DYL" | grep -qF '[GaodeClean] '; then
  say "  [note] 体内残留 GCLog 诊断串（仅当本次构建 FINALPACKAGE=1 时才算失败）"
  if [ "${FINALPACKAGE:-0}" = "1" ]; then
    bad "正式包不应残留 GCLog 诊断串"
  fi
else
  ok "无 GCLog 诊断串残留（日志已剥离）"
fi

# --- 6. 注入过滤器 ---
PL=$(find "$TMP/root" -name 'GaodeClean.plist' | head -1)
if [ -n "$PL" ]; then
  plutil -p "$PL" 2>/dev/null | grep -q 'com.autonavi.amap' \
    && ok "过滤器 Bundles=com.autonavi.amap" || bad "过滤器不含 com.autonavi.amap"
fi

rm -rf "$TMP"

if [ "$FAIL" -eq 0 ]; then
  say "== 核验通过：$DEB"
else
  say "== 核验失败：$DEB"
fi
exit "$FAIL"
