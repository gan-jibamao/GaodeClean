# GaodeClean 0.6.7 — 源码与构建说明

**Author: jibamao** · Repo: https://gan-jibamao.github.io/ · Section: `jibamao-Tweaks`

高德地图 17.00.2 (com.autonavi.amap) UI 清理 tweak。纯 ObjC runtime hook，
不依赖 substrate/frida，不碰网络与 IPA，仅视图层。

## 当前终态 0.6.9 的功能清单
- 底栏两钮居中 + 胶囊(选中视图)跟随选中按钮 (0.3.1 + 0.4.13-0.4.17)
- 左侧车机圆钮、右下组合钮(定位+回正)对齐到搜索框上方 8pt (0.4.3/0.4.4/0.4.40)
- 首页搜索栏下沉 + 首帧锁定 + setFrame/setCenter 钳位 + didMoveToSuperview 重挂自愈
  + **切页 8ms 快修（0.5.57/0.5.58，见下）**
- 首页搜索栏去文字(城市名/滚词) (0.4.7/0.4.8)
- 来扫街(template_oparate_icon) + 扫街榜(template_rank) 隐藏 (0.4.7)
- 探索/附近/我的页裁剪与滚动限制 (0.3.1 机制)
- **底栏上拉白雾/闪白根除 (0.5.44/0.5.50/0.5.53)**
- **顶部「沉浸高斯」模糊带根除 (0.5.8, EmptyImmersiveState 改派)**
- **首页白块根除 (0.5.9, 恢复 sheet/mask/bottomMask hidden)**
- **底栏「上拉发现」提示根除 (0.6.7：周期通道 + 底栏子树扫描 + 标题写回)**
- **切页响应提速：切「我的→首页」不再慢一拍 (0.6.8)**
- **正式包零诊断**：0.6.8 补齐 —— 收掉了残留的 Flatten(win)+写文件、以及读取已不存在的 diagnostics.json

## 本轮（0.5.1 → 0.6.0）主线：两场闪光的追查

### A. 底栏上拉「白雾/闪白」
现象：底栏首页/我的往上滑动松手时，地图被一层白蒙住，短暂后消失。

- 量化（逐帧最小二乘回归）：`out = 0.2035 × in + 204.22` → **一层纯白 alpha≈0.80 的覆盖层**，
  只盖地图区（y>59pt），底栏/搜索栏不受影响（它们画在玻璃之上）。
- **连打 6 版空枪**：钳 `MapWidgetContainerView` alpha、钳 `AMap3DView` alpha、
  钳 `layer.opacity`、拦 VMap `setGlobalShowMask:`、封 `WINMapMaskView`、封 `AUGlobalBlurService`
  —— 诊断全部显示「钳位记录为空 / 该 setter 从未被调用」。
  地图是 C++ 引擎（VMap）直接画在 `AMap3DView` 的 backing layer 上，**无子视图、无子层**，UIKit 层够不着。
- **决定性对照**：逐帧扫 0.5.30 的老视频 → 全程无闪白。**结论：闪白是 tweak 自己造的。**
- **真根因**：0.5.45 起加的各种「拦截上拉」（拒绝手势 / 拒绝 PullUp 状态跃迁 /
  强行 hidden 面板）**打断了 app 的转场动画**，地图被留在「已洗白」的中间态几十毫秒。
- **正解（0.5.50）**：只对 `WINTabBar` / `WINMultiStyleRootView` 的**本体**摘 pan/swipe，
  **绝不碰子树**（子树里有搜索栏），不拦状态机、不抢 setHidden。转场正常跑完 → 不闪。
- 0.5.51/0.5.52 曾误回退到 0.5.44（把 0.5.50 的修复删掉）→ 闪白回归；0.5.53 装回。

### B. 「我的 → 首页」切页时搜索栏闪一下
- 逐帧实测：搜索栏区域亮度掉到 **216–226 档**（正常 254）即「缺席」。
- 排除顺序（**重要方法论**）：
  1. 拦 `layoutSubviews` 强制 `hidden = NO` → 无效
  2. 拦 `setHidden:` 定向拒绝 → 无效
  3. 拦 `didMoveToSuperview` 重挂 → 无效
  → 说明不是「谁藏了它」，而是**归位逻辑跑得太慢**。
