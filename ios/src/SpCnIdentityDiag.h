// SpCnIdentityDiag —— 只为定位 / 绕过 AIR 的 `application packaging error`（黑屏真凶）。
//
// 背景（已用 IDA 定位到代码）：主二进制 `sub_100011B94` 在 SDK ≥51.2 的分支里读
// `META-INF/AIR/__swf__` 与 `META-INF/AIR/license.txt`（两者在两个包之间逐字节一致），随后
// `sub_1002EB42C(v14, license, swf)` 抛异常被 `_setjmp` 兜住 ⇒ 打印 `AdobeAIR: application packaging error`
// ⇒ 内容永不加载（黑屏、零网络请求、不崩溃）。触发条件是**身份字符串**：
//   身份全为 com.leiting.wf ⇒ 不报错；把 plist/描述符/entitlements 改成 com.testdj.wf ⇒ 报错。
// 所以 AIR（或其 DRM/装载链）在拿某一处身份对账。本模块做两件事：
//   ① 诊断：interpose 异常抛出点 + 读 entitlements 的 API + swizzle -[NSBundle bundleIdentifier]，
//      把「谁在读身份、抛了什么异常」写进 SpCnLog；
//   ② 绕过：可选「对 AIR 谎报 bundleIdentifier」——`<DATA>/spcn-conf.plist` 里
//      `IdentityLie`（要谎报的 id，如 com.leiting.wf）+ `IdentityLieSeconds`（默认 8 秒；0 = 一直谎报）。
//      只对 mainBundle 谎报，且只在启动后若干秒内（AIR 的启动自检窗口），避免影响游戏后续的路径计算。
#import <Foundation/Foundation.h>

// ⚠️ Tweak.xm 会被 logos 编译成 Objective-C++（.mm）⇒ 声明必须用 extern "C"，
//    否则引用的是 C++ 修饰名（_Z23SpCnIdentityDiagInstallv），而实现是纯 ObjC 的 C 符号 ⇒ 链接失败。
#ifdef __cplusplus
extern "C" {
#endif

/// 安装诊断（在 Tweak constructor 里尽早调用，必须在 AIR 起来之前）。
void SpCnIdentityDiagInstall(void);

#ifdef __cplusplus
}
#endif
