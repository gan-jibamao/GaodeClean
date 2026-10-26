#!/bin/bash
# ============================================================================
#  scripts/build.sh —— GaodeClean 一键出包（C2，0.9.98）
#
#  用法：
#    scripts/build.sh release 0.9.98+trial55     # 正式包（日志剥离、无探针）
#    scripts/build.sh probe   0.9.98+probe43     # 探针包（带 GAODECLEAN_PROBE）
#
#  它会替你做完这几件容易漏的事：
#    1) 由根 control 生成 controls/control.<后缀>，Version 改成你给的版本
#    2) 临时把 src/GaodeClean.m 的 kGCVersion 改成同一版本
#       —— 并且用 trap 保证**无论如何退出都会还原**（含 Ctrl-C / 构建失败）
#    3) 双架构构建（arm64 rootless + arm64e RootHide）
#    4) 调 scripts/gate.sh 做源码门禁 + 包门禁 + 二进制取证
#    5) 产出交付目录 <DEST>/GaodeClean-<x.y.z>-<后缀>/：两个 deb + 两个 dylib + SHA256SUMS
#
#  历史教训：上一轮出包要手敲 6~8 条命令，其中「忘了还原 kGCVersion」
#  和「忘了跑探针口径语法检查」各踩过一次。这两件事现在都固化在脚本里。
#
#  环境变量：
#    DEST   交付根目录（默认 /var/minis/attachments；自测时可指到 /tmp）
#    SDK    iOS SDK 路径（默认 /tmp/sdk165/iPhoneOS16.5.sdk）
#    SKIP_GATE=1  跳过门禁（只在明知道自己要什么时用）
#
#  退出码：0 成功；1 失败；2 参数错误
# ============================================================================
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"

usage() { sed -n '2,30p' "$0"; exit 2; }

[ $# -eq 2 ] || usage
MODE=$1
VER=$2

case "$MODE" in release|probe) ;; *) echo "模式只能是 release 或 probe" >&2; usage ;; esac

# 版本必须形如 0.9.98+trial55 / 0.9.98+probe43
if ! printf '%s' "$VER" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+\+(trial|probe)[0-9]+$'; then
    echo "版本格式不合法：$VER" >&2
    echo "  正确示例：0.9.98+trial55  /  0.9.98+probe43" >&2
    exit 2
fi

BASE=${VER%%+*}      # 0.9.98
SUFFIX=${VER#*+}     # trial55 / probe43
DEST=${DEST:-/var/minis/attachments}
SDK=${SDK:-/tmp/sdk165/iPhoneOS16.5.sdk}
OUT=/tmp/gc-$SUFFIX
SRC=src/GaodeClean.m
CTL=controls/control.$SUFFIX
BAK=$(mktemp /tmp/gc_src.XXXXXX)

echo "═══ 出包：$VER（$MODE）═══"

# ── 0 环境 ────────────────────────────────────────────────────────────────
[ -d "$SDK" ]        || { echo "SDK 缺失：$SDK" >&2; exit 1; }
[ -f "$ROOT/control" ] || { echo "缺少根 control 模板" >&2; exit 1; }
case "$(uname -m)" in *) ;; esac

# ── 1 control ─────────────────────────────────────────────────────────────
mkdir -p controls
sed "s/^Version:.*/Version: $VER/" control > "$CTL"
echo "[1] control → $CTL（$(grep '^Version:' "$CTL")）"

# ── 2 kGCVersion（trap 保证还原）──────────────────────────────────────────
cp "$SRC" "$BAK"
restore() {
    cp "$BAK" "$SRC"
    rm -f "$BAK"
    printf '\n[还原] kGCVersion → %s\n' "$(grep -o 'kGCVersion *= *@"[^"]*"' "$SRC" | grep -o '@"[^"]*"' | tr -d '@"')"
}
trap restore EXIT INT TERM

CUR=$(grep -o 'kGCVersion *= *@"[^"]*"' "$SRC" | grep -o '@"[^"]*"' | tr -d '@"')
if [ "$CUR" != "$VER" ]; then
    sed -i "s/kGCVersion     = @\"[^\"]*\"/kGCVersion     = @\"$VER\"/" "$SRC"
fi
echo "[2] kGCVersion → $(grep -o 'kGCVersion *= *@"[^"]*"' "$SRC" | grep -o '@"[^"]*"' | tr -d '@"')"

# ── 3 构建 ────────────────────────────────────────────────────────────────
echo "[3] 构建（$MODE，双架构）"
rm -rf "$OUT"
if [ "$MODE" = release ]; then
    PATH=/tmp/shims:$PATH make -f Makefile.local RELEASE=1 CONTROL="$CTL" OUT="$OUT" >/tmp/gc_build.log 2>&1
else
    PATH=/tmp/shims:$PATH make -f Makefile.local RELEASE=0 CONTROL="$CTL" OUT="$OUT" \
        EXTRA=-DGAODECLEAN_PROBE=1 >/tmp/gc_build.log 2>&1
fi
grep -E '^\[deb\]' /tmp/gc_build.log || { echo "构建失败，见 /tmp/gc_build.log" >&2; tail -20 /tmp/gc_build.log >&2; exit 1; }

# ── 4 门禁 ────────────────────────────────────────────────────────────────
if [ "${SKIP_GATE:-0}" = "1" ]; then
    echo "[4] 门禁：已按 SKIP_GATE=1 跳过"
else
    echo "[4] 门禁"
    scripts/gate.sh --pkg "$OUT" --kind "$MODE" || { echo "门禁失败，已中止交付" >&2; exit 1; }
fi

# ── 5 交付 ────────────────────────────────────────────────────────────────
DELIV="$DEST/GaodeClean-$BASE-$SUFFIX"
echo "[5] 交付 → $DELIV"
rm -rf "$DELIV"; mkdir -p "$DELIV"
for d in "$OUT"/*.deb; do
    n=$(basename "$d")                          # com.jibamao.gaodeclean_<ver>_iphoneos-arm64.deb
    case "$n" in
        *roothide*) cp "$d" "$DELIV/GaodeClean-$BASE-$SUFFIX-arm64e-roothide.deb" ;;
        *)          cp "$d" "$DELIV/GaodeClean-$BASE-$SUFFIX-arm64.deb" ;;
    esac
done
cp "$OUT/GaodeClean-arm64.dylib" "$OUT/GaodeClean-arm64e.dylib" "$DELIV/"
cp "$CTL" "$DELIV/control.$SUFFIX"      # 该版本用的 control 存档，便于复现
( cd "$DELIV" && sha256sum ./*.deb ./*.dylib > SHA256SUMS )
echo "     $(ls "$DELIV" | tr '\n' ' ')"
echo "     SHA256SUMS 已生成（$(wc -l < "$DELIV/SHA256SUMS") 行）"

echo
echo "★ 完成：$VER"
echo "  下一步：真机安装 → 验收 → 提交并推送"
echo "    git add -A && git commit -m '...' && git push <remote> probe/width-hierarchy"