- **真根因（代码级）**：搜索栏归位只发生在 `LayoutMinimalHome` 里，
  而它**只由 100ms 的 Schedule tick 驱动**。实测缺席时长恰好是 **16.7ms 的整数倍
  （17/33/67/83/100ms）** —— 就是在「等下一次 tick」。
- **0.5.57**：`KickBarFix()` —— 搜索栏一被 app 动到就启动 16ms 快修窗口，
  640ms 内以 60Hz 反复跑 `LayoutMinimalHome`。100ms → 33ms。
- **0.5.58**：不再等 `selectedViewControl` 翻转（app 切页完成才翻，实测 ~33ms 延迟），
  被摘的同一瞬间直接挂回并显示；快修提到 8ms。**实测：三次切页零缺席（仅冷启动首帧 1 帧）。**

### C. 切 2D/3D 时「天气 + LOGO」位置跳变（0.6.1）
- 用户报告：「切换地图 3D 和 2D，天气和 LOGO 位置在变动」。确认是真问题。
- **量化**（pt 标尺读原生分辨率裁剪）：

  | 元素 | 2D (f171) | 3D (f189/f195) | 位移 |
  |---|---|---|---|
  | ☁ 云图标 | pt 58 | pt 45 | **−13pt** |
  | 30°C | pt 76 | pt 65 | **−11pt** |
  | 🔷高德地图 LOGO | pt 118 | pt 105 | **−13pt** |
  | 比例尺 | pt 215 | pt 215 | 0 |

  同时车机钮 pt18-45 → pt22-50（右移 4pt）—— **天气行与车机钮反向移动**，
  说明不是 app 整体重排，而是「我方对齐丢了」。
- **根因（代码级，`HookWeatherRow` 两个脆弱点）**：
  1. 钩子写成 `if (!objc_getAssociatedObject(v, &AlignedKey)) return;`
     —— 依赖「缓存实例 + 一次性标记」。**切 2D/3D 时 app 重建地图控件树，
     新实例没有 AlignedKey → 钩子第一行就 return → 天气行退回 app 原生位置。**
  2. `CachedRow` 的失效判据是「旧实例的 window 没了」，但切模式时旧实例常常还挂着
     → 缓存一直指着旧的，永远轮不到新实例。
- **修法**：钩子改为**按尺寸自识别**（宽 150–360、高 <40、y 落在地图区、且当前是首页），
  认「行」不认「实例」；缓存失效条件补上「尺寸不再匹配」。
- **验证（逐帧）**：云图标高饱和蓝质心追踪，全片 1168 帧
  中位 pt 68.7，**唯一偏移段 f893–f905 仅 Δ2.0pt（转场边界噪声）**；
  约 10 次 2D↔3D 切换，位置零变化。

### D. 切 2D/3D 时天气行「瞬时下坠 17pt 再弹回」（0.6.2）
- 0.6.1 之后用户复报：「切换 2D 和 3D 的时候天气和 LOGO 没有固定位置，在跳动」。**确实还在。**
- **★ 0.6.1 为什么漏掉它（方法论）**：偏移检测器写的是「持续 ≥8 帧才算异常」，
  而**这事件只持续 1–4 帧**，整个被跳过 → 得出了错误的「位置稳定」结论。
  **教训：瞬态（1–4 帧）事件必须用「瞬时偏离」检测（|y−中位| > 阈值即算），不能用「持续段」检测。**
- **量化**（云图标质心逐帧，664 帧 / 5.5s）：
  - 水平已稳（x 中位 raw 39.5 恒定）→ 0.6.1 的水平修复有效
  - 垂直 4 次事件，每次下移 ~17pt 再回落：

    | 事件 | 峰值 | 回落 |
    |---|---|---|
    | f215-216 | 388.7（−16.9pt） | f217 |
    | f252-253 | 389.0（−17.5pt） | f254 |
    | f575-576 | 388.6（−16.7pt） | f577 |
    | f613 | 384.4（−9.3pt） | f614 |

    y 序列：`389 → 383 → 380 → 379`（掉下去再弹回来）
  - **车机钮（对齐基准）y=385.8 全程纹丝不动** → 不是基准漂移，
    是 **app 在推这一行**，我的修正晚 3–4 帧才追上，且写入走隐式动画。
