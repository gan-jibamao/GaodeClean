# GaodeClean (private)

Amap iOS 17.00.2 UI cleanup tweak. UI-only ObjC runtime hooks — no substrate dependency,
no network interception, no IPA patching. Private backup, not for distribution.

- `src/GaodeClean.m` — current build (0.6.6)
- `HISTORY.md` — feature list, version chain, root-cause notes, full build recipe
- `dist/` — built dylib + rootless/roothide debs (0.6.6)

## 0.6.6 状态
底栏上拉白雾/闪白、顶部沉浸高斯模糊带、首页白块、冷启动跳动、
「我的 → 首页」切页时搜索栏闪、切 2D/3D 时天气行+LOGO 位移及其「瞬时下坠弹回」、冷启动后天气行不归位 —— 全部逐帧量化验证通过。
正式包零诊断（不再写 Documents/GaodeClean-blur.txt）。
