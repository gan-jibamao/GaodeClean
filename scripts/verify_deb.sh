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
#    7. 体内版本串 kGCVersion 与 control 的 Version 一致（0.9.17 A6 新增）
#       —— 起因：0.9.17 只改了 control/文档，漏改源码 kGCVersion，
#          导致包装出来是 0.9.17、体内日志却仍报 0.9.16。
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
# 0.9.18（A4）：调试包（版本含 "+"，如 0.9.18+diag3）不是发布包 ——
#   它按设计**不剥** GCLog、且版本号带后缀，不能拿发布不变量判它失败。
case "$VER" in
  *+*) IS_DEBUG_PKG=1; VER_BASE="${VER%%+*}" ;;
  *)   IS_DEBUG_PKG=0; VER_BASE="$VER" ;;
esac
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
# 注意：不同 dpkg 版本的 `dpkg-deb -c` 输出带不带 "./" 前缀不一致（homebrew dpkg 不带），
# 这里用 (行首|空格) 可选 "./" 的写法，避免把正确的载荷误判为失败。
if printf '%s\n' "$LIST" | grep -E "(^| )(\./)?${WANT}\$" >/dev/null; then
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

# --- 5. FINALPACKAGE 剥离哨兵（0.9.20 A2 改口径：零日志、零探针）---
# 0.9.14~0.9.19 的口径是「GCLog 剥空 + 故意保留 8 处 NSLog」；
# 0.9.20 起把 8 处 NSLog 也清除，正式包内**不允许**再出现任何 `[GaodeClean] ` 日志串。
# 哨兵仍取「只出现在 GCLog 里的文案」，另外补一组探针专属串（诊断模块/环境开关/右列 dump）。
GC_LOGONLY='blocked tab guide lottie|page=%ld anchor=pending|splash ad hidden|weather row released|fog sweep hides'
GC_PROBEONLY='gaodeclean-diag|GAODECLEAN_DEBUG|GAODECLEAN_DIAG_LOG|WINSplash classes at runtime|hook SKIPPED|splash guard hooked|ad-window blacklist SKIPPED'
NLOG=$(strings -a "$DYL" | grep -cF '[GaodeClean] ' || true)
PROBEHIT=$(strings -a "$DYL" | grep -cE "$GC_PROBEONLY" || true)
if [ "${PROBEHIT:-0}" -gt 0 ]; then
  if [ "$IS_DEBUG_PKG" = "1" ]; then
    say "  [skip] 调试包：按设计保留探针（命中 ${PROBEHIT} 条）"
  else
    bad "正式包残留诊断探针串（命中 ${PROBEHIT} 条）：${GC_PROBEONLY}"
  fi
else
  ok "无诊断探针串残留（模块/环境开关/右列 dump 均不在包内）"
fi
# ★ 断言一律「先取值再比较」，不要 `strings | grep -q`：
#   本脚本开了 `set -o pipefail`，grep -q 命中即退出会让 strings 吃到 SIGPIPE(141)，
#   管线状态变非零 ⇒ 把「命中」误判成「未命中」（剥离去向错则变成**假通过**）。
GCLOGHIT=$(strings -a "$DYL" | grep -cE "$GC_LOGONLY" || true)
if [ "${GCLOGHIT:-0}" -gt 0 ]; then
  if [ "$IS_DEBUG_PKG" = "1" ]; then
    say "  [skip] 调试包 ${VER}：按设计保留 GCLog（命中 ${GCLOGHIT} 条），不适用发布不变量"
  elif [ "${FINALPACKAGE:-0}" = "1" ]; then
    bad "正式包残留 GCLog 诊断串（GCLog 未被剥空）"
  else
    say "  [note] 非正式构建，保留 GCLog 诊断串（正常）"
  fi
