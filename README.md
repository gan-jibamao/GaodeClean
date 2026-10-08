# GaodeClean · 高德地图 UI 精简

> 纯 UI 层的 Objective-C runtime hook。不依赖 Substrate 私有 API、不抓网络、不改 IPA。

| | |
|:--|:--|
| **版本** | `0.7.3`（0.7.4 已回退，见 HISTORY §L） |
| **Author** | **jibamao** |
| **Repo** | <https://gan-jibamao.github.io/> · Section `jibamao-Tweaks` |
| **目标** | 高德地图 / AMap `com.autonavi.amap` **17.00.2** |
| **架构** | rootless `arm64` · RootHide `arm64e` |
| **许可** | 私有备份，不对外分发 |

---

## 清理项

| 项目 | 版本 | 状态 |
|:--|:--|:--:|
| 底栏上拉白雾 / 闪白 | 0.5.53 | ✅ |
| 顶部「沉浸高斯」模糊带 | 0.5.8 | ✅ |
| 首页白块 | 0.5.9 | ✅ |
| 冷启动跳动 | 0.5.0 | ✅ |
| 「我的 → 首页」搜索栏闪 | 0.5.58 | ✅ |
| 切 2D/3D 天气行 + LOGO 位移 | 0.6.1 | ✅ |
| 切模式「下坠 17pt 弹回」 | 0.6.2 | ✅ |
| 冷启动天气行不归位 | 0.6.6 | ✅ |
| 底栏偶发「上拉发现」提示 | 0.6.7 | ✅ |
| 「我的 → 首页」比反向慢 | 0.6.9 | ✅ |
| 启动屏广告（偶发填充） | 0.7.1 | ✅ |
| 常驻开销收敛（3 定时器 → 2） | 0.7.2 | ✅ |
| 滚动热路径收敛 | 0.7.3 | ✅ |

正式包**零诊断埋点** —— 不再写 `Documents/GaodeClean-*.txt`，源文件零磁盘 I/O。

---

## 验证记录（逐帧量化）

判据统一为**分区帧间差分**，噪声底取自静止画面。

| 项目 | 改前 | 改后 |
|:--|:--|:--|
| 切页后地图区残差 | `Δ 0.41`，持续 **850 ms** | `Δ 0.00`，**0 帧**超阈 |
| 静止首页地图区（噪声底） | `Δ 0.02 – 0.06` | — |
| 切 2D/3D 天气行位移 | −13 pt（云图标） | 中位漂移 2.0 pt |
| 切模式瞬时下坠 | 4 次 / 664 帧 `−17 pt` | 0 次 |
| 冷启动搜索栏缺席 | 最多 5 帧（≈ 40 ms） | 首帧即在位 |

> 判据踩坑记录见 [`HISTORY.md`](HISTORY.md)：底栏胶囊定位、整页亮度两个指标都曾把结论带反；
> 最终以**参考帧最近邻分类**（取已知正确的帧做标尺）为准。

---

## 目录

```
src/GaodeClean.m          当前源码（0.7.3）
src/GCCGeometry.h         几何辅助头
scripts/make-roothide.sh  rootless deb → RootHide deb 转换
scripts/mkdeb-local.py    不依赖 dpkg-deb 的打包脚本
dist/                     构建产物
HISTORY.md                功能清单 / 版本链 / 根因分析 / 构建配方
```

---

## 构建

### 本机直接编译（iSH / Alpine aarch64，无需 macOS 与 theos 本体）

需要 theos 的 SDK：<https://github.com/theos/sdks> → `iPhoneOS16.5.sdk`

```bash
SDK=/path/to/iPhoneOS16.5.sdk

clang -target arm64-apple-ios15.0 -isysroot $SDK \
  -fobjc-arc -fblocks -fobjc-runtime=ios-15 -O2 \
  -dynamiclib -fuse-ld=lld \
  -Wl,-fixup_chains \
  -Wl,-install_name,@rpath/GaodeClean.dylib \
  -Wl,-adhoc_codesign \
  -framework UIKit -framework Foundation \
  -framework CoreGraphics -framework QuartzCore \
  src/GaodeClean.m -o GaodeClean.dylib
```

### 打包 deb

```bash
python3 scripts/mkdeb-local.py
```

产出 rootless（arm64）与 RootHide（arm64e）两种布局。RootHide 包载荷去掉
`/var/jb` 前缀，`Architecture` 写 `iphoneos-arm64e`，`Depends` 补 `oldabi`。

arm64e 切片有两个坑：lld 不支持它的 `-fixup_chains`（改走经典 `LC_DYLD_INFO` 绑定），
且 lld 会把输出头的 **cpusubtype 写成 0**（dyld 靠它判断是否为 arm64e 映像）。
签名后用 `tools/fixarch.py <dylib> 2` 修正并重算签名页哈希。

### 安装路径

| 环境 | 切片 | 路径 |
|:--|:--|:--|
| rootless / Dopamine | `arm64` | `/var/jb/Library/MobileSubstrate/DynamicLibraries/` |
| RootHide | `arm64e` | `/Library/MobileSubstrate/DynamicLibraries/`（jbroot 内） |

装完 `sbreload` 或重启用户空间。

---

## 版本链

```
0.3.1   基线
0.4.0   底栏两圆钮
0.4.3   圆钮对齐搜索框
0.4.41  冷启动跳动根除
0.5.0   优化清理
0.5.8   顶部模糊带（EmptyImmersiveState 改派）
0.5.9   首页白块
0.5.50  上拉白雾定稿
0.5.58  切页搜索栏闪
0.6.0   摘诊断，定版
0.6.1   切 2D/3D 天气行位移
0.6.2   切模式瞬时下坠弹回
0.6.3   调度链
0.6.6   冷启动天气行归位
0.6.7   底栏「上拉发现」根除
0.6.7b  重写（0.6.7a 卡死已回滚）
0.6.8   切页响应 · 清除残留文件 I/O
0.6.9   快修窗不再空转
0.7.1   开屏广告移除
0.7.2   常驻开销收敛
0.7.3   滚动热路径收敛            ← 当前（采用）
0.7.4   ✗ 后台/静默期收敛（真机有问题，已回退）
```

---

## 标识

源码与产物均带 `jibamao` 标识：

```bash
strings GaodeClean.dylib | grep -i jibamao
# jibamao
# gan-jibamao.github.io
# jibamao-Tweaks
# GaodeClean by jibamao
```

启动输出：`[GaodeClean] GaodeClean v0.7.1 | jibamao | https://gan-jibamao.github.io/`
