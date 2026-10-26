# ============================================================================
#  GaodeClean —— theos 工程（2026-10-22 构建通道迁移：正式包一律走 GitHub CI）
#
#  正式发布包（GitHub Actions, macos-14）：
#    make package FINALPACKAGE=1 THEOS_PACKAGE_SCHEME=rootless
#        → com.jibamao.gaodeclean_<ver>_iphoneos-arm64.deb      （载荷前缀 /var/jb）
#    make package FINALPACKAGE=1 THEOS_PACKAGE_SCHEME=roothide
#        → com.jibamao.gaodeclean_<ver>_iphoneos-arm64e.deb     （载荷前缀 /Library）
#
#  本机 iSH 自研 clang 链（/tmp/sdk165 + lld + scripts/fixarch.py）保留为
#  【临时验证】用途，见 Makefile.local：
#    make -f Makefile.local check     # 剥离/不剥离 双跑 0 警告门禁
#    make -f Makefile.local deb       # 本地临时包（不得作为发布资产）
# ============================================================================

ARCHS = arm64 arm64e
TARGET = iphone:clang:16.5:15.0
INSTALL_TARGET_PROCESSES = AMap

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = GaodeClean

# 源码与本地链完全同源：src/GaodeClean.m（+ GCCGeometry.h）
GaodeClean_FILES = src/GaodeClean.m
GaodeClean_CFLAGS = -fobjc-arc -fmodules -Isrc -Wall -Wextra -Wno-unused-parameter \
                    -fvisibility=hidden -fno-ident
# 0.9.21（A1）加固：-Wl,-x 剥掉全部本地符号，-Wl,-dead_strip 去死代码；
# 配合 -fvisibility=hidden，nm/strings 里不再暴露内部函数名与实现线索。
GaodeClean_LDFLAGS = -Wl,-x -Wl,-dead_strip
GaodeClean_FRAMEWORKS = UIKit Foundation

# 正式包剥掉全部 GCLog 诊断串（与 Makefile.local 的 RELEASE=1 语义一致）
ifeq ($(FINALPACKAGE),1)
GaodeClean_CFLAGS += -DGAODECLEAN_STRIP_LOGS=1
endif

# 0.9.99：GitHub CI 也能出探针包（本地用 Makefile.local 的 EXTRA=... 即可）
#   用法：make package FINALPACKAGE=1 THEOS_PACKAGE_SCHEME=rootless GC_PROBE=1
ifeq ($(GC_PROBE),1)
GaodeClean_CFLAGS += -DGAODECLEAN_PROBE=1
endif

include $(THEOS_MAKE_PATH)/tweak.mk
