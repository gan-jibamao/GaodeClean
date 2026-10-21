# GaodeClean · 高德地图 UI 精简

> 纯 UI 层的 Objective-C runtime hook。不依赖 Substrate 私有 API、不抓网络、不改 IPA。

| | |
|:--|:--|
| **版本** | `0.9.13`（冷启动右下按钮「屏幕中部裸奔」修复 · 兜底验位） |
| **门禁** | arm64 / arm64e 双架构 **0 警告**；旧版本串残留 0；arm64e cpusubtype `0x2` |
| **Author** | **jibamao** |
| **Repo** | <https://gan-jibamao.github.io/> · Section `jibamao-Tweaks` |
| **目标** | 高德地图 / AMap `com.autonavi.amap`（**版本限制已取消，全版本自适应**） |
| **架构** | rootless `arm64` · RootHide `arm64e` · TrollFools 注入用裸 `arm64` dylib |
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
| 启动黑屏根因修复 | 0.7.5 | ✅ |
| 适配高德 17.01.0（新开屏体系 + 版本闸门） | 0.8.0 | ✅ |
| 取消版本限制（修复 17.01.1「失效」，全版本自适应） | 0.9.0 | ✅ |
| 拦截「上拉发现」引导 Lottie（17.01.1 新机制） | 0.9.1 | ✅ |
| 冷启动搜索栏闪断修复（120fps 精测 117ms → 0ms） | 0.9.2 | ✅ |
| 冷启动天气行错误位置修复（60fps 精测 350ms 错位 → 0） | 0.9.3 | ✅ |
| 源码审计优化（告警 14→0，死代码清除，行为零变化） | 0.9.4 | ✅ |
| 冷启动 LOGO 中屏闪现修复（半件 130ms → 0） | 0.9.5 | ✅ |
| 回归修复：LOGO 搬运叠压天气（搬运面收归单一） | 0.9.6 | ✅ |
| 200米比例尺误关修复（首次释放后封网 + 位置门槛） | 0.9.7 | ✅ |
| 审计修复 15 项（崩溃面 · 兜底失效 · 热路径 · 构建链） | 0.9.8 | ✅ |
| 冷启动右下按钮「屏幕中部裸奔」修复（兜底显示前验位置） | 0.9.13 | ✅ |

正式包**零诊断埋点** —— 不再写 `Documents/GaodeClean-*.txt`，源文件零磁盘 I/O。
需要取证时可用环境变量 `GAODECLEAN_DEBUG_HOOKS=1`（列出被签名守卫跳过的 Hook）
或 `GAODECLEAN_DEBUG_SPLASH=1`（列出运行时 `WINSplash*` 类）；两者默认**全关**，
打开也只走 `NSLog`，仍不落任何文件。

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

### 构建门禁（0.9.8 起，`make check` 强制）

| 项 | 判据 | 0.9.8 实测 |
|:--|:--|:--|
| 编译告警 | 与 0.9.7 基线逐条比对 | **0**（基线亦 0）|
| 版本串残留 | 旧版本号命中数 | **0** |
| arm64 cpusubtype | 应为 `0x0` | `0x0` |
| arm64e cpusubtype | 应为 `0x2` | `0x2`（fixarch 重算 50 页签名哈希）|
| 载荷路径 | rootless `/var/jb`、RootHide `/Library` | 解包逐条核验通过 |
| `Installed-Size` | 按真实载荷计算 | 198 / 199 KB |

---

## 目录

```
src/GaodeClean.m          当前源码（0.9.8）
src/GCCGeometry.h         几何辅助头
Makefile                  一键构建（arm64 + arm64e + deb + 0 警告门禁）
scripts/mkdeb.py          不依赖 dpkg-deb 的打包脚本（版本/路径全参数化）
scripts/fixarch.py        arm64e cpusubtype 修正 + 签名页哈希重算
scripts/make-roothide.sh  【已废弃】历史脚本，打包请直接用 mkdeb.py
tools/                    逆向分析工具箱（高德升级应对流程，见 tools/README.md）
dist/                     构建产物（当前版本）
HISTORY.md                功能清单 / 版本链 / 根因分析 / 构建配方
```

---

## 构建

### 一键（0.9.8 起）

