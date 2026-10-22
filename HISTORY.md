# GaodeClean — 开发记录

> 高德地图 UI 精简 tweak。纯 ObjC runtime hook，不依赖 substrate 私有 API，
> 不碰网络与 IPA，只改视图层。

| | |
|:--|:--|
| **当前版本** | `0.9.16` |
| **Author** | **jibamao** — <https://gan-jibamao.github.io/> · Section `jibamao-Tweaks` |
| **目标** | 高德地图 / AMap `com.autonavi.amap`（**版本限制已取消，全版本自适应**） |
| **架构** | `arm64`（rootless / TrollFools 注入）· `arm64e`（RootHide） |
| **未采用** | `0.7.4`（真机有问题，已回退，见 §L） |

---

## 一、功能清单

### 底栏

| 功能 | 版本 |
|:--|:--|
| 两钮居中 + 胶囊（选中视图）跟随 | 0.3.1 / 0.4.13–0.4.17 |
| 上拉「白雾 / 闪白」根除 | 0.5.44 / 0.5.50 / 0.5.53 |
| 「上拉发现」引导提示根除 | 0.6.7 |

### 首页

| 功能 | 版本 |
|:--|:--|
| 搜索栏下沉 + 首帧锁定 + `setFrame`/`setCenter` 钳位 + 重挂自愈 | 0.4.19 / 0.4.45–0.4.50 |
| 搜索栏去文字（城市名 / 滚词） | 0.4.7 / 0.4.8 |
| 冷启动跳动根除 | 0.4.41 / 0.5.0 |
| 顶部「沉浸高斯」模糊带根除 | 0.5.8 |
| 白块根除（`sheet` / `maskView` / `bottomMaskLayer`） | 0.5.9 |

### 控件对齐

| 功能 | 版本 |
|:--|:--|
| 左侧车机圆钮、右下组合钮对齐到搜索框上方 8 pt | 0.4.3 / 0.4.4 / 0.4.40 |
| 天气行 + LOGO 移到车机钮右侧、冷启动即归位 | 0.6.1 / 0.6.2 / 0.6.6 |
| 探索 / 附近 / 我的页裁剪与滚动限制 | 0.3.1 |
| 来扫街 + 扫街榜隐藏 | 0.4.7 |

### 稳定性

| 项 | 版本 |
|:--|:--|
| 切页 8 ms 快修（搜索栏归位提速） | 0.5.57 / 0.5.58 |
| 切「我的 → 首页」不再慢一拍 | 0.6.8 / 0.6.9 |
| 正式包**零诊断埋点**，源文件**零磁盘 I/O** | 0.6.0 / 0.6.8 |
| 启动屏广告移除 | 0.7.1 |
| 常驻开销收敛（3 定时器 → 2，全树遍历 -80%） | 0.7.2 |
| 滚动热路径收敛（事件源 + bringSubviewToFront + clip path 缓存） | 0.7.3 |
| 冷启动兜底解耦（逐成员补显示，控制件不再永久隐藏） | 0.9.8 |
| 热路径缓存（广告关键词 / 天气行类名 / `Kind()`） | 0.9.8 |
| 全类枚举有界化 + 诊断探针默认关 | 0.9.8 |

---

## 二、问题档案

每个案例固定五段：**现象 → 量化 → 根因 → 修法 → 验证**。

### A. 底栏上拉「白雾 / 闪白」（0.5.44 → 0.5.50）

**现象** — 底栏首页 / 我的往上滑动松手时，地图被一层白蒙住，短暂后消失。

**量化** — 逐帧最小二乘回归：`out = 0.2035 × in + 204.22`
→ **一层纯白 alpha≈0.80 的覆盖层**，只盖地图区（y > 59 pt），底栏与搜索栏不受影响。

**根因** — **连打 6 版空枪**：钳 `MapWidgetContainerView` alpha、钳 `AMap3DView` alpha、
钳 `layer.opacity`、拦 VMap `setGlobalShowMask:`、封 `WINMapMaskView`、封 `AUGlobalBlurService`
—— 诊断全部显示「钳位记录为空 / 该 setter 从未被调用」。
地图是 C++ 引擎（VMap）直接画在 `AMap3DView` 的 backing layer 上，**无子视图、无子层**，UIKit 层够不着。

**决定性对照** — 逐帧扫 0.5.30 的老视频 → 全程无闪白。
**结论：闪白是 tweak 自己造的。** 真根因是 0.5.45 起加的各种「拦截上拉」
（拒绝手势 / 拒绝 PullUp 状态跃迁 / 强行 hidden 面板）**打断了 app 的转场动画**，
地图被留在「已洗白」的中间态几十毫秒。

**修法** — 只对 `WINTabBar` / `WINMultiStyleRootView` 的**本体**摘 pan/swipe，
**绝不碰子树**（子树里有搜索栏），不拦状态机、不抢 `setHidden`。转场正常跑完 → 不闪。

**验证** — 0.6.0 逐帧：地图区 std 全程未掉出正常区间（真压白会掉到 1–5）→ **通过**。

> 0.5.51 / 0.5.52 曾误回退到 0.5.44（把 0.5.50 的修复删掉）→ 闪白回归；0.5.53 装回。

---

### B. 「我的 → 首页」切页时搜索栏闪一下（0.5.54 → 0.5.58）

**现象** — 切到首页的瞬间搜索栏缺席约 40 ms。

**量化** — 逐帧实测搜索栏区域亮度掉到 **216–226 档**（正常 254）即「缺席」。

**排除顺序（重要方法论）**
1. 拦 `layoutSubviews` 强制 `hidden = NO` → 无效
2. 拦 `setHidden:` 定向拒绝 → 无效
3. 拦 `didMoveToSuperview` 重挂 → 无效

→ 说明不是「谁藏了它」，而是**归位逻辑跑得太慢**。

**根因（代码级）** — 搜索栏归位只发生在 `LayoutMinimalHome` 里，而它**只由 100 ms 的
Schedule tick 驱动**。实测缺席时长恰好是 **16.7 ms 的整数倍（17 / 33 / 67 / 83 / 100 ms）**
—— 就是在「等下一次 tick」。

进一步（0.5.56 才查清）：app 切页是把搜索栏 **`removeFromSuperview`**（不是 `hidden`），
而既有守卫写成 `b.superview && ...` —— **恰好把「被摘掉」（`superview == nil`）
这个唯一要管的场景跳过了**。

**修法**
- 0.5.57 `KickBarFix()`：搜索栏一被 app 动到就启动 16 ms 快修窗口，640 ms 内以 60 Hz 反复跑
  `LayoutMinimalHome`。100 ms → 33 ms。
- 0.5.58 不再等 `selectedViewControl` 翻转（app 切页完成才翻，实测 ~33 ms 延迟），
  被摘的同一瞬间直接挂回并显示；快修提到 8 ms。

**验证** — 三次切页零缺席（仅冷启动首帧 1 帧，属设计内首帧锁定）→ **通过**。

---

### C. 切 2D/3D 时「天气 + LOGO」位置跳变（0.6.1）

**现象** — 切换地图 2D / 3D，天气与 LOGO 位置变动。

**量化**（pt 标尺读原生分辨率裁剪）

| 元素 | 2D (f171) | 3D (f189/195) | 位移 |
|:--|--:|--:|--:|
| ☁ 云图标 | 58 | 45 | **−13 pt** |
| 30°C | 76 | 65 | **−11 pt** |
| 🔷 高德地图 LOGO | 118 | 105 | **−13 pt** |
| 比例尺 | 215 | 215 | 0 |

同时车机钮 pt 18-45 → 22-50（右移 4 pt）—— **天气行与车机钮反向移动**，
说明不是 app 整体重排，而是「我方对齐丢了」。

**根因** — `HookWeatherRow` 两个脆弱点：
1. 钩子写成 `if (!objc_getAssociatedObject(v, &AlignedKey)) return;`
   —— 依赖「缓存实例 + 一次性标记」。切 2D/3D 时 app **重建地图控件树**，
   新实例没有 `AlignedKey` → 钩子第一行就 return。
2. `CachedRow` 的失效判据是「旧实例的 window 没了」，但切模式时旧实例常常还挂着
   → 缓存一直指着旧的。

**修法** — 钩子改为**按尺寸自识别**（宽 150–360、高 <40、y 落在地图区、且当前是首页），
认「行」不认「实例」；缓存失效条件补上「尺寸不再匹配」。

**验证** — 云图标高饱和蓝质心追踪，全片 1168 帧中位 pt 68.7，
唯一偏移段 f893–f905 仅 Δ2.0 pt（转场边界噪声）→ **通过**。

---

### D. 切 2D/3D 时天气行「瞬时下坠 17 pt 再弹回」（0.6.2）

**量化** — 云图标质心逐帧（664 帧 / 5.5 s）：

| 事件 | 峰值 | 回落 |
|:--|--:|:--|
| f215-216 | 388.7（−16.9 pt） | f217 |
| f252-253 | 389.0（−17.5 pt） | f254 |
| f575-576 | 388.6（−16.7 pt） | f577 |
| f613 | 384.4（−9.3 pt） | f614 |

y 序列 `389 → 383 → 380 → 379`（掉下去再弹回来）。**车机钮（对齐基准）y=385.8 全程纹丝不动**
→ 不是基准漂移，是 **app 在推这一行**，我的修正晚 3–4 帧才追上，且写入走隐式动画。

**★ 0.6.1 为什么漏掉它** — 偏移检测器写的是「持续 ≥8 帧才算异常」，
而**这事件只持续 1–4 帧**，整个被跳过 → 得出了错误的「位置稳定」结论。
**教训：瞬态（1–4 帧）事件必须用「瞬时偏离」检测，不能用「持续段」检测。**

**修法**
1. `AlignWeatherRow` 的写入包进 `[CATransaction setDisableActions:YES]`；
   偏差 >2 pt 时 `[row.layer removeAllAnimations]`（否则修正本身也走动画）。
2. **拦截 `WINGroupMapWidget -setCenter:` / `-setFrame:`** —— app 有些时刻不走
   `layoutSubviews`、直接写位置；现在一写就同步纠回，同一个 runloop 内完成。
3. 抽出 `IsWeatherRowView()` 尺寸自识别助手，与 `layoutSubviews` 钩子共用。

**验证** — 4 次事件全部消除 → **用户确认通过**。

---

### E. 冷启动后天气行停在原生位置、切一次页才归位（0.6.6）

**★ 定位方式：放弃视频，改加诊断块。** 前四版（0.6.1–0.6.5）都在用视频猜，
每次都改「何时查找 / 如何对齐」，全部无效。0.6.5d 在 dylib 里加了一段诊断
（每 5 拍把 tick 状态 + `WINGroup*` 视图树写进 `Documents/GaodeClean-cold.txt`），
用户导出后**一次定位**：

```
tick#20 ColdTicks=20 win=有 Car=WINDeviceInterconnectWidget
   WINScaleLineLogoMapWidget {{10,411},{188,20}} hid=0 ok=1
   NMScaleLineView           {{96,411},{102,20}} hid=0 ok=0
```

**日志给出的三条硬事实**
1. **tick 在跑**（tick#20）→ 0.6.4 的断链修复有效
2. **`CachedCar` 正常**（车机钮已找到）
3. **`WINGroupMapWidget` 整个不在视图树里**；承载这一行的是子件
   `WINScaleLineLogoMapWidget`，位置仍是原生 `{{10,411}}`。
   而且它**通过了原有尺寸判据**（`ok=1`）→ **判据没错，错的是类名**

**根因** — 所有查找都硬编码 `WINGroupMapWidget`：

| 状态 | 视图树里有什么 | 结果 |
|:--|:--|:--|
| 正常态（切页后） | 容器 `WINGroupMapWidget` 存在 | 找得到 → 归位 ✅ |
| 冷启动态 | 容器尚未创建，只有子件 `WINScaleLineLogoMapWidget` | 永远找不到 → 不归位 ❌ |

这正是「冷启动后位置不对、切一次页才对」：切页会把容器建出来。

**修法** — `IsWeatherRowClass()` 认三个类名
（`WINGroupMapWidget` / `WINScaleLineLogoMapWidget` / `WINWeatherLimitView`）；
查找时**优先外层容器**，否则取最宽候选。`layout` 与 `layoutSubviews` 两个钩子都挂上，
tick 路径去掉「只在首页」限制。

**验证** — f1–f261 在原生位置；**f301 起出现在车机钮正右边**，
🔷高德地图 pt 85–145、200米 pt 165–215，左边缘 pt 85（期望 86）→ **通过**。

---

### F. 冷启动后底栏首页偶发显示「上拉发现」（0.6.7）

**现象** — 冷启动后底栏左钮（首页）在图标位置渲染出黄色「上拉发现」提示，右钮正常。偶发。

**根因（三条通道全漏）**
1. **时机** — 0.5.1 的 `HideDiscoverPrompt` 只挂在 `WINTabBar -layoutSubviews` /
   `-amap_relayoutTabItems`。而提示是**异步引导态**，常在最后一次布局**之后**才写进 label
   —— 那一拍扫空，再没有下一次布局触发 → 留在屏幕上。冷启动才偶发，正是因为
   引导态与布局的先后顺序取决于启动耗时。**没有周期通道，是这个 bug 存在的根本原因。**
2. **判据** — `NodeText` 只对 `UILabel` 读 `text`、对 `AJX*` 前缀读 `attributed*`；
   其它自定义 label 类只能靠 `accessibilityLabel` 撞运气。
3. **处置** — 即便扫到也只是 `hidden = YES`。引导态复用的就是 item 的标题 label，
   隐藏它等于把「首页」两个字一起抹掉。

**修法（只作用底栏子树，零全局钩子、零新增定时器）**
- **时机** — 复用已在跑的 200 ms tick 调 `SweepTabBarHints(CachedTabBar)`；
  另挂 `WINTabBarItem -didMoveToWindow`。
- **范围** — 只走 `WINTabBar` 子树（20–40 个视图，上限 200），扫描体内**没有
  `convertRect:`、没有窗口遍历**。
- **文本来源** — `TabBarTextOf()` 任何类依次试
  `text / attributedText / attributedString / title / tipText / hintText`，
  用 `TextGetterCache` 按类缓存可用 getter，之后每拍只剩几次 msgSend。
- **判据** — 含「上拉」且长度 ≤24（「发现」单独出现不算）。
- **收尾** — 向上找到所属 `WINTabBarItem` → 写回历史标题 → 无则取
  `item.model.title / text / name / tabTitle / displayName` → 都拿不到（纯引导浮层）才隐藏，
  且只向上收 3 层、遇 `WINTabBar` / `WINTabBarItem` 即止。

**⚠ 0.6.7a 卡死事故（必须记住）**

第一版用了两条「看起来更彻底」的手段，直接把 app 拖死：

1. `Replace(UILabel.class, @selector(setText:))` / `setAttributedText:`
   → **全 app 每个 label 的每次写文本**都要过一次 `imp_implementationWithBlock`，主线程直接打满。
2. 每 200 ms（外加命中后 0.8 s / 16 ms 快窗）`SweepAllWindowsForHints`
   → **全窗口 BFS + 逐节点 `convertRect:`**，一窗几千个视图。
3. 构造函数里还开了那个 16 ms 定时器 —— 冷启动最重的时候扫全窗口。

**铁律**
> 给 UIKit 打补丁，钩子必须落在**目标类**上，绝不能落在基类 / 基框架类
> （`UILabel` / `UIView` / `CALayer`）。
> 周期性扫描**必须先有范围上界，再谈频率**。

**顺带修掉的既有隐患** — `WINTabBar -amap_relayoutTabItems` 在本文件被 `HookVoid`
装了两次，而 `Replace()` 走 `method_setImplementation` —— 后装的那次会把先装的
（`CenterTabButtons` / `HideDiscoverPrompt`）**顶掉**。加钩子前先查重复对：

```python
re.findall(r'HookVoid\("([^"]+)",\s*@"([^"]+)"', src)
```

---

### G. 「我的 → 首页」比反向慢一拍（0.6.8，未修好）

**现象** — 用户报的是**方向不对称**（我的→首页慢，首页→我的快），不是单纯慢。

**三处不对称**
1. **早退门** — `LayoutMinimalHome` 的
   `if (!parent.window || ![tabBar isKindOfClass:UIView.class]) return;`
   切页转场中间态 `parent.window` 还是 nil，整拍丢掉，只能等下一次 100 ms tick。
   反向（首页→我的）只走 `!home` 分支的 `bar.hidden = YES` 一次完事，**不经过这道门**。
2. **快修窗被动** — `KickBarFix()` 只挂 `WINQuickSearchBarV2 -didMoveToSuperview` /
   `-setHidden:`，要等 app 先动搜索栏才启动。
3. **底栏布局路径上的残留文件 I/O** — `CenterTabButtons` 末尾调 `LogCoveringViews(bar)`：
   `Flatten(win)` 整棵窗口树 + 拼最多 130 行写 `Documents/GaodeClean-cover.txt`。
   **0.6.0 宣布「正式包零诊断」时漏了这一处**，一直挂在 `WINTabBar -layoutSubviews` 上。

**修法** — `KickBarFixFor(seconds)` 参数化；新增 `WatchHomeTransition()`；
直接钩 `WINTabBarControl -setSelectedViewControl:`；早退分支改开 160 ms 快修窗
（`BarFixStalls` 封顶 60 段 ≈9.6 s，否则 8 ms 循环会无限自旋）；
删除底栏布局路径全部文件 I/O。

**结果** — ❌ **没修好。** 我只改了「开窗时机」，没碰「窗里干了什么」。见 H。

---

### H. 「我的 → 首页」慢：逐帧定位到快修窗空转（0.6.9）

**★ 先分清「哪一帧才是运动」**

多个判据先后把我带偏：

1. **底栏胶囊定位** — 我测的是**胶囊底色的列亮度**，它给出的是「底栏本体中较亮的那一大块」，
   与图标高亮位置无关 → 整段读出反的。
2. **整页亮度** — 「我的」页里那张**彩色世界地图**（饱和度 >20 的像素占比 0.89）
   让 `mapness` 误判成首页。
3. **最终自洽方案** — **参考帧最近邻分类**（f300=首页、f400=我的，取整页像素 L1 距离最近者）。

用它得到的结论才可信：**两个方向的内容到位时延几乎一样**
（mine→home 50 / 58 / 50 ms，home→mine 18 / 67 / 67 ms）→ **慢的不是页面内容**。

**真信号 = 分区帧间差分**（噪声底取自静止画面：首页地图区 Δ=0.02–0.06）

