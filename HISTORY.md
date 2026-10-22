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
0.9.16  锚点「定格后才锁定」+ 几何不变量 + 未定格不摆位（真根因：SearchBarSettledY 锁了第一帧）  ← 当前（采用）
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
[GaodeClean] GaodeClean v0.9.16 | jibamao | https://gan-jibamao.github.io/
```
