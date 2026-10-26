# GaodeClean · 高德地图 UI 精简

> 纯 UI 层的 Objective-C runtime hook。不依赖 Substrate 私有 API、不抓网络、不改 IPA。

| | |
|:--|:--|
| **版本** | `0.9.29`（搜索栏/底栏收窄 240pt + 伴生层同步 + 发丝线裁除 + 冷启动零闪变；探针代码物理删除） |
| **门禁** | arm64 / arm64e 双架构 **0 警告**（日志剥离开/关**双跑**）；旧版本串残留 0；arm64e cpusubtype `0x2`；**探针与自定义日志零残留**；锚点逻辑按真机数值逐拍仿真 |
| **Author** | **jibamao** |
| **Repo** | <https://gan-jibamao.github.io/> · Section `jibamao-Tweaks` |
| **目标** | 高德地图 / AMap `com.autonavi.amap`（**版本限制已取消，全版本自适应**） |
| **架构** | rootless `arm64` · RootHide `arm64e` · TrollFools 注入用裸 `arm64` dylib |
| **许可** | MIT（见 [LICENSE](LICENSE)） |

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
| 冷启动右下按钮「屏幕中部裸奔」修复（0.9.9→0.9.13） | 0.9.9→0.9.13 | ❌ 未收敛，已回退 |
| 回退 W 系列，恢复 0.9.7 显示语义（真根因：`HomeSettled` 门控被拆） | 0.9.14 | ❌ 真机仍裸露 18-21 帧 |
| 锚点「定格后才锁定」+ 几何不变量 + 未定格不摆位（假设：`SearchBarSettledY` 锁了第一帧） | 0.9.15 | ❌ 真机仍裸露 22 帧 |
| 治本：真凶是 App 原生 `WINLiteWidgetGroupView`（出生即藏 + 未定格按住 + 定格后同刻放行） | 0.9.16 | ✅ 真机 0 帧（本地版 + CI 版各一次复验） |
| ⊙/↰ 间隙对表原生（8pt→20pt）：整组上移 12.4pt，恢复与 2D/3D 的原生间隙 | 0.9.17 | ✅ 真机 Δ=0（图标逐位一致） |
| 车机钮独立间隙 50pt（不再与胶囊共用 20pt） | 0.9.18 | ✅ 真机该项无反馈（2026-10-22） |
| 天气行回原生关系：车机钮正下方、左对齐（不再是「车机钮右侧」） | 0.9.18 | ✅ 真机该项无反馈（2026-10-22） |
| 2D/3D 按钮摆回 ⊙/↰ 胶囊正上方（0.9.18 用文本判定，真机**从未命中**） | 0.9.18 | ❌ 真机反馈「还是没动」 |
| 2D/3D 识别器三级重写 + `WINPermanentCompassView` 类名直钩 + 间隙 13.3 | 0.9.19 | ✅ 真机验收通过（2026-10-22） |
| 清探针、清日志：删诊断模块 + 2 个环境开关 + 全类枚举探针；8 处 `NSLog` 全清（正式包 `[GaodeClean]` 计数 **0**） | 0.9.20 | 🕐 仅构建验证，功能与 0.9.19 同源 |
| **最高级加固混淆**：441 处字面量 / 295 条唯一串全部加密存储 + 运行时解密；`-Wl,-x` 剥离本地符号（`nm -a` 残留 **0**） | 0.9.20 | 🕐 混淆回环 **295/295** 逐字节自证通过 |
| 做爱源详情页与包描述**只讲功能**（界面精简/位置归位/稳定不闪），并给出源地址 | 0.9.21 | 🕐 文案定稿，功能与 0.9.20 一致 |
| 搜索栏/底栏收窄 240pt：独立白底/渐变/描边/环境层同步、发丝线与原生圆角残留裁除、冷启动零闪变 | 0.9.29 | ✅ 真机验收通过（录屏逐帧 + 3x 裁图） |

发布包**零诊断埋点、零自定义日志**（0.9.20 起）：

- 不写任何文件（源文件零磁盘 I/O）；诊断模块与两个 `GAODECLEAN_DEBUG_*` 环境开关**物理删除**，不是关掉
- 8 处 `NSLog` 全部清除；正式包内 `[GaodeClean] ` 字符串计数为 **0**，由门禁第 5 条双零断言守住
- 开发期日志走 `GCLog`：`Makefile.local` 的 `RELEASE=0` 构建才会打印，正式包编译期展开为空操作

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

### 加固与混淆（0.9.20 起，最高级）