| 区间 | mine→home | home→mine |
|:--|:--|:--|
| 搜索栏带 y750-840 | 0.04 – 0.33 | **0.00** |
| **地图区 y150-700** | **0.41 → 0.22，持续到 t+0.85 s** | **0.00** |
| 底栏带 y860-920 | 1.37 → 收敛 | 2.00 → 收敛 |

**根因** — `LayoutMinimalHome` 里写的是**无条件** `bar.frame = ...` +
`[parent bringSubviewToFront:bar]`，而快修窗每 8 ms 跑一次它 ——
等于切页后几百毫秒里每 8 ms 给搜索栏设一次 frame 并重排父视图的兄弟层级。
**反向（`!home`）只走一句 `bar.hidden = YES; return;`，根本不碰这些** —— 不对称就出在这里。

**修法**
1. 先算期望 frame，`CGRectEqualToRect` 相等就不写。
2. 层级单独判 —— 只有搜索栏真被压在兄弟视图之下才 `bringSubviewToFront:`
   （它比设 frame 重）。
3. `sheet` / `maskView` / `bottomMaskLayer` 同理，只在需要时写。
4. 新增 `BarFixIdle`：连续 6 拍（≈48 ms）没有任何改动 → **立刻收窗**，
   不再把 640 ms 空转完。

**验证（同一口径对照）**

| 分区（切页后 0.75 s 内） | 0.6.8 | **0.6.9** |
|:--|:--|:--|
| 搜索栏带 | 0.04 – 0.33 | **0.00** |
| **地图区** | **0.41，持续 850 ms** | **0.00**（超阈帧数 **0**） |
| 底栏带 | 1.37 → 收敛 | 0.00 – 1.23 → 收敛 |

四个切页点（mine→home ×2、home→mine ×2）切完那一帧之后三个分区**同时归零**，无尾巴。
地图区连续超过噪声底（0.10）的帧数 **50 → 0**。
冷启动段（f1–f115）不受影响，两个方向均验。

---

### I. 启动屏广告「偶发」出现（0.7.1）

**现象** — 开屏广告不是每次冷启动都出现。

**为什么偶发** — 广告 SDK 按**填充率**决定是否展示：有素材才弹，没有就直接进 App。
所以**不能只在某个固定时机扫一次** —— 这正是 0.6.7「上拉发现」踩过的同一个坑
（只挂 `layoutSubviews`，晚到的内容就漏了）。

**先查真名，再动手（关键方法论）**

不去猜类名，而是回到**高德 17.00.2 的二进制字符串表**里核对。结论非常干净：

- 高德广告走**阿里广告聚合 SDK**，命名空间是 **CNG**（另有 `CNBSplash`）：
  `CNGLaunchSplashView` / `CNGLaunchSplashImageView` / `CNGLaunchSplashPrefetchAdsCache` /
  `CNGSplashAdsConfigManager` / `CNGDoubleSplashCoordinator` / `CNGCSJ*SplashAd` /
  `CNGMSBaseSplashAd` / `CNGMSDirectSplashAd` …
- 方法层：`isSplashAd` / `hasSplash` / `isShowSplash` / `isSplash` /
  `showSplashAd` / `showSplashAdInWindow` / `showSplashViewInRootViewController`
- **远端配置键**：`ad_splash_enable` / `_ad_splash_enable` / `ignore_splash_ads` /
  `ft_ad_splash_enable_key`

**修法（四层，全部有界）**

1. **运行时发现真类** —— `objc_getClassList()` 遍历所有已注册类，
   取类名前缀属于广告命名空间（`CNGLaunchSplash` / `CNGSplashAds` / `CNBSplash` …）的类，
   再按**真实 selector** 挂钩：
   - 方法名以 `showSplash` / `beginToShow*SplashAd` 开头 → 换空实现
   - 方法名是 `isSplash*` / `hasSplash` / `isShowSplash` → 返回 `NO`
2. **签名严格校验** — 换空实现前核对：返回类型必须是 `v`、参数个数与 block
   **逐一对应**（`numberOfArguments` 含 self/_cmd，2→无参、3→一参、4→两参）。
   **只钩「这个类自己实现」的方法**（`class_copyMethodList` 判定），
   否则 `Replace()` 会退化成 `method_setImplementation` 改到**父类**，波及全部子类。
3. **窗口/视图兜底** — `UIWindow -addSubview:`（窗口加视图的瞬间）、
   `UIViewController -presentViewController:`（模态广告）、
   以及启动 / 回前台后 15s 内由已有 200ms tick 兜底扫描。命中判据：
   类名含广告 SDK 词 + 覆盖窗口 ≥60% 面积；**绝不隐藏 App 主窗口**
   （主窗口 = 承载底栏的那个窗口，`CenterTabButtons` 里记下）。
   裸 `ad` 不进关键词表 —— `header` / `download` / `shadow` 全会误伤。
4. **懒加载补扫** — 启动后 1s / 3s 各再发现一次（一次性，非周期），
   回前台时也重扫；广告 SDK 常是懒注册的。

**成本** — 不新增任何定时器（仍是 0.6.9 的 4 个）；`UIWindow -addSubview:` 调用频率极低，
不是热路径；类发现只在启动 / 回前台 / 两个延迟点各跑一次，有 200 节点上限。

**待真机确认** — 类名与 selector 全部来自二进制字符串表核对，但
**「哪个 selector 是运行时真正被调用的那个」必须装机验证**：
启动 10 次看广告是否 0 次出现，并看 Console 里
`[GaodeClean] splash guard hooked N: …` 有没有命中。

### J. 常驻开销收敛（0.7.2）

**审计（每秒，源码逐行核对）**

| 源 | 频率 | 每次做什么 |
|:--|--:|:--|
| Schedule | 5.0 | `CleanPage × Pages`：全树 `Flatten` ≤2000 + 每节点 2–6 次 msgSend ← **最重** |
| actionTimer | 3.3 | 白雾全窗 BFS ≤6000 + 每节点 `convertRect`；手势剥离全窗 BFS ≤6000 |
| gt | 2.5 | 全窗 BFS ≤6000（剥手势） |

合计 **≈10.8 次唤醒 + 5.8 次全树遍历**。

**修法（不改变任何清理行为，只改「何时跑」和「跑多远」）**

1. **`CleanPage` 改事件驱动 + 5 拍兜底** —— 加 `full` 参数：非全量拍且已匹配时
   跳过 `Flatten` 锚点匹配段（全树扫描 5/s → 事件时 + 1/s）。事件源：
   `AJX3View -layoutSubviews` / `-didMoveToWindow`（app 动内容必触发）、
   `WatchHomeTransition`（切页）、`Capture`（AJX 元素重建）—— 置 `CleanForce`。
2. **两个常驻定时器并入主 tick** —— `actionTimer`(300ms) 与 `gt`(400ms) 删除，
   白雾扫描每拍跑（节点上限 6000 → **600**，白雾是顶层覆盖物浅层就能找到），
   手势剥离每 2 拍（6000 → **1200** / **400**）。唤醒 10.8/s → **5/s**。
3. **`NodeText` 按类缓存** —— AJX 判定每类只做一次（原来每节点都要
   `NSStringFromClass` + `hasPrefix`），CleanPage 每拍上千节点的 msgSend 直接减半。
4. **天气行查找 ×2 的窗口 BFS 上限 20000 → 2000**（都在地图控件浅层）。
5. **`SweepLog` 纯泄漏删除** —— 它只增不减，而写文件的代码 0.6.0 就删了。

**待真机确认** —— 白雾/手势扫描降频到 400ms 后，若切页时白雾回归
（地图区 Δ 掉到 1–5），把白雾扫描改回每拍；其余项无此风险。

### K. 0.7.2 的 CleanPage 降频实际上没生效（0.7.3）

**自查发现** — 0.7.2 把 `CleanForce` 挂在 `AJX3View -layoutSubviews` 和 `Capture` 上，
想做成事件驱动。但这两个钩子在**滚动 / 元素重渲染时每帧都触发**：

- `AJX3View -layoutSubviews`：滚动动画里每帧触发（卡片位移、折叠展开）
- `AJXBaseElement -reloadView` / `-layoutSubViews`（Capture 的钩子）：
  元素重渲染，滚动时每帧多次

→ `CleanForce` 几乎每拍都成立，`fullClean` 几乎每拍都是 YES，
**0.7.2 想要的「CleanPage 降频」实际上被自己的事件源抵消了**。

**另外两处滚动热路径**（逐行审计 UpdateMask 在 `setBounds:` / `setContentOffset:`
钩子里的调用频率发现）：

| 位置 | 问题 | 频率 |
|:--|:--|:--|
| `UpdateMask(kind 2/3)` | 每帧无条件 `bringSubviewToFront:` —— 父视图层级每帧重排 | 60–120 Hz |
| `UpdateMask(kind 1)` | 每帧重建 `UIBezierPath` + `CGPath`（搜索页滚动时） | 60–120 Hz |

**0.7.3 修法**
1. **事件源收敛**：`CleanForce` 只保留 `didMoveToWindow`（真页面挂载）+
   `WatchHomeTransition`（真切页）。`layoutSubviews` / `Capture` 不再置强制位 ——
   5 拍（1 s）兜底已覆盖。
2. **`bringSubviewToFront` 加守卫**：只在 `page.subviews.lastObject != blankArea`
   时才调（blankArea 本来就该在最上层）。
3. **clip path 缓存**：高度变化 >0.5 pt 才重建 `UIBezierPath + CGPath`
   （GCCState 加 `clipHeight` 属性）。
4. **白雾扫描降为每 2 拍（400 ms）** —— 白雾是持续态不是闪现，
   源头修复（0.5.8 / 0.5.9 / 0.5.50）已掐死它的出现条件，这里只是兜底。

**待真机确认** — 「我的」页滚动时白块是否回归（blankArea 移位依赖
`bringSubviewToFront`，加了守卫后如果 app 在滚动时把别的视图插到 blankArea 之上，
白块会露出来）。若有，把守卫换成「先查再调」的逆序判定。

### L. 0.7.4 回退（未采用）

**结论** — 0.7.4 在真机使用中暴露出问题，**已回退**（当时采用版本回到 `0.7.3`；
后续 0.7.5 / 0.8.0 已修复并取代，见 §M）。
0.7.4 的提交保留在历史中（`5ea5f24` 源码与文档、`020c6d3` 二进制产物），
但不再作为采用版本；本次回退是**新增提交**（`49312f0`），未改写任何历史。

**回退手法** — `git read-tree -u --reset ffca284`（把索引与工作树设为 0.7.3 的树，
HEAD 不动）再新增提交。**未使用 `reset --hard` + 强推**，符合「禁止改写仓库历史」约定。

**0.7.4 改动清单（供定位用，嫌疑从高到低）**

| # | 改动 | 潜在风险点 | 嫌疑 |
|:--|:--|:--|:--|
| A3 | `GCCArmTick()`：前台 200 ms / 后台 2 s + `DidBecomeActive`/`DidEnterBackground` 观察者 | 后台拉长后若 `DidBecomeActive` 未按预期触发、或 `ScheduleTimer` 状态异常，回前台可能清理停滞 | **最高** |
| A4 | `GCCActiveUntil` 活跃窗：窗内每 2 拍、静默每 6 拍扫 | 静默期降频后，白雾/手势若在静默期出现可能扫不到 | 高 |
| A2 | 非活跃态删 100 ms 自持重试链，改直接 `return` | 链改由 GCD 定时器续跑 | 中 |
| A6 | 底栏提示每 2 拍 + 天气行重扫节流 4 拍 | 引导态/天气行归位可能慢 400–800 ms | 中 |
| A5 | 广告窗口兜底 15 s 后降为每 10 拍 | 广告若 15 s 后才弹，最长 2 s 才隐藏 | 低 |
| A1 | 扫描块内三函数各一次（修 0.7.3 重复调用） | 纯减法，无风险 | 无 |

**下次继续的入口** — 等具体症状（哪个页面、什么表现、是否可复现）后按症状二分：
先单独回滚 A3 做验证，再逐条加回 A4/A5/A6。

### M. 0.7.5 / 0.8.0 —— 高德 17.01.0 「完全没效果」修复（当前采用）

**症状** — 2026-10-09 高德地图从 `17.00.2` 升级到 `17.01.0` 后，tweak **完全没效果**
（不是部分失效）。用户提供 17.01.0 解密 IPA 供取证。

#### M1. 根因一（致命）：硬版本闸门把 dylib 自己关掉了

0.7.5 构造函数里有一道闸门：

```objc
if (![[NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"] isEqual:@"17.00.2"]) {
    NSLog(@"[GaodeClean] unsupported app version; disabled");
    return;                                  // ← 一个钩子都不装
}
```

版本一变，条件为假 → 构造函数直接 `return` → **零钩子安装**，现场表现就是「完全没效果」。

**铁证** — 用户设备上经 TrollFools 注入的 dylib 内嵌字符串：

```
CFBundleShortVersionString  17.00.2  [GaodeClean] unsupported app version; disabled
```

其 `__TEXT.__text` 段 sha256 前缀 `5819eb9ca91fb599` 与本地 0.7.5 构建**逐字节一致**
（即确实是发布版被加载了，只是被自己的闸门拦下）。

**教训** — 版本护栏必须写成「白名单 + 显式日志」，不能写成 `isEqual:` 硬匹配后静默 return：
护栏失效时要**看得见**。0.8.0 改为打印实际识别版本 + 支持列表。

#### M2. 根因二：开屏广告换了体系（解闸门也不够）

对两版二进制做 `__objc_classname` / `__objc_methname` 节区全量对比（`lief` 提取）：

| 体系 | 17.00.2 | 17.01.0 |
|:--|:--|:--|
| 阿里聚合广告 `CNGLaunchSplash*` | 15 个类 | **0** |
| `BUAdSDK`(穿山甲) / `GDTMobSDK`(优量汇) / `KSAdSDK`(快手) / `BaiduMobAd`(百度) | 26 / 2 / 5 / 59 处 | **全 0** |
| 自研 `WINSplashScreen*` | **0** | **60+ 个** |

→ 旧版钩的 CNG 类名在新版**一个都不存在**，钩子永不触发。新版关键 selector：

```
shouldSplashScreenShow:launchCheck:
isLocalSplashDataCanExposure
presentSplashScreenWithData:scene:fromBackground:otherInfo:filteringSuccessBlock:…（8 参）
presentRealTimeSplashScreen:scene:customFilterBlock:…
hideSplashView / fetchSplashDataWithScene: / doFetchSplashDataAfterDelay:scene:…
```

配置键 `splash_last_adgroup_id` / `splash_last_ad_timestamp` 仍在 → 确认仍是广告开屏。

#### M3. 0.8.0 改动（A1–A5）

| 项 | 改动 |
|:--|:--|
| A1 | 硬闸门 → `GCSupportedVersions()` 白名单 `{17.00.2, 17.01.0}`；未验证版本打印 `unsupported app version %@ (supported: …) - no hooks installed` 后自禁；放行打印 `app version %@ accepted, installing hooks` |
| A2 | `kGCVersion` → `0.8.0`；loaded 日志带支持列表；迁移边界缓存键改 `GCBoundaryKey()` 随版本走 |
| A3-1 | 类名前缀表追加 16 个 `WINSplash*` 前缀（**旧 CNG 词全部保留**，兼容 17.00.2） |
| A3-2 | 判定表追加 `shouldSplashScreenShow:launchCheck:`、`isLocalSplashDataCanExposure` → 返回 `NO` |
| A3-3 | 判定层参数上限由「必须无参」放开到 **≤2 参**（新体系判定方法带参），按真实参数个数生成对应 block |
| A4 | `GCReportSplashClasses()` 只读探针：启动 + 1s/3s 各打印一次运行时 `WINSplash*` 类清单 |

**★ 明确不碰展示层** — `presentSplashScreenWithData:` 带 4 个 completion block
（filteringSuccess / filteringFailure / playFinish / animationFinish），置空会让启动流程
永远等不到回调而卡白屏/黑屏。这与 §L 记录的黑屏事故同源，故只在「判定层」返回 NO。

#### M4. 风险面实测（非推测）

对 17.01.0 的 `__objc_methname` 逐条核对：旧的 8 个「展示」selector 与 7 个「判定」selector
**全部 0 命中** → 新版最多只可能挂上那 **2 个新判定方法**（各自只被一个类实现），
展示层与主窗口路径完全不会被触及。

若真机日志出现 `splash guard hooked 0` 且广告仍在 → 说明判定方法归属类不在 `WINSplash`
前缀内，按 A4 探针日志做第二轮（**只动判定层**）。

#### M5. 顺带修掉的打包缺陷

`mkdeb.py` 用 `rstrip('\n')` 生成 control → **控制文件缺末尾换行**，
`dpkg-deb -f / -c / -e` 报 `end of file during value of field 'Installed-Size'`。
0.7.3 / 0.7.5 的包同样有此病（此前只用 Python 侧核对字段，未过 `dpkg-deb`）。
0.8.0 改为 `rstrip('\n') + '\n'`，现在三种核验全部通过。

#### M6. 构建踩坑（务必记住）

`clang … | head -30` 会因 **SIGPIPE** 把 clang 打断 —— **产物没生成，却看不出任何错误**
（`head` 截断输出后关闭管道，clang 收到 SIGPIPE 死在写文件之前）。
正确姿势：加 `-w` 抑制警告，并把 stderr 重定向到文件后再检查。

#### M7. 验证门禁（0.8.0 构建后实测）

```
HookVoid 总数 26 ｜ 重复钩子对 0
关键 selector 14/14 命中 ｜ 涉及类 16 个
产物实存：0.8.0 / app version accepted / WINSplash classes at runtime /
         shouldSplashScreenShow:launchCheck: / isLocalSplashDataCanExposure
deb：dpkg-deb -f / -c / -e 全通过；载荷路径 rootless=/var/jb/… arm64、RootHide=/Library/… arm64e
```

**抽类名表的方法（可复用）** — `python3 + lief` 取 `__objc_classname` / `__objc_methname`
节区，NUL 切分导出 txt，再 `rg` 比对两版差异。比 `strings` 精确，能直接判定
「某个类 / selector 在新版是否还存在」。

### N. 高德 17.01.1「失效」修复 —— 取消版本限制（0.9.0，当前采用）

**现象**：高德 2026-10-13 升级 17.01.1 后 GaodeClean 完全没效果。
**根因**：0.8.0 的版本白名单 `{17.00.2, 17.01.0}` 不含 17.01.1 →
构造函数撞闸门 `return`，**零钩子安装**（设计内的自禁护栏）。
铁证：用户注入的 dylib 与 0.8.0 官方产物 21 个区段逐字节相同（唯一差异=TrollFools
重签名），内含 `unsupported app version` 串与白名单仅两版本。

