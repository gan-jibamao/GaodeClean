# tools/ —— 逆向分析工具箱

高德每次大版本升级后的**标准应对流程**用得到的工具。
它们不是在 tweak 运行时用的，而是**分析新版 app 二进制**时用的。

## 升级应对五步（按顺序）

### 第 1 步：dump 新版类名/方法/字符串，与旧版 diff

```bash
python3 tools/dump_sections.py /path/to/AMapiPhone /tmp/new
python3 tools/dump_sections.py /path/to/旧版备份   /tmp/old
# 然后 diff 找目标：
diff <(sort /tmp/old/cls.txt) <(sort /tmp/new/cls.txt) | head -50
rg -x 'WINTabBar.*' /tmp/new/cls.txt        # 找某个类族
rg -x '.*[Gg]uide.*' /tmp/new/sel.txt      # 找某个 selector 族
```

判定「我们的 hook 目标还活着吗」：

```bash
# 一次验证全部目标
python3 tools/dump_sections.py /path/to/AMapiPhone /tmp/new \
  --check WINTabBar,WINTabBarItem,WINMapMaskView,updateGuideLottie:viewState:
```

### 第 2 步：从 objdump 元数据建「类->方法 imp」映射

```bash
llvm-objdump --macho --objc-meta-data /path/to/AMapiPhone > /tmp/meta.txt
# 里面形如：
#   name 0x... updateGuideLottie:viewState:
#   imp 0x106650d14
```

### 第 3 步：看某个方法内部调用了什么（真实 selector 名）

```bash
python3 tools/decode_func.py /path/to/AMapiPhone 0x106650d14 0x1066515e8
# 输出形如：
#   0x106650fa8: bl -> [createLottieViewWithZipUrl:ready:]
#   0x106650fc0: bl -> [setUnSelectedGuideLottie:]
#   ...
```

### 第 4 步：找「谁调用了它」（xref 扫描）

```bash
python3 tools/xref_scan.py /path/to/AMapiPhone 0x106650d14 0x106655ca0
# 输出各调用点地址，再用 meta.txt 里的 imp 区间归属到类-方法
```

### 第 5 步：验证自己的新代码真的进了产物（反汇编级）

```bash
# 对 dylib 的静态变量访问扫描法（比字符串引用扫描可靠）：
#   找到变量符号地址 → adrp 到它所在页 + ldrb/strb [xN, #偏移] 即为读写点
llvm-nm GaodeClean.dylib | grep 变量名
llvm-objdump --macho --disassemble GaodeClean.dylib > /tmp/full.txt
# 在 /tmp/full.txt 里搜对应偏移
```

## 工具清单

| 工具 | 用途 | 依赖 |
|:--|:--|:--|
| `dump_sections.py` | 导出类名/selector/字符串 + 批量存在性检查 | `lief` |
| `decode_func.py` | 函数内 objc 调用解码（stub→selector） | `capstone` |
| `xref_scan.py` | 全段 BL 调用扫描（numpy 向量化） | `numpy` |

## 本次战役的用法示例（17.01.1「上拉发现」）

```bash
# 1. 发现线索：全域搜「上拉发现」无果（文案在 Lottie 资源里）
rg -a '上拉发现' AMapiPhone
# 2. 搜埋点串：
rg -a 'tab guide lottie' AMapiPhone
#    → 命中 "tab guide lottie start play"
# 3. 找周边方法名：rg 'GuideLottie' sel.txt → 全套方法
# 4. decode_func 解码渲染方法：确认它创建 Lottie + 挂载
# 5. xref_scan 确认唯一渲染点：WINTabBarItem.updateGuideLottie:viewState:
# 6. 空实现该入口 → 修复完成
```

## 注意事项

- **主二进制要砸壳版**（cryptid=0），App Store 包需先处理
- `xref_scan.py` 的 `TEXT_VADDR` 常量按目标调整（本仓库针对高德 17.x 设 0x100004000）
- chained fixup 编码下，**静态字符串引用扫描不可靠** —— 用「变量访问扫描法」
  （adrp + ldrb/strb 模式）验证自己的代码更稳（0.9.2 的 BarShownOnce 就是这么验的）
- macOS 上可直接用 `jtool2` / `ipsw` / Hopper 更省事；本工具箱针对 **iSH 移动端**（纯 Python）