- **0.6.2 修法（零延迟纠回）**：
  1. `AlignWeatherRow` 的写入包进 `[CATransaction setDisableActions:YES]`；
     偏差 >2pt 时 `[row.layer removeAllAnimations]`（否则修正本身也走动画）
  2. **拦截 `WINGroupMapWidget -setCenter:` / `-setFrame:`** —— app 有些时刻不走
     layoutSubviews、直接写位置；现在一写就同步纠回，同一个 runloop 内完成，
     那一帧不会显示在错误位置
  3. 抽出 `IsWeatherRowView()` 尺寸自识别助手（宽 150–360、高 <40、y 在地图区），
     layoutSubviews 钩子与 setter 拦截共用

### E. 冷启动后天气行停在原生位置、切一次页才归位（0.6.6）
- 用户报告：「删除后台重新进高德，冷启动后天气和 LOGO 的位置不正确，
  点击我的再切回首页位置才正确」。
- **★ 定位方式：放弃视频，改加诊断块。** 前四版（0.6.1–0.6.5）都在用视频猜，
  每次都改「何时查找 / 如何对齐」，全部无效。0.6.5d 在 dylib 里加了一段诊断
  （每 5 拍把 tick 状态 + `WINGroup*` 视图树写进 `Documents/GaodeClean-cold.txt`），
  用户导出后**一次定位**：
  ```
  tick#20 ColdTicks=20 win=有 Car=WINDeviceInterconnectWidget
     WINScaleLineLogoMapWidget {{10,411},{188,20}} hid=0 ok=1
     NMScaleLineView           {{96,411},{102,20}} hid=0 ok=0
  ```
- **日志给出的三条硬事实**：
  1. **tick 在跑**（tick#20，冷启动 20 拍后仍在）→ 0.6.4 的断链修复有效
  2. **CachedCar 正常**（车机钮已找到）
  3. **`WINGroupMapWidget` 整个不在视图树里**；承载这一行的是子件
     `WINScaleLineLogoMapWidget`，位置仍是原生 `{{10,411}}`。
     而且它**通过了原有尺寸判据**（`ok=1`，宽 188 / 高 20 / y 411）
     → **判据没错，错的是类名**
- **真根因（贯穿 0.6.1–0.6.5 全版）**：所有查找都硬编码 `WINGroupMapWidget`。

  | 状态 | 视图树里有什么 | 结果 |
  |---|---|---|
  | 正常态（切页后） | 容器 `WINGroupMapWidget` 存在 | 找得到 → 归位 ✅ |
  | 冷启动态 | 容器尚未创建，只有子件 `WINScaleLineLogoMapWidget` | 永远找不到 → 不归位 ❌ |

  这正是「冷启动后位置不对、切一次页才对」：切页会把容器建出来。
- **0.6.6 修法**：`IsWeatherRowClass()` 认三个类名
  （`WINGroupMapWidget` / `WINScaleLineLogoMapWidget` / `WINWeatherLimitView`）；
  查找时**优先外层容器**（存在时它就是整行），否则取最宽候选
  （冷启动时是 188pt 的 `WINScaleLineLogoMapWidget`）。
  同时 `layout` 与 `layoutSubviews` 两个钩子都挂上，tick 路径去掉「只在首页」限制。
- **验证（逐帧）**：f1–f261 天气行在原生位置（pt≈50，左边被裁）；
  **f301 起出现在车机钮正右边** —— 🔷高德地图 pt 85–145、200米 pt 165–215，
  持续到片尾。左边缘 pt 85（期望 86 = 车机钮右缘 78 + 8pt 间距）→ **通过**。

