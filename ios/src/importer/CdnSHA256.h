//  CdnSHA256.h
//  SpCnEmbedded —— CDN 归档导入引擎（移植自 wf-cdn-importer-iOS 的 ios/importer/）
//
//  自带 SHA-256（纯 C，只依赖 <stdint.h> / <stddef.h>）。
//
//  为什么自带而不是照搬参考实现的 <CommonCrypto/CommonDigest.h>：
//    · 本项目的硬约束是「只能用 Foundation / UIKit / zlib」，CommonCrypto 不在清单里；
//    · CC_SHA256 在 iPhoneOS16.5.sdk 里没有独立的 .tbd，是靠 libSystem 转发才链得上的 ——
//      自带一份就是零链接期依赖，两条线（越狱 deb / 非越狱注入）都不会因为漏一个 -l 而挂；
//    · 有 GUI 的面板会拿它做「解压前逐包比 sha256」的内容校验，正确性用 NIST 标准向量核对过
//      （空串 / "abc" / 两段式 100 万字符 'a'）。
//
//  实现按 FIPS 180-4（大端序、64 字节分块、末尾 64 位比特长度）。

#ifndef CDN_SHA256_H
#define CDN_SHA256_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct {
    uint32_t state[8];
    uint64_t bitLength;
    uint8_t buffer[64];
    size_t bufferLength;
} CdnSHA256Context;

void CdnSHA256Init(CdnSHA256Context *context);
void CdnSHA256Update(CdnSHA256Context *context, const void *bytes, size_t length);
void CdnSHA256Final(CdnSHA256Context *context, uint8_t digest[32]);

#ifdef __cplusplus
}
#endif

#endif
