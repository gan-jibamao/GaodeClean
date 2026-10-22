// ============================================================================
//  GaodeClean —— 字符串混淆运行时（0.9.20 A2）
//
//  源码里不再出现明文字符串：scripts/gen_obf.py 按 scripts/obf_strings.txt
//  把 src/GaodeClean.m 中的 @"..." 全部替换为 GCStrAt(i)，明文字节以
//  「逐位密钥 + 位置相关偏移 + 循环移位」编码后放进 src/GCStrData.h。
//  运行时按需解码并缓存（每串只解一次，之后是数组取值）。
//
//  逆向者 strings/otool/nm 只能看到随机字节与 0 个本地符号，看不到要 Hook
//  的类名、选择器与业务关键词。解码数学在 src/GCObfMath.h（纯 C，无 Foundation），
//  由 scripts/obf_selftest.sh 用同一份实现做主机的逐串回环校验。
// ============================================================================
#ifndef GCSTR_H
#define GCSTR_H

#import <Foundation/Foundation.h>
#include "GCObfMath.h"

static NSString *GCStrAt(NSUInteger idx) {
    static NSMutableArray *cache;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        cache = [NSMutableArray arrayWithCapacity:GC_OBF_COUNT];
        for (NSUInteger i = 0; i < GC_OBF_COUNT; i++) [cache addObject:NSNull.null];
    });
    id v = cache[idx];
    if (v != NSNull.null) return v;

    unsigned char buf[GC_OBF_MAXLEN + 1];
    unsigned len = GCObfDecode((unsigned)idx, buf);
    v = [[NSString alloc] initWithBytes:buf length:len encoding:NSUTF8StringEncoding];
    if (!v) v = NSNull.null;
    cache[idx] = v;
    return v;
}
#endif  // GCSTR_H