### F. 冷启动后底栏首页偶发显示「上拉发现」（0.6.7，含 0.6.7a 卡死回滚）
- 用户报告：「冷启动后底栏首页会出现上拉发现，是偶发的。」截图确认：底栏左钮（首页）
  在图标位置渲染出黄色「上拉发现」提示，右钮「我的」正常。
- **真根因（三条通道全漏，所以偶发）**：
  1. **时机** —— 0.5.1 的 `HideDiscoverPrompt` 只挂在 `WINTabBar -layoutSubviews` /
     `-amap_relayoutTabItems` 上。而「上拉发现」是**异步引导态**，常在最后一次布局
     **之后**才写进 label —— 那一拍扫空，再没有下一次布局触发 → 提示留在屏幕上。
     冷启动才偶发，正是因为引导态与布局的先后顺序取决于启动耗时。
     **没有周期通道，是这个 bug 存在的根本原因。**
  2. **判据** —— `NodeText` 只对 `UILabel` 读 `text`、对 `AJX*` 前缀读
     `attributedString/attributedText/text`；底栏 item 的标题若是别的自定义 label 类，
     只能靠 `accessibilityLabel` 撞运气。
  3. **处置** —— 即便扫到也只是 `v.hidden = YES`。引导态复用的就是 item 的标题 label，
     隐藏它等于把「首页」两个字一起抹掉。
- **0.6.7 修法（只作用底栏子树，零全局钩子、零新增定时器）**：
  - **A 时机**：复用**已经在跑的 200ms tick** 调 `SweepTabBarHints(CachedTabBar)`；
    另挂 `WINTabBarItem -didMoveToWindow`（item 上树即查一次）。
  - **B 范围**：只走 `WINTabBar` 子树（20–40 个视图，上限 200），**扫描里没有任何
    `convertRect:` / 窗口遍历**。
  - **C 判据**：`TabBarTextOf()` 任何类都依次试
    `text / attributedText / attributedString / title / tipText / hintText`，
    并用 `TextGetterCache` **按类缓存可用的 getter**，之后每拍只剩几次 msgSend；
    命中判据 = 含「上拉」且长度 ≤24（「发现」单独出现不算，正常内容里也有这词）。
  - **D 收尾**：向上找到所属 `WINTabBarItem` → 用之前记下的正常标题写回；
    没有历史值时取 `item.model.title / text / name / tabTitle / displayName`；
    都拿不到（纯引导浮层）才隐藏，且只向上收 3 层、遇 `WINTabBar`/`WINTabBarItem` 即止。
- **★ 0.6.7a 卡死事故（必须记住）**：第一版用了两条「看起来更彻底」的手段，直接把
  app 拖死 ——
  1. `Replace(UILabel.class, @selector(setText:))` / `setAttributedText:`
     → **全 app 每个 label 的每次写文本都要过一次 `imp_implementationWithBlock`**，
     高德主线程直接打满；
  2. 每 200ms（外加命中后 0.8s / 16ms 快窗）`SweepAllWindowsForHints`
     → **全窗口 BFS + 逐节点 `convertRect:`**，一窗几千个视图，地图卡住；
  3. 构造函数里还开了那个 16ms 定时器 —— 冷启动最重的时候扫全窗口。
  **教训：给 UIKit 打补丁，钩子必须落在「目标类」上，绝不能落在基类/基框架类上；
  周期性扫描必须先有范围上界，再谈频率。** 用户实测卡死，随即回滚重写。
- **同时修掉的既有隐患**：`WINTabBar -amap_relayoutTabItems` 在本文件被 `HookVoid`
  装了两次，而 `Replace()` 走 `method_setImplementation` —— 后装的那次会把先装的
  （`CenterTabButtons` / `HideDiscoverPrompt`）**顶掉**。现在两条路径各自带上
  `CachedTabBar = bar` + `CenterTabButtons` + `SweepTabBarHints`，谁后装都不丢功能。
  加钩子前先查重复对：`re.findall(r'HookVoid\("([^"]+)",\s*@"([^"]+)"')`。