**修复（0.9.0，应「取消版本限制」指令）**：
| 项 | 改动 |
|---|---|
| N1 | 删除 `GCSupportedVersions()` 白名单函数及其注释块 |
| N2 | 删除构造函数闸门判断，直接 `installing hooks` |
| N3 | loaded 日志改 `(no version limit; appVer=%@)` |
| N4 | `kGCVersion` → `0.9.0`；文件头 Target 行同步 |
| N5 | deb control → Version 0.9.0；描述同步 |

**17.01.1 数据面实测（全存活）**：16 主 hook 类 + 12 次要 hook 类 = **28/28**；
全部关键 selector 命中；WINSplash* 63 类仍在。→ 无需任何类名/selector 适配。

**构建门禁（0.9.0 实测全绿）**：
```
双架构编译零告警；unsupported app version 字符串 0 残留
反汇编：Initialize 唯一早退 = bundleID 检查（设计保留）；版本早退路径消失
arm64e cpusubtype=2 + 45/45 页哈希；arm64 45/45
deb 双包 dpkg-deb：路径 /var/jb/… 与 /Library/… 分别正确、Version=0.9.0
集成版 IPA：1418 条目无增缺、唯一差异=GaodeClean 条目、DTHbalSe/主程序 CRC 未动、testzip 无坏条目
```

**教训**：护栏（版本白名单）在自禁时是安全的，但每次高德升级都会「失效」——
本次起改为**运行时自适应**：hook 目标不存在时各自静默跳过，版本判断彻底让位于
「能力探测」。这与 0.6.x 的「不猜类名、按真实 selector 挂钩」同一哲学。

### O. 「上拉发现」引导 Lottie 拦截（0.9.1，当前采用）

**现象**：高德 17.01.1 上拉底栏时弹出「双箭头 + 上拉发现」（引导态，持续显示）。
**破译**（视频 40+ 帧 + 主二进制全证据链）：
17.01.1 的「上拉发现」走 **GuideLottie 渲染链**——
服务端下发 lottieZipUrl → `WINTabBarItemDataLogic.updateTabBar:param:callback:` →
`WINTabBarItemControl.updateGuideLottie:viewState:` → **`WINTabBarItem.updateGuideLottie:viewState:`（唯一渲染点）**
创建 Lottie 动画（双箭头 morph + 文案）叠加到底栏 item，并用 `amap_setGuideMaskHidden:forViewState:`
盖住原图标。

**铁证**：
- 埋点串 `tab guide lottie start play` / `tab guide lottie finished`（0x7f538a1）；
- 「上拉发现」不在任何本地资源（UTF-8/UTF-16 全域扫过）→ 文案打包在 Lottie 资源里
  → 0.6.7 的文本层扫描（SweepTabBarHints）对动画画面无效——这是 0.6.7 机制在新版失效的根因；
- xref 全链：唯一渲染点 = `updateGuideLottie:viewState:`（无子类覆写）。

**修复（0.9.1）**：
| 项 | 改动 |
|---|---|
| O1 | 新增 `InstallTabBarGuideLottieBlock()`：空实现 `updateGuideLottie:viewState:` |
| O2 | 签名校验（4 参数 + void）+ 限流日志 `blocked tab guide lottie`（20 条）|
| O3 | `kGCVersion` → 0.9.1；control 同步 |

**下游安全论证**：按压观察者对空 lottie 走 NSNull 分支（反汇编确认）；
`WINTabBar.gestureRecognizerShouldBegin:` 里 `amap_hasActiveGuideLottie=NO` 时跳过引导手势。
底栏点按/切换/上拉手势不受影响。

**构建门禁（0.9.1 实测全绿）**：
```
反汇编核验拦截装载：4fa0(NSClassFromString)→4fb8(NSSelectorFromString)→4fd4(class_getInstanceMethod)
→5020(imp_implementationWithBlock)→5038(class_addMethod/fallback setImplementation) 全链在案
拦截 block 0xfaf0：cmp #0x13 限流 + NSLog + ret 不调用原实现
arm64/arm64e 45/45 页哈希；deb 双包核验；集成 IPA 1418 条目唯一差异
```

### P. 冷启动搜索栏「闪断」修复（0.9.2，当前采用）

**现象**：冷启动后搜索栏出现 0.4s → 消失 ~117ms → 恢复（120fps 逐帧实测：
t=2.775s 整屏消失 14 帧，t=2.892s 恢复，位置完全一致——纯「隐藏→恢复」脉冲）。

**根因**：三道防闪线门槛全是 `ColdTicks >= 15`（启动后约 3.2s 才生效）——
- `setHidden:` 拒绝（2447 行）：`ColdTicks >= 15 && 首页选中`
- `didMoveToSuperview` 抢挂（2419-2420 行）：`if (ColdTicks < 15) return;`
- tick 偏差兜底（651-654 行）：`ColdTicks < 15` 才隐藏

闪发生在启动后 ≈2.0s（ColdTicks ≈ 7~9）→ **正好落在「无保护窗口」**：
app 原生布局在冷启动后段的一次瞬时隐藏被全部放行。

**修复（0.9.2）**：
| 项 | 改动 |
|---|---|
| P1 | 新增 `BarShownOnce` 标记（LayoutMinimalHome 里 `!bar.hidden` 时置位）|
| P2 | `setHidden:` 保护条件 → `(ColdTicks >= 15 \|\| BarShownOnce)` + 限流日志 `refused search bar hide` |
| P3 | `didMoveToSuperview` 冷启动门 → 三重条件（显示过 + 仍可见 + 首页选中）+ 日志 `re-attached search bar` |

**反汇编核验（BarShownOnce 三处代码落位）**：
```
写点 @0xb4c8: tbnz(hidden)→skip; strb [0x21000,#0x250] ← 仅 !hidden 置位
读点 @0xc7bc: cmp ColdTicks,#0xe → b.gt 原路径; ldrb [0x250] ← A2 保护
读点 @0xca5c: cmp ColdTicks,#0xe → b.gt 原路径; ldrb [0x250] ← A3 冷启动门
```

**下游安全**：与既有 >=15 行为同语义、只提前生效点；「我的」页/正常摘除照常放行。

### Q. 冷启动「天气行错误位置闪现」修复（0.9.3，当前采用）

**现象**：冷启动后「天气行+高德LOGO」先出现在**屏幕中部原生位置**（y≈411pt），
约 350ms 后瞬跳回搜索栏上方。60fps 逐帧实测：t≈2.12s 露错位（无搜索栏陪伴）
→ t≈2.47s 搜索栏出现同时归位。用户视角 = 「天气和LOGO瞬间回到搜索栏上方」。

**根因**：对齐锚点（车机圆钮 CachedCar）比天气行晚就绪（350ms 差）。
`AlignWeatherRow` 在锚点未就绪时直接 `return`（无法计算目标位）——
这 350ms 里天气行就**敞在 app 原生位置**，没有任何扣留机制。

**修复（0.9.3）**：
| 项 | 改动 |
|---|---|
| Q1 | 新增 `GCWeatherHeldRows` 扣留登记表 + 三帮助函数（AnchorReady / InHoldPhase / HoldRow / ReleaseHeld）|
| Q2 | `AlignWeatherRow` 对齐成功 → `GCWeatherReleaseHeld()` 恢复 |
| Q3 | tick 顶部 `ColdTicks >= 30` 兜底释放（6 秒，杜绝永久隐藏）|
| Q4 | tick 放行被扣留的行（否则 deadlock：行被扣 → tick 早退 → 永远释放不了）|
| Q5 | 三类双路径拦截（didMoveToWindow 上窗扣留 + setHidden: 拒绝显示请求）|
| Q6 | `kGCVersion` → 0.9.3；control 同步 |

**反汇编核验（调用点级）**：
```
GCWeatherHoldRow 调用点 ×2：@0x11294（setHidden: 拒绝路径）/ @0x11440（didMoveToWindow 上窗路径）
GCWeatherReleaseHeld 调用点 ×2：@0x101b4（AlignWeatherRow 尾）/ @0x15b1c（tick cmp #0x1e 后）
GCWeatherHeldRows @0x211f0 读写均与设计一致
```

### R. 源码审计优化（0.9.4，当前采用）

**背景**：0.9.3 真机验收通过后，应「审计一下源码」指令做全量审计 + 优化。
**方法**：`-Wall -Wextra` 全告警编译（14 条）逐条溯源 + 热点路径走查 + 死代码反查。

**审计发现与处置（11 项，行为零变化）**：
| 组 | 改动 | 证据 |
|---|---|---|
| A1 | 删 `IsBlurOverlayView` / `GCCColorStr` / `GCCScreenMapMean` | `-Wunused-function` 实证；白雾判定由 `GCCIsWhiteVeil` 承担 |
| A2 | 删 `ConfineLegacyChrome` | 零引用 |
| A3 | 删变量 `Cleaning` | 零引用 |
| B1 | 主循环「探索/附近」数组 → `dispatch_once` 静态化 | 原 5Hz × 每拍重建 |
| B2 | `NodeText` 取词数组静态化 | 节点扫描热路径 |
| B3 | `IsHiddenMapPromo` 取词数组静态化 | layout 频率 |
| B4 | 白雾日志限流（10 条） | 异常时防刷屏 |
| C1 | `.windows` ×5 → `GCAllWindows()` 集中入口（内联后无符号） | 弃用警告集中 suppress |
| C2 | `.keyWindow` → `w.isKeyWindow` | 属性替代 |
| D | 版本 0.9.4 + control | — |

**核心指标**：编译告警 **14 → 0**；4 个死符号 nm 实证消失；行为零变化。

**有意不动（附理由）**：`NSStringFromClass` 42 处逐点比较（内部有类名缓存、每拍仅数次，收益小风险大）；tick 两轮 HomeHandlers 遍历合并（微收益、动行为顺序）。

### S. 冷启动「LOGO 中屏闪现」修复（0.9.5，当前采用）

**现象**：冷启动 t≈2.4s，「🔷高德地图」LOGO **单独**闪现在屏幕中部原生位（~130ms），
随后才跳回搜索栏上方。用户 120fps 视频指认「2 秒处 LOGO 位置不对」。
（0.9.3 修复的是「整行」闪现；本次是「半件 LOGO」残留。）

**根因**（逐帧 + 源码级）：
- 0.9.3 扣留只覆盖 3 类且要求行级尺寸（宽 150-360pt）；
- 闪现的 LOGO 是半行（仅 ~65pt 宽）——尺寸门槛漏网；
- 二进制还有 `WINLiteWidgetLogoScaleLineView`（Lite 版）/ `LTMBigPearMapLogoView`（引擎版）等族类未覆盖。

**修复（0.9.5）**：
| 项 | 改动 |
|---|---|
| Q1 | 类网 3→6 + 语义前缀兜底（`*LogoScaleLine*`/`*ScaleLineLogo*`）|
| Q2 | 六类 × 四路径全挂：上窗 / setHidden: / setFrame:+setCenter: / setAlpha:（防淡入绕过）|
| Q3 | 锚点就绪收紧 =「车机钮已对齐」（打过 AlignedKey），不再过早放行 |
| Q4 | 释放即时化（每拍）+ 扣留窗内扫描取消防抖（防 130ms 窗口错过）+ BFS 任意尺寸扣留 |
| Q5 | 版本 0.9.5 + control |

**安全设计**：扣留仅冷启动窗内；6s 兜底；释放先清表防递归；类存在性全检查。

### T. 0.9.5 回归 —— LOGO 搬运叠压天气（0.9.6，当前采用）

**现象**：0.9.5 装后，底栏行里「🔷高德地图」LOGO 被单独搬到车机钮右侧，
天气（☀25°C）消失/被叠压（用户截图指认）。

**根因**：0.9.5 修「半件闪现」时新增 4 处「释放后逐元素搬运」
（释放循环 / didMoveToWindow / 五类 setFrame: / setCenter:）——
被扣留的多个元素各自独立被搬到**同一目标位**（车机钮右侧+8pt）→ 叠压；
LOGO z-order 高 → 盖住天气。0.9.4 验收时搬运面只有「单一 Row」所以无此问题。

**修复（0.9.6）**：
| 项 | 改动 |
|---|---|
| T1 | 撤销 4 处新增搬运（释放/上窗/五类写位置 → 只扣留不搬运）|
| T2 | tick 搬运候选收窄回 3 类（0.9.4 行为）；6 类网仅用于扣留 |
| T3 | 保留 0.9.5 全部扣留面（六类×四路径 + 锚点收紧 + 每拍释放）|

**反汇编核验**：AlignWeatherRow 调用点 8 → 6（全部为 0.9.4 原有归属：
LayoutMinimalHome ×1 + WINGroupMapWidget 老块 ×4 + tick ×1）。

**教训**：扣留面可以扩（多样拦截无害），但**搬运面必须单一**——
多目标搬运必然叠压；「拦截」与「归位」是两个职责，钩子只做前者。

### U. 「200米比例尺误关」修复（0.9.7，当前采用）

**现象**（120fps 逐帧）：冷启动 t=5.5s「200米」+比例尺线**单帧瞬消**，t=8.7s 单帧瞬回
（消失 3.2s）；期间其余元素原位不动，恢复位置与原位逐像素一致。

**根因**（双因素叠加）：
1. 锚点实例抖动 —— app 启动中段刷新车机钮实例，AlignedKey 随旧实例丢失 →
   AnchorReady 翻回 NO → 扣留窗**重新打开**（ColdTicks 仍 <30）
2. 0.9.5 扩网钩子在场 —— 比例尺（LTMBigPearScaleLine，LOGO 容器 _scaleView）
   刷新显示被 setHidden:/setAlpha: 拦截 → 误扣 → 关到 30 拍兜底释放
   （8.7s = ColdTicks 30 拍线；3.2s = 27 拍，逐拍吻合）

**修复（0.9.7）**：
| 项 | 改动 |
|---|---|
| F1 | 首次释放后本轮封网（GCWeatherDoneOnce）—— 扣留窗一生只开一次，免疫锚点抖动 |
| F2 | 扣留位置门槛 —— 只扣「中屏原生错误位」（y<窗高 55%），行内元素（y≈78%）直接放行 |
| F2b | HoldRow 返回是否真正扣留；setHidden: 仅在真正扣留时拒绝显示（防死元素）|
| F3 | 版本 0.9.7 + control |

**教训**：扩网（扣留面）之后，每一个钩子路径都要重新审「误伤面」——
锚点实例会抖、app 会刷新实例，任何「实例级状态」都不可作为长窗状态判定。

### V. 0.9.8 审计修复 15 项（当前采用）

**背景**：0.9.7 发版后应「检查源码还有没有需要优化的地方」做全量审计。审计前先核对远端，
发现 **0.9.7 之后那批修复从未推送**（仓库一直停在 `ed01450`：0.55 门、`layoutSubViews`、
无 `GCCIsAppOwnSplash` 全部原样命中）—— 所以本轮把旧账与本轮新发现一并做掉，一次出 0.9.8。

**P1 · 崩溃面与功能失效**

| 编号 | 问题 | 根因铁证 | 修复 |
|:--|:--|:--|:--|
| A1 | 667pt 机型 LOGO 中屏闪现回归 | 扣留门槛按窗高比例算（`0.55h = 367pt`），而原生错误位是**绝对 411pt**（源码内 `{{10,411}}` 实测注释）—— 门槛在错误位置上方就已放行 | 0.55 → **0.70**（0.70×667 = 467pt > 411pt），667–932pt 全机型覆盖 |
| A2 | 模态全屏广告通道**从未命中** | `presentViewController:...` 返回瞬间 `vc.view.window` 恒为 nil，`GCCIsSplashAd` 首句即判死；且即便命中，在调用栈内同步 dismiss 会撞 UIKit「presentation in progress」断言 | 判定移到 completion 内 + dismiss 放下一 runloop |
| A3 | 新版高德一改属性就崩 | 4 处裸 KVC / 裸 selector：`maskViews`（非数组 → `makeObjectsPerformSelector:` 崩）、`clearBlurViews` 与 `setViewControlParams:`（改名 → unrecognized selector）、`setValue:nil forKey:`（属性删除 → `NSUnknownKeyException`）| 类型 / 存在性 / 方法签名三重校验 |
| A4 | 「重复点首页」清理从未生效 | `initWithFrame:model:` 真实签名是 **4 参 + 返回 `@`**，被 `HookVoid` 的「2 参 + void」守卫**静默跳过** | 迁到 ABI 安全的 `-didMoveToWindow`；守卫增加可发现日志（`GAODECLEAN_DEBUG_HOOKS=1`）|
| A6 | 启动偶发白屏 | `GCCHasAdKeyword` 词表含裸词 `splash`，把自家 `APSplashScreen*` 一并网住并隐藏 | 新增 `GCCIsAppOwnSplash` 白名单，3 处判定统一放行 |
| A8 | 右下定位钮凭空消失 | 任一 widget 对齐成功即置 `HomeSettled = YES`，`ColdTicks > 12` 兜底对其余仍在 `ColdWidgets` 里隐藏的控件**永久失效** | 兜底改为逐成员补显示（幂等）；该标志只写不读，整体删除 |

**P2 · 热路径与常驻开销**

| 编号 | 问题 | 根因铁证 | 修复 |
|:--|:--|:--|:--|
| A7 | 每次回前台卡顿 + 日志刷屏 | `GCCHookAdClasses` 每次 `DidBecomeActive` 都跑 `objc_getClassList`（真机约 4 万类）+ malloc，并把已装钩子重打一遍 | 限制为 4 次（install / +1s / +3s / 首个回前台）；`GCReportSplashClasses` 默认关闭 |
| A9 | 切页 / 切 2D-3D 瞬间卡顿 | `LayoutMinimalHome` 被 `BarFixTimer` 以 **8ms** 调用，`rowStale` 时每次 ≤2000 节点全窗 BFS —— 一次 640ms 快修窗最多 16 万次视图访问 | 非扣留期节流到每 4 拍；扣留期保持全速 |
| A10 | 滚动时每帧多算一半 | `UpdateMask` 把 `Kind()` 算两遍，而它是 `PagePath → ObjectGetter → methodSignatureForSelector` 全链路，挂在 `setBounds:` 后每帧触发 | 只算一次 |
| A11 | 启动期 addSubview 变慢 | `GCCHasAdKeyword` 挂在 `UIWindow -addSubview:` 全局热路径，每次 `lowercaseString` + 27 次 `containsString:` | 按类名缓存判定结果 |
| A12 | 冷启动前 6 秒空转 | `IsWeatherRowClass` 无缓存 —— 30 拍 × 2000 节点 × 8 次字符串比较 ≈ **48 万次** | 类名缓存（同 `AjxCache` 模式）|
| A13 | 无天气行机型同样空转 | `GCWeatherHeldRows` 为空时 `GCWeatherReleaseHeld` 提前 return，`GCWeatherDoneOnce` 永不置位 → 整个 `ColdTicks < 30` 期间判定恒真 | 无待释放对象时同样封网 |
| A14 | 全 app 图层动画多一层开销 | `CALayer -setOpacity:` 先取 `delegate` 再判值，而绝大多数调用 `op == 1.0` | 判值提到最前，99% 调用免 delegate 访问 |