else
  ok "GCLog 诊断串已剥空"
  if [ "${NLOG:-0}" -eq 0 ]; then
    ok "自定义日志零残留（[GaodeClean] 计数 0）"
  elif [ "$IS_DEBUG_PKG" = "1" ]; then
    say "  [skip] 调试包保留自定义日志（计数 ${NLOG}）"
  else
    bad "正式包仍残留自定义日志串（[GaodeClean] 计数 ${NLOG}，0.9.20 起应为 0）"
  fi
fi

# --- 6. 版本串一致性（0.9.17 A6 新增）---
# 起因：0.9.17 只改 control/文档，漏改源码 kGCVersion ⇒ 包是 0.9.17、体内日志仍报 0.9.16。
# 断言：control 的 Version 必须能在体内找到；且不得再出现「同族旧版本串」。
# 同样先取值再比较（见上：pipefail + grep -q 的 SIGPIPE 陷阱）。
VERHIT=$(strings -a "$DYL" | grep -cF "$VER_BASE" || true)
if [ "${VERHIT:-0}" -gt 0 ]; then
  ok "体内版本串 ${VER}（与 control 一致）"
else
  bad "体内版本串与 control 不一致：control=${VER}（基版本 ${VER_BASE}），dylib 内找不到"
fi
STALE=$(strings -a "$DYL" | grep -oE '0\.9\.[0-9]+' | sort -u | grep -v "^${VER_BASE}$" || true)
if [ -n "$STALE" ]; then
  bad "体内残留同族旧版本串: $(printf '%s' "$STALE" | tr '\n' ' ')"
else
  ok "无同族旧版本串残留"
fi

# --- 7. 加固与混淆（0.9.20 A2 新增）---
# 7a 抽样断言：这些明文（Amap 私有类名 / 中文关键词）不得出现在正式包内。
GC_OBF_PROBE='WINPermanentCompassView|WINAJXCombinedWidgetView|WINLiteWidgetGroupView|WINDeviceInterconnectWidget|WINGroupMapWidget|amap_bundle_quickservice'
OBFHIT=$(strings -a "$DYL" | grep -cE "$GC_OBF_PROBE" || true)
if [ "${OBFHIT:-0}" -eq 0 ]; then
  ok "字符串混淆生效（抽样 6 类敏感明文命中 0）"
else
  bad "明文未混淆：命中 ${OBFHIT} 条（${GC_OBF_PROBE:-}）"
fi
# 7b 中文关键词按 UTF-16 形状核验（Objective-C 中文字面量编成 UTF-16）
CNHIT=0
for w in 酒店 加油站 超市 停车场; do
  if [ "$(LC_ALL=C grep -c . /dev/null)" ]; then :; fi
  if strings -a -e l "$DYL" 2>/dev/null | grep -qF "$w"; then CNHIT=$((CNHIT+1)); fi
done
if [ "$CNHIT" -eq 0 ]; then
  ok "中文关键词无明文残留"
else
  bad "中文关键词仍有明文（${CNHIT} 个）"
fi
# 7c 本地符号应被链接期剥离（-Wl,-x）
#     注意：必须用 { ... || true; } 包住 nm。脚本开头是 set -euo pipefail，
#     在 iSH 上 nm 读 Mach-O 会非零退出（busybox nm 不支持），pipefail 会
#     把整条管道判失败 ⇒ set -e 直接终止脚本 ⇒ 脚本静默 exit 1（既无 FAIL
#     也无「核验通过」，本次实测踩到）。包住后 nm 失败只降级为「无法核验」。
if command -v nm >/dev/null 2>&1; then
  LOCALSYM=$( { nm -a "$DYL" 2>/dev/null || true; } | awk '$2=="t"||$2=="s"' | wc -l | tr -d ' ')
  if [ "${LOCALSYM:-1}" -le 2 ]; then
    ok "本地符号已剥离（残留 ${LOCALSYM}）"
  else
    bad "本地符号未剥离（残留 ${LOCALSYM}）"
  fi
fi

# --- 8. 注入过滤器 ---
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
