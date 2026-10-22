// GaodeClean —— 字符串混淆「主机回环自测」
// 目的：用与运行时**完全同一份**解码数学（src/GCObfMath.h），在主机上把 295 条
// 混淆串全部解回明文，逐条与 scripts/obf_strings.txt 比对，并校验 FNV 摘要。
// 本文件不参与 dylib 编译，只做构建期自证。
#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include "../src/GCObfMath.h"

int main(int argc, char **argv) {
    const char *list = (argc > 1) ? argv[1] : "scripts/obf_strings.txt";
    FILE *f = fopen(list, "r");
    if (!f) { printf("FAIL 打不开清单 %s\n", list); return 2; }
    static char lines[1024][512];
    int n = 0;
    while (n < 1024 && fgets(lines[n], sizeof(lines[n]), f)) {
        size_t L = strlen(lines[n]);
        while (L && (lines[n][L-1] == '\n' || lines[n][L-1] == '\r')) lines[n][--L] = 0;
        n++;
    }
    fclose(f);
    if (n != (int)GC_OBF_COUNT) {
        printf("FAIL 清单条数 %d != GC_OBF_COUNT %d\n", n, (int)GC_OBF_COUNT);
        return 1;
    }
    int bad = 0;
    unsigned char buf[GC_OBF_MAXLEN + 8];
    for (int i = 0; i < n; i++) {
        unsigned len = GCObfDecode((unsigned)i, buf);
        if ((size_t)len != strlen(lines[i]) || memcmp(buf, lines[i], len) != 0) {
            if (bad < 5) printf("  MISMATCH #%d\n    期望: %s\n    解得: %s\n", i, lines[i], (char *)buf);
            bad++;
        }
    }
    unsigned long long h = GCObfDigest();
    if (h != (unsigned long long)GC_OBF_FNV) {
        printf("FAIL 摘要不符: 解得 0x%016llX != 头内 0x%016llX\n", h, (unsigned long long)GC_OBF_FNV);
        return 1;
    }
    if (bad) { printf("FAIL %d/%d 条解码不符\n", bad, n); return 1; }
    printf("PASS 混淆回环 %d/%d 条逐字节一致；FNV=0x%016llX\n", n, n, h);
    return 0;
}
