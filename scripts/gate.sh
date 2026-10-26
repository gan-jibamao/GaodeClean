#!/bin/sh
# ============================================================================
#  scripts/gate.sh —— GaodeClean 门禁一键化（C1，0.9.98）
#
#  用法：
#    scripts/gate.sh                          # 只跑源码门禁（日常改代码后跑这个）
#    scripts/gate.sh --pkg /tmp/trial55       # 源码门禁 + 包门禁（出包后跑这个）
#    scripts/gate.sh --pkg /tmp/probe43 --kind probe   # 探针包（断言探针串「必须存在」）
#
#  为什么需要它（每条都是踩过的坑）：
#   1) `make check` 带 -Wno-format-security，而 Makefile.local 构建行不带
#      ⇒ 构建时冒出的 -Wformat-security 不是新问题。真正能抓 error 的只有
#        「探针口径 clang -fsyntax-only」这一道（make check 只 grep warning）。
#   2) 正式包里探针字符串必须为 0 —— 但要分开查：纯 ASCII 的用 `strings -a`，
#      带中文的（内存里是 UTF-16LE）必须用 `strings -a -e l`，混用会误报 0。
#   3) 钩子功能符号（_imp_implementationWithBlock 等）必须还在；
#      `_class_getName` 缺失是正常的（只被探针块引用，编译掉后无引用）。
#
#  退出码：0 = 全绿；1 = 有失败项；2 = 参数错误
# ============================================================================
set -u

ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT" || exit 2

SDK=${SDK:-/tmp/sdk165/iPhoneOS16.5.sdk}
PKG=""
KIND="release"

while [ $# -gt 0 ]; do
    case "$1" in
        --pkg)   [ $# -ge 2 ] || { echo "--pkg 需要目录参数" >&2; exit 2; }; PKG=$2; shift 2 ;;
        --kind)  [ $# -ge 2 ] || { echo "--kind 需要 release|probe" >&2; exit 2; }; KIND=$2; shift 2 ;;
        -h|--help) sed -n '2,26p' "$0"; exit 0 ;;
        *) echo "未知参数：$1（-h 看用法）" >&2; exit 2 ;;
    esac
done

case "$KIND" in release|probe) ;; *) echo "--kind 只能是 release 或 probe" >&2; exit 2 ;; esac

FAIL=0
ok()  { printf '  [OK]   %s\n' "$1"; }
bad() { printf '  [FAIL] %s\n' "$1"; FAIL=$((FAIL + 1)); }
warn(){ printf '  [warn] %s\n' "$1"; }

echo "═══ GaodeClean 门禁（kind=$KIND${PKG:+ pkg=$PKG}）═══"

# ── 0 环境 ────────────────────────────────────────────────────────────────
echo "[0/4] 环境"
if [ -d "$SDK" ]; then ok "SDK $SDK"; else bad "SDK 缺失：$SDK（可用 SDK=... 覆盖）"; fi
if [ -d /tmp/shims ]; then
    PATH=/tmp/shims:$PATH; export PATH; ok "shims 已加入 PATH（verify_deb 需要 lipo）"
else
    warn "/tmp/shims 不存在：包门禁里的 lipo 检查会退化"
fi

# ── 1 探针口径语法（唯一能抓 error 的一道）────────────────────────────────
echo "[1/4] 探针口径语法 -fsyntax-only（-DGAODECLEAN_PROBE=1）"
if [ -d "$SDK" ]; then
    if clang -target arm64-apple-ios15.0 -isysroot "$SDK" -fobjc-arc -fmodules -O2 \
        -Wall -Wextra -Wno-unused-parameter -Wno-format-security -I src \
        -fvisibility=hidden -DGAODECLEAN_PROBE=1 -fsyntax-only src/GaodeClean.m 2>/tmp/gc_gate_syntax.log
    then ok "0 error 0 warning"; else bad "语法/警告未通过（见 /tmp/gc_gate_syntax.log）"; fi
else
    warn "跳过（无 SDK）"
fi

