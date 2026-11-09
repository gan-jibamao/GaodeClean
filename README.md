# GaodeClean · 高德地图界面精简

> 把高德地图的广告、引导、白雾和乱跑的控件收拾干净。纯运行时 hook，不抓网络、不改 IPA。

| | |
|:--|:--|
| **最新版本** | `0.9.134` |
| **适用** | 高德地图 / AMap `com.autonavi.amap` |
| **支持** | iOS 15+ · rootless（arm64） · RootHide（arm64e） · TrollFools 注入 |
| **版本限制** | 无 —— 按类名与几何特征自适应，不绑定 App 版本号 |
| **许可证** | MIT |

---

## 它做什么

**去广告**

- 开屏广告
- 顶部运营横幅（带「广告」角标的通栏）
- 顶部运营通知条（「请查收：【…】」「…待查收，来领」这类）—— 按**结构**判定，不看文案

**去干扰**

- 底栏上滑白雾 / 闪白
- 顶部「沉浸高斯」模糊带
- 首页白块
- 底栏「上拉发现」引导（含 Lottie 动画）

**修布局**

- 定位/路线胶囊回右下、连接车机回左下，按原生关系摆放
- 搜索栏、天气行归位，切页不闪、不跳
- 冷启动时控件不会先在屏幕中部裸奔再瞬移到底部
- 底栏胶囊收窄至 240pt（可选效果，见下）

**深色模式**

- 跟随系统的深色外观，底栏圆钮、胶囊、搜索钮一并压深
- 「我的」页的整片白底会被正确涂成深色

---

## 安装

### 从软件源（推荐）

在 Sileo / Zebra 添加源：

```
https://gan-jibamao.github.io/
```

搜 **GaodeClean** 安装。装完注销（`sbreload`）或重启用户空间，再打开高德。

### 手动装 deb

到 [Releases](https://github.com/gan-jibamao/GaodeClean/releases) 下载对应架构的包：

| 你的越狱环境 | 下载 |
|:--|:--|
| rootless / Dopamine / palera1n | `*_iphoneos-arm64.deb` |
| RootHide | `*_iphoneos-arm64e.deb` |

两个架构**不要同时装**。

---

## 兼容性

- **不依赖具体 App 版本**。判据全部基于类名与几何特征，高德升级后自动适配；
  目标类不存在时每条 hook 各自静默跳过，不会崩。
- **不加反调试 / 反 VM**，与 Dopamine、RootHide、palera1n 共存无冲突。
- **纯 UI 层**：不拦截网络、不读写 App 数据、正式包不写任何文件。

---

## 装完发现没效果？

1. 确认**完全退出**高德（从后台卡片上滑关掉）再重开，不是切后台。
2. 确认装的是对应架构的包（rootless 装 `arm64`、RootHide 装 `arm64e`）。
3. 部分效果（如胶囊位置）依赖首页布局定型，**冷启动后等 2 秒**再看。

仍然不对，[提 issue](../../issues) 时请附上：高德版本号、越狱环境、现象截图或录屏。

---

## 实现概要

纯 Objective-C runtime hook，约 7600 行单文件实现，零第三方依赖。

- **定位**：`+load` 期按类名找到目标类，钩 `layoutSubviews` / `didMoveToWindow` / 各 setter；
  未命中则静默跳过。
- **同步**：一个 `CADisplayLink` 帧级驱动器 + 一个 5Hz 兜底 tick。
  帧级负责"任何通道动了控件，下一帧提交前纠回"，5Hz 负责发现新实例。
- **判据**：一律用几何不变量（位置/尺寸/层级关系），不用文案、不用版本号、不用颜色阈值
  判断"这是哪个控件"——除深色判定外，那条只能靠屏幕亮度采样（高德自锁了浅色 trait）。
- **加固**：295 条字符串加密存储、链接期剥离本地符号，`strings` 读不出实现线索。

细节、根因分析、踩过的坑都在 [`HISTORY.md`](HISTORY.md)。

---

## 构建

正式包一律由 GitHub Actions 构建，不在本地交叉编译。

```bash
# 推分支：只出包 + 门禁，产物在 Actions artifact
git push origin main

# 发版：打 tag 后自动构建并发布到 Release
git tag v0.9.134 && git push origin v0.9.134
```

CI 流程：`ubuntu-latest` + theos（commit 固定）+ iPhoneOS SDK（commit 固定），
矩阵 `rootless` / `roothide` 各出一包，跑 `scripts/verify_deb.sh` 门禁，
失败即红；commit 或 SDK 固定保证产物可复现。

本地只做临时验证（iSH clang 链，产出**不可发布**）：

```bash
make -f Makefile.local check SDK=/path/to/iPhoneOS16.5.sdk   # 0 警告门禁 + 单测
make -f Makefile.local arm64 SDK=/path/to/iPhoneOS16.5.sdk   # 只编 arm64 自测
```

> ⚠️ 本机 lld 产出的 **arm64e 切片会导致真机 dyld 崩溃**（`bad bind opcode`），
> 门禁已内建拦截。arm64e 只能由 CI 的完整 LLVM 产出。

### 门禁覆盖什么

`make check` + `scripts/gate.sh` 共 237 项断言，主要防这几类事故：

| 项 | 判据 |
|:--|:--|
| 编译告警 | `STRIP=1` / `STRIP=0` 双跑均为 0 |
| 单测 | 几何判据、胶囊豁免、安全阀、字号边界、深色判定 |
| 混淆回环 | 295/295 条密文解回明文逐字节一致 + FNV 摘要 |
| 版本串 | `control` 与二进制体内一致，无旧版本残留 |
| arm64e 绑定 | 必须带 `LC_DYLD_CHAINED_FIXUPS`，否则真机必崩 |
| 载荷 | 路径前缀、架构切片、依赖、过滤器逐项核验 |
| 洁净度 | 正式包内 `[GaodeClean]` 日志与探针串命中 0 |

---

## 目录

```
src/GaodeClean.m                  主实现（单文件）
src/GCStr.h / GCStrData.h         字符串加密表与运行时解码
src/GCObfMath.h                   纯 C 解码数学（主机与设备同一份）
src/GCCGeometry.h                 几何辅助

Makefile                          正式构建入口（theos）
Makefile.local                    本地临时验证入口（不作发布）
.github/workflows/build-theos.yml CI：双架构出包 + 门禁 + 打 tag 发 Release

scripts/verify_deb.sh             deb 核验门禁
scripts/gate.sh                   一键门禁（语法 / make check / 双包 / 二进制取证）
scripts/obf_selftest.c            混淆回环自测
scripts/mkdeb.py                  本地打包（不依赖 dpkg-deb）
scripts/fixarch.py                arm64e cpusubtype 修正 + 签名页哈希重算

tests/                            纯 C 单测（几何判据 / 深色 / 安全阀）
tools/ldid/                       CI 用的静态 ldid 二进制（避免依赖外部 CDN）
HISTORY.md                        版本链 / 根因分析 / 踩坑记录
```

---

## 已知限制

- **「我的」页个别自绘位图无法压制**：部分白底来自 App 自己渲染的位图，不是视图背景色，
  hook 改不到。这是 0.9.111~0.9.117 最终被回退的原因。
- **深色判定靠屏幕采样**：高德把 `overrideUserInterfaceStyle` 锁成 Light，
  系统 trait 不可信，只能按屏幕亮度判断，切换瞬间可能有一两帧过渡色。
- **底栏胶囊收窄**会改变原生间距，若你觉得某些按钮位置变得不习惯，
  可以反馈，我出一版不带收窄的。

---

## 许可

MIT，见 [LICENSE](LICENSE)。
