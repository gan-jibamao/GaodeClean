# GaodeClean 0.4.40 — 源码备份说明

高德地图 17.00.2 (com.autonavi.amap) UI 清理 tweak。纯 ObjC runtime hook，
不依赖 substrate/frida，不碰网络与 IPA，仅视图层。

## 当前终态 0.4.40 的功能清单
- 底栏两钮居中 + 胶囊(选中视图)跟随选中按钮 (0.3.1 + 0.4.13-0.4.17)
- 左侧车机圆钮、右下组合钮(定位+回正)对齐到搜索框上方 8pt (0.4.3/0.4.4/0.4.40)
- 首页搜索栏下沉 + 首帧锁定防跳动 (0.3.1 + 0.4.19)
- 首页搜索栏去文字(城市名/滚词) (0.4.7/0.4.8)
- 来扫街(template_oparate_icon) + 扫街榜(template_rank) 隐藏 (0.4.7)
- 探索/附近/我的页裁剪与滚动限制 (0.3.1 机制)
- 诊断 dump：启动后 2/5/8/12/18/25s 全窗口树落盘
  高德 Documents/GaodeClean-dump-t<N>.txt（同时写 /var/mobile/Documents/）

## 已移除（0.4.38 起，搜索页 = 完全原生）
0.4.20-0.4.37 的搜索页干预层全部剥除：CleanSearchPromo、AJXLabel/AJXScrollView
即时钩子、分类行收起、推广带隐藏、输入态探针（焦点/清空/字段文本）。
教训：输入框 AJXInputView 住在「滚动推广词」AJXScrollView 里；AJX label 文字
只存 accessibilityLabel；位置类隐藏必须窗口坐标 + 输入态联动。

## 版本链
0.3.1 基线(src/GaodeClean-0.3.1.m 参考件) → 0.4.0 两圆钮跟随 → 0.4.3/4 对齐
方向定稿(底边贴搜索框上方8pt) → 0.4.6/7 promo 定稿(oparate_icon+rank) →
0.4.8 首页bar去文字 → 0.4.14 底栏回退0.3.1 → 0.4.17 胶囊跟随选中钮 →
0.4.19 首帧锁定 → 0.4.20-37 搜索页层(已废) → 0.4.38 搜索页回退 →
0.4.39 右下钮回原生(废弃) → **0.4.40 右下钮恢复跟随对齐(本包)**

## 从源码重建
SDK：theos patched iPhoneOS16.5.sdk（https://github.com/theos/sdks）
clang -target arm64-apple-ios15.0 -isysroot $SDK -fobjc-arc -fblocks \
  -fobjc-runtime=ios-15.0 -dynamiclib -fuse-ld=lld -Wl,-fixup_chains \
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
dist/GaodeClean.dylib — 0.4.40 构建件(ldid 签名)
dist/local.gaode.clean_0.4.40_iphoneos-arm64.deb — rootless
dist/local.gaode.clean_0.4.40_iphoneos-arm64-roothide.deb — RootHide
