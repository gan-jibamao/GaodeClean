// ============================================================================
//  GaodeClean —— 字符串混淆：纯 C 解码数学（0.9.20 A2）
//
//  故意**不依赖 Foundation**：运行时的 GCStr.h 与主机的 obf_selftest.c
//  共用同一份实现，保证「编出来的是什么，跑起来解出的就是什么」。
//  编码端见 scripts/gen_obf.py 的 encode()，算法逐位对齐。
// ============================================================================
#ifndef GCOBFMATH_H
#define GCOBFMATH_H
#include "GCStrData.h"

// 8 位循环左移（n 已规约到 0..7；n=0 时两个方向都移 0 位，结果原值）
static inline unsigned char GCRotN(unsigned char v, unsigned n) {
    n &= 7;
    return (unsigned char)(((unsigned)v << n) | ((unsigned)v >> ((8 - n) & 7)));
}

// 解出第 idx 串：out 容量需 >= GC_OBF_MAXLEN + 1；返回字节长度（不含结尾 0）
// 解码 = 逆序还原编码的「XOR 密钥 → 位置偏移 → 循环移位」三步
static inline unsigned GCObfDecode(unsigned idx, unsigned char *out) {
    const gcObfEnt *e = &gcObfTab[idx];
    unsigned len = e->len, i;
    for (i = 0; i < len; i++) {
        unsigned n = e->idx + i;                                            // 全局位置（编码端 base+i）
        unsigned char u = GCRotN(gcObfBytes[e->off + i],
                                 (unsigned char)(8 - (n % 8)));             // 逆转循环移位
        unsigned char t = (unsigned char)(u - (unsigned char)(17 * n + 3)); // 逆位置偏移
        out[i] = (unsigned char)(t ^ e->key);                               // 逆 XOR
    }
    out[len] = 0;
    return len;
}
// 明文校验摘要（与 scripts/gen_obf.py 的 fnv1a64 完全一致）：
// 遍历全部 295 条明文（按索引顺序），逐字节 FNV-1a，每条后混入分隔符 0x1F。
static inline unsigned long long GCObfDigest(void) {
    unsigned long long h = 1469598103934665603ULL, i;
    unsigned j;
    unsigned char buf[GC_OBF_MAXLEN + 8];
    for (i = 0; i < GC_OBF_COUNT; i++) {
        unsigned len = GCObfDecode((unsigned)i, buf);
        for (j = 0; j < len; j++) h = (h ^ buf[j]) * 1099511628211ULL;
        h = (h ^ 0x1FULL) * 1099511628211ULL;
    }
    return h;
}
#endif  // GCOBFMATH_H