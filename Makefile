# ============================================================================
#  GaodeClean —— 构建入口（0.9.8 / A15 新增）
#
#  此前仓库没有任何构建脚本：mkdeb.py 里写死 /tmp/gcbuild090 与 VERSION=0.9.0，
#  编译参数只存在于历史对话里，任何人拿到仓库都无法一键重建。
#
#  用法：
#    make            # arm64 + arm64e + 两个 deb
#    make arm64      # 只出 rootless 切片
#    make arm64e     # 只出 RootHide 切片
#    make deb        # 只打包（需先有 dist/*.dylib）
#    make check      # 只做语法/警告门禁（0 警告才算过）
#    make clean
#
#  SDK 默认 /tmp/sdk165/iPhoneOS16.5.sdk，可用 SDK=... 覆盖。
# ============================================================================

SDK        ?= /tmp/sdk165/iPhoneOS16.5.sdk
CLANG      ?= clang
TARGET_IOS ?= 15.0
OUT        ?= dist
SRC        := src/GaodeClean.m
HDR        := src/GCCGeometry.h

COMMON := -isysroot $(SDK) -fobjc-arc -fmodules -O2 \
          -Wall -Wextra -Wno-unused-parameter -I src
LINK   := -dynamiclib \
          -install_name /Library/MobileSubstrate/DynamicLibraries/GaodeClean.dylib \
          -framework UIKit -framework Foundation -fuse-ld=lld -Wl,-adhoc_codesign

DYLIB64  := $(OUT)/GaodeClean-arm64.dylib
DYLIB64E := $(OUT)/GaodeClean-arm64e.dylib

.PHONY: all arm64 arm64e deb check clean

all: deb

arm64: $(DYLIB64)
arm64e: $(DYLIB64E)

# arm64：lld 支持 -fixup_chains，走链式绑定
$(DYLIB64): $(SRC) $(HDR) | $(OUT)
	$(CLANG) -target arm64-apple-ios$(TARGET_IOS) $(COMMON) $(LINK) \
	  -Wl,-fixup_chains -o $@ $(SRC)

# arm64e：lld 不支持 arm64e 的 -fixup_chains，走经典 LC_DYLD_INFO_ONLY；
#         链接后再把 cpusubtype 从 0 改回 2 并重算签名页哈希（见 scripts/fixarch.py）
$(DYLIB64E): $(SRC) $(HDR) | $(OUT)
	$(CLANG) -target arm64e-apple-ios$(TARGET_IOS) $(COMMON) $(LINK) -o $@ $(SRC)
	python3 scripts/fixarch.py $@ 2

$(OUT):
	mkdir -p $(OUT)

deb: $(DYLIB64) $(DYLIB64E)
	python3 scripts/mkdeb.py --dist $(OUT) --control control --plist GaodeClean.plist \
	  --dylib-arm64 $(DYLIB64) --dylib-arm64e $(DYLIB64E)

# 门禁：必须 0 警告（与 0.9.7 基线一致）
check:
	@out=$$($(CLANG) -target arm64-apple-ios$(TARGET_IOS) $(COMMON) -fsyntax-only $(SRC) 2>&1); \
	if echo "$$out" | grep -q 'warning:'; then \
	  echo "$$out"; echo "FAIL: 存在警告"; exit 1; \
	fi; echo "OK: 0 warnings"

clean:
	rm -f $(DYLIB64) $(DYLIB64E) $(OUT)/*.deb