### G. 「我的 → 首页」比反向慢一拍（0.6.8）
- 用户报告：「在我的页面切换到首页好像有延迟，不如在首页切换到我的速度快。」
- **这个不对称是结构性的，三个原因叠在一起**：
  1. **首页方向会被早退挡在门外**。`LayoutMinimalHome` 里 `if (!parent.window || !tabBar) return;`
     —— 切页转场中间态 `parent.window` 还是 nil，这一拍整个丢掉，只能等下一次 100ms tick。
     多个 tick 叠加就是你感觉到的延迟。而**反向（首页→我的）只走 `!home` 分支的一条
     `bar.hidden = YES`，一次就完事**，根本不经过这道早退 —— 慢快之差就在这里。
  2. **快修窗是被动的**。0.5.57 的 `KickBarFix()` 只挂在
     `WINQuickSearchBarV2 -didMoveToSuperview` / `-setHidden:` 上 —— 要等 app 先动搜索栏
     才启动。切成首页时 app 未必立刻动它，于是又退回等 tick。
  3. **底栏布局路径上挂着残留文件 I/O**。`CenterTabButtons` 末尾调 `LogCoveringViews(bar)`：
     `Flatten(win)` 遍历整棵窗口树 + 拼最多 130 行文本写
     `Documents/GaodeClean-cover.txt`。0.6.0 宣布「正式包零诊断」时**漏掉了这一处**，
     它一直挂在 `WINTabBar -layoutSubviews` 上 —— 而切页正是底栏密集重排的时刻。
     顺带还有一处：从「我的」页取不到 anchor 时会去读 `GaodeClean-diagnostics.json`，
     那个文件在 0.6.0 之后永远不会再生成，只剩一次无意义的磁盘探测。
- **0.6.8 修法**：
  - `KickBarFixFor(seconds)` 参数化窗口时长（原 `KickBarFix()` = 0.64s 保持不变）；
  - 新增 `WatchHomeTransition(tabs)`：tick 每拍读一次 `selectedViewControl`
    （本来就在读，零额外开销），一旦从别的页翻到【首页】且冷启动结束，立即开 320ms 快修窗；
  - 直接钩 `WINTabBarControl -setSelectedViewControl:`（方法名拿不到就静默跳过，
    tick 那条通道照样兜得住），切到首页的那一瞬间就开窗，最多省下 200ms；
  - 早退分支改为**开 160ms 快修窗**而不是丢弃这一拍，并用 `BarFixStalls` 封顶
    60 段（≈9.6s）—— 否则一旦 `parent.window` 始终不为真，8ms 循环会无限自旋；
  - **删除底栏布局路径上的全部文件 I/O**：`LogCoveringViews` 整段移除，
    `SaveDiagnostics` 与两个调用点移除，读取已不存在的 diagnostics.json 那段移除。
    现在整个源文件零磁盘 I/O。
- **方法论**：用户报的是「方向不对称」，不是「慢」。先问哪个方向慢 ——
  慢的那条一定多绕了一道闸（这里是早退 + 被动等待 + 文件 I/O），
  快的那条就是基线。

### H. 「我的 → 首页」慢：逐帧定位到快修窗空转（0.6.9）
- 0.6.8 之后用户仍报慢，并给了 13.9s / 827 帧的屏幕录制。逐帧量化后定位到真因。
- **★ 方法论：先分清「哪一帧才是运动」。** 多个判据先后把我带偏过：
  底栏胶囊定位（把高亮认成背景）、整页亮度（被「我的」页那张彩色世界地图骗了）。
  最后**用参考帧最近邻分类**（f300=首页、f400=我的）才得到自洽的结果：
  两个方向的内容到位时延其实几乎一样（mine→home 50/58/50ms，home→mine 18/67/67ms）
  —— **所以慢的不是页面内容**。
- **真信号在分区帧间差分**（对照：静止首页地图区 Δ=0.02–0.06，是噪声底）：
  | 区间 | mine→home | home→mine |
  |---|---|---|
  | 搜索栏带 y750-840 | 0.04–0.33 | 0.00 |
  | 地图区 y150-700 | **0.41 → 0.22 持续到 t+0.85s** | 0.00 |
  | 底栏带 y860-920 | 1.37 → 收敛 | 2.00 → 收敛 |