**P3 · 清理与构建链**

- **A5** 删除 `layoutSubViews`（大写 V）死钩子。**不补** `layoutSubviews` —— 0.7.3 已实测它
  在滚动动画里每帧触发，会抵消 `CleanPage` 降频。事件源由 `reloadView` /
  `updateVoiceOverIDAndLabel` / `AJX3View-didMoveToWindow` 三条承担。
- **A15** 死变量清理（`GCCSplashView` / `GCCSplashDone` / `state.attempts`，均为只写不读）；
  `SearchBarSettled` 方向变化时复位；`mkdeb.py` 全参数化（版本读 `control`、路径走参数、
  `Installed-Size` 按真实载荷）；**新增 `Makefile`**；`make-roothide.sh` 标注废弃。

**门禁（全绿）**：双架构 0 警告（与 0.9.7 基线逐条一致）；版本串 `0.9.7` 残留 0；
arm64e cpusubtype `0x2`（fixarch 重算 50 页签名哈希）；载荷路径与 `Depends` 解包核验；
`Installed-Size` 181 / 199 KB（原写死 160）。

**教训**：见 §五 第 11、12 条（群体标志不可作兜底门控；守卫不得静默拒绝签名）。

### W. 冷启动「右下按钮在屏幕中部裸奔」修复（0.9.9 → 0.9.13，**已回退**）

**现象**（60fps 逐帧，真机视频）：冷启动 **1.47s**，右下角「定位 + 路线」按钮首次出现，
位置在**屏幕右侧中部**（原图 y 768–958，约屏高 40–50%）；停留 **19 帧（310ms）** 后，
**1.80s 一帧瞬移**到底部正确位置（y 1370–1556），**位移 301pt**。

**根因**：0.4.41 的「未对齐先按住」只挂在 `-layoutSubviews` 一个入口：

```c
HookVoid(@"WINAJXCombinedWidgetView", @"layoutSubviews", ^(UIView *view) {
    ...
    view.hidden = YES; [ColdWidgets addObject:view];
});
```

而它的 `setHidden:` 钩子只处理「广告推广」，**没有拦住「未对齐就想显示」**。
app 走 `setHidden:NO` 这条路时直接绕过 → 按钮以原生位置露出来，
直到 1.80s `AlignOneWidget` 把它搬到下方。

**修复（0.9.9）**：

| 项 | 改动 |
|---|---|
| W1 | `WINAJXCombinedWidgetView -setHidden:` 增加「未对齐拒绝显示」（压回 hidden + 登记 `ColdWidgets`）|
| W1b | **0.9.10 补丁**：新增 `GCCLooksLikeRightBottomWidget` 几何兜底 —— `getItemTag` 是 AJX 数据字段，可能晚于视图上屏才写入；1.42s 判定返回 NO 导致 W1/W2 拦截整段失效（真机复验：仍裸奔 21 帧/350ms）|
| W1c | **0.9.11 补丁**：几何兜底改为**纯类名认定**，并去掉 `setHidden:`/`setAlpha:` 的 `self.window` 前置条件 —— app 常在 `addSubview` **之前**就设好 hidden/alpha，那时 window 还是 nil，条件被整段跳过（复验仍裸奔 14 帧/233ms）|
| W1d | **0.9.11 补丁**：补 `-didMoveToWindow` 通道 —— 上窗那一帧即触发，早于首次渲染，覆盖「直接 addSubview（默认可见）」这条不经过任何 setter 的路径 |
| W1f | **0.9.12 补丁**：`HookWidgetSetFrame` 对右下按钮增加「未对齐 + 中心落在屏高 25%–70%」的 frame/center **写入拒绝**。复验发现 app 既不改 hidden 也不改 alpha，只是把视图从屏幕外移到可见位置 —— 四条显示通道全部漏过，`setFrame:` 是唯一必经之路 |
| W1g | **0.9.13 补丁**：兜底显示前**先验位置** —— 五轮复验数据共同指向：裸露总发生在启动后 2.0-2.5s，即 `ColdTicks > 12` 兜底开闸时刻。兜底只管显示不管位置，若此刻 `CachedRight` 还是 nil，按钮就以原生中部位置现身（0.9.12 复验：2.45-2.47s，2 帧/33ms）。在中部（屏高 25%-70%）的成员继续藏，交给 `AlignCornerWidgets` 摆位；30 拍硬底线保留 |
| W2 | 新增 `WINAJXCombinedWidgetView -setAlpha:` 拦截（防透明度淡入绕过）|
| W3 | `WINDeviceInterconnectWidget` 同样补 `setHidden:` / `setAlpha:` 两条拦截 |
| W4 | `AlignOneWidget` 与 `ColdTicks>12` 兜底补 **alpha 恢复**（W2/W3 的自伤点）|
| W5 | 版本 0.9.13 + control |

**教训**：
1. **「先隐藏、对齐后再显示」必须覆盖所有显示路径**。只挂 `layoutSubviews` 等于只堵了一条门；
   `setHidden:` / `setAlpha:` 都是 app 的合法显示入口，漏一条就会裸奔。
2. **任何「压 alpha」的拦截，放行时必须同时恢复 alpha 与 hidden**。
   只恢复 `hidden` 而 alpha 仍是 0，控件会变成「逻辑可见、视觉全透明」——
   比不修更难查（W2/W3 的自伤点，已在 W4 补上）。

**⚠️ 六轮结论：本系列（W1/W1b/W1c/W1d/W1f/W1g/W2/W3/W4）全线失败，已在 0.9.14 整体回退。**
逐帧复验数据从未收敛，且在 0.9.13 反弹：

| 版本 | 中部裸露 | 说明 |
|:--|:--|:--|
| **0.9.7** | **0 帧** | 用户实测 —— 无任何显示路径拦截，零裸露 |
| 0.9.8 | 19 帧 | `HomeSettled` 门控被拆（A8），兜底从「一次性」变「每拍跑」|
| 0.9.9 | 21 帧 | W1 拦截（越修越差）|
| 0.9.10 | 14 帧 | W1b/W1c |
| 0.9.11 | 4 帧 | W1c/W1d |
| 0.9.12 | 2 帧 | W1f |
| 0.9.13 | **14 帧（反弹）** | W1g |

19 → 21 → 14 → 4 → 2 → **14** 这种钟摆曲线本身就说明：**拦截不是在修 bug，而是在造 bug**。
每加一层显示路径拦截，就多一处自锁（alpha 卡 0 / 丢弃 frame 写入 / 兜底抢 `AlignedKey`），
而 app 布局时序在每次启动的抖动又让「哪一层先赢」随机化 —— 数值只能乱跳，永远到不了 0。
真根因见 §X。

### X. 0.9.14 —— 回退 W 系列，恢复 0.9.7 显示语义（**经验证不足，见 §Y**）

**定位方法**：不再猜测，直接 `git show ed01450:src/GaodeClean.m`（0.9.7）与当前源码
做**函数级归一化逐字比对**（去注释、压缩空白），差异清单就是唯一嫌疑：

```
✅ 逐字相同  IsRightBottomWidget
✅ 逐字相同  HookWidgetSetFrame
✅ 逐字相同  WINAJXCombinedWidgetView setHidden 钩子
✅ 逐字相同  WINAJXCombinedWidgetView layoutSubviews 钩子
✅ 逐字相同  WINDeviceInterconnectWidget layoutSubviews 钩子
⚠️ 差异      AlignOneWidget      → 仅多一行 alpha 恢复；HomeSettled = YES 已恢复
⚠️ 差异      兜底 ColdTicks 块    → 仅 guard 写法等价改写 + alpha 恢复；门控已恢复
```

**根因（唯一实测差异）**：`AlignOneWidget` 末尾的 `HomeSettled = YES;`

| 版本 | `AlignOneWidget` 末句 | 兜底门控 | 结果 |
|:--|:--|:--|:--|
| **0.9.7** | `HomeSettled = YES` ✅ | `if (!HomeSettled && ColdTicks > 12)` | 车机钮 ~1.3s 对齐即**封门** → 兜底永不跑 → 右下钮只由 `AlignOneWidget` 在**正确位置**显示 = **0 帧裸露** |
| 0.9.8+ | 已删除 ❌ | `if (ColdTicks > 12)` **每拍跑** | 启动 2.4s 起每 200ms 把未对齐控件 `hidden = NO`；此刻 `CachedRight`（精确 `getItemTag` 判据）尚未配对，按钮 frame 仍是 app 原生中部位 → **一开闸就以错误位置现身** = 19 帧 |

0.9.8 拆门控的动机是「防某控件永远对齐不上而永久隐藏」，但它把一条**最后保险**
改成了**每拍的显示通道** —— 于是「保险」变成了「裸露源」。

**施工（A1-A10，全部回退到 0.9.7 语义）**：

| 项 | 改动 | 位置 |
|:--|:--|:--|
| A1 | `WINAJXCombinedWidgetView -setHidden:` 移除「未对齐拒绝显示」，恢复直通（仅留 `IsHiddenMapPromo`）| 按钮钩子区 |
| A2 | 删除同类的 `-setAlpha:` 拦截整块 | 按钮钩子区 |
| A3 | 删除 `-didMoveToWindow` 拦截整块 | 按钮钩子区 |
| A4 | `-layoutSubviews` 判定由纯类名回到**精确 tag** `IsRightBottomWidget(v)` | 按钮钩子区 |
| A5 | `HookWidgetSetFrame` 删除 `setFrame:` / `setCenter:` 的「中部写入拒绝」（W1f）| 对齐辅助函数 |
| A6 | `WINDeviceInterconnectWidget` 的 `setHidden:` / `setAlpha:` 两条拦截移除，只留 0.4.41 `layoutSubviews` | 按钮钩子区 |
| A7 | 删除 `GCCLooksLikeRightBottomWidget`（纯类名兜底，已无引用）| 按钮钩子区 |
| A8 | 兜底恢复 **`HomeSettled` 一次性门控** + `AlignOneWidget` 恢复置门 | tick 链 / 对齐函数 |
| A9 | 12 处「每事件级」诊断日志改 `GCLog`，正式包（`-DGAODECLEAN_STRIP_LOGS=1`）展开为空操作；装机核对必需的 8 处（signature/version/loaded/hook SKIPPED/blacklist SKIPPED/splash guard hooked）保留 `NSLog` | 全文 |
| A10 | `control` 版本 0.9.14；`Installed-Size` 由 `mkdeb.py` 按真实载荷重算（181 / 183 KB）；`Makefile` 支持 `RELEASE=0` 出调试包、`make check` 双跑门禁（剥离开/关都须 0 警告）| control / Makefile |

**影响范围与验证方法**：
- **影响**：仅冷启动 2.4s 内的右边控件显示时序；天气行扣留、上拉白雾、底栏引导、
  搜索栏归位、开屏广告、比例尺等全部链条**未触碰**（比对确认逐字相同）。
- **防回归门禁**：`python3 /tmp/gcc_regress.py` 式函数级比对 —— 按钮链 5 个函数与 0.9.7
  逐字相同；另 2 个差异仅为防御性 alpha 恢复与等价 guard 改写。
- **真机验收标准**：冷启动录屏逐帧扫描 `y 768–958`（原图 x 820），
  **中部裸露帧数必须 = 0**（0.9.7 基线），且按钮最终位置与 0.9.13 一致（贴搜索栏上方 8pt）。

**教训（新增）**：
3. **最后保险不能变成常规通道**。「一次性 + 封门」的兜底一旦改成「每拍跑」，
   它就从「防永久隐藏」变成「主动显示错误位置」—— 兜底的触发条件必须稀缺。
4. **修 bug 前先与已知良好版本的代码做逐字/diff 比对**。六轮里每轮都在「解释现象」，
   却没人把 0.9.7 的函数拉出来对一遍；真根因只是一行 `HomeSettled = YES;`。
   现象驱动的层层加码，会把一个 1 行回归滚成 8 条拦截 + 6 个版本。

### Y. 0.9.14 → 0.9.16 —— 真机取证定位「裸露」真凶：锚点「首帧锁定」（当前采用）

**为什么还要一轮取证**：0.9.14 已把按钮显示链**函数级逐字**恢复成 0.9.7 语义（比对 5/5
通过），真机却仍裸露 18-21 帧 —— 说明「0.9.7 无此问题」这条口头基线、或裸露的真正成因，
至少有一个与假设不符。于是做了一版**只记录、不改行为**的取证包
（`-DGAODECLEAN_DIAG_LOG=1`：每 200ms 采样 + 事件级日志落盘到 `gaodeclean-diag.log`）。

**取证日志（0.9.14+diag，真机）关键行**：

```
[  1.187]   didMoveToWindow win=1 hid=0 a=1.00 tag=template_mainmapRightBottom frame=(0,0)
[  1.187]   setFrame:->(339,281,44x88) win系(339,340)      ← 窗口系 y=340（屏高 40%）
[  1.229]   layoutSubviews frame=(339,547,44x88) hid=0 win=1
             tag=template_mainmapRightBottom 精确判定=1
[  1.834]   setHidden:1 @(339,167,44x44) tag=template_rank  ← 全档唯一一次 setHidden:
```

**三个立刻成立的事实**：
1. **tag 完全匹配**（`template_mainmapRightBottom` 含 `rightbottom`，`精确判定=1`）
   —— 「tag 可能不匹配」的猜测全部作废；
2. app **从未**对按钮调过 `setHidden:`（唯一那次打在别的控件上），它建出来就是可见的；
3. 我们的 `layoutSubviews` 钩子确实在工作（它隐藏了 `template_rank`），但对该按钮
   **一次都没隐藏** —— 因为 `AlignedKey` 早已被我们自己的 `AlignOneWidget` 打上，
   所有「未对齐才隐藏」的钩子集体跳过。

**逐帧录屏（886x1920）**：按钮出现在**窗口系 y=340、底边 428**，稳定停留 21 帧（350ms）
后瞬移到底部（窗口系 606，底边 694）。三带轨迹扫描另证实：同屏的「+/图层」圆钮
（`template_mainmapRightTop`）**没有任何裸露** —— 因为它从不被我们对齐，
app 在同一毫秒内就把它摆到了最终位置。

**真根因：锚点被「第一帧」锁死**

`LayoutMinimalHome` 里搜索栏是**跟随 tab 栏**定位的：

```objc
CGRect tabFrame = [tabBar convertRect:tabBar.bounds toView:parent];
CGRect want = CGRectMake(0, MAX(0, tabFrame.origin.y - height - 12), ...);   // 最终 701
if (moved) { bar.frame = want; }
...
// 0.4.19 首帧锁定：缓存最终 y ...      ← 注释说「最终」，代码锁的却是「第一帧」
if (!SearchBarSettled) { SearchBarSettledY = bar.frame.origin.y; SearchBarSettled = YES; }
```

冷启动时 tab 栏自身还在迁移（启动期 498 → 最终 763），于是搜索栏先出现在
**y≈436**（436-8 = **428**，与裸露位置**逐位吻合**），最终才落到 701。锁定 436 之后：

1. 控件钳位 `HookWidgetSetFrame` 的目标 = `SearchBarSettledY - 8` = **428** —— 而 app 的
   原生槽位恰好也是 428（它自己的界面模型里搜索栏还在 447 附近），**两方一致**
   ⇒ 按钮被稳稳钉在屏高 40%；
2. `AlignOneWidget` 在按钮出生后约 40ms 就按搜索栏**当时**的位置 (436) 把它摆好并显示，
   同时置 `AlignedKey` ⇒ 隐藏路径全部失效；
3. 直到搜索栏落到 701，下一拍 `AlignOneWidget` 才把它拉到底部 —— 那一下就是「瞬移」。

**六轮结论作废**：真凶不是「显示路径漏拦」，而是**我们自己的钳位目标**用了一个启动瞬态
位置。0.9.9~0.9.13 的五层拦截之所以只能把数据在 19→21→14→4→2→14 之间来回晃，是因为
它们拦的是 app 的写入，而写入本身没错 —— 错的是我们钉住的目标值。

**为什么 0.9.7 也会露**：`0.4.19 首帧锁定` 早于 0.9.7，逻辑一字未变。老大那次「0.9.7
没问题」应当是那一拍 tab 栏恰好没有迁移（同一逻辑下的概率性表现），不代表 0.9.7 免疫。

**施工（A1-A6）**：

| 项 | 改动 |
|---|---|
| A1 | 锚点改为「定格后才锁定」：稳定性计数改为**与上一拍比较**（不再与锁定值比较，避免自循环）；新增**几何不变量** —— 目标位置必须落在容器**底部 30%**（启动瞬态 436/852 = 51% 不满足，最终 701/852 = 82% 满足）；`ColdTicks<30` 内若又稳定停到新位置则**自愈重锁**；锁定条件 =（稳定 3 拍 或 ColdTicks≥20）且（几何达标 或 ColdTicks≥20） |
| A2 | `AlignCornerWidgets`：锚点未定格前 `if (!SearchBarSettled) return;` —— 不摆位、不认领、不显示；控件与搜索栏用**同一判据**（`BarStableTicks>=3`）解除，二者同时出现、位置都是最终值 |
| A3 | 新增 `WINAJXCombinedWidgetView -didMoveToWindow` 钩子（**精确 tag** 判定）：上窗瞬间即隐藏 —— 日志显示 app 在 addSubview 同一毫秒内就把 frame 摆到中部，而首次 `layoutSubviews` 要等 42ms（≈2.5 帧） |
| A4 | 兜底阈值 `ColdTicks > 12` → `> 16`，避免它抢在 A2 的闸门（≥15）之前把控件按原始位置强显 |
| A5 | 版本 0.9.16 + control；文档同步 |
| A6 | 修诊断模块定时器：`dispatch_source_t` 原来是函数局部变量，ARC 下出作用域即释放 ⇒ 采样一次都没跑（本次取证的失误，日志里 0 条 `Sxx` 行）；改为文件级强引用 |

**影响范围与验证方法**：
- **影响**：搜索栏与两个伴随控件（车机钮 / 右下组合钮）的**出现时刻**由「第一拍」改为
  「搜索栏定格那一拍」——三者从此同时出现、位置都是最终值。其余链条（天气行扣留、
  上拉白雾、底栏引导、开屏广告、比例尺、切页/切 2D-3D）未触碰。