# ── 2 make check（STRIP=1/0 + 混淆回环 + FNV）──────────────────────────────
echo "[2/4] make check（STRIP=1 / STRIP=0 / 混淆回环 / FNV）"
if make -f Makefile.local check >/tmp/gc_gate_check.log 2>&1; then
    grep -q '全部通过' /tmp/gc_gate_check.log && ok "静态门禁全部通过" || bad "静态门禁未报「全部通过」"
    grep -E 'OK: 0 warnings|PASS 混淆回环' /tmp/gc_gate_check.log | sed 's/^/         /'
else
    bad "make check 失败（见 /tmp/gc_gate_check.log）"
fi

# ── 3 包门禁 ──────────────────────────────────────────────────────────────
echo "[3/4] 包门禁"
if [ -z "$PKG" ]; then
    warn "未指定 --pkg，跳过解包核验"
elif [ ! -d "$PKG" ]; then
    bad "目录不存在：$PKG"
else
    DEBS=$(find "$PKG" -maxdepth 2 -name '*.deb' | sort)
    if [ -z "$DEBS" ]; then bad "$PKG 下没有 .deb"; fi
    for d in $DEBS; do
        case "$d" in
            *roothide*) SCHEME=roothide ;;
            *)          SCHEME=rootless ;;
        esac
        if FINALPACKAGE=1 bash -u scripts/verify_deb.sh "$d" "$SCHEME" >/tmp/gc_gate_deb.log 2>&1; then
            ok "$(basename "$d")（$SCHEME）"
        else
            bad "$(basename "$d")（$SCHEME，见 /tmp/gc_gate_deb.log）"
        fi
        echo "         版本=$(dpkg-deb -f "$d" Version) 架构=$(dpkg-deb -f "$d" Architecture)"
    done
fi

# ── 4 二进制取证（探针残留 / 钩子符号 / 版本串）───────────────────────────
echo "[4/4] 二进制取证"
if [ -z "$PKG" ]; then
    warn "未指定 --pkg，跳过取证"
else
    for f in $(find "$PKG" -maxdepth 2 -name '*arm64.dylib' | sort); do
        b=$(basename "$f")
        ASCIIHIT=$(strings -a   "$f" | grep -cE 'SUBhook\[|IPIN\[' || true)
        UTF16HIT=$(strings -a -e l "$f" | grep -cE 'CLAMP\[|PIN 2D' || true)
        if [ "$KIND" = "release" ]; then
            [ "$ASCIIHIT" -eq 0 ] && [ "$UTF16HIT" -eq 0 ] \
                && ok "$b 探针残留 0（ASCII=$ASCIIHIT / UTF16=$UTF16HIT）" \
                || bad "$b 探针残留！ASCII=$ASCIIHIT / UTF16=$UTF16HIT"
        else
            [ "$ASCIIHIT" -gt 0 ] && ok "$b 探针串存在（ASCII=$ASCIIHIT / UTF16=$UTF16HIT）" \
                || bad "$b 探针串缺失（构建可能没带 -DGAODECLEAN_PROBE=1）"
        fi
        # 钩子功能符号：正式包也必须保留
        MISS=""
        for sym in _imp_implementationWithBlock _class_getInstanceMethod _object_getClass; do
            llvm-nm -u "$f" 2>/dev/null | grep -q "$sym" || MISS="$MISS $sym"
        done
        [ -z "$MISS" ] && ok "$b 钩子符号齐全" || bad "$b 缺符号:$MISS"
        # 版本串：纯 ASCII，必须用 strings -a（用 -e l 会误报 0）
        V=$(dpkg-deb -f "$(find "$PKG" -maxdepth 2 -name "*.deb" | head -1)" Version 2>/dev/null || echo "")
        if [ -n "$V" ]; then
            if strings -a "$f" | grep -qF "$V"; then ok "$b 版本串 $V 可见"
            else warn "$b 版本串 $V 未命中（kGCVersion 可能已被 dead_strip 删掉）"; fi
        fi
    done
fi

echo "═══════════════════════════════════════"
if [ "$FAIL" -eq 0 ]; then
    echo "★ 门禁全绿（0 失败）"
    exit 0
else
    echo "✗ 门禁失败 $FAIL 项"
    exit 1
fi