| 层 | 措施 | 核验方式 |
|:--|:--|:--|
| 编译 | `-fvisibility=hidden -fno-ident` | 内部符号不外露 |
| 链接 | `-Wl,-x`（剥本地符号）、`-Wl,-dead_strip`（去死代码） | `nm -a` 的 `t/s` 符号 **0** |
| 字符串 | 441 处字面量 / 295 条唯一串加密存储（逐串密钥 + 位置偏移 + 位旋转），运行时 `GCStr.h` 解密并缓存 | 门禁 7a：抽样 6 类敏感明文命中 **0**；7b：中文关键词无残留 |
| 自证 | 主机用**同一份**解码数学把 295 条全部解回明文逐条比对 + FNV 摘要校验 | `PASS 混淆回环 295/295 条逐字节一致` |
| 不做 | 不加反调试 / 反 VM（会与 Dopamine / RootHide 冲突）；系统公开 API 名不加密（App 镜像里本就有） | — |

> `strings GaodeClean.dylib` 现只能读出两条刻意保留的信息：安装路径中的
> `GaodeClean.dylib`，以及版本串 `0.9.20`（由构造函数内存屏障钉住，供门禁与装机核对）。

### 构建门禁（0.9.8 起，`make check` 强制）

| 项 | 判据 | 0.9.20 实测 |
|:--|:--|:--|
| 编译告警 | 与 0.9.7 基线逐条比对 | **0 / 0**（`STRIP=1` 与 `STRIP=0` 双跑均为 0）|
| 版本串残留 | 旧版本号命中数 | **0** |
| arm64 cpusubtype | 应为 `0x0` | `0x0` |
| arm64e cpusubtype | 应为 `0x2` | `0x2`（fixarch 重算 50 页签名哈希）|
| 载荷路径 | rootless `/var/jb`、RootHide `/Library` | 解包逐条核验通过 |
| 锚点逻辑 | 按真机数值（目标 436→701）逐拍仿真 | 旧逻辑 3 拍落中部位；新逻辑 **0 拍** |
| 载荷一致性 | deb 内 dylib 与交付 dylib `cmp` | 双架构**逐字节一致** |
| 探针残留 | 诊断模块 / 环境开关 / 全类枚举探针 | 正式包内命中 **0** |
| 日志残留 | 正式包内 `[GaodeClean]` 自定义日志串 | 命中 **0**（0.9.20 起 GCLog 与 NSLog 全清） |
| `Installed-Size` | 按真实载荷计算 | 198 / 200 KB |

---

## 目录

```
src/GaodeClean.m          当前源码（0.9.20，无探针/无日志）
src/GCCGeometry.h         几何辅助头
Makefile                  ★ 正式构建入口（theos 工程，GitHub Actions 使用）
Makefile.local            本地临时验证构建入口（iSH clang 链，不产出发布资产）
.github/workflows/build-theos.yml  ★ CI：macos-14 + theos，双架构出包 + 门禁 + 打 tag 自动发 Release
scripts/verify_deb.sh     deb 核验门禁（载荷前缀 / 架构切片 / 日志剥离 / 混淆生效 / 符号剥离 / 过滤器）
scripts/gate.sh           ★ 一键门禁（探针口径语法 / make check / 双包 verify_deb / 二进制取证）
scripts/build.sh          ★ 一键出包（生成 control、临时改版本号并保证还原、构建、门禁、交付）
controls/                 历史版本 control 存档（control.trialNN / control.probeNN，各版本可复现）
scripts/gen_obf.py        字符串混淆生成器（可 --from-list 从清单逐字节复现数据头）
scripts/obf_strings.txt   ※ 混淆明文清单 —— **不入仓库、不随源码分发**（仅本机自测用，已在 .gitignore）
scripts/obf_selftest.c    主机回环自测（把密文解回明文逐条比对 + 校验 FNV 摘要）
src/GCStr.h               混淆串解码运行时（懒解码 + 缓存）
src/GCObfMath.h           纯 C 解码数学（主机与设备同一份）
src/GCStrData.h           自动生成：密文表 295 条 + FNV 摘要
scripts/mkdeb.py          不依赖 dpkg-deb 的打包脚本（本地链专用，版本/路径全参数化）
scripts/fixarch.py        arm64e cpusubtype 修正 + 签名页哈希重算（本地链专用）
scripts/make-roothide.sh  【已废弃】历史脚本，打包请直接用 mkdeb.py
tools/                    逆向分析工具箱（高德升级应对流程，见 tools/README.md）
dist/                     本机临时验证产物（★ 正式发布包见 Release，由 CI 构建）
HISTORY.md                功能清单 / 版本链 / 根因分析 / 构建配方
```

---

## 构建