- **防回归门禁（逻辑级）**：`/tmp/gcc_anchor_sim.py` 按真机数值（tab 栏 498→763 ⇒ 目标
  436→701）逐拍仿真新旧逻辑：旧逻辑 3 拍（≈36 帧）落在中部位，新逻辑 **0 拍**。
- **真机验收标准**：冷启动逐帧扫 `y768-958`（原图 x 820）**必须 0 帧**；且**按钮出现
  时刻不得早于搜索栏**；按钮最终位置窗口系 606-694（底边贴搜索栏上方 8pt）不变。

**教训（新增）**：
5. **「锁定最终值」的代码必须真的锁最终值**。变量名 `SearchBarSettledY`（Settled）与注释
   「缓存最终 y」都在说最终值，代码却是「第一帧」—— 注释与实现分歧是最难查的一类 bug，
   比没有注释更危险。
6. **拦症状之前先算一遍「正确位置是多少」**。六轮都在拦 app 的写入，却没人算过
   「钳位目标 = 搜索栏 y - 8」在启动瞬态下等于多少 —— 一算就发现 428 与实测裸露位置
   逐位吻合。
7. **取证代码同样是代码**。第一版取证包因一个局部 `dispatch_source_t` 被 ARC 释放，
   采样表 0 条记录，只能靠录屏反推；它也要过「真的跑了吗」这一关。

## 三、跨版本验证汇总

| 版本 | 项目 | 结果 |
|:--|:--|:--|
| 0.6.0 | 上拉闪白（地图区 std） | 全程未掉出正常区间 **通过** |
| 0.6.0 | 切页搜索栏 | 三方向第一帧即在位 **通过** |
| 0.6.1 | 切 2D/3D 天气行位移 | 中位漂移 2.0 pt **通过** |
| 0.6.2 | 切模式瞬时下坠 | 4 次事件全消除 **用户确认** |
| 0.6.6 | 冷启动天气行归位 | 左边缘 pt 85（期望 86）**通过** |
| 0.6.7 | 底栏「上拉发现」 | 整段录屏未见提示态 **通过** |
| 0.6.9 | 切页后地图区残差 | 0 帧超阈（原 50 帧）**通过** |
| 0.7.1 | 开屏广告 | 待真机确认 |
| 0.9.8 | 构建门禁（静态） | 双架构 0 警告 · 旧版本串残留 0 · cpusubtype `0x2` · 载荷路径与 `Depends` 解包核验 **通过** |
| 0.9.8 | 运行时（真机） | 冷启动右下按钮裸奔已定位（见 §W），其余待验收 |
| 0.9.9 | 右下按钮冷启动位置 | 修复未生效：仍裸露 21 帧（getItemTag 时序）|
| 0.9.10 | 右下按钮冷启动位置 | 仍未归零：14 帧（window 前置条件与几何判定双重失效）|
| 0.9.11 | 右下按钮冷启动位置 | 未归零：4 帧（67ms）—— app 只改 frame，不改 hidden/alpha |
| 0.9.12 | 右下按钮冷启动位置 | 未归零：2 帧（33ms）—— 裸露源是兜底开闸，非 app 写入 |
| 0.9.13 | 右下按钮冷启动位置 | **仍未归零：14 帧（233ms，较 0.9.12 反弹）** → 系列整体回退 |
| 0.9.14 | 构建门禁（静态） | 双架构 0 警告（剥离开/关**双跑**）· 0.9.13 版本串残留 0 · cpusubtype `0x2` · 载荷路径与 `Depends` 解包核验 · 按钮链与 0.9.7 **函数级逐字比对通过** **通过** |
| 0.9.14 | 右下按钮冷启动位置 | **仍未归零：18-21 帧（350ms）** → 触发取证包（见 §Y） |
| 0.9.16 | 锚点逻辑（仿真） | 按真机数值逐拍仿真：旧逻辑 3 拍落中部、新逻辑 **0 拍** **通过** |
| 0.9.16 | 构建门禁（静态） | 双架构 0 警告（剥离开/关**双跑**）· 0.9.14 版本串残留 0 · `cpusubtype 0x2` · 载荷路径与 `Depends` 核验 · 载荷与交付 dylib 逐字节一致 **通过** |
| 0.9.16 | 右下按钮冷启动位置 | 待真机逐帧复验（验收：中部裸露 = 0 帧 且 按钮不早于搜索栏出现） |

> 本表只收录**有明确记录**的条目；0.8.0–0.9.7 各版的逐版真机结论未逐条回填。

---

## 四、核心机制（可复用）

- **冷启动跳动** — 隐藏 → 定位 → 一次性显示 + 逐 widget `AlignedKey` + 顶边对齐
  + `setFrame`/`setCenter` 钳位 + `didMoveToSuperview` 同步重挂。
  **守卫不能写成 `b.superview &&`**，否则漏掉「被摘掉」这条。
- **顶部模糊** — `WINAMapHome*SearchBar*State` 的 `*ImmersiveState` → 改派 `*EmptyImmersiveState`。
- **白块** — `sheet.hidden` / `maskView.hidden` / `bottomMaskLayer.hidden`；
  移除会露出上拉发现面板白底。
- **胶囊跟手** — 只写 `origin.x` 与宽度，**绝不碰 transform**
  （位置基准是 app 用 transform 建立的）。
- **文本识别** — 任何类都试 `text / attributedText / attributedString / title /
  tipText / hintText`，`ObjectGetter` 先验「返回 `@` 且无参」才不会误调 setter。
- **对齐逻辑** — 按**尺寸自识别**，不依赖缓存实例 + 一次性标记
  （app 重建视图树时标记会丢）。

---

### §Y · 0.9.15 —— 锚点「定格后才锁定」（思路正确，但真凶不是它）

**现象**：0.9.14（完整回退到 0.9.7 语义）真机**仍裸露 18–22 帧**。
diag 日志给出关键事实：`tag=template_mainmapRightBottom`、`精确判定=1` ⇒ 六轮「tag 不匹配 / 时序」
猜测全部作废；按钮实例**零次**被 app 隐藏，出生即可见。

**当时的假设**：`SearchBarSettledY` 锁的是**第一帧**而非定格值。搜索栏跟随 tab 栏定位
（`tabFrame.origin.y - height - 12`），启动期 tab 栏在迁移（498→763），搜索栏先停 y≈436、
最终停 701 —— 锁定 436 ⇒ 钳位目标 `436-8 = 428` 恰好等于 App 原生中位槽，双方一致，
按钮被稳钉在屏高 40%。

**施工（A1–A6）**：A1 锚点改为**定格后才锁定** + 几何不变量（目标须落容器底部 30%，
`ColdTicks<30` 允许自愈重锁）；A2 锚点未定格时 `AlignCornerWidgets` 直接 return；
A3 新增 `didMoveToWindow` 精确 tag 钩子；A4 兜底阈值 12→16；A5 版本与文档；
A6 修 diag 定时器在 ARC 下被释放（`dispatch_source_t` 必须文件级强引用）。

**结果**：**真机仍裸露 22 帧 / 367 ms** ⇒ 假设被推翻，交给 §Z 定案。
0.9.15 录屏实测中部裸露帧为 F0150–F0171、`y=384px`（= win 系 340），与日志逐位吻合，
成为 §Z 结论的对照基线。

**关键代码位置**：`src/GaodeClean.m` 锚点锁定段（`SearchBarSettledY` 赋值处）、
`AlignCornerWidgets` 入口守卫、`AlignOneWidget` 几何不变量；`src/GCCDiag.h` 定时器持有。

---

### §Z · 0.9.16 —— 七轮误靶的终点：中部裸露的真身是 App 原生控件

**现象**：冷启动约 2.5s，屏幕右侧中部（win系 y≈340，即屏高 40%）出现 ⊙+↰ 白色胶囊，
约 0.35s 后瞬移到底部搜索栏上方。用户录屏逐帧可复现。

**七轮修复史（全部无效）**

| 版本 | 手段 | 中部裸露帧数 |
|:--|:--|:--|
| 0.9.7 | （基线，未干预） | 用户当时反馈「无问题」 |
| 0.9.8 | A8 兜底解耦 | 19 帧 |
| 0.9.9 | W1a `setHidden:` 拦截 | 21 帧 |
| 0.9.10 | W1b/W1c 几何+纯类名 | 14 帧 |
| 0.9.11 | W1d `didMoveToWindow` | 4 帧 |
| 0.9.12 | W1f `setFrame:`/`setCenter:` 中部拒绝 | 2 帧 |
| 0.9.13 | W1g 兜底验位 | 14 帧 |
| 0.9.14 | 全量回退到 0.9.7 语义 | 18~22 帧 |
| 0.9.16 | 锚点定格后才锁定（A1-A6） | 22 帧 |

**真根因（diag2 日志 + 录屏三方铁证）**

中部那个胶囊**不是** `WINAJXCombinedWidgetView`（七轮一直在藏的对象），而是高德 App 自己的：

```
WINLiteWidgetGroupView(339,340,44x88)   ← 原生「轻量控件组」容器（真身）
  UIVisualEffectView(339,340,44x88)     ← 毛玻璃底（白胶囊外观的来源）
    WINLocationView(339,340,44x44)      ← ⊙ 定位图标
    （↰ 路线图标同级）
```

铁证链：

1. **t=0.613**（`SB=0`，搜索栏未定格）：我们的控件**尚未创建**（采样行 `W0`），
   而中部**已经有** `WINLiteWidgetGroupView(339,340)` ⇒ 中部胶囊的出现**不依赖我们的控件**。
2. **t=1.187**：`setFrame:->(339,281) win系(339,340) hid=1` —— App 在中部摆它时，
   **它本身处于隐藏态**（我们 A3 的 `didMoveToWindow` 已生效）。
3. **全档 97 条采样**：我们的控件 `89 条 @(339,606) hid0`（**只在正确底部位可见**）
   ＋ `8 条 @(339,340) hid1`（在中部位时**全部隐藏**）；`hid0` 从未出现在 y≈340。
4. `setHidden:` 三连：`1.184 藏在(0,59)` → `1.218 藏在中部(已隐藏)` → `1.656 只有到正确位 606 才解除隐藏`。
5. 暴露窗口 = **`SB=0` 全程**（0.33–1.6s）；`SB=1` 后中部立刻清空。

⇒ **我们的按压逻辑 100% 生效；中部裸露物与我们管的对象完全无关。**
也终于解释「为什么 0.9.7 也露」——它**从 0.4.x 起就没人碰过**。

**修复（0.9.16）**

- **A1 按住原生组容器**：`WINLiteWidgetGroupView` 的 `didMoveToWindow` + `layoutSubviews`，
  在 `!SearchBarSettled` 期间 `hidden = YES` 并登记；判据用**几何**排除右上「+/图层」胶囊
  （同类，但出生于窗口顶部 y≈69 ≈ 窗高 3.6%，故以「y > 窗高 25%」区分）。
- **A2 定格后由我们放行**：`AlignCornerWidgets` 扫描时缓存 `CachedLiteGroup`；
  `AlignOneWidget` 显示右下控件时把它一并 `hidden = NO` ⇒ 胶囊与我们的控件**同时**出现，
  背景与图标不缺。另设安全网（`SB=1` 且 `ColdTicks>16` 仍未配对则强制放行）。
- **A3 诊断增强**：`WINLiteWidgetGroupView` / `WINLocationView` 纳入事件与逐拍探针；
  `mid` 列表增加**有效可见性**判定（沿祖先链查 `hidden`/`alpha`）——这是本轮唯一盲点，
  「祖先隐藏」的视图仍会被列出，上一版据此无法断定有效可见。
- **A4** 版本 0.9.16 + 文档。

**教训（第 15-17 条，见 §五）**

**关键代码位置**：`src/GaodeClean.m` 按钮钩子区（A1 两钩子 + `GCCIsLiteGroupCapsule()`）、
`AlignCornerWidgets` 扫描段（`CachedLiteGroup`）、`AlignOneWidget` 放行段（A2）、
tick 链安全网；`src/GCCDiag.h`（A3 探针）。

**真机复验（2026-10-22，录屏 `video_DB2D22B5.mp4` 逐帧）**：中部裸露 **0 帧**
（0.9.14 18–22 帧 / 0.9.15 22 帧 367ms → 0.9.16 **0 帧 0ms**）。
模板匹配全画面扫描（归一化互相关，阈值 0.55）**唯一命中点 (384,684)**，
首现 F0199 = 3.300s，与搜索栏**同帧**出现；右上「+/图层」胶囊 2.617s 起全程在屏未被误伤。

---

### §AA · 构建通道迁移：正式 deb 一律由 GitHub CI 构建（2026-10-22）

**背景**：此前正式包全部由本机 iSH 自研 clang 链产出（`clang` + `/tmp/sdk165` +
`-fuse-ld=lld` + `scripts/fixarch.py` + `scripts/mkdeb.py`）。该链路有三个硬伤：
① 只存在于本机，任何人拿到仓库都无法一键重建；② 与 Darwin 工具链二进制不同源，无法在
macOS runner 复现；③ 人工上传大文件到 Release 易断。

**新约定（用户 2026-10-22 下达）**：**所有项目的正式 deb 一律由 GitHub Actions 构建**；
本地自研链降级为「临时验证」，产出物不得作为发布资产。与既有的「RootHide 一律 GitHub CI」
合并为「**全部架构一律 CI**」。

**改造（A1–A5，源码零改动）**

| 项 | 内容 |
|:--|:--|
| A1 | 原自定义 Makefile → `Makefile.local`（本地临时验证，含 `check`/`dev`/`diagdebs`）；新增 theos 版 `Makefile`（根）：`ARCHS = arm64 arm64e`、`TARGET = iphone:clang:16.5:15.0`、`INSTALL_TARGET_PROCESSES = AMap`、`FINALPACKAGE=1` 时注入 `-DGAODECLEAN_STRIP_LOGS=1` |
| A2 | 新增 `.github/workflows/build-theos.yml`：`macos-14` + theos（roothide fork，pinned `cfba89a…`）+ sdks（pinned `0222fd5…`）+ `brew install ldid dpkg`，matrix `[rootless, roothide]`，`make package FINALPACKAGE=1 THEOS_PACKAGE_SCHEME=<scheme>` |
| A3 | 新增 `scripts/verify_deb.sh` 核验门禁：包名/版本/架构标签、载荷前缀（`/var/jb/...` vs `/Library/...`）、dylib 切片（`lipo -info`）、维护脚本路径、**GCLog 诊断串残留哨兵**（`strings \| grep -F '[GaodeClean] '`）、过滤器 `com.autonavi.amap` |
| A4 | 打 `v*` tag 时自动发布 Release：deb×2 + dylib×2 + `git archive` 生成的干净 `Source.zip`（剔除 `dist/`、`.theos/`、`packages/`）+ `SHA256SUMS.txt`（release job 跑 `ubuntu-latest`，不耗 macOS 额度） |
| A5 | 版本号不变（源码 = 真机已验收的 0.9.16 同源），README/HISTORY 同步说明 |

**可行性已核实**：本工程源码仅 `UIKit/Foundation/objc runtime` + `NSClassFromString` 私有类，
**不含 substrate/logos**（唯一 hook 手段 `method_setImplementation` + `__attribute__((constructor))`），
无私有头依赖 ⇒ theos 化零风险。

**额度约束（实测）**：GitHub Free 私有仓库每月 2,000 min，macOS 按 **×10** 计。
2026-10 已用 Linux 496 min + macOS 431.8 min（≈4,318）⇒ **超 2,814**，
私有仓库 macOS job 会被拒（steps=0，注解「recent account payments have failed or your spending limit needs to be increased」）。
`11-01` 重置后约可跑 60–100 次双架构构建（本工程双 job 预估 ≈3 macOS min）。
发布前若额度不足，需：临时转公开（窗口约 3 分钟）／等重置／提额。

**关键文件**：根 `Makefile`、`Makefile.local`、`.github/workflows/build-theos.yml`、`scripts/verify_deb.sh`。

---

### §AB · 0.9.17 —— ⊙/↰「连接车机」间隙对表原生（整组上移 12.4pt）

**起因**：用户提供一段 **未改动的原生高德录屏**（886×1920@120fps / 16.6s / 997 帧）与一张原生截图，
指出「原生的连接车机位置在天气上方，2D/3D 按钮在小胶囊上方」。

**取证方法**：把原生录屏与我们的 CI 版录屏放在**同一坐标口径**下逐元素模板匹配
（归一化互相关；模板取自定格帧，阈值 0.55；坐标标定 `px = pt × 1.1272`）。

| 元素 | 原生 | 我们 0.9.16 CI | Δ |
|:--|--:|--:|--:|
| ⊙ 图标（模板 score） | **599.7pt**（1.000） | 612.1pt（0.906） | **+12.4pt** |
| ↰ 图标（模板 score） | **632.5pt**（1.000） | 644.9pt（0.934） | **+12.4pt** |
| 搜索栏白底顶边 | 702.6pt | 702.6pt | 0 |
| 天气行（22°C/19°C 行） | 649.4..669.8 | 649.4..669.8 | 0 |

**判定**：两个图标位移**完全一致**（12.4 / 12.4）⇒ 是**整组平移**，内部间距未坏；
搜索栏与天气行两边**逐位一致** ⇒ 差值 100% 来自我们写死的底边间隙：

- 原生：胶囊底边 683.1 → 搜索栏顶边 702.6 ⇒ **间隙 19.5pt**
- 我们：胶囊底边 695.7 → 搜索栏顶边 702.6 ⇒ **间隙 6.9pt**（= 源码里的 `- 8`）

**这一条同时解释用户提到的两句话**：① 我们下压 12.4pt 后，⊙/↰ 贴住了天气行，
原生「在天气上方」的关系被吃掉；② 2D/3D 按钮由 App 自己摆放（我们不动），
胶囊下压 12.4pt 后两者间隙比原生小 12.4pt（原生截图里该间隙约 11pt ⇒ 我们实际 ≈ −1.4pt，等于压住）。

**施工（A1–A3，源码 3 处同源常量）**

| 项 | 文件·行 | 原码 | 改后 |
|:--|:--|:--|:--|
| A1 | `src/GaodeClean.m:1632`（`AlignOneWidget`） | `CGFloat targetBottom = barTop - 8;` | `= barTop - 20;` |
| A2 | `src/GaodeClean.m:1788`（`setFrame:` 钳位） | `= SearchBarSettledY - 8;` | `= SearchBarSettledY - 20;` |
| A3 | `src/GaodeClean.m:1808`（`setCenter:` 钳位） | 同上 | 同上 |

> **必须三处同改**：只改 A1 的话，`setFrame:`/`setCenter:` 的钳位会把摆放拉回旧位（0.5.1 起的既有耦合）。