- **根因**：`LayoutMinimalHome` 里写的是**无条件** `bar.frame = ...` + `[parent bringSubviewToFront:bar]`，
  而 0.5.57/0.6.8 的快修窗每 8ms 跑一次它 —— 等于切页后几百毫秒里每 8ms 给搜索栏设一次
  frame 并重排父视图的兄弟层级。**反向（!home）只走一句 `bar.hidden = YES; return;`，
  根本不碰这些** —— 不对称就出在这里。
- **0.6.9 修法**：
  - 先算期望 frame，`CGRectEqualToRect` 相等就不写；层级单独判（只有真被压在下面才
    `bringSubviewToFront:`，它比设 frame 重）；
  - sheet / maskView / bottomMaskLayer 同理，只在需要时写；
  - 新增 `BarFixIdle`：连续 6 拍（≈48ms）没有任何改动 → **立刻收窗**，
    不再把 640ms 的窗口空转完。
- **验证（对照视频的量化口径，装机后跑）**：mine→home 之后地图区 Δ 应在 ~50ms 内
  落到 ≤0.06（原来 0.41 持续 850ms）。

## 核心机制（可复用）
- 冷启动跳动：隐藏→定位→一次性显示 + 逐 widget AlignedKey + 顶边对齐 + setFrame/setCenter 钳位
  + `didMoveToSuperview` 同步重挂（**注意：守卫不能写成 `b.superview &&`，否则会漏掉「被摘掉」这条**）
- 顶部模糊：`WINAMapHome*SearchBar*State` 的 `*ImmersiveState` → 改派 `*EmptyImmersiveState`
- 首页白块：`sheet.hidden / maskView.hidden / bottomMaskLayer.hidden`（移除会露出上拉发现面板白底）
- 胶囊跟手：只写 `origin.x` 与宽度，**绝不碰 transform**（位置基准是 app 用 transform 建立的）

## 关键教训
1. **视图「不见了」要按三个通道依次排除**：`hidden` → `alpha` → `removeFromSuperview`；
   三个都无效时，第四类是**「归位逻辑的调度频率不够」**（缺席时长呈 16.7ms 整数倍即为特征）。
2. **不要碰子树**：`WINMultiStyleRootView` 子树含搜索栏，摘它的手势 = 按死搜索栏（0.5.42 事故）。
3. **改「面板背景」前先确认底下有没有别的视觉层**（0.5.3 清 alpha → 露出容器自带磨砂玻璃）。
4. **跨版本同指标对照**是识别「我引入的回归」最快的手段；否定证据（拦截记录为空）同样是硬信息。
5. **先确认基于哪个源码版本编的**（0.5.52 基于 0.5.51 编译 → 静默删掉已验证的修复）。

## 版本链
0.3.1 基线 → 0.4.0 两圆钮 → 0.4.3/4 对齐 → 0.4.6/7 promo → 0.4.8 首页bar去文字 →
0.4.14-17 底栏/胶囊 → 0.4.19 首帧锁定 → 0.4.20-37 搜索页层(已废) → 0.4.38 回退 →
0.4.40 右下钮跟随 → 0.4.41-50 冷启动跳动根除 → 0.5.0 优化清理 →
0.5.1-7 白块/模糊带 → 0.5.8 EmptyImmersiveState → 0.5.9 白块修复 →
0.5.34-44 白雾追查(6 版空枪) → 0.5.50 上拉定稿 → 0.5.53 装回 →
0.5.54-58 切页搜索栏闪 → 0.6.0 定版（摘诊断）→ 0.6.1 切 2D/3D 天气行位移 → 0.6.2 瞬时下坠弹回 → 0.6.3/0.6.4 调度链 → 0.6.6 冷启动归位 → 0.6.7 底栏「上拉发现」根除（0.6.7a 卡死已回滚重写）→ 0.6.8 切页响应 → **0.6.9 快修窗不再空转**

