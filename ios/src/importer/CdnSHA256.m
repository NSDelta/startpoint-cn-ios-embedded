//  CdnSHA256.m
//  SpCnEmbedded —— CDN 归档导入引擎（移植自 wf-cdn-importer-iOS 的 ios/importer/）
//
//  FIPS 180-4 的 SHA-256，纯 C 实现（无 ObjC / 无任何系统库依赖）。
//  用途：与 <CommonCrypto/CommonDigest.h> 的 CC_SHA256 同口径，替换参考实现里的那一处调用。

#import "CdnSHA256.h"

#include <string.h>

/// FIPS 180-4 §4.2.2 的 64 个轮常量（前 64 位小数部分取前 32 位）。
static uint32_t const kCdnSHA256RoundConstants[64] = {
    0x428a2f98u, 0x71374491u, 0xb5c0fbcfu, 0xe9b5dba5u,
    0x3956c25bu, 0x59f111f1u, 0x923f82a4u, 0xab1c5ed5u,
    0xd807aa98u, 0x12835b01u, 0x243185beu, 0x550c7dc3u,
    0x72be5d74u, 0x80deb1feu, 0x9bdc06a7u, 0xc19bf174u,
    0xe49b69c1u, 0xefbe4786u, 0x0fc19dc6u, 0x240ca1ccu,
    0x2de92c6fu, 0x4a7484aau, 0x5cb0a9dcu, 0x76f988dau,
    0x983e5152u, 0xa831c66du, 0xb00327c8u, 0xbf597fc7u,
    0xc6e00bf3u, 0xd5a79147u, 0x06ca6351u, 0x14292967u,
    0x27b70a85u, 0x2e1b2138u, 0x4d2c6dfcu, 0x53380d13u,
    0x650a7354u, 0x766a0abbu, 0x81c2c92eu, 0x92722c85u,
    0xa2bfe8a1u, 0xa81a664bu, 0xc24b8b70u, 0xc76c51a3u,
    0xd192e819u, 0xd6990624u, 0xf40e3585u, 0x106aa070u,
    0x19a4c116u, 0x1e376c08u, 0x2748774cu, 0x34b0bcb5u,
    0x391c0cb3u, 0x4ed8aa4au, 0x5b9cca4fu, 0x682e6ff3u,
    0x748f82eeu, 0x78a5636fu, 0x84c87814u, 0x8cc70208u,
    0x90befffau, 0xa4506cebu, 0xbef9a3f7u, 0xc67178f2u,
};

static uint32_t CdnSHA256RotateRight(uint32_t value, uint32_t bits) {
    return (value >> bits) | (value << (32u - bits));
}

/// 压缩一个 64 字节分块（§6.2.2）。
static void CdnSHA256Compress(CdnSHA256Context *context, const uint8_t block[64]) {
    uint32_t schedule[64];
    for (size_t index = 0; index < 16; index++) {
        schedule[index] = ((uint32_t)block[index * 4] << 24)
                        | ((uint32_t)block[index * 4 + 1] << 16)
                        | ((uint32_t)block[index * 4 + 2] << 8)
                        | ((uint32_t)block[index * 4 + 3]);
    }
    for (size_t index = 16; index < 64; index++) {
        uint32_t small0 = CdnSHA256RotateRight(schedule[index - 15], 7)
                        ^ CdnSHA256RotateRight(schedule[index - 15], 18)
                        ^ (schedule[index - 15] >> 3);
        uint32_t small1 = CdnSHA256RotateRight(schedule[index - 2], 17)
                        ^ CdnSHA256RotateRight(schedule[index - 2], 19)
                        ^ (schedule[index - 2] >> 10);
        schedule[index] = schedule[index - 16] + small0 + schedule[index - 7] + small1;
    }

    uint32_t a = context->state[0];
    uint32_t b = context->state[1];
    uint32_t c = context->state[2];
    uint32_t d = context->state[3];
    uint32_t e = context->state[4];
    uint32_t f = context->state[5];
    uint32_t g = context->state[6];
    uint32_t h = context->state[7];

    for (size_t index = 0; index < 64; index++) {
        uint32_t big1 = CdnSHA256RotateRight(e, 6)
                      ^ CdnSHA256RotateRight(e, 11)
                      ^ CdnSHA256RotateRight(e, 25);
        uint32_t choose = (e & f) ^ ((~e) & g);
        uint32_t temp1 = h + big1 + choose + kCdnSHA256RoundConstants[index] + schedule[index];
        uint32_t big0 = CdnSHA256RotateRight(a, 2)
                      ^ CdnSHA256RotateRight(a, 13)
                      ^ CdnSHA256RotateRight(a, 22);
        uint32_t majority = (a & b) ^ (a & c) ^ (b & c);
        uint32_t temp2 = big0 + majority;

        h = g;
        g = f;
        f = e;
        e = d + temp1;
        d = c;
        c = b;
        b = a;
        a = temp1 + temp2;
    }

    context->state[0] += a;
    context->state[1] += b;
    context->state[2] += c;
    context->state[3] += d;
    context->state[4] += e;
    context->state[5] += f;
    context->state[6] += g;
    context->state[7] += h;
}

void CdnSHA256Init(CdnSHA256Context *context) {
    if (context == NULL) return;
    context->state[0] = 0x6a09e667u;
    context->state[1] = 0xbb67ae85u;
    context->state[2] = 0x3c6ef372u;
    context->state[3] = 0xa54ff53au;
    context->state[4] = 0x510e527fu;
    context->state[5] = 0x9b05688cu;
    context->state[6] = 0x1f83d9abu;
    context->state[7] = 0x5be0cd19u;
    context->bitLength = 0;
    context->bufferLength = 0;
}

void CdnSHA256Update(CdnSHA256Context *context, const void *bytes, size_t length) {
    if (context == NULL || bytes == NULL || length == 0) return;
    uint8_t const *input = (uint8_t const *)bytes;
    size_t index = 0;
    while (index < length) {
        size_t space = 64 - context->bufferLength;
        size_t take = (length - index < space) ? (length - index) : space;
        memcpy(context->buffer + context->bufferLength, input + index, take);
        context->bufferLength += take;
        index += take;
        if (context->bufferLength == 64) {
            CdnSHA256Compress(context, context->buffer);
            context->bitLength += 512u;
            context->bufferLength = 0;
        }
    }
}

void CdnSHA256Final(CdnSHA256Context *context, uint8_t digest[32]) {
    if (context == NULL || digest == NULL) return;

    // 补位长度用的是「补位之前」的总比特数，所以先存下来（后面 Update 会继续累加）。
    uint64_t bitLength = context->bitLength + (uint64_t)context->bufferLength * 8u;

    uint8_t padding = 0x80u;
    CdnSHA256Update(context, &padding, 1);
    uint8_t zero = 0x00u;
    while (context->bufferLength != 56) {
        CdnSHA256Update(context, &zero, 1);
    }
    uint8_t lengthBytes[8];
    for (size_t index = 0; index < 8; index++) {
        lengthBytes[index] = (uint8_t)(bitLength >> (56u - 8u * index));
    }
    CdnSHA256Update(context, lengthBytes, 8);

    for (size_t index = 0; index < 8; index++) {
        digest[index * 4] = (uint8_t)(context->state[index] >> 24);
        digest[index * 4 + 1] = (uint8_t)(context->state[index] >> 16);
        digest[index * 4 + 2] = (uint8_t)(context->state[index] >> 8);
        digest[index * 4 + 3] = (uint8_t)(context->state[index]);
    }
}