A4：`control` → 0.9.17；README 版本行/功能表/版本链/门禁表同步；A5：走 GitHub CI 出双架构包。

**验证口径**：`make -f Makefile.local check` 双跑 0 警告；`rg -n 'targetBottom = '` 应只剩 3 处 `- 20`；
真机复验用同一模板匹配，**Δ 应 ≈ 0**（改前 12.4pt）。

**关键文件**：`src/GaodeClean.m`（3 处常量）、`control`、`README.md`。

**A6 · 发布门禁补强（本轮自身踩坑的固化）**

| # | 事实 | 修法 |
|:--|:--|:--|
| 1 | 0.9.17 只改了 `control`/文档，**漏改源码 `kGCVersion`（行 21）** ⇒ 包名是 0.9.17、体内日志却仍报 0.9.16 | 改 `kGCVersion = @"0.9.17"`；`scripts/verify_deb.sh` 新增**版本串一致性断言**（control 的 `Version` 必须能在体内找到 + 不得残留同族旧版本串） |
| 2 | 新断言首跑「误判失败」——真因是脚本自己的坑：`set -o pipefail` + `strings \| grep -q`，grep 命中即退出 → `strings` 吃 **SIGPIPE(141)** → 管线状态非零 → **命中被读成未命中** | 所有断言改为「先取值再比较」：`HIT=$(strings … \| grep -cF … \|\| true); [ "$HIT" -gt 0 ]`。同一坑在 GCLog 哨兵处已存在（方向相反 ⇒ **假通过**），一并修掉 |

**验证**：新断言对「刚发布的缺陷包」判定 FAIL、对修正后的本地包判定 PASS（正反两向都验过）。

---

### §AC · 0.9.18 —— 车机钮 / 天气行 / 2D3D 三项对表原生

**起因**：0.9.17 真机反馈两条 ——
① 「连接车机按钮还是在天气旁边，没有按原生摆在天气上方」
② 「2D3D 按钮还是在屏幕中间，没有按原生在定位和线路小胶囊上方」

**实测（原生录屏/截图 vs 我们 0.9.17，同口径逐元素比对）**

| 元素 | 原生 | 我们 0.9.17 | 差 |
|:--|:--|:--|:--|
| ⊙ / ↰ 图标 | 599.7 / 632.5pt | **599.7 / 632.5pt** | **0** ✅（0.9.17 修对了） |
| 车机钮（白方块） | y 616..652 | y 648..682 | **低 30pt** |
| 天气行 | x=10, y 670..690 | x=56, y 650..672 | 右移 46 / 高 20 |
| 2D/3D 按钮 | y 543..580（胶囊正上方） | y 294..320（屏高 35%） | **高 250pt** |

**根因（三条，皆有源码/实测铁证）**

1. **车机钮与胶囊共用同一个间隙常量**（`AlignOneWidget` 的 `barTop - 20`），但原生两者不同：
   胶囊底 683 = 搜索栏顶 702.6 − 19.5；车机钮底 652 = 702.6 − **50.6**。共用 ⇒ 车机钮低 30pt，
   正好被塞进天气行。0.9.17 只改了常量数值（8→20），**没意识到两者不该共用**。
2. **天气行「搬到车机钮右侧」是 0.5.33 起的假设**（`CGRectGetMaxX(carRect) + 8`），从未对过表。
   原生关系是「车机钮在上、天气行在**正下方**、两者左对齐（x=10），间隙 18pt」。
3. **App 把 2D/3D 按钮锚在「组容器 `WINLiteWidgetGroupView` 上方 15pt」**，而我们这个组容器
   冷启动期停在 (339,340)。铁证：我们 2D 底 325 与组容器顶 340 的间隙 = **15pt**，
   与原生（2D 底 580、胶囊顶 595）**完全同构** ⇒ 锚点对象一致、只是锚点本身位置错了。
   （旁证：0.9.14 的 diag 日志里同类容器在 y=516，接近原生 —— 偏移是后续改动引入的。）

**施工**

| # | 位置 | 内容 |
|:--|:--|:--|
| A1 | `src/GaodeClean.m:28-31`、`:1831-1832`、`:1853`、`:1871`、`:1891`、`:2990-2991` | 新增 `GCGapCar=50` / `GCGapCapsule=20` / `GCGapMapType=15`；`AlignOneWidget` 与 `HookWidgetSetFrame`（含 setFrame/setCenter 两处钳位）改为**按类传间隙** |
| A2 | `:1236-1241` | 天气行改回原生关系：`x = 车机钮 minX`、`top = 车机钮 maxY + 18` |
| A3 | 新增（`:1740-1796`）、调用 `:1833` | 新增 `GCCViewTreeHasMapTypeLabel` / `GCCFindMapTypeButton` / `AlignMapTypeButton`：按「尺寸 26..64 方形 + 右列 + 子树含 2D/3D 文字」双重守卫识别，摆到 `胶囊顶 − 15`；**刻意不打 AlignedKey**，避免与胶囊那套钳位打架 |
| A4 | `src/GCCDiag.h`（采样段） | 新增 `RIGHT:` 行：每拍 dump 右列（x>0.65W、14..90pt）视图树（类名+frame+hidden+父类），含 2D/3D 命中标记 ⇒ 万一 A3 未命中，一次装包即得类名与父链 |
| A5 | `control`→0.9.18、README、本节 | 版本与文档同步；另出 `0.9.18+diag3` 调试包 |

**门禁**

- 本地双跑 0 警告；调用点/常量一致性扫描全绿。
- `scripts/verify_deb.sh`：四包全部核验通过（正式包 11 项 + 调试包按「非发布不变量」跳过剥离断言，
  版本串按**基版本**比对）。调试包判定依据：`control` 的 Version 含 `+`。

### §AD · 本地链修复 —— 调试包不再产出「名字冒充正式包」的 deb

**事实**：0.9.18 出包时先跑 `make -f Makefile.local`（正式）再跑
`make -f Makefile.local RELEASE=0 EXTRA=-DGAODECLEAN_DIAG_LOG=1 OUT=distdiag`。
第二条命令的打包步骤仍用仓库 `control`（Version 0.9.18）⇒ 在 `distdiag/` 里**额外**产出
`com.jibamao.gaodeclean_0.9.18_iphoneos-arm64.deb`，但它内部是**未剥离的调试 dylib**。
复制交付时按文件名取件 ⇒ 正式包位置放进了调试构建（体积 74,582B vs 正确 63,418B 暴露）。

**根因**：`Makefile.local` 的打包步骤硬编码 `--control control`，`OUT` 与 `CONTROL` 不可分别指定。

**修法**：新增 `CONTROL ?= control`，打包步骤改用 `--control $(CONTROL)`；调试包改为
```bash
sed 's/^Version: \(.*\)$/Version: \1+diag3/' control > /tmp/control.diag
make -f Makefile.local clean
make -f Makefile.local RELEASE=0 EXTRA="-DGAODECLEAN_DIAG_LOG=1" OUT=distdiag CONTROL=/tmp/control.diag
```
⇒ 只产出正确命名的 `..._0.9.18+diag3_*.deb`。

**附带门禁**：交付前**逐包开包核验**（`dpkg-deb -x` 后查体内 dylib）：
正式包必须 `GCLog命中=0 且 DIAG命中=0`，调试包才允许两者命中。本轮据此拦下污染件。

---

### §AE · 0.9.19 —— 2D/3D（地图类型）按钮：真身是 `WINPermanentCompassView`

**起因**：0.9.18 真机反馈「2D3D 还是没动」。0.9.18（A3）写了识别器却**从未命中**。

**真机 diag 铁证**（0.9.18+diag3 日志 `shared-449BFE16_gaodeclean-diag.log`，0.9.19 段 665 行起）：

```
RIGHT: ... WINPermanentCompassView(339,286,44x44)hid0^MapWidgetContainerView
             UIView(339,286,44x44) UIVisualEffectView(339,286,44x44) ...
```

- 那个 44x44 圆钮 = `WINPermanentCompassView`（Amap 类名复用，父类 `MapWidgetContainerView`）
- 它的子视图**只有毛玻璃**（`UIVisualEffectView` 一系），**子树里没有任何 2D/3D 文本视图**
  ⇒ 0.9.18 的「子树含 2D/3D 文本」判定**必然失败**（文字是自绘/图片）
- `RIGHT:` 行封顶 14 条，早期采样被别的条目挤满，所以 6.242s 前看不到它（不是不存在）

**位置铁证（原生录屏模板匹配，同一模板同一口径）**：

| | 2D 按钮顶 | 胶囊顶 | 差 |
|:--|--:|--:|--:|
| 原生 | **536.7pt**（score 0.622） | 594 | **57.3** |
| 我们 | **283.0pt**（score 0.627） | **340（冷启动瞬态位）** | **57.0** |

⇒ **App 摆 2D 按钮的规则 = 「胶囊顶 − 57.3」**；我们的构建里 App 用胶囊的**冷启动瞬态位(340)**
当锚（我们 0.9.16 起把胶囊按在 340），于是按钮被钉在 283，**与原生差 253.7pt ≈ 594−340 = 254**。

**施工 A1–A4**：
- **A1** `GCGapMapType` 15.0 → **13.3**（原生 594 − 580.7；0.9.18 的 15 偏 1.7pt）
- **A2** `GCCFindMapTypeButton` 重写为**三级识别**：
  ① 文本判定（保留，跨版本通用）→ ② **类名判定**（`Compass`/`MapType`/`MapStyle`/`MapMode`）
  → ③ 兜底「BFS 序里第一个 40..48 方形」；
  新增 `GCCIsClaimedWidget`（不碰已认领的车机钮/胶囊/组容器及其祖先后代）；
  `AlignMapTypeButton` 加**重入保护** + **`SearchBarSettled` 闸**（绝不拿瞬态位当锚）
- **A3** 新增 `WINPermanentCompassView` 的 `layoutSubviews` / `didMoveToWindow` 两条钩子：
  每次 App 布局完立刻按「胶囊顶 − GCGapMapType」纠正，不必等 200ms 轮询（类名与 tick 双保险）
- **A4** `GCCDiag.h` 新增 `MAPTYPE:` 诊断行（命中档位 + 类名 + frame + 目标底），下一轮日志可自证

**验证**：双跑门禁 0 警告；diag 变体编译通过（`MAPTYPE:`/`未识别到`/`0.9.19 2D/3D 摆位` 三条
字符串经 UTF-16 搜索均在体内 —— 中文字面量编成 `__ustring`，`strings` 搜不到是正常现象）。

---

### §AF · 0.9.20 —— 清探针 + 清日志（发布收尾）

**起因**：2D/3D 通过真机验收后，用户指令「去掉探针和日志」并交付正式源。

**A1 清探针（全部删除，非仅关开关）**

| 对象 | 处理 |
|:--|:--|
| `src/GCCDiag.h`（真机取证模块，462 行） | **整文件删除**；`#include` 与 `GCDiagInstall()` 调用一并移除 |
| `GAODECLEAN_DEBUG_SPLASH` 环境开关 + `GCReportSplashClasses()`（全类枚举探针） | 函数与 2 处调用（install / +1s/+3s 定时）删除 |
| `GAODECLEAN_DEBUG_HOOKS` 环境开关（hook 跳过提示） | 删除，恢复静默 `return` |
| 构建侧 | `Makefile` 去 `DIAG` 分支；`Makefile.local` 去 `diagdebs`；工作流去 `diag` 输入与分支 |

**A2 清日志（8 处 `NSLog` 全清）**

启动横幅 3 条、`signature=`、app version、`loaded`、hook 跳过、广告窗黑名单跳过、开屏守卫命中 —— 全部移除。
正式包内 `[GaodeClean] ` 计数从「8 条」降为 **0**。

> ★ 连带约束（踩过的坑）：`kGCSignature` / `kGCSection` 清日志后变成未使用常量 ⇒ `-Wunused-const-variable` 会
> 破「0 警告」门禁，故一并删除；**`GaodeCleanSignature()` 保留**（它引用 `kGCVersion`/`kGCAuthor`/`kGCRepo`，
> 既让这些常量保持「已使用」，也让版本串仍在包内 —— 门禁第 6 条「版本串一致性」正是靠它才成立）。

**A3 门禁改口径**

`verify_deb.sh` 第 5 条从「GCLog 剥空 + 保留 8 处 NSLog」改为**双零断言**：

- 探针哨兵：`gaodeclean-diag|GAODECLEAN_DEBUG|GAODECLEAN_DIAG_LOG|WINSplash classes at runtime|hook SKIPPED|splash guard hooked|ad-window blacklist SKIPPED`
- 日志哨兵：`[GaodeClean] ` 计数必须为 **0**（调试包自动跳过）

**A4 版本与详情**

`control` → 0.9.20；`Description` 重写为结构化多行（主要效果 / 全版本自适应 / 装后注销提示），
Sileo 详情页排版更清晰；工作流 Release 正文重写（装哪个包对照表 + 本版说明 + 功能一览 + 校验 + 构建说明）。

**实测**：双跑编译 **0 警告**；本地双包门禁全绿（探针 0 / 日志 0 / 版本串 `0.9.20` / 载荷路径正确）；
`Installed-Size` 198 KB（arm64）/ 200 KB（arm64e）。

### §AG · 0.9.20 —— 最高级加固：字符串混淆加密 + 链接期符号剥离

**起因**：老大追加要求「最高级加密混淆成品 deb」。此前 0.9.x 一直沿用
「发布构建剥日志 + FINALPACKAGE 剥调试符号」，`strings` 仍能一眼读出全部
Amap 私有类名（`WINPermanentCompassView`/`WINLiteWidgetGroupView`/…）与
全部 selector，等于把「这个 tweak 打了什么」直接摊开。

**A1 编译/链接期加固**（`Makefile`、`Makefile.local` 同步同口径）

| 项 | 原状 | 现状 |
|:--|:--|:--|
| 可见性 | 默认 | `-fvisibility=hidden`（内部符号不外露） |
| 本地符号 | 保留（`AlignCornerWidgets`/`CachedLiteGroup`/`SearchBarSettledY` 等公开可读） | `-Wl,-x` 全部剥离 ⇒ `nm -a` 本地符号 **0** |
| 死代码 | 保留 | `-Wl,-dead_strip` |
| 编译器标识 | 默认 | `-fno-ident` |

**A2 全部内部字符串混淆加密（本轮主体）**

- 规模：**441 个 `@"…"` 字面量 / 295 条唯一串 / 430 个替换点**。
- 方案：`scripts/gen_obf.py` 扫描源码 → 逐串独立密钥（`0xA7 + idx*31`）做
  `b ^ key` → 加位置相关偏移 `17*(idx+i)+3` → 按 `(idx+i)%8` 左旋，得密文表；
  写入 `src/GCStrData.h`（`gcObfBytes` 4,582 字节 + `gcObfTab` 295 条），
  并把源码中的字面量整体改写为 `GCStrAt(idx)`。
- 运行时：`src/GCStr.h` 懒解码 + `NSMutableArray` 缓存（每条只解一次，
  非热点零开销）；纯 C 解码数学抽到 `src/GCObfMath.h`，主机与设备**同一份代码**。
- 刻意**不加密**的只有 3 个文件级 `static NSString *const`（`kGCAuthor`
  /`kGCRepo`/`kGCVersion`）——C 静态初始化必须是编译期常量，无法用函数替换。
- 刻意**不做**的：不加反调试 / 反 VM（会与 Dopamine/RootHide 冲突，见全局约定）。
- 系统公开 API（UIKit/Foundation 的类名与 selector）不加密也无意义：它们本就出现在
  App 自身镜像里，藏不住也不影响判定。

**A2 自证（关键：加密不能把功能改坏）**

- `scripts/obf_selftest.c`：用 `GCObfMath.h` 在主机上把 295 条密文全部解回明文，
  逐条与 `scripts/obf_strings.txt` 比对，并校验数据头内嵌的 FNV-1a 摘要
  `GC_OBF_FNV = 0x80C5B4682D5E281C`。
- 结果：`PASS 混淆回环 295/295 条逐字节一致`；已接入 `make -f Makefile.local check`
  与 CI（`Obfuscation round-trip self-test` 步骤），今后任何一次改串都会自动复验。
- 数据头可从清单**逐字节复现**：`python3 scripts/gen_obf.py --from-list` 重生成的
  `GCStrData.h` 与在用版本 diff 仅多一行摘要 ⇒ 清单顺序/密钥/旋转全部可追溯。

**A3 加固连带踩坑：版本串被 `-dead_strip` 删除（当场修）**

- 现象：加固后门禁报 `体内版本串与 control 不一致：control=0.9.20 … dylib 内找不到`。
- 根因：`kGCVersion` 只被 `GaodeCleanSignature()` 引用，而后者在 0.9.20 清日志后
  **已无任何调用者** ⇒ 死代码被整段移除，字符串随之消失。
- 修法：构造函数内以内存屏障钉住该串（不进任何功能路径）：
  `__asm__ volatile("" :: "r"(kGCVersion.UTF8String) : "memory");`
- 复验：`strings -a` 命中 `0.9.20` **1** 处，本地符号仍为 **0**。

**A4 门禁新增（`scripts/verify_deb.sh` §7a/7b/7c）**

- **7a 混淆生效**：`WINPermanentCompassView|WINAJXCombinedWidgetView|WINLiteWidgetGroupView|WINDeviceInterconnectWidget|WINGroupMapWidget|amap_bundle_quickservice` 命中必须 **0**。
- **7b 中文关键词**：`酒店/加油站/超市/停车场` 无明文残留（注意中文字面量在 Mach-O 里是
  UTF-16/`__ustring`，`strings` 查不实，须按 UTF-16 形状核验）。
- **7c 本地符号**：`nm -a` 的 `t/s` 符号数 ≤ 2（实测 0）。

**A5 交付面**

- `control` 新增「已加固」说明（Sileo 详情可见）；`control` 体积 916 → 1,073 B。
- CI 源码包**刻意剔除** `scripts/obf_strings.txt`（明文清单只留私有仓库），
  避免「二进制混淆了、源码包又把明文送出去」。

**实测（本地链，双架构）**：双跑编译 **0 警告**；混淆回环 **295/295 PASS**；
两包门禁各 **14 项全 OK**（含 7a/7b/7c）；arm64 dylib 190,416 B / arm64e 191,072 B。

### §AH · 0.9.21 —— 面向用户的详情文案「只讲功能」（并补做爱源地址）

**起因**：老大指出做爱源详情页与包描述里塞的是**构建内幕**（`-Wl,-x`、295 条字符串加密、
混淆自证、清探针清日志）——用户看不懂、也不关心，而真正的卖点（去白雾、2D·3D 归位、
冷启动不闪）被埋到第二屏。要求「只介绍功能，优化文案」，并追加「把做爱源地址加到详情内容」。

