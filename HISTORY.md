# GaodeClean 0.5.0 — 源码备份说明

高德地图 17.00.2 (com.autonavi.amap) UI 清理 tweak。纯 ObjC runtime hook，
不依赖 substrate/frida，不碰网络与 IPA，仅视图层。

## 当前终态 0.5.0 的功能清单
- 底栏两钮居中 + 胶囊(选中视图)跟随选中按钮 (0.3.1 + 0.4.13-0.4.17)
- 左侧车机圆钮、右下组合钮(定位+回正)对齐到搜索框上方 8pt (0.4.3/0.4.4/0.4.40)
- 首页搜索栏下沉 + 首帧锁定 + setFrame/setCenter 钳位 + didMoveToSuperview 重挂自愈
  （0.3.1 + 0.4.19 + 0.4.46/0.4.48/0.4.50，冷启动零跳动，含稳定性门槛 0.4.45）
- 首页搜索栏去文字(城市名/滚词) (0.4.7/0.4.8)
- 来扫街(template_oparate_icon) + 扫街榜(template_rank) 隐藏 (0.4.7)
- 探索/附近/我的页裁剪与滚动限制 (0.3.1 机制)

## 已移除（0.4.38 起，搜索页 = 完全原生）
0.4.20-0.4.37 的搜索页干预层全部剥除：CleanSearchPromo、AJXLabel/AJXScrollView
即时钩子、分类行收起、推广带隐藏、输入态探针（焦点/清空/字段文本）。
教训：输入框 AJXInputView 住在「滚动推广词」AJXScrollView 里；AJX label 文字
只存 accessibilityLabel；位置类隐藏必须窗口坐标 + 输入态联动。

## 0.5.0 优化（本次）
1. 剥除诊断埋点：RecFrame/FrameHist/DumpDebugTree/心跳帧/热路径 NSLog 全删
   （正式包零诊断开销；调试期产物已进 git 历史 0.4.50 提交）
2. AlignCornerWidgets 缓存两个圆钮实例（weak），每轮直接对齐，实例失效才重扫窗口树
3. 清死代码：孤儿注释、IsInputLike 后的冗余 TextField/Input 判断
4. 版本 0.4.50 → 0.5.0

## 冷启动跳动根除（0.4.41-0.4.50 完整链，可复用）
跳动 = 原生位置先渲染一帧再被拉到位。最终三层闭环：
- 隐藏→定位→一次性显示（HomeSettled/ColdWidgets 超时兜底 2.4s）
- 逐 widget AlignedKey 标记 + 顶边对齐(固定 44pt)，高度 88→44 不跳
- setFrame/setCenter 钳位 + didMoveToSuperview 重挂自愈（app 抢回去也不动）
关键坑：①全局 HomeSettled 标志竞态→改逐 widget 关联对象 ②app 周期性重挂搜索栏
进 sheet 并挪离屏(1140)→didMoveToSuperview 同步挂回 ③NSTimer/GCD timer 都在
~1.35s 停跑→位置修正不能依赖 timer，必须走 layoutSubviews/didMoveToSuperview 自愈。

## 版本链
0.3.1 基线 → 0.4.0 两圆钮 → 0.4.3/4 对齐定稿 → 0.4.6/7 promo 定稿 →
0.4.8 首页bar去文字 → 0.4.14 底栏回退 → 0.4.17 胶囊跟随 → 0.4.19 首帧锁定 →
0.4.20-37 搜索页层(已废) → 0.4.38 搜索页回退 → 0.4.40 右下钮跟随 →
0.4.41-50 冷启动跳动根除 → **0.5.0 优化清理(本包)**

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
data.tar.gz: var/jb/Library/MobileSubstrate/DynamicLibraries/{GaodeClean.dylib,GaodeClean.plist}
control: Package local.gaode.clean / Architecture iphoneos-arm64 / Depends firmware>=15.0, mobilesubstrate
RootHide 转换：scripts/make-roothide.sh（去 /var/jb 前缀 + Depends 补 oldabi；
注意输出路径必须传绝对路径，脚本会 cd 到临时目录）

## 本包产物
dist/GaodeClean.dylib — 0.5.0 构建件(ldid 签名)
dist/local.gaode.clean_0.5.0_iphoneos-arm64.deb — rootless
dist/local.gaode.clean_0.5.0_iphoneos-arm64-roothide.deb — RootHide