需要 theos 的 SDK：<https://github.com/theos/sdks> → `iPhoneOS16.5.sdk`

```bash
make SDK=/path/to/iPhoneOS16.5.sdk        # arm64 + arm64e + 两个 deb
make check SDK=/path/to/iPhoneOS16.5.sdk  # 只跑 0 警告门禁
make clean
```

等价的手工命令（`make` 内部就是这两条）：

```bash
SDK=/path/to/iPhoneOS16.5.sdk
CLANG=clang

# arm64 / rootless：lld 支持 -fixup_chains
$CLANG -target arm64-apple-ios15.0 -isysroot $SDK \
  -fobjc-arc -fmodules -O2 -Wall -Wextra -I src \
  -dynamiclib -install_name /Library/MobileSubstrate/DynamicLibraries/GaodeClean.dylib \
  -framework UIKit -framework Foundation -fuse-ld=lld -Wl,-adhoc_codesign \
  -Wl,-fixup_chains \
  src/GaodeClean.m -o dist/GaodeClean-arm64.dylib

# arm64e / RootHide：lld 不支持 arm64e 的 -fixup_chains，且会把 cpusubtype 写成 0
$CLANG -target arm64e-apple-ios15.0 -isysroot $SDK \
  -fobjc-arc -fmodules -O2 -Wall -Wextra -I src \
  -dynamiclib -install_name /Library/MobileSubstrate/DynamicLibraries/GaodeClean.dylib \
  -framework UIKit -framework Foundation -fuse-ld=lld -Wl,-adhoc_codesign \
  src/GaodeClean.m -o dist/GaodeClean-arm64e.dylib
python3 scripts/fixarch.py dist/GaodeClean-arm64e.dylib 2
```

### 打包 deb

```bash
make deb
# 等价：python3 scripts/mkdeb.py --dist dist --control control \
#         --plist GaodeClean.plist \
#         --dylib-arm64 dist/GaodeClean-arm64.dylib \
#         --dylib-arm64e dist/GaodeClean-arm64e.dylib
```

产出 rootless（arm64）与 RootHide（arm64e）两种布局。RootHide 包载荷去掉
`/var/jb` 前缀，`Architecture` 写 `iphoneos-arm64e`，`Depends` 补 `oldabi`。
版本号从 `control` 的 `Version` 字段读，`Installed-Size` 按真实载荷计算。

arm64e 切片有两个坑：lld 不支持它的 `-fixup_chains`（改走经典 `LC_DYLD_INFO` 绑定），
且 lld 会把输出头的 **cpusubtype 写成 0**（dyld 靠它判断是否为 arm64e 映像）。
签名后用 `scripts/fixarch.py <dylib> 2` 修正并重算签名页哈希。

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
0.7.3   滚动热路径收敛
0.7.4   ✗ 后台/静默期收敛（真机有问题，已回退）
0.7.5   启动黑屏根因修复
0.8.0   高德 17.01.0 适配（版本白名单 + WINSplashScreen 判定层）
0.9.0   取消版本限制（修复 17.01.1「失效」；全版本自适应）
0.9.1   拦截「上拉发现」引导 Lottie（17.01.1 GuideLottie 机制）
0.9.2   冷启动搜索栏闪断修复（117ms 消失 → 0ms）
0.9.3   冷启动天气行错误位置修复（350ms 错位 → 0）
0.9.4   源码审计优化（告警 14→0）
0.9.5   冷启动 LOGO 中屏闪现修复（半件 130ms → 0）
0.9.6   回归修复：LOGO 叠压天气（搬运面收归单一）
0.9.7   200米比例尺误关修复（封网 + 位置门槛）
0.9.8   审计修复 15 项（崩溃面 / 兜底失效 / 热路径 / 构建链）
0.9.9   冷启动右下按钮「屏幕中部裸奔」修复（显示路径全覆盖）
0.9.10  右下按钮拦截补几何兜底（getItemTag 晚写入）
0.9.11  显示路径补齐：纯类名判定 + didMoveToWindow
0.9.12  拦截 setFrame:/setCenter: 中部写入
0.9.13  兜底显示前验位置（30 拍硬底线保留）   ← 当前（采用）
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

启动输出：`[GaodeClean] GaodeClean v0.9.13 | jibamao | https://gan-jibamao.github.io/`
