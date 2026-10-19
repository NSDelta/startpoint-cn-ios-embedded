# startpoint-cn-ios-embedded

把 [startpoint-cn](https://github.com/DontBeAlarmed/startpoint-cn)（世界弹射物语 CN 1.8.1 服务端）**单机内嵌进 iOS App**：
一个 IPA 装进手机就能自己玩，不需要电脑、不需要局域网、不需要连服务器。

> 服务端跑在**游戏进程内**：`NodeMobile.framework`（Node 18.20.4 / ABI 108，V8 `--jitless`）由注入的 dylib
> `dlopen` + `dlsym("node_start")` 拉起，`server-bundle` 与 `node_modules` 随包带上，数据卷落在 App 容器里。
> 悬浮球 + 悬浮窗负责「启动 / 停止 / 重启 / 后台 / 资源导入 / 日志 / 后端切换」。
> 另一条腿是越狱线的 `.deb`（独立 node 子进程 + 同一份 dylib），两条线共用同一份运行时与 UI。

- 目标客户端：官方 iOS 1.8.4 解密 dump（`Payload/worldflipper.app/worldflipper`，108,757,200 B，`cryptid=0`）
- 设备实测：iPhone 7 Plus / iOS 15.8.3 / 无根越狱（Dopamine + ellekit）+ AppSync，或 **TrollStore 直装 IPA**
- 许可：[GPL-3.0](LICENSE)（服务端与客户端补丁工具来自上游 GPL-3.0 项目，见文末「上游与出处」）

## 现在能做什么

| 能力 | 状态 |
| --- | --- |
| 单机跑通服务端（`/healthz` = `status=ready`，DB schema 28） | ✅ 真机验证 |
| 客户端登录 + 进游戏 + 战斗/同步（`/sync_data`、`tutorial/finish_trigger` 200） | ✅ 真机验证 |
| 悬浮球 / 悬浮窗不吃游戏手势（窗口级 `hitTest`） | ✅ 真机验证 |
| 资源导入（客户端容器内 13.7 万文件 / 9.8 GB，646 条归档计划，1.4.54–1.57） | ✅ 引擎 + 计划对账通过，真机跑过一次完整导入 |
| 后台管理页（账号/存档/服务器时间/邮件） | ✅ 真机验证（`/admin/`） |
| 账号绑定相关（绑定验证码公告、`/bind` 文案、后台绑定接口 7 条） | ✅ 单机版已全部移除（410 + 公告中性化 + 闸门恒关） |
| 改 bundle id 二次安装（`com.testdj.wf` 之类） | ⚠️ **不行**：AIR 启动自检要求 `CFBundleIdentifier` 必须是 `com.leiting.wf`，否则黑屏（详见「踩过的坑」） |
| 越狱线 deb（独立 node 子进程后端） | ✅ 装机验证（rootless，`/var/jb/...`） |

## 三条腿的关系

```
游戏 App（iOS 1.8.4，已打客户端补丁）
└── Frameworks/SpCnEmbedded.dylib        注入的 dylib（无 MobileSubstrate 依赖，构造函数启动）
    ├── 悬浮球 / 悬浮窗（SpCnOverlay / SpCnPanelViewController / SpCnResourceViewController / SpCnLogViewController）
    ├── SpCnSupervisor  ── 后端二选一
    │   ├─ process：posix_spawn 独立 node（越狱线；能单独重启、崩溃不连累游戏）
    │   └─ framework：dlopen NodeMobile.framework + node_start（进程内；非越狱线唯一可行）
    ├── SpCnConfig      ── 运行时目录/数据卷探测、端口、偏好（<DATA_DIR>/spcn-conf.plist）
    └── SpCnResourceImporter（CDN 导入引擎，634→646 条归档计划）
```

- **进程内后端**的入口是 `SpCnRuntime/ios-entry.js`：先做三件事再 `require` 服务端 —— ① 包 `process.exit/abort`（进程内 `exit(10/11/12/13/14)` 会直接把游戏带走）② 装 `uncaughtException`/`unhandledRejection` 兜底 ③ **无 ICU 的 TextDecoder 降级**（`NodeMobile.framework` 是 `--with-intl=none` 编的，服务端 `ordered-map.js` 用了 `{fatal:true}`）。
- 服务端三条运行时补丁（`tools/patch-*.mjs`，幂等、带标记串，`tools/build-all.mjs` 的 ⓪ 步自动跑）：
  `patch-no-icu`（TextDecoder 站点包 try/catch）、`patch-asset-version`（资源版本白名单 1.4.54–1.57）、`patch-single-player`（去账号绑定）。

## 构建

前置：Windows + WSL2(Ubuntu) 里的 [Theos](https://theos.dev)（普通用户装，不能 root）、Node 18+、一份官方 iOS 1.8.4 解密 IPA。

```bash
# 一次性准备（详见 docs/STATUS-final.md 的「本机事实」）
node tools/extract-framework.mjs --ipa=<某份含 NodeMobile.framework 的 IPA>   # 或 tools/fetch-nodemobile.mjs
node tools/assemble-runtime.mjs --node runtime/node-ios-arm64/node \
     --bundle runtime/SpCnRuntime/server-bundle --modules runtime/SpCnRuntime/node_modules \
     --out runtime/SpCnRuntime

# 一条命令重出全部交付物（① 运行时装补丁+清单 ② theos 编 tweak ③ 运行时 tar ④ 一键 deb ⑤ 一体 IPA ⑥ 纯补丁 IPA ⑦ 汇总）
node tools/build-all.mjs --ipa=C:/path/to/iOS-1.8.4.ipa
```

出件在 `dist/`：`SpCnEmbedded-{rootless,rootful}.{deb,dylib}`、`SpCnEmbedded-full-*.deb`（带运行时，一键装）、
`SpCnRuntime.tar.gz`、`spcn-ios-standalone.ipa`（一体，179.6 MB）、`spcn-ios-patched-only.ipa`（纯补丁）、`BUILDS.json`。

## 安装

**A. 越狱（无根 Dopamine/ellekit，推荐）**

```bash
bash tools/install-full-deb.sh            # scp + dpkg -i，dylib+运行时一起落 /var/jb/...
```

装完点游戏图标即可；`uiopen` 拉起的进程在锁屏时不跑代码，需要用户自己点。

**B. 非越狱（TrollStore / AppSync / Sideloadly）**

装 `dist/spcn-ios-standalone.ipa`（重签名由安装器负责，包内已含 `Frameworks/NodeMobile.framework` 与
`SpCnRuntime/`，`node` 条目必须是 `0755` —— 打包器会断言这一点）。首次进入若资源为空，用面板「资源 → 选目录 → 导入」
导入 CDN（`SpCnCdn-*.tar.part*` + `SpCnPatches-*.tar.gz` 解到同一父目录得 `cn/` 与 `patches/`）。

## 踩过的坑（都是真机实测，改代码前先读）

1. **`CFBundleIdentifier` 必须是 `com.leiting.wf`**：AIR 的 `-[CTAppDescriptor appID]` 读 `[[NSBundle mainBundle] infoDictionary]` 缓存成 `_appID`，喂给 ADEP 许可证/解密链；换 id 就抛 AS3 异常 → `_longjmp` → 被 `sub_100011B94` 的 `_setjmp` 兜住 → 打印 `AdobeAIR: application packaging error`，内容永不加载（黑屏、零请求、不崩溃）。想换 id 只能用运行时谎报 `-[NSBundle infoDictionary]`（见 `ios/src/SpCnIdentityDiag.m`）。
2. **iOS 没有 JIT**：`node_start` 必须显式传 V8 旗标 `--jitless --no-opt --no-sparkplug --no-wasm-tier-up --no-wasm-code-gc`，否则 V8 走 `EnableTrapHandler` → `EXC_BREAKPOINT` 带走整个进程。
3. **`isExecutableFileAtPath:` 在沙盒里会撒谎**（对自己的 0755 文件返回 NO），`exec` 也被拦（EPERM）⇒ 非越狱线只能用进程内后端。
4. **`realpath()` 会绕出 iOS 的路径遮蔽**（`/var` → `/private/var` ⇒ `lstat('/private/var/mobile')` ENOENT），服务端 `assertIsolatedContentPaths` 直接失败 ⇒ `ios-entry.js` 里包了一层「沙盒安全 realpath」。
5. **悬浮球吃手势**：`UIWindow.hitTest:` 在所有子视图都不认这次触摸时返回窗口自己 ⇒ 必须**窗口级**重写 `hitTest:withEvent:`（返回 nil），只让某个 view 返回 nil 不够。
6. **`uiopen`/锁屏**：锁屏时被拉起的进程不跑代码；`uiopen` 只认 `-b/--bundleid`（`--path` 会被拒）。
7. **弹窗公告/绑定**：单机版把 `IOS_NOTICE_TITLE` 改成「公告」、公告正文换成「无需绑定」，后台 `/api/.../binding` 7 条路由全部 410，闸门 `bind-gate` 恒关。
8. 运行时目录探测顺序：App 包内 `SpCnRuntime/` → `<Documents>/SpCnRuntime` → `/var/mobile/Library/SpCn/runtime` → `/var/jb/usr/share/spcn/runtime` → `/usr/share/spcn/runtime`（认 `spcn-runtime.json`）。

## 目录

```
ios/            Theos 工程（Tweak.xm + src/*.m + src/importer/*.m 资源导入引擎）
runtime/        node-ios-arm64/node（Node 18.20.4）、SpCnRuntime（server-bundle/node_modules/ios-entry.js）、NodeMobile.framework
tools/          build-all / build-ipa / pack-ipa / embed-runtime / patch-* / 设备脚本（push/install/watch/diag）
docs/           DELIVERY-single.md（产物表+装法）、STATUS-final.md（关键事实清单）、INSTALL-jailbreak.md
PLAN.md         设计决策记录（Q1–Q6）
```

## 上游与出处

- 服务端、客户端补丁工具：<https://github.com/DontBeAlarmed/startpoint-cn>（GPL-3.0）
- CDN 导入引擎移植自：<https://github.com/NSDelta/wf-cdn-importer-iOS>
- NodeMobile.framework：nodejs-mobile（Node 18.20.4 版本），见 `runtime/node-framework-ios-arm64/PROVENANCE.json`
- 运行时独立 node 二进制：imcynic/nodejs-ios(`nodejs_18.20.4-1_iphoneos-arm64.deb`)

本仓库不包含游戏本体、CDN 资源与解密密钥；请自行从合法渠道取得客户端与资源。