> **★ 2026-10-22 起：所有正式 deb 一律由 GitHub Actions 构建**（`.github/workflows/build-theos.yml`，
> macos-14 + theos，matrix `rootless`/`roothide`）。本地链降级为**临时验证**，产出物不得作为发布资产。

### 正式发布（GitHub CI）

```bash
# 推 main / 手动触发：只出包 + 核验，产物在 Actions artifact
git push origin main
gh workflow run "Build GaodeClean"

# 发版：打 tag 后自动构建并把资产挂到 Release
git tag v0.9.20 && git push origin v0.9.20
```

CI 内部等价于：

```bash
make package FINALPACKAGE=1 THEOS_PACKAGE_SCHEME=rootless   # → iphoneos-arm64
make package FINALPACKAGE=1 THEOS_PACKAGE_SCHEME=roothide   # → iphoneos-arm64e
scripts/verify_deb.sh <deb> <scheme>                        # 门禁，失败即红
```

### 本地临时验证（iSH clang 链，不用于发布）

```bash
make -f Makefile.local check             # 剥离/不剥离 双跑 0 警告门禁
make -f Makefile.local deb               # 本地临时包（仅自检，不作交付）
make -f Makefile.local SDK=/path/to/iPhoneOS16.5.sdk
```

等价的手工命令（`Makefile.local` 内部就是这两条）：

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

### 一键门禁 / 一键出包（0.9.98 新增）

手工跑门禁要记 6 条命令、4 个坑，现在固化进两个脚本：

```bash
# 只跑源码门禁（改完代码先跑这个）
scripts/gate.sh

# 出包（自动生成 control、临时改 kGCVersion、构建、门禁、交付；退出时必定还原源码）
scripts/build.sh release 0.9.98+trial55     # 正式包
scripts/build.sh probe   0.9.98+probe43     # 探针包
```

`gate.sh` 覆盖的四道门禁与它们各自防的坑：

| 门 | 内容 | 防的坑 |
|:--|:--|:--|
| 1 | 探针口径 `clang -fsyntax-only -DGAODECLEAN_PROBE=1` | `make check` 只 grep warning，**抓不到 error** |
| 2 | `make check` | 剥离/不剥离双跑 0 警告 + 混淆回环 295/295 + FNV 基线 |
| 3 | `verify_deb` 双包 | 载荷路径、架构、维护脚本、符号剥离 |
| 4 | 二进制取证 | 正式包探针残留必须 0；钩子符号必须还在；版本串必须可见 |

取证那一关的两个已知陷阱（都写进脚本了）：纯 ASCII 串要用 `strings -a`，带中文的（内存里 UTF-16LE）要用 `strings -a -e l`；`_class_getName` 在正式包里缺失是**正常的**（只被探针块引用）。

`build.sh` 的 `kGCVersion` 还原用 `trap EXIT INT TERM` —— 构建失败或 Ctrl-C 也会还原，不会再出现「源码里留着 probe 版本号」的脏提交。交付目录默认落在 `/var/minis/attachments/GaodeClean-<ver>-<suffix>/`（可用 `DEST=` 覆盖），并附 `control.<suffix>` 存档以便复现。

### 打包 deb（本地链，仅临时验证）

```bash
make -f Makefile.local deb
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
0.9.13  兜底显示前验位置（30 拍硬底线保留）—— 系列失败，已回退
0.9.14  回退 W 系列，恢复 0.9.7 显示语义（假设：HomeSettled 门控被拆）—— 真机仍裸露 18-22 帧
0.9.15  锚点定格后才锁定 + 几何不变量 + 未定格不摆位 —— 真机仍裸露 22 帧
0.9.16  §Z：真凶是 App 原生 WINLiteWidgetGroupView（出生即藏 + 未定格按住 + 定格后同刻放行）
0.9.17  ⊙/↰ 间隙对表原生 8pt→20pt（整组上移 12.4pt）
0.9.18  车机钮 50pt / 天气行回「钮下左对齐」；2D3D 文本识别未命中（真机未动）
0.9.19  §AE：2D3D 真身 = WINPermanentCompassView；三级识别 + 类名直钩 + 间隙 13.3（真机验收通过）
0.9.20  §AF：清探针 + 清日志；§AG：最高级加固（字符串混淆加密 + 链接期符号剥离）
0.9.21  §AH：详情文案「只讲功能」+ 补做爱源地址（功能与 0.9.20 一致）
0.9.29  §AI：搜索栏/底栏收窄 240pt（伴生层同步 + 发丝线裁除 + 冷启动零闪变；探针物理删除）   ← 当前（采用）
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
