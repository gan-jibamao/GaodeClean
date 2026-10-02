# GaodeClean 0.6.6 — 源码与构建说明

**Author: jibamao** · Repo: https://gan-jibamao.github.io/ · Section: `jibamao-Tweaks`

高德地图 17.00.2 (com.autonavi.amap) UI 清理 tweak。纯 ObjC runtime hook，
不依赖 substrate/frida，不碰网络与 IPA，仅视图层。

## 当前终态 0.6.6 的功能清单
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
- **正式包零诊断**：不再写 Documents/GaodeClean-blur.txt (0.6.0)

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
0.5.54-58 切页搜索栏闪 → 0.6.0 定版（摘诊断）→ 0.6.1 切 2D/3D 天气行位移 → 0.6.2 瞬时下坠弹回 → 0.6.3/0.6.4 调度链 → **0.6.6 冷启动归位**

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
- `dist/GaodeClean.dylib` — 0.6.6 构建件（197,168 B，带 jibamao 标识，ldid 签名）
- `dist/com.jibamao.gaodeclean_0.6.6_iphoneos-arm64.deb` — rootless
- `dist/com.jibamao.gaodeclean_0.6.6_iphoneos-arm64-roothide.deb` — RootHide

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
