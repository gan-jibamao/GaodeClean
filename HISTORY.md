# GaodeClean — 开发记录

> 高德地图 UI 精简 tweak。纯 ObjC runtime hook，不依赖 substrate 私有 API，
> 不碰网络与 IPA，只改视图层。

| | |
|:--|:--|
| **当前版本** | `0.7.2` |
| **Author** | **jibamao** — <https://gan-jibamao.github.io/> · Section `jibamao-Tweaks` |
| **目标** | 高德地图 / AMap `com.autonavi.amap` **17.00.2** |
| **架构** | `arm64` 单切片（rootless + RootHide 两种包） |

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

---

## 六、构建与产物

### 本机直接编译（iSH / Alpine aarch64，无需 macOS 与 theos 本体）

需要 theos 的 SDK：<https://github.com/theos/sdks> → `iPhoneOS16.5.sdk`

```bash
SDK=/path/to/iPhoneOS16.5.sdk

clang -target arm64-apple-ios15.0 -isysroot $SDK -fobjc-arc -fblocks \
  -fobjc-runtime=ios-15 -O2 -dynamiclib -fuse-ld=lld -Wl,-fixup_chains \
  -Wl,-install_name,@rpath/GaodeClean.dylib -Wl,-adhoc_codesign \
  -framework UIKit -framework Foundation \
  -framework CoreGraphics -framework QuartzCore \
  src/GaodeClean.m -o GaodeClean.dylib
```

deb 打包用 `scripts/mkdeb-local.py`（Python 写 `ar` 归档，不需要 `dpkg-deb`）。

> **arm64e 是这样出来的** —— 两件事都要处理：
> 1. lld 不支持 arm64e 的 `-fixup_chains`（只支持 x86_64 与 arm64），
>    所以 arm64e 切片走经典 `LC_DYLD_INFO_ONLY` 绑定，**不加** `-Wl,-fixup_chains`。
> 2. **clang 的 arm64e 后端是对的（`.o` 里 cpusubtype=2），但 lld 写出 Mach-O 时会把
>    输出头的 cpusubtype 写成 0。** dyld 用
>    `(cpusubtype & ~CPU_SUBTYPE_MASK) == CPU_SUBTYPE_ARM64E` 判断「是否为 arm64e 映像」，
>    判错就会把认证指针按普通 arm64 处理 —— 第一次走 `__got` 槽就崩。
>    所以签名之后必须用 `tools/fixarch.py <dylib> 2` 修正 subtype **并重算签名页哈希**
>    （cpusubtype 在 header 偏移 8，落在第 0 页里）。
>
> ```
> # arm64e 切片
> clang -target arm64e-apple-ios15.0 -isysroot $SDK -fobjc-arc -fblocks \
>   -fobjc-runtime=ios-15 -O2 -dynamiclib -fuse-ld=lld \
>   -Wl,-install_name,@rpath/GaodeClean.dylib -Wl,-adhoc_codesign \
>   -framework UIKit -framework Foundation -framework CoreGraphics -framework QuartzCore \
>   src/GaodeClean.m -o GaodeClean-arm64e.dylib
> python3 tools/fixarch.py GaodeClean-arm64e.dylib 2
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

### 本包产物（0.7.1）

| 文件 | 说明 |
|:--|:--|
| `dist/GaodeClean-arm64.dylib` | 181,088 B · arm64 · chained fixups + adhoc 签名 |
| `dist/GaodeClean-arm64e.dylib` | 182,416 B · arm64e · dyld_info 绑定 + adhoc 签名 |
| `dist/com.jibamao.gaodeclean_0.7.2_iphoneos-arm64.deb` | rootless |
| `dist/com.jibamao.gaodeclean_0.7.2_iphoneos-arm64e-roothide.deb`（arm64e） | RootHide |

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
0.7.2   常驻开销收敛                      ← 当前
```

---

## 八、标识

源码与产物均带 `jibamao` 标识：

```bash
strings GaodeClean.dylib | grep -i jibamao
# jibamao
# gan-jibamao.github.io
# jibamao-Tweaks
# GaodeClean by jibamao
```

启动输出：

```
[GaodeClean] GaodeClean v0.7.1 | jibamao | https://gan-jibamao.github.io/
```