**A1 详情页重写**（`depictions/com.jibamao.gaodeclean.json`，由 `workspace/gaodesrc/build_dep.py` 生成）

| 原状 | 改后 |
|:--|:--|
| 「0.9.20 更新」整段讲编译链接参数、加密条数、自证结果 | 小节化：**插件描述 → 主要功能（界面精简 / 位置归位 / 稳定不闪）→ 适配与兼容 → 安装说明 → 信息表** |
| 更新日志写「清探针清日志 / 字符串混淆」 | 改用户语言：「2D·3D 按钮回到定位·路线胶囊正上方」等可感知结果 |
| 无源地址 | 安装说明首句给「在 Sileo 添加源 `https://gan-jibamao.github.io`」+ 信息表新增「源地址」行 |

**A2 包描述同步**：`control` 的 `Description` 删掉「已加固：链接期剥离全部本地符号…」段落，
换成功能分项 + 加源指引；`Version` 0.9.20 → **0.9.21**，`kGCVersion` 同步（两处必须同改，
否则门禁版本串一致性直接报错）。体积 1073 → 1379 B。

**A3 踩坑（脚本自检）**：生成脚本内置「内幕字样扫描」（混淆/加固/符号/剥离/加密/探针/自证/`-Wl`/FNV 必须命中 0），
首版把 tab 名「更新**日志**」里的「日志」误判成内幕 ⇒ 扫描范围由整个 JSON 收窄为 `tabs[*].views`（只扫正文，UI 标签不算）。

**实测**：`make -f Makefile.local check` 全绿（0 警告 + 混淆回环 295/295 PASS）；
本地双包门禁 **15/16 项 [OK]、exit 0**；体内版本串 `0.9.21` ×1、`0.9.20` 残留 **0**；
敏感明文 0、本地符号 0（加固不回退）。

### §AI · 0.9.22 —— 搜索栏 / 底栏缩窄（对原生截图逐像素定量后定值）

**起因**：老大给出原生截图并要求「把搜索栏和底栏缩窄一点，变窄多少你决定，优化整体最佳视觉」。

**原生定量**（截图 1179px @3x = 393×852pt，逐像素测边界）

| 元素 | 左→右 | 宽 | 两侧留白 |
|:--|:--|:--|:--|
| 搜索栏可见白胶囊 | 10.7 → 382.3pt | 371.6pt | 10.7pt |
| 底栏（首页/我的）可见胶囊 | ≈9.5 → 383.5pt | 374pt | ≈10pt |
| 右侧地图控件（+ / 图层 / 定位） | 353 → 383pt | 30pt | 右 10pt |

**定值**：两条栏**两侧各 24pt**（宽 345pt，比原生窄 26.6pt ≈ 7.2%）。理由：与地图控件（10pt）拉开
「内容层 vs 控件层」的层次，两条栏彼此**同宽同边距**；比原生明显但不激进。数值由单一常量
`GCBarInset` 控制（调大 = 更窄）。

**A1 施工（`src/GaodeClean.m`）**

- `GCBarInset = 24.0` + `GCNarrowClamp()`：**绝对宽度规则**——凡「居中、两端都在屏内 40pt 内、
  宽 ≥ 屏宽-60、高 ∈ [20, 屏宽×0.35]」的条，一律收到左端 24pt、宽 345pt；幂等（已达标即放行）。
- `GCNarrowVisibleLayer()`：**运行时自适应取层** —— 容器可能是「全宽透明容器 + 内嵌可见胶囊」，
  也可能是胶囊本身；优先取「最宽的合格直接子视图」，取不到就用容器自身，两种情况都能收窄。
- `GCNarrowHookClass()`：给被判定的那一层挂 `setFrame:` 钳位 —— App 或我们自己的布局代码再写一次
  也会被同规则夹回，**不会出现 100ms 级的撑开/回缩抖动**。
- 挂点 4 处：搜索栏捕获处（`SearchBarView = bar` 之后）、底栏 `layoutSubviews` 钩子内、
  `CachedTabBar = bar` 处、tick 每 5 拍（≈0.5s）兜底重认（实例/类被换掉时自动跟上）。

**安全边界（防误伤整屏容器）**：只处理**被捕获的这两条栏及其直接子视图**，且必须同时满足上述几何条件，
并显式排除窗口自身与 `window.rootViewController.view`。

**验证（纯 C 复刻同一套规则仿真，`scripts/clamp_sim.c`，`gcc -O2 scripts/clamp_sim.c -lm && ./a.out`）**

- 正例 **5/5**：容器满屏宽 / 胶囊内缩 10.7 / 底栏容器 / 底栏胶囊 / 底栏高 70pt → 全部收到 **x=24、w=345（两侧 24）**
- **幂等 ✓**：连夹两次，第二次一像素不变
- 反例 **7/7 不动**：窗口根内容视图（393×852）、窗口自身、200pt 窄视图、非居中宽视图、
  过高视图（200pt > 屏宽×0.35）、超屏宽、端头太靠左（L=60）
- 小屏：320pt 屏 → 272pt 宽（同样 24pt 边距，不越界）

**同类问题自查（施工中抓到）**：一度新增 `HookVoid(GCStrAt(88), GCStrAt(92), …)` 想再加一个入口，
但清单第 92 项是 `AUGlobalBlurService`（**类名，不是 selector**，91 才是 `layoutSubviews`）——
属无效空钩子。改为把缩窄挂进**既有**的底栏 `layoutSubviews` 钩子。

**版本**：0.9.22；`control` 与 `kGCVersion` 两处同步；双跑 0 警告；混淆回环 295/295 PASS；
本地双包门禁 15/16 项 [OK]、exit 0；体内版本串 `0.9.22` ×1。

### §AJ · 0.9.23 —— 缩窄第二版：底栏也生效（v1 的取层方式先天漏底栏）

**现场反馈**：「搜索栏好像变窄了，搜索栏下面的没有变化」—— 搜索栏生效、**底栏没动**。

**v1（0.9.22）的破绽（根因）**：v1 的取层是「**从捕获引用向下**找可见层」：
`GCNarrowVisibleLayer(SearchBarView)` / `(CachedTabBar)`。
- 搜索栏命中：容器是我们自己按全宽摆的（`parent.bounds.size.width`），**白胶囊就是它的直接子视图** ⇒ 向下能找到。
- 底栏落空：底栏的可见胶囊**不在被捕获的那个视图里**（极可能是它的父级或兄弟层）⇒ 向下找永远找不到，
  于是 v1 对底栏等于空操作。**这是取层方式先天缺陷，不是参数问题**（参数只影响宽度，不影响命中）。

**v2 改法（不再依赖捕获引用）**

| 项 | v1（0.9.22） | v2（0.9.23） |
|:--|:--|:--|
| 取层来源 | 捕获引用（`SearchBarView`/`CachedTabBar`）向下找 | **按窗口几何在「下屏条带」直接发现**，与捕获引用解耦 |
| 判定 | 与捕获引用同容器 | 完全在屏内 + 居中（中轴偏差 ≤4pt）+ 宽 ≥ 屏宽-60 + 高 ∈ [20,110]pt + 中线在下 30% 条带 |
| 夹哪些层 | 只夹找到的那一层 | 条带内**所有**合格层都夹到**同一绝对几何**（左端 24pt、宽 屏宽-48）⇒ 可见层无论落在哪一级都必然收到目标宽度，父子两层叠加也不会翻倍 |
| 防回弹 | 仅 `setFrame:` | `setFrame:` + `setBounds:` + `setCenter:` **三重钳位** |
| 兜底 | 每 5 拍（0.5s）重认捕获引用 | 每 5 拍**全条带重扫** + **每拍**轻量复核（只比宽度，达标即放行） |

新增实现：`GCNarrowIsBar`（判定）、`GCNarrowClamp`（绝对几何、幂等）、`GCNarrowCollect`（条带收集，
深度 ≤6，子树底边高于 0.55H 直接剪枝）、`GCNarrowDiscover`（重扫 + 挂钳位 + 记弱引用表）、
`GCNarrowRecheck`（每拍）、`GCBarWindow`（窗口取用）、`GCNarrowOneBar`（兼容 v1 调用点，只标脏）。

**安全边界**：绝不碰窗口自身与 `window.rootViewController.view`；高度上限 110pt 把「更大的面板容器」排除在外；
宽度 ≤ 目标（345）直接放行 —— 幂等，也是绝大多数视图的最快路径（一次比较）。

**验证（`scripts/clamp_sim.c` 按 v2 语义重写）**

- 正例 **6/6** 收到 x=24 / w=345：搜索栏容器、搜索栏胶囊、**底栏容器（父级）**、**底栏可见胶囊（父级内缩 9.5）**、
  **底栏胶囊（无合格父级，独立存在）**、底栏高 70pt —— 后三格正是 v1 漏掉的形态
- **幂等 ✓**（连夹两次一像素不变）
- 反例 **6/6 不动**：根内容视图、过大面板（高 130 > 110）、窄条（200pt）、非居中、条带外（屏幕中部）、横向出屏
- 小屏/大屏：320pt → 272pt 宽；430pt → 382pt 宽（两侧恒为 24pt）

**★ 施工中抓到的两个真问题（都当场修）**

1. **构建实际失败、而 `make check` 给了假绿灯（P1，门禁缺陷）**
   v2 模块定义在 tick 之后，tick 里对它俩的首次引用成了隐式声明 ⇒ 真实构建 4 个 error。
   但 `make -f Makefile.local check` 报「静态门禁通过」—— 根因：check 只 `grep -q 'warning:'`，
   **从不检查 clang 的退出码**，于是「有 error、无 warning」被判为通过。
   修法：`out=$(clang …); rc=$?; if [ $rc -ne 0 ]; then … FAIL: 编译未通过（exit=$rc）… fi`。
   **双向自测**：对坏源码 → `FAIL: 编译未通过（exit=1）`；补前置声明后 → 通过。
2. **v2 函数用在该文件更早位置 ⇒ 需前置声明**：在既有前置声明区补
   `GCNarrowSetDirty()` / `GCNarrowRecheck()`，修复后真实构建通过。

**教训（补入 §五）**：静态门禁必须以**退出码**为准，只看日志关键字必然假绿灯；
文案/门禁类改动做完必须跑一次**真实构建**（`make`），不能只信 `check`。

**版本**：0.9.23；`control` 与 `kGCVersion` 同步；细节页更新日志改用户语言
（「底栏（首页 / 我的）也可缩窄了：修 0.9.22 只有搜索栏生效的问题」）。

### §AK · 0.9.24 —— 缩窄第三版：两条路径并存（v2 把搜索栏漏在高上限）

**现场反馈（录屏，无文字）**：逐帧测量定标后确认为 **v2 的副作用**：

| 元素 | 视频实测（393×852pt 定标后） | 原生 | 判定 |
|:--|:--|:--|:--|
| 搜索栏白胶囊 | 10.6..382.3pt（宽 371.7） | 371.6pt | **原生宽度（0.9.22 的收窄丢了）** |
| 底栏胶囊 | ≈24..370pt（宽 ≈346） | ≈374pt（两侧 9.5） | **已收窄 ✓（几何发现生效）** |

**定标方法（关键，避免误判设备）**：录屏 886×1920 无元数据可辨机型；先用「首页」文字墨水高度
（比例 0.727）粗估 → 误差大；改用**两侧都必然相同的元素**——搜索栏白胶囊高度：
视频 120px ÷ 截图 53.3pt = **2.251 px/pt ⇒ 屏宽 393.6 ≈ 393pt** ✓（与截图同一机型）。

**根因（我的 v2 阈值）**：v1 判定高度上限是 `屏宽×0.35 = 137.6pt`；v2 我收紧成 **110pt**。
搜索栏容器（可点区域，含内边距）高度落在 **110~137.6** 之间 ⇒ v2 不认它 ⇒ 搜索栏回原生；
底栏可见胶囊高 ~50-70pt ⇒ 能被认到 ⇒ 收窄 ✓。**两条观测完全自洽，是阈值问题不是取层问题。**

**v3 改法：两条路径并存**

| 路径 | 规则 | 负责 |
|:--|:--|:--|
| **捕获引用**（v1 路径） | `GCNarrowPickFrom(bar)`：bar 自身与直接子视图里挑最宽合格层；合格判定用**宽松高度上限 屏宽×0.35**，不要求下屏条带 | 搜索栏（0.9.22 实测有效） |
| **几何发现**（v2 路径） | 下屏条带 + 严格高度上限 **110pt**（排除更大面板） | 底栏（0.9.23 实测有效） |
| 钳位（共用） | 高度上限放宽到 **屏宽×0.35**，其余（宽≥屏宽-60/居中/在屏内）不变 | 两条路径共用，防回弹 |

- 新增 `GCNarrowAlike`（宽松判定）、`GCNarrowPickFrom`（取层）、`GCNarrowCaptured`（捕获引用弱表）、
  `GCNarrowFromCaptured`（重认）；`GCNarrowOneBar` 恢复「立即取层 + 记录引用 + 标脏」；
- tick 每 5 拍：`GCNarrowSetDirty()` + `GCNarrowFromCaptured()`；每拍：`GCNarrowRecheck()`；
- 几何发现改为**扫所有窗口**（不再只认 keyWindow）；收集深度 6 → 10。

**验证**（`scripts/clamp_sim.c`）：
正例 **6/6** 收到 x=24/w=345；**幂等 ✓**；反例 **6/6 不动**（根内容视图/高 150pt 过大面板/窄条/非居中/条带外/横向出屏）；
新增高度分路径用例：可见胶囊高 53pt ✓、容器高 120pt ✓（钳位路径）、面板 180pt 不动 ✓。

**教训**：收紧判定阈值（110 < 137.6）会**静默丢功能** —— 判定类改动必须拿「已生效的旧值」做回归对照（本次正是 0.9.22 生效、0.9.23 失效）。

### §AL · 0.9.25 —— 搜索栏/底栏缩窄 v4：两条栏等宽（修「多夹了一层」）

**现场输入**：第二支录屏（886×1920，5.14s，≈59fps，约 31 帧可用）。

**定标（复用 §AK 技法）**：搜索栏白胶囊高度 120px ÷ 原生 53.3pt = **2.251 px/pt ⇒ 屏宽 393pt**（与首支视频同机型）。

**逐帧测量（末帧，扣圆角/子像素误差约 ±1.5pt）**：

| 元素 | 实测 | 原生 | 判定 |
|---|---|---|---|
| 搜索栏**白胶囊** | **33..357pt（宽 324）** | 371.7（容器 393 内缩 10.65/侧） | ❌ 与底栏不等宽 |
| 底栏**灰胶囊** | **24..370.5pt（宽 346）** | 374 | ✅ 达标 |
| 底栏内容 | 页签中心 136.2 / 256.2（胶囊中心 197） | — | ✅ 居中正常 |

**根因（破绽链，机制级）**：
0.9.24 的 `GCNarrowPickFrom` 挑的是「**最宽合格层**」= 搜索栏的**包装容器**（393）；夹成 345 后，App 按自己的内缩把白胶囊摆成 `345 − 21.3 = 323.7`。
而白胶囊此时 **< 333（= 屏宽−60）**，**不再被几何发现认领**；`GCNarrowRecheck` 又只会「收窄」不会「回补」（只判 `>`）⇒ 白胶囊**永久停在 324**。
⇒ 两条栏从此不等宽（搜索 324 / 底栏 346）。**不是阈值问题，是「多夹了一层」。**

**修法（v4，最小改动、底栏零改动）**：
- **A1** 新增三条判据 + 一个取层：
  - `GCNarrowInSearchSubtree(v)`：沿 superview 链判断是否在捕获的搜索栏子树内；
  - `GCNarrowInnerLike(v)`：**内层胶囊口径** = 同 bar 形状，但下限放宽到 `sw-120`、并**排除满宽容器**（`> sw-12`）—— 这条「排除满宽」正是区分「包装容器」与「里面的白胶囊」的判据；
  - `GCNarrowInnerBarDescendant(v)`：深度 ≤4 内找最宽的「内层胶囊」（有它 ⇒ v 是包装容器）；
  - `GCNarrowPickFrom` 改为**优先取最内层可见胶囊**。
- **A2** `GCNarrowClamp` 增补：
  - **搜索栏的包装容器整体放行**（`inSearch && InnerBarDescendant(v) ⇒ return f`）⇒ App 每次仍把白胶囊摆到 371.7，我们把它夹到 345 ⇒ **稳定且与底栏齐平**；
  - 内层胶囊的**下限闸门放宽**到 `target*0.8`（276），使其无论被内缩吃成多少都能进入夹取；
  - **唯一一条回补通道**：`isInner && 宽度 ∈ [0.85×target, target)` ⇒ 允许加宽回 345（自愈竞态）。
- **A3** `GCNarrowRecheck` 对「已判定且登记在案」的层做**条件回补**（仅内层胶囊、仅 85% 阈值内），不再只有「收窄」一个方向。
- 底栏走几何发现路径，判据不含搜索子树 ⇒ **一个字都没改**（防回归）。
- 常量仍只有 `GCBarInset = 24`（宽 345pt = 393−48）。

**验证**：
- 决策仿真 `scripts/narrow_v4_sim.c`（已接入本地 `make check`，防回归）：
  - S1 搜索栏包装容器 393 ⇒ **放行不动**（修 v3 的错）✓
  - S2 白胶囊 371.7 ⇒ **夹到 345**（与底栏齐平）✓
  - S3 **竞态自愈**：胶囊被容器内缩吃成 323.7 ⇒ **回补到 345** ✓
  - S4 底栏 346 ⇒ 不动 ✓；S5 根内容视图 393 ⇒ 不动 ✓；S6 窄条 200 ⇒ 不动 ✓；S7 非居中 ⇒ 不动 ✓
  - H1 面板 180pt ⇒ 不动（超高度上限）✓；H2 内层胶囊 120pt ⇒ 345 ✓；H3 内层胶囊 150pt ⇒ 不动 ✓
  - **PASS 全部用例通过（失败 0 项）**
- 编译双跑 **0 警告**（`make check` 已含退出码判定 + 混淆回环 295/295）；
- 本地双包门禁：rootless **15/15 [OK]**、roothide **16/16 [OK]**，exit 0。

**影响范围**：仅缩窄模块的目标宽度决策；两条栏、其余功能、加固混淆（字面量仍全加密）均不变。可回退 0.9.24。
## 五、教训

1. **视图「不见了」按三个通道依次排除** — `hidden` → `alpha` → `removeFromSuperview`；
   三个都无效时，第四类是**「归位逻辑的调度频率不够」**
   （缺席时长呈 16.7 ms 整数倍即为特征）。
