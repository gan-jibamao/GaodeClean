# GaodeClean · 高德地图 UI 精简

| | |
|---|---|
| **Author** | **jibamao** |
| **Repo** | https://gan-jibamao.github.io/ |
| **Section** | `jibamao-Tweaks` |
| **Current** | **0.6.6**（定版） |
| **Target** | 高德地图 / AMap `com.autonavi.amap` **17.00.2** |
| **License** | 私有备份，不对外分发 |

纯 UI 层的 ObjC runtime hook —— 不依赖 Substrate 的私有 API、不抓网络、不改 IPA。

## 清理项（全部逐帧量化验证通过）

| 项 | 状态 |
|---|---|
| 底栏上拉白雾 / 闪白 | ✅ |
| 顶部沉浸式高斯模糊带 | ✅ |
| 首页白块 | ✅ |
| 冷启动跳动 | ✅ |
| 「我的 → 首页」切页时搜索栏闪 | ✅ |
| 切 2D/3D 时天气行 + LOGO 位移 | ✅ |
| 切模式「瞬时下坠 17pt 弹回」 | ✅ |
| 冷启动后天气行不归位 | ✅ |

正式包零诊断埋点（不再写 `Documents/GaodeClean-*.txt`）。

## 目录

```
src/GaodeClean.m       当前源码（0.6.6，带 jibamao 标识）
src/GCCGeometry.h      几何辅助头
scripts/make-roothide.sh  rootless deb → roothide deb 转换
dist/                  构建产物（dylib + 两种 deb）
HISTORY.md             功能清单 / 版本链 / 根因分析 / 完整构建配方
```

## 构建

```bash
clang -target arm64-apple-ios15.0 \
  -isysroot $THEOS_SDK -I src \
  -fobjc-arc -fblocks -fobjc-runtime=ios-15.0 \
  -dynamiclib -fuse-ld=lld \
  -Wl,-fixup_chains -Wl,-install_name,@rpath/GaodeClean.dylib -Wl,-no_adhoc_codesign \
  -framework UIKit -framework Foundation -framework CoreGraphics -framework QuartzCore \
  src/GaodeClean.m -o GaodeClean.dylib
ldid -S GaodeClean.dylib
```

## 版本链

```
0.6.0  摘诊断，定版
0.6.1  切 2D/3D 天气行位移
0.6.2  切模式瞬时下坠弹回
0.6.3 / 0.6.4  调度链（未成功）
0.6.6  冷启动天气行归位  ← 当前定版
```

## 标识

源码与产物均带 `jibamao` 标识，可用 `strings` 核对：

```bash
strings GaodeClean.dylib | grep -i jibamao
# jibamao
# gan-jibamao.github.io
# jibamao-Tweaks
# GaodeClean by jibamao
```

启动时输出：`[GaodeClean] GaodeClean v0.6.6 | jibamao | https://gan-jibamao.github.io/`