## 从源码重建
SDK：theos patched iPhoneOS16.5.sdk（https://github.com/theos/sdks）

    clang -target arm64-apple-ios15.0 -isysroot $SDK -fobjc-arc -fblocks \
      -fobjc-runtime=ios-15 -dynamiclib -fuse-ld=lld -Wl,-fixup_chains \
      -Wl,-install_name,@rpath/GaodeClean.dylib -Wl,-no_adhoc_codesign \
      -framework UIKit -framework Foundation -framework CoreGraphics \
      -framework QuartzCore src/GaodeClean.m -o GaodeClean.dylib
    ldid -S GaodeClean.dylib

（arm64e 编不出：lld 不支持 arm64e chained fixups；A16 加载 arm64 切片正常）

## rootless deb 结构
- `data.tar.gz`: `var/jb/Library/MobileSubstrate/DynamicLibraries/{GaodeClean.dylib,GaodeClean.plist}`
- `control`: Package `local.gaode.clean` / Architecture `iphoneos-arm64` /
  Depends `firmware (>= 15.0), mobilesubstrate`
- RootHide 转换：`scripts/make-roothide.sh`（去 `/var/jb` 前缀 + Depends 补 oldabi；
  **输出路径必须传绝对路径**，脚本会 cd 到临时目录）

## 本包产物
- `dist/GaodeClean.dylib` — 0.6.7 构建件（179,568 B，chained fixups + adhoc 签名，带 jibamao 标识）
- `dist/com.jibamao.gaodeclean_0.6.7_iphoneos-arm64.deb` — rootless（载荷 `var/jb/...`）
- `dist/com.jibamao.gaodeclean_0.6.7_iphoneos-arm64-roothide.deb` — RootHide（载荷无 `/var/jb` 前缀，Depends 补 oldabi）

### 本机（iSH / Alpine aarch64）直接构建
`clang 19` + theos `iPhoneOS16.5.sdk`，不依赖 theos 本体与 macOS：

    clang -target arm64-apple-ios15.0 -isysroot $SDK -fobjc-arc -fblocks \
      -fobjc-runtime=ios-15 -O2 -dynamiclib -fuse-ld=lld -Wl,-fixup_chains \
      -Wl,-install_name,@rpath/GaodeClean.dylib -Wl,-adhoc_codesign \
      -framework UIKit -framework Foundation -framework CoreGraphics -framework QuartzCore \
      src/GaodeClean.m -o GaodeClean.dylib

deb 打包用 `scripts/mkdeb-local.py`（Python 写 `ar` 归档，不需要 dpkg-deb）。
**arm64e 不可用**：`ld64.lld: error: -fixup_chains is only supported on x86_64 and arm64 targets`
→ 只出 arm64 单切片；RootHide 包沿用官方兼容包做法（载荷去 `/var/jb` 前缀 + Depends 补 `oldabi`）。

## 标识
源码与产物均带 `jibamao` 标识，`strings` 可核对：
```
jibamao / gan-jibamao.github.io / jibamao-Tweaks / GaodeClean by jibamao
```
启动输出：`[GaodeClean] GaodeClean v0.6.6 | jibamao | https://gan-jibamao.github.io/`

## 0.6.6 验证记录
- 冷启动：f301 起天气行出现在车机钮正右边（pt 85-215），左边缘 pt 85（期望 86）→ **通过**

## 0.6.2 验证记录
- 切 2D/3D：4 次「下坠 17pt 再弹回」事件（f215/f252/f575/f613）全部消除 → **用户确认通过**

## 0.6.1 验证记录（前接 0.6.0）
- 切 2D/3D：云图标质心全片 1168 帧中位 pt 68.7，唯一偏移段 Δ2.0pt（噪声）→ **通过**
- 搜索栏：无缺席（仅冷启动首帧与启动段）→ **通过**
- 地图压白：std 全程正常 → **通过**

## 0.6.0 验证记录（逐帧量化，25.5s / 3059 帧 + 10.5s / 1257 帧）
- 上拉闪白：地图区 std 全程未掉出正常区间（真压白会掉到 1–5）→ **通过**
- 切页搜索栏：三次「我的→首页」回到首页的**第一帧**搜索栏即在位
  （245 / 244 / 254），全程无 216–226 档；唯一一帧缺席在冷启动 0.4s 处，属设计内首帧锁定 → **通过**