2. **不要碰子树** — `WINMultiStyleRootView` 子树含搜索栏，摘它的手势 = 按死搜索栏（0.5.42 事故）。
3. **改「面板背景」前先确认底下有没有别的视觉层**（0.5.3 清 alpha → 露出容器自带磨砂玻璃）。
4. **跨版本同指标对照**是识别「我引入的回归」最快的手段；否定证据（拦截记录为空）同样是硬信息。
5. **先确认基于哪个源码版本编的**（0.5.52 基于 0.5.51 编译 → 静默删掉已验证的修复）。
6. **瞬态事件要用瞬时偏离检测** — 「持续 ≥N 帧才算异常」会漏掉 1–4 帧的下坠（0.6.1 的教训）。
7. **UI 判据先拿已知正确的帧当标尺**再去量别的（参考帧最近邻胜过自定义特征）。
8. **钩子只落在目标类**；周期性扫描先定范围上界再谈频率（0.6.7a 卡死事故）。
9. **热路径上不能有文件 I/O、全树遍历、几何换算** —— 底栏布局路径上挂了个写文件的诊断，
   一直没被发现，直到逐帧量差分才暴露（0.6.8 / 0.6.9）。
10. **重复 `HookVoid` 对会互相顶掉**（`Replace()` 走 `method_setImplementation`），加钩子前先查重。
11. **兜底不能挂在「任一成功」的群体标志上** —— 标志一旦被第一个成功的成员置位，
    其余成员的兜底就永久失效。兜底必须按**成员自身状态**判断，不要按群体标志
    （0.9.8 A8：`HomeSettled` 被任一 widget 置 YES → 其余仍隐藏的控件失去 2.4s 兜底，
    表现为右下定位钮凭空消失）。
12. **守卫只接受一种签名，就等于静默拒绝其他签名** —— 挂钩器只支持「2 参 + void」，
    4 参返回对象的构造器钩子就**从未装上**，而且一声不响。任何「不匹配就 return」
    的守卫都必须留痕，否则等于把 bug 藏起来（0.9.8 A4：`initWithFrame:model:` 的
    「重复点首页」清理从未执行）。
13. **「先隐藏、对齐后再显示」必须覆盖所有显示路径** —— 只挂 `layoutSubviews` 等于只堵一条门；
    `setHidden:` / `setAlpha:` 都是 app 的合法显示入口，漏一条就会以原生位置裸奔
    （0.9.9 §W：右下按钮在屏幕中部裸露 310ms 后瞬移 301pt）。
14. **压 alpha 的拦截，放行时必须同时恢复 alpha 与 hidden** —— 只恢复 `hidden`、alpha 仍是 0，
    控件会「逻辑可见、视觉全透明」，比不修更难查（0.9.9 W2/W3 的自伤点，W4 补齐）。

---
15. **静态门禁必须判退出码**：只 grep 日志关键字（如 `warning:`）会把「有 error、无 warning」判成通过（0.9.23 实测假绿灯）；文案/门禁改动后必须跑一次真实构建。

## 六、构建与产物

### 一键构建（0.9.8 起）

需要 theos 的 SDK：<https://github.com/theos/sdks> → `iPhoneOS16.5.sdk`

```bash
make SDK=/path/to/iPhoneOS16.5.sdk        # arm64 + arm64e + 两个 deb
make check SDK=/path/to/iPhoneOS16.5.sdk  # 只跑 0 警告门禁
```

`Makefile` 内部就是「clang 两条 + fixarch.py 一次 + mkdeb.py 一次」，
参数与产物命名全部与本节下文一致。

deb 打包用 `scripts/mkdeb.py`（Python 写 `ar` 归档，不需要 `dpkg-deb`）；
版本号从 `control` 的 `Version` 读，`Installed-Size` 按真实载荷计算。

> **arm64e 是这样出来的** —— 两件事都要处理：
> 1. lld 不支持 arm64e 的 `-fixup_chains`（只支持 x86_64 与 arm64），
>    所以 arm64e 切片走经典 `LC_DYLD_INFO_ONLY` 绑定，**不加** `-Wl,-fixup_chains`。
> 2. **clang 的 arm64e 后端是对的（`.o` 里 cpusubtype=2），但 lld 写出 Mach-O 时会把
>    输出头的 cpusubtype 写成 0。** dyld 用
>    `(cpusubtype & ~CPU_SUBTYPE_MASK) == CPU_SUBTYPE_ARM64E` 判断「是否为 arm64e 映像」，
>    判错就会把认证指针按普通 arm64 处理 —— 第一次走 `__got` 槽就崩。
>    所以签名之后必须用 `scripts/fixarch.py <dylib> 2` 修正 subtype **并重算签名页哈希**
>    （cpusubtype 在 header 偏移 8，落在第 0 页里）。
>
> ```
> # arm64e 切片
> clang -target arm64e-apple-ios15.0 -isysroot $SDK -fobjc-arc -fblocks \
>   -fobjc-runtime=ios-15 -O2 -dynamiclib -fuse-ld=lld \
>   -Wl,-install_name,@rpath/GaodeClean.dylib -Wl,-adhoc_codesign \
>   -framework UIKit -framework Foundation -framework CoreGraphics -framework QuartzCore \
>   src/GaodeClean.m -o GaodeClean-arm64e.dylib
> python3 scripts/fixarch.py GaodeClean-arm64e.dylib 2
> ```
>
> 校验：`csverify.py` 应报「页哈希 45/45 通过」；头部 cpusubtype=2、cputype=0x100000c。

### deb 布局

| 包 | 切片 | data 载荷路径 | Depends |
|:--|:--|:--|:--|
| rootless / Dopamine | **arm64** | `var/jb/Library/MobileSubstrate/DynamicLibraries/` | `firmware (>= 15.0), mobilesubstrate` |
| RootHide | **arm64e** | `Library/MobileSubstrate/DynamicLibraries/` | `…, mobilesubstrate, oldabi` |

| 环境 | 装机路径 |
|:--|:--|
| rootless / Dopamine | `/var/jb/Library/MobileSubstrate/DynamicLibraries/` |
| RootHide | `/Library/MobileSubstrate/DynamicLibraries/`（jbroot 内） |

装完 `sbreload` 或重启用户空间。

### 本包产物（0.9.16）

| 文件 | 说明 |
|:--|:--|
| `GaodeClean-0.9.16.dylib`（arm64）| 201,776 B · rootless / Dopamine |
| `GaodeClean-0.9.16-arm64e.dylib` | 203,248 B · RootHide（`cpusubtype 0x2` 已由 `fixarch.py` 修正）|
| `com.jibamao.gaodeclean_0.9.16_iphoneos-arm64.deb` | 62,488 B · rootless（载荷 `/var/jb/Library/MobileSubstrate/…`）|
| `com.jibamao.gaodeclean_0.9.16_iphoneos-arm64e-roothide.deb` | 61,972 B · RootHide（载荷 `/Library/…`，`Depends` 含 `oldabi`）|
| `com.jibamao.gaodeclean_0.9.16+diag_*.deb` | 取证包（行为与正式包一致，仅多 `-DGAODECLEAN_DIAG_LOG=1`）|
| `dist/GaodeClean-0.9.16-Source.zip` | 完整源码（src + control + scripts + tools + Makefile + GCCDiag.h）|

**0.9.16 日志分档**：正式包由 Makefile 注入 `-DGAODECLEAN_STRIP_LOGS=1`，
12 处每事件级 `GCLog` 在编译期展开为空操作（`strings` 已验证全部消失）；
装机核对所需的 8 处 `NSLog` 保留。需真机排查时用 `make dev` 出带日志的调试包。

> 产物体积随代码增长而变；以 `make` 的实际输出与 `dist/SHA256SUMS.txt` 为准。
> **体积跳变提示**：0.9.16 较 0.9.15 文件 +16,752 B，而 `__text` 仅 +1,544 B ——
> 差额是 `__got` 跨 `0x4000` 页边界的对齐填充（16,384 B），与 0.9.8 审计时的同一现象，**非重复代码**。

### 每次发版自检清单

```bash
# 1. 版本号三处一致
grep -n 'kGCVersion' src/GaodeClean.m; grep '^Version:' control

# 2. 无重复 HookVoid 对（后装顶掉先装）
python3 -c "import re;s=open('src/GaodeClean.m').read();\
p=re.findall(r'HookVoid\(\"([^\"]+)\",\s*@\"([^\"]+)\"',s);\
print([x for x in set(p) if p.count(x)>1] or 'none')"

# 3. 零磁盘 I/O
rg -n 'writeToURL|dataWithContentsOfFile|NSFileHandle' src/GaodeClean.m   # 应为空

# 4. 载荷与新编译件一致
cmp <(ar p dist/*.deb data.tar.gz | tar xzO ./var/jb/.../GaodeClean.dylib) dist/GaodeClean.dylib
```

---

## 七、版本链

```
0.3.1   基线
0.4.0   底栏两圆钮
0.4.3   圆钮对齐搜索框
0.4.8   首页搜索栏去文字
0.4.19  首帧锁定
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
0.6.4   调度链断链修复
0.6.6   冷启动天气行归位
0.6.7   底栏「上拉发现」根除
0.6.7a  ✗ 卡死事故（已回滚）
0.6.7b  重写：只作用底栏子树
0.6.8   切页响应 · 清除残留文件 I/O
0.6.9   快修窗不再空转
0.7.1   开屏广告移除
0.7.2   常驻开销收敛
0.7.3   滚动热路径收敛
0.7.4   ✗ 后台/静默期收敛（真机有问题，已回退）
0.7.5   启动黑屏根因修复（窗口拉黑保险丝 + 有界化）
0.8.0   高德 17.01.0 适配：版本白名单 + WINSplashScreen 判定层
0.9.0   取消版本限制（修复 17.01.1「失效」；全版本自适应）
0.9.1   拦截「上拉发现」引导 Lottie（17.01.1 GuideLottie 机制）
0.9.2   冷启动搜索栏闪断修复（117ms 消失 → 0ms）
0.9.3   冷启动天气行错误位置闪现修复（350ms 错位 → 0）
0.9.4   源码审计优化（告警 14→0；死代码清除 + 热点轻量化）
0.9.5   冷启动 LOGO 中屏闪现修复（半件 130ms → 0）
0.9.6   回归修复：LOGO 搬运叠压天气（搬运面收归单一）
0.9.7   200米比例尺误关修复（首次释放后封网 + 位置门槛）
0.9.8   审计修复 15 项：崩溃面 / 兜底失效 / 6 条热路径 / 构建链
0.9.9   冷启动右下按钮「屏幕中部裸奔」修复（显示路径全覆盖）
0.9.10  右下按钮拦截补几何兜底（getItemTag 晚写入导致 W1 失效）
0.9.11  显示路径补齐：纯类名判定 + didMoveToWindow（四条通道全覆盖）
0.9.12  拦截 setFrame:/setCenter: 中部写入（app 只挪位置时的唯一通道）
0.9.13  兜底显示前验位置（裸露源=兜底开闸而非 app 写入）—— 系列失败，已回退
0.9.14  回退 W 系列，恢复 0.9.7 显示语义（真根因：HomeSettled 门控被拆）—— 真机仍裸露，见 §Y
0.9.15  锚点「定格后才锁定」+ 几何不变量 + 未定格不摆位（假设：SearchBarSettledY 锁了第一帧）—— 真机仍裸露 22 帧，见 §Z
0.9.16  §Z：真凶是 App 原生 WINLiteWidgetGroupView —— 出生即藏 + 未定格按住 + 定格后同刻放行  ← 当前（采用）
0.9.16+§AA  构建通道迁移：正式 deb 一律由 GitHub Actions（macos-14 + theos）构建，本地链降级为临时验证
0.9.17  §AB：⊙/↰「连接车机」间隙 6.9 → 19.5pt（整组上移 12.4pt，对表原生）
0.9.18  §AC：车机钮 / 天气行 / 2D·3D 三项对表原生（间隙按类分离 + 天气行左对齐钮下方）
0.9.19  §AE：2D/3D 真身 `WINPermanentCompassView`（三级识别 + 直钩 layout/didMoveToWindow）
0.9.20  §AF 清探针清日志 + §AG 最高级加固：全量字符串混淆加密 + 链接期符号剥离  ← 当前（采用）
0.9.21  §AH：面向用户的详情文案「只讲功能」+ 补做爱源地址（功能与 0.9.20 一致）  ← 当前（采用）
0.9.22  §AI：搜索栏 / 底栏缩窄（两侧各 24pt，宽 345pt，两条栏同宽对齐）  ← 当前（采用）
0.9.23  §AJ：缩窄 v2 —— 按窗口几何发现该收窄的层，底栏也生效（v1 只从捕获引用向下找，先天漏底栏）
0.9.24  §AK：缩窄 v3 —— 两条路径并存（捕获引用负责搜索栏 + 几何发现负责底栏），修 v2 高上限 110 把搜索栏漏掉的问题
0.9.25  §AL：缩窄 v4 —— 两条栏等宽（搜索栏容器不碰，只夹可见白胶囊）  ← 当前（采用）
```

---

## 八、标识

**0.9.20 起（加固后，0.9.21 同口径）**：镜像内**不再**出现作者/仓库标识。原因有二：

1. `GaodeCleanSignature()` 在 0.9.20 清日志后已无调用者，被 `-Wl,-dead_strip` 整段移除，
   其引用的 `jibamao` / `gan-jibamao.github.io` / `GaodeClean by jibamao` 一并消失；
2. 其余全部内部字符串已混淆加密（§AG · A2），`strings` 读到的都是密文。

现在可核对的只剩两项，均为**刻意保留**：

```bash
# ① 安装路径标识（必须叫 GaodeClean.dylib，无法也不该隐藏）
strings GaodeClean.dylib | grep -i gaodeclean        # /Library/.../GaodeClean.dylib
# ② 版本串（门禁与装机核对依赖；由构造函数内存屏障钉住）
strings GaodeClean.dylib | grep -F 0.9.24            # 0.9.24  ×1
```

**无任何自定义日志**：0.9.20 起 `[GaodeClean]` 前缀命中 **0**，启动不再打印版本行。

### §AA 附：CI 通道首次打通与产物核验（2026-10-22 07:0x–07:3x）

**踩坑三连（全部为脚本自身缺陷，产物无问题）**

| # | 失败点 | 铁证 | 修法 |
|:--|:--|:--|:--|
| 1 | `dpkg-deb` 解析 control | `duplicate value for 'Installed-Size' field` | theos 的 `deb.mk` 会剥掉 `Version:`/`Architecture:` 再自行追加，**但不动 `Installed-Size`** ⇒ control 里手写的那行成了重复字段。删除手写行；`mkdeb.py` 改为「有则替换、无则插入」 |
| 2 | 载荷路径误判 | homebrew dpkg 的 `dpkg-deb -c` 输出**不带 `./` 前缀** | 正则改 `(^| )(\./)?PATH$` |
| 3 | 脚本崩溃 | `verify_deb.sh: line 112: NLOG<乱码>: unbound variable` | `$NLOG` 后紧跟**全角逗号**被 bash 并入变量名 ⇒ 一律写 `${NLOG}` |

另修正一处**哨兵设计错误**：正式包**故意保留 8 处 `NSLog`**，拿 `[GaodeClean] ` 当剥离哨兵必然误判；
哨兵改为只出现在 GCLog 里的文案（`blocked tab guide lottie` / `page=%ld anchor=pending` /
`splash ad hidden` / `weather row released` / `fog sweep hides`）。

**最终运行**

- `Build GaodeClean`（tag `v0.9.16`，sha `38617ec`）**双 job success**，run `39741000876`；Release `420422431` 已发布，6 资产齐全。
- 私有仓库额度拦截实测：本月 Linux 496 min + macOS 431.8 min（×10）≈ **4,814 / 免费 2,000**
  ⇒ 私有仓库 macOS job **steps=0 秒失败**，注解「recent account payments have failed or your spending limit needs to be increased」。
  本次经授权**临时转公开**（07:10→07:34，24 分钟窗口），跑完立即转回 private。

**CI 产物核验（回下载逐项）**

| 项 | 结果 |
|:--|:--|
| 6 资产 SHA256 | **6/6 OK**（与 `SHA256SUMS.txt` 一致） |
| 架构标签 | rootless `iphoneos-arm64` / roothide `iphoneos-arm64e` |
| 载荷路径 | `/var/jb/Library/MobileSubstrate/DynamicLibraries/` 与 `Library/MobileSubstrate/DynamicLibraries/` 各就位 |
| dylib 切片 | **两包均为 fat：arm64（sub 0x0）+ arm64e（sub 0x80000002）** |
| 过滤器 | `Bundles=[com.autonavi.amap]`，二进制 plist |
| 维护脚本 | 无（无需路径转换） |
| 日志剥离 | GCLog 哨兵 0 命中；单切片保留 8 处 NSLog（fat 计 16） |
| Source.zip | 33 文件，含 `Makefile`/`control`/`src`/`.github/workflows`；`dist/`、`.theos/`、`packages/`、`.git/` **0 命中** |

**与本地已验收二进制的等价性**：同一份源码、不同工具链 ⇒ 二进制不同（theos 走 `-Os`+strip，
`__text` 58,580 vs 本地 `-O2` 84,964）。静态比对：CI 的 `__cstring` 271 条、`__objc_methname` 199 条
**全部是本地版对应集合的子集**；私有类名（`WINLiteWidgetGroupView`/`WINMultiStyleRootView`/`WINTabBarControl`）、
`didMoveToWindow`/`layoutSubviews`/`setHidden`、ARC 运行时符号（`_objc_retain`/`_objc_release`/`_objc_storeStrong`）均在。
本地版多出的是 `AlignCornerWidgets`/`CachedLiteGroup`/`SearchBarSettledY`/`ColdTicks` 等
**static 函数与变量名**（只存在于符号表，theos 发布构建会剥掉）—— 属预期的发布加固，非功能缺失。

**CI 版真机复验（2026-10-22，录屏 `video_44161DBD.mp4`）**：口径与本地版一致 ⇒ **中部裸露 0 帧**；
竖列全帧扫描 240 命中、y 集合恒为 `{683px = 605.9pt}`（= 日志 win 606）；全宽粗网格 61 命中
位置集合恒为 `{x=384, y=684}`（全屏唯一位置，0 幽灵）；搜索栏/相机/底栏与胶囊**同帧 2.300s** 出现，
不早于搜索栏；右上「+/图层」1.900s 起在屏未被误伤。
⇒ **CI 构建（theos/-Os）与本地构建（-O2）行为一致，通道迁移完成。**
