# 世界弹射物语 CN · iOS 单机集成方案（规划稿 v1）

> 目标：把 `startpoint-cn` 服务端**单机**集成进 iOS 客户端，做成**一个 IPA**（游戏 + 服务端 + Node 运行时 + 悬浮球后台），
> 装到手机上断网也能玩。构建优先用本机 WSL 的 theos；需要 macOS 的环节（原生模块交叉编译）走既有 GitHub Actions macOS 线。
> 本文档 = 现状事实 + 架构 + 决策点 + 分期计划 + 风险。**决策点见 §5，未拍板前不动手改代码。**

---

## 1. 交付物定义（先说清楚"单个 IPA"能装什么）

| 内容 | 体积 | 是否进 IPA | 说明 |
| --- | --- | --- | --- |
| 游戏本体（已 patch 的 Mach-O） | ~108.7 MB | ✅ | iOS 1.8.4 官方解密 dump，域名字符串改成 `http://<pad>@127.0.0.1:8001` |
| Server Bundle（`out/` + `assets/` + `web/`） | 67.4 MB → zip ~20 MB | ✅ | `_release/win/platform/server-bundle`（Server Bundle v3） |
| 生产依赖 `node_modules` | 27 MB → zip ~8 MB | ✅ | 含 **ios-arm64 版 better_sqlite3.node**（待解决，见 P1） |
| iOS Node 运行时 | 70.8 MB → zip ~20 MB | ✅ | Node 18.20.4 arm64（现成 deb 内已提取到，见 §2.4） |
| 我们的 tweak dylib（Supervisor + 悬浮球/悬浮窗） | < 1 MB | ✅ | `LC_LOAD_DYLIB @executable_path/Frameworks/SpCnServer.dylib` |
| **游戏资源 CDN（1.4.54）** | **10.14 GB** | ❌ **不可能进 IPA** | 装机后首次运行导入到客户端容器（见 §5-Q3） |

**预计 IPA 体积：~132 MB（原始）+ ~48 MB（运行时与代码）≈ 175–185 MB**（未签名；签名后略增）。
"单个 IPA" = 服务端与运行时全在里面；**资源是独立的 10 GB 数据包**，装完导一次即可（这是物理限制，不是设计取舍）。

---

## 2. 现状盘点（今天已核实的事实）

### 2.1 服务端（`D:\wfcnmod\server\startpoint-cn-dev`，HEAD `20d3b575`）
- 平台包 `_release/win/platform`：`server-bundle` 67.4 MB / 933 文件，`runtime-pack` 115.6 MB（`node` 88.2 MB + `node_modules` 27 MB）。
- 启动器 `run.js` = **平台 Supervisor**：用 Node 20.6+ 的 `process.loadEnvFile` 读 `.env`，Windows 上用 directory junction 把 `runtime-pack/node_modules` 铺到 `server-bundle/` 与 `server-bundle/out/`，再调 `out/content/startup/bootstrap.js` → `out/cn-server.js`。
  → **iOS 上不能直接用它**：`process.loadEnvFile`（Node 18 没有）+ junction（iOS 无此机制）。我们要按 `docs/embedded-runtime-contract.md` 自己写 iOS Supervisor。
- 嵌入式契约（现成的、正是为我们准备的接缝）：
  - `EMBEDDED_RUNTIME=1`、`DATA_DIR` 必须绝对路径、`BETTER_SQLITE3_NATIVE_BINDING=<绝对 .node>`（用 `process.dlopen()` 加载，绕开 node_modules 解析）；
  - 退出码语义 `0/10/11/12/13/14/15/1`（11 = runtime-pack 问题）；
  - 健康检查 `GET /healthz` → `{status, services.http, services.tcp, database.schema, admin.available, assets, multiplayer}`；
  - `SIGTERM/SIGINT` 优雅停机 + WAL checkpoint。
- 端口：HTTP 8001、TCP 会话 8003、hub 8004。资源模式：`client-owned`（客户端自有资源，启动不跑同步）/ `local`（本地 CDN 目录）/ `remote`。

### 2.2 Node 版本兼容性 —— ✅ 今天实测通过（关键结论）
- 用 `node-v18.20.4-win-x64`（ABI 108）+ `better-sqlite3@11.3.0` 官方 prebuild `node-v108-win32-x64` 直接跑 `server-bundle/out/cn-server.js`：
  ```
  [TCP] session server listening
  [iOS-NOTICE] notice endpoints ready (3 paths, shotgun=true, provideCode=injected)
  {"level":30,...,"msg":"Server listening at http://127.0.0.1:8001"}
  ```
  DB 自动建库成功（`wdfp_data.db` + `-wal`，schema 28），`/healthz` 有响应（该次响应被机器上另一个 Node 24 实例接走了，我自己的进程日志证明监听成功）。
- 编译产物 `out/**/*.js` 全量 grep Node 20+ 专属 API：**只有 2 处**——`run.js`/`tools/start_cn.cjs` 的 `process.loadEnvFile`（平台启动器，iOS 上本来就要替换）、`out/lib/mission/active-fact-session.js:251` 的 `structuredClone`（Node 17+ 已有）。产物是 CommonJS，无 `import ... with { type }`。
- **⇒ 结论：iOS 端用 Node 18.20.4 即可，不必自己把 Node 20/22 移植到 iOS**（那是最贵的一条路，直接省掉）。`package.json` 的 `engines: >=20.12.0` 是声明，不是硬依赖。

### 2.3 静态补丁层（已有工具，可直接复用）
- `client-patch/build/patch-ipa.mjs`（唯一出包入口，零依赖，要 Node ≥20）：域名字符串表 + AIR ABC 常量池**等长改写**；基线 108,757,200 B 主二进制、**150 个站点中 137 个可改写**（13 个太短）；`https://shijtswygamegf.leiting.com`（5+26）↔ `http://<userinfo 填充>@host:port`（4+27）→ **总长必须严格相等**，客户端字符串池是顺序长度前缀表，改短就黑屏。
- 6 处函数补丁：sohu 域名阻断、首登提示 stub、登录弹窗 3 分支、欢迎横幅 3 处、协议门 3 处、bundleId 校验 stub（`0x312230` 返回 0，可改 CFBundleIdentifier 装第二份）；启动守卫 NOP（仅 `0xb00c`，默认安全模式）。
- IPA 重打包保留 zip 元数据（method=8 / madeBy=0x1300 / externalAttr=0x81ed0000 / mode 0o755、3568 条 CRC 校验）——换 `jar uf0` 会把 AltStore 装不上的坑已经踩过。
- 单机目标：把 authority 统一改成 `http://000000000000@127.0.0.1:8001`（保长），或 `--endpoint=none` 保留原域名（用于对照/抓包）。

### 2.4 iOS Node 运行时 —— 现成件已拿到
- `D:\spcntweak\_ref\nodejs-ios\nodejs_18.20.4-1_iphoneos-arm64.deb`（12.3 MB，解包后）内含：
  - `var/jb/usr/local/lib/nodejs/node` = **70.78 MB arm64 Mach-O（Node 18.20.4）**
  - `var/jb/usr/local/lib/nodejs/entitlements.xml`（动态代码生成 / JIT / 库校验绕过）
  - `var/jb/usr/local/bin/node` = 包装脚本，带 V8 flags `--no-wasm-code-gc --no-opt --no-sparkplug --single-threaded --liftoff --no-wasm-tier-up`
- 上游配方（可自建、可复现）：`nickscha/nodejs-mobile`（Node 18 patch，直接产出 `out/Release/node` 可执行文件）、`capawesome-team/nodejs-mobile`（Node 18.20.4，`tools/ios_framework_prepare.sh`：`./configure --dest-os=ios --dest-cpu=arm64 --v8-options=--jitless …` → `xcodebuild` → `NodeMobile.xcframework`）。
- 原 `janeasystems/nodejs-mobile` 只到 **Node 12.19**（`src/node_version.h`），用不了。

### 2.5 资源资产 —— 本机全有
- `D:\wfcnmod\cdn\` = **10.14 GB / 697 文件**，标准 CDN_DIR 结构：`archive-{android,common,ios,medium}-{full,diff}` + `entities/` + `path`。
- `D:\wfspcn\resources\server\` = **10.83 GB / 6211 文件**，一个跑通的 local 模式数据目录（`.cdn` + `.database` + `assets` + `data` + `docs`）。
- 客户端侧导入先例：`NSDelta/wf-cdn-importer-iOS` —— 把 634 个归档写进 `<container>/Library/Application Support/<app id>/Local Store/asset/asset_download/<sub>/download/`，最终 137,820 文件 / 10,191,161,030 B，写 `info.json`（version 1.4.54 / assetRecoveryInfo [] / totalSize）；悬浮球 + 导入面板 + 进度/取消，已实机修过 3 个问题。

### 2.6 UI 与分发先例
- 自家 C 线 `SpLoginOverlay`（`ios/tweak/SpLoginOverlay.m`）：独立 `UIWindow`（`UIWindowLevelStatusBar + 100`）、永不 `makeKeyAndVisible`、`hitTest` 返回 nil 穿透、52×52 可拖悬浮球、面板用 `addChildViewController`、键盘期临时 `makeKeyWindow` 后还原、冷启动 resume 轮询 + 1.5s/5s keepalive 防回收。**悬浮球+悬浮窗这套我们已经有实机验证过的实现。**
- 分发链路：`D:\wfspcn\sileo-repo`（Sileo 源，含 `.github/workflows/update-packages.yml`）；C 线 CI `.github/workflows/ios-tweak.yml`（macOS runner 出 rootful/rootless 两条腿，最近成功 run 36712942199）。
- 参考工程 `WF-SP-Elisif-s-server/SPLogin-iOS`：Theos 结构、"只有一份构建"（不做 rootful/rootless 分叉）、静态加固默认开（Makefile `after-all::` 挂钩，因为 `make package` 会重新链接）、WSL 本地构建脚本 `scripts/local-build-wsl.sh`，已知坑：`/mnt/d`（DrvFs）上 `ldid`/`llvm-strip` 报 `Operation not permitted` → 必须复制到 `/tmp` 再签；CRLF 会破坏 `control`。

### 2.7 本机 WSL 现状 —— ⚠️ 当前起不来（阻塞"本地 theos 构建"）
```
错误代码：Wsl/Service/CreateInstance/CreateVm/HCS/ERROR_NO_SYSTEM_RESOURCES
```
- `Ubuntu-24.04`（WSL2）已安装、状态 Stopped；`.wslconfig`：`processors=8 / memory=4GB / swap=4GB`；宿主 15.9 GB 总内存，目前**仅 1.5 GB 可用**。
- 对策（按性价比）：① 关闭占内存大户（Chrome/Electron 类）后 `wsl --shutdown` 重试；② `.wslconfig` 降到 `memory=2GB swap=2GB`；③ 仍不行就走 GitHub Actions macOS 线（C 线已跑通，零阻塞）。

---

## 3. 架构：三层结构

```
┌─ L1 静态层（装机即生效，产物 = 打好的 IPA） ────────────────────────────
│  patch-ipa.mjs        authority → http://<pad>@127.0.0.1:8001（等长）
│  inject-dylib.mjs     LC_LOAD_DYLIB @executable_path/Frameworks/SpCnServer.dylib
│  SpCnRuntime/          node(arm64) + server-bundle + node_modules  ← 塞进 .app
├─ L2 运行时层（SpCnServer.dylib = Supervisor + UI） ────────────────────
│  ① 首次运行：.app/SpCnRuntime → <container>/Library/Application Support/SpCnRuntime
│     （.app 只读且签名不可破坏；原样拷贝后不再动）
│  ② 配置：Library/Preferences/com.starpoint.spcn.plist（沿用 C 线 plist 约定）
│  ③ 生成 .env：DATA_DIR / CDN_DIR / ASSET_MODE / IOS_COMPAT_ENABLED / IOS_API_HOST …
│  ④ posix_spawn node：优先 /var/jb/usr/local/lib/nodejs/node，否则包内自带的
│     env: EMBEDDED_RUNTIME=1
│          BETTER_SQLITE3_NATIVE_BINDING=<…>/better_sqlite3.node
│     cwd: <runtime>/server-bundle/out
│  ⑤ 就绪门：轮询 GET /healthz 直到 ready 才放行游戏网络（首启游戏会立刻发请求）
│  ⑥ 崩溃重启（指数退避）+ 日志 Documents/SpCnServer.log + 退出码 10–15 翻译成人话
├─ L3 悬浮球 + 悬浮窗（复用 C 线 SpLoginOverlay 机制，改造成「服」球） ──────
│  状态  healthz 全字段 / 端口 / DB schema / 存档数
│  服务  启动 / 停止 / 重启 / 随游戏自启 / 守护模式切换
│  资源  CDN 导入（复用 wf-cdn-importer-iOS 引擎，带进度/取消）
│  后台  内嵌 WKWebView 打开 http://127.0.0.1:8001/admin/（web/dist 就在 bundle 里）
│  日志  tail / 导出 / 分享
└────────────────────────────────────────────────────────────────────
```

**资产（§5-Q3 三选一）**：
- **A 客户端导入（推荐）**：复用 wf-cdn-importer-iOS 引擎把 10.14 GB 归档写进客户端 `Local Store`，服务端 `ASSET_MODE=client-owned` → 只占一份空间、断网即玩、服务端不参与大文件传输。
- **B 服务端本地 CDN**：把 10 GB 归档放容器里，`ASSET_MODE=local` + `CDN_DIR` 指过去，让客户端自己"下载"（本机 loopback 下载）。实现最省事（= PC 上那套原样搬），但要占两份空间（归档 + 展开）。
- **C 先跳过**：如果手机上客户端**已经有完整的 1.4.54 资源**（曾经连官服/私服下载过），单机直接就能跑，资源导入可以放到最后做。

---

## 4. 分期计划

| 阶段 | 目标 | 交付物 | 验证方式 |
| --- | --- | --- | --- |
| **P0**（今天，已完成） | 可行性验证 | Node 18 实测通过；资产/运行时/工具链盘点；WSL 阻塞点定位 | 本地起服务 + `/healthz`；本文档 |
| **P1** | 让服务端在 iOS 上跑起来（先不碰游戏） | `SpCnRuntime/`（arm64 node + node_modules + **ios-arm64 `better_sqlite3.node`**）+ 最小 dylib/CLI 拉起 + 日志 | 真机 `node --version`；`/healthz` 200；`database.schema=28`；写档重启不丢 |
| **P2** | Supervisor + 悬浮球/悬浮窗 | Theos tweak 骨架；5 页签面板；plist 配置；崩溃恢复 | 真机：球能拖、面板能开、能启停服务、杀进程能自愈 |
| **P3** | 资源 + 单机闭环（先在 PC 上对齐） | 资源导入引擎（或 local 模式）；存档路径确认 | PC 对照：patched IPA + 本机服务端能进游戏；再搬设备 |
| **P4** | 单 IPA 组装 | `build-ipa.mjs`（patch + 注入 dylib + 塞运行时）+ 未签名 IPA + 安装/签名 SOP | `docs/` 里的 16 项注入不变量断言全过；IPA 能在 TrollStore/自签下装起来 |
| **P5** | 实机验收 | 验收清单 + 报告 | 冷启动、飞行模式、后台切换、杀进程恢复、存档、10 GB 资产、发热/耗电 |

**P1 的头号风险 = `better_sqlite3.node` 的 ios-arm64 交叉编译 —— ✅ 已解除（2026-10-17，78 s 一次通过）**：
- 实际走的是第 4 条路（原计划外）：**WSL/theos 的 clang 11.1.0 + `$THEOS/sdks/iPhoneOS16.5.sdk` 直接编**，不需要 macOS、不需要 node-gyp、不需要 nodejs-mobile 的 gyp 分支。
- 原因：better-sqlite3 11.3.0 的 `src/better_sqlite3.hpp` 只 `#include <node.h> <node_object_wrap.h> <node_buffer.h>`（**纯 V8 老式 addon，不用 NAN / node-addon-api**），所以只要 Node 18.20.4 头文件 + 内置 `deps/sqlite3/sqlite3.c` 即可；链接用 `-bundle -undefined dynamic_lookup`（iOS 上插件由主程序解析符号），**不需要 libnode.a**。
- 产物 `better_sqlite3.node` 1,847,512 B，导出 `_node_register_module_v108`（与 Node 18 ABI 108 精确匹配），未定义 211 个 v8/node 符号留给运行期。
- 可复用命令与全量 `DEFS` 见 `docs/DELIVERY-standalone.md` §交叉编译；脚本化在 `tools/build-native.sh`。
- 兜底（仍未删）：现成 arm64 iOS 二进制（前作 `StarPointCN-iOS-Server.ipa` 里的 `ios_sqlite.dylib` + 适配器）；换存储层实现（**不推荐**）。

---

## 5. 决策记录（2026-10-17 已拍板）

| # | 决策 | 影响 |
| --- | --- | --- |
| **Q1** | **C 两条并行**：越狱 deb 线与单 IPA 线同时做，共用同一份 runtime 与同一份 UI 代码 | 交付两个包：`com.starpoint.spcnserver_*.deb`（rootless/rootful）+ 未签名单 IPA |
| **Q2** | **A 游戏进程内 `posix_spawn` 子进程** | Supervisor 在 dylib constructor 里拉起 node；需实测 jetsam（R2 风险表） |
| **Q3** | **A 导入到客户端容器（client-owned）** | 复用 wf-cdn-importer-iOS 引擎；服务端 `ASSET_MODE=client-owned`，只占一份空间 |
| **Q4** | **A 先用现成 iOS node 18.20.4 二进制** | 已落盘 `D:\spcntweak\runtime\node-ios-arm64\node`（70.78 MB，iOS MinOS 13 / SDK 16.2 / 仅依赖 libSystem + libc++）；后续可换自建 |
| **Q5** | **独立仓库；构建与"CI"走本机 WSL 的 theos**（不用 GitHub Actions macOS） | ⚠️ 前提：WSL 必须能起（已修，见 §2.7）；原生模块交叉编译也要在 WSL 里用 theos 的工具链完成 |
| **Q6** | **非越狱线的 Node 运行方式 = B 两条腿都要、配置切换**：越狱线 `posix_spawn` 独立 `node` 进程（隔离、可重启）；非越狱线 `dlopen` **NodeMobile.framework**（Node 18.20.4 / ABI 108 / 52.8 MB，进程内 `node_start`，彻底不碰 exec 与签名） | 两条腿共用同一份 runtime 与同一份 UI；`spcn-conf.plist` 里 `NodeBackend=process\|framework`（缺省：有 framework 且非越狱 → framework，否则 process）。依据：前作 `StarPointCN-iOS-Server.ipa`（`local.starpoint.cn.iosserver` v2.5.1）已用 NodeMobile.framework 在 iOS 12+ 上进程内跑同一个服务端并发布过 |

**Q5 带来的连带约束（重要）**：
1. 本机 WSL 的 theos 升级为**唯一构建入口**：tweak、dylib、deb、`.node` 原生模块全部在 WSL 里出件。
2. `better_sqlite3.node`（ios-arm64）不再走 macOS CI + node-gyp/Xcode，而是用 **theos 的 Linux clang + iPhoneOS SDK** 交叉编译：
   `clang -target arm64-apple-ios14.0 -isysroot $THEOS/sdks/iPhoneOS16.5.sdk -bundle -undefined dynamic_lookup` +
   Node 18.20.4 头文件（`--nodedir`）。Node 插件在 iOS 上就是 `-bundle` + 动态查找符号，**不需要** libnode.a。
3. `.wslconfig` 已从 `memory=4GB/swap=4GB/processors=8` 调成 `memory=3GB/swap=2GB/processors=4`（原文件备份为 `.wslconfig.bak-spcntweak`），WSL 已能正常启动。
4. 原 `.github/workflows` macOS 那套可以退化成**可选**（不删，留作对照/备用）。

---

## 6. 风险与对策

| 风险 | 影响 | 对策 |
| --- | --- | --- |
| `better_sqlite3.node` ios-arm64 编不出来 | P1 卡死 | macOS CI + nodejs-mobile gyp；兜底换绑定/换实现 |
| 内存：游戏（AIR）+ Node 同进程组超 jetsam | 游戏中随机被杀 | Q2 选子进程/launchd；V8 参数（`--max-old-space-size`、jitless）；实测 RSS |
| V8 无 JIT 性能 | 服务端变慢 | 服务端是 I/O 型（登录/存档/资源索引），预期可接受；必要时用带 JIT entitlement 的签名（越狱线可用） |
| 游戏启动时服务端未就绪 | 首启白屏/黑屏 | L2 就绪门 + healthz 轮询；必要时先弹"服务端启动中"浮窗 |
| 10 GB 资源导入耗时/空间 | 用户体验 | 复用 importer 的进度/取消；导入完成后可删源归档；断点续传 |
| WSL 起不来 | 本地 theos 构建受阻 | 见 §2.7；CI 兜底 |
| 签名/安装链 | 装不上 | P4 出未签名 IPA + 三套 SOP（TrollStore / Sideloadly / 越狱 AppSync）；保留 zip 元数据那套坑已踩过 |

---

## 7. 可复用清单（不重复造轮子）

| 来源 | 复用什么 |
| --- | --- |
| `startpoint-cn` `client-patch/` | IPA 打补丁、20 字节等长改写、6 处函数补丁、16 项注入不变量 |
| `startpoint-cn` `_release/win/platform` | Server Bundle v3、Runtime Pack 结构、`docs/embedded-runtime-contract.md` 契约、退出码 |
| `NSDelta/wf-cdn-importer-iOS` | 悬浮球外壳、10 GB 归档导入引擎（ZIP 64 位/路径校验/续传）、`inject-dylib.mjs` |
| C 线 `ios/tweak/SpLoginOverlay.m` | 独立窗口 + 悬浮球 + 面板 + keepalive 全套机制 |
| `WF-SP-Elisif-s-server/SPLogin-iOS` | Theos 工程结构、静态加固、WSL 构建脚本与已知坑 |
| `nickscha/nodejs-mobile` / `capawesome-team/nodejs-mobile` | iOS Node 18.20.4 构建配方（二进制 / xcframework 两种产物） |
| 自家 `D:\wfspcn\sileo-repo` + C 线 workflows | deb 分发与 macOS CI |
| `D:\wfcnmod\cdn` / `D:\wfspcn\resources\server` | 全量资源，本地即可测试，不必下载 |

---

## 8. 下一步（等 Q1–Q5 拍板后立即执行）

1. 按 Q4 选定运行时来源，产出 `SpCnRuntime/` 骨架（node + node_modules 占位 + `.env` 模板）。
2. 按 Q1 选定路线，起 `ios/standalone/`（Theos 工程）与 Windows 侧装配脚本 `tools/`。
3. 并行推进 P1 原生模块交叉编译（CI 建 workflow 骨架）。
4. WSL 内存问题按 §2.7 处理，恢复本地 theos 构建能力。

---

## 9. 进度（2026-10-17 第三轮结束时的真实状态；§2.7 与 §8 已被本节取代）

**已完成**（可复现，命令见 `docs/DELIVERY-standalone.md` §5）：
1. WSL 修好（`.wslconfig`：processors=4 / memory=3GB / swap=2GB + autoMemoryReclaim）⇒ theos 成为唯一构建入口，已跑通 `make package` 出 rootless/rootful 两个 deb。
2. `better_sqlite3.node`（ios-arm64，1,847,512 B，ABI 108）用 theos clang 交叉编译成功 → P1 风险解除。
3. 运行时组装完成：`runtime/SpCnRuntime/` = node 70.78 MB + server-bundle 67.4 MB + node_modules 28.7 MB + **NodeMobile.framework 52.84 MB** + `ios-entry.js`，共 4,368 文件 / 219.8 MB，清单 `spcn-runtime.json`（含 sha256/ABI/角色）。
4. tweak 源码全部落地（`ios/src/`：Config / Log / Supervisor / **NodeFramework** / Overlay / PanelViewController + `Tweak.xm`），**两种后端**（`process` = posix_spawn 独立进程；`framework` = dlopen + node_start 进程内；`auto` 按越狱状态与 framework 存在性自动选）。
5. 单机一体 IPA 总装打通（`tools/build-ipa.mjs`：补丁 → 注入 dylib → 塞运行时/framework）：`dist/spcn-ios-standalone.ipa` 188,192,209 B / 7,939 条目 / sha256 `6b8855b9d478066d…`，三段自校验全过。
6. 仓库独立成 `NSDelta/startpoint-cn-ios-embedded`（公开 GPL-3.0），本地已有 2 个提交（**尚未 push**）。

**未做（下一轮）**：
1. **上机验证**（唯一挡在交付前的事）：越狱线装 deb + 铺运行时；非越狱线 TrollStore 直装一体 IPA。看面板状态与 `Documents/SpCnEmbedded.log`。
2. 10 GB 资源导入（`client-owned` 模式下先跳过；需要时接 wf-cdn-importer 引擎）。
3. `tools/build-all.sh` 一键出两个包；push 到 GitHub。

---

## 10. 进度（2026-10-17 第四轮：把「能装」这件事做到一键）

**这一轮解决的问题**：第三轮交付的越狱线要手工把 4,368 个文件（220 MB）铺到 `/var/jb/usr/share/spcn/runtime`，
上机门槛太高（Filza 里点到天亮）。本轮把它变成**一个 deb 装完**，并给越狱线单独出「纯补丁 IPA」。

1. **一键 deb**（`tools/build-runtime-deb.sh`）：包名与 tweak 小 deb 相同（`com.starpoint.spcnembedded`，Version 0.2.0）
   ⇒ 装 full 就是升级，避免两个包共享同一批文件、卸载其一删掉另一文件。内容 = dylib + 过滤器 plist + 完整运行时（含 NodeMobile.framework）。
   产物 `SpCnEmbedded-full-rootless.deb` / `-rootful.deb`（各 ≈49.6 MB），dpkg 门禁 9 项（node 0755 / 清单 / ios-entry.js /
   framework / server-bundle 入口 / 原生模块 / dylib / plist / 条目数 ≥4300）。
2. **纯补丁 IPA**（`tools/build-ipa.mjs --no-dylib --no-runtime`）：只做端点/站点/guard 补丁，不带 dylib 与运行时
   （dylib + 运行时由 deb 提供）⇒ 避免同一进程里两份同名类 dylib（两套悬浮球 + 两个 node 抢 8001）。
   `dist/spcn-ios-patched-only.ipa` 135,720,976 B / 3,568 条目 / sha256 `fe3871230b6de853…`。
3. **重复注册守卫**（`ios/Tweak.xm`）：`NSClassFromString(@"SpCnOverlay") != [SpCnOverlay class]` ⇒ 本份 dylib 直接退出，
   兜住「deb 与注入式 IPA 同时装」的误配。
4. **资源导入引擎接线**（用户指定的下一优先项）：`ios/src/SpCnPanelViewController.m` 加第 7 个按钮「资源」→
   `ios/src/SpCnResourceViewController.{h,m}`（选目录/扫描/导入/取消/打开目录 + 进度 + 日志 + security-scope 持有），
   引擎在 `ios/src/importer/`（移植自 wf-cdn-importer-iOS 的 ZIP/TAR 解析 + 导入计划 + 引擎；Makefile 已加 `-lz` 与 `-Isrc/importer`）。
5. **上机文档**：`docs/INSTALL-jailbreak.md`（判断 rootless/rootful → 装 deb → 装补丁 IPA → 首启 → 排障表 → 可调项 → 卸载）
   + `tools/serve-dist.mjs`（PC 起只读文件服务，手机 Safari 直接下载两个包；PC 局域网 IP = 192.168.0.105）。

---

## 11. 进度（2026-10-17 第五轮：资源导入真正进包 + 全量重出）

**这一轮解决的问题**：第四轮只把「资源」按钮的 UI 搭出来，引擎还是空壳；本轮把 wf-cdn-importer-iOS 的导入引擎真正编进 dylib，并让整条交付线一条命令可复现。

1. **引擎移植落地**（子代理执行，本机编译验证）：`ios/src/importer/` 共 12 个 `.m` / 18 个文件 ——
   `CdnImporterConfig`（路径解析：Local Store 四级探测 / asset_download 子目录（`dummy` 回退）/ 4 个 partial 标记 / 工具函数）、
   `CdnArchiveSource`、`CdnArchiveIndex`、`CdnTarIndex`、`CdnZipArchive`（中央目录解析 + 流式解压 + 逐条目 CRC32）、`CdnSHA256`、
   `CdnImportPlan` + `CdnImportPlan.generated`（634 条归档、后覆盖先的顺序、压缩态合计与终态口径 10,191,161,030 B / 137,820 文件）、
   `CdnImportEngine`（索引 → 缺包检查 → 内容校验（可关）→ 解压 → 写 `info.json` + 清 partial）、门面 `SpCnResourceImporter`
   （`scanSourceDir:` / `startImport` / `cancel` / `reset` / `onChange` 回主线程 + 4 次/秒节流）。
   日志并入 `SpCnLog`（`CdnImporterLog(...)` ≡ `[SpCnLog line:...]`，不再开第二个日志文件）；`ios/Makefile` 已加 `-lz` 与 `-Isrc/importer`。
   **dylib 126,928 B → 402,160 B**。
2. **编译修复**：`ios/src/SpCnResourceViewController.m:186` 的 `scanSourceDir:nil` 撞 `-Werror,-Wnonnull`（我写 UI 时的失误）→ 去掉那次调用，改为只更新标签。
3. **全量交付物重出**（`node tools/build-all.mjs`，本轮新增）：11 个产物 + `dist/BUILDS.json`；大小与 sha256 见 `docs/DELIVERY-standalone.md` §1 锚点块（已从占位改为实测值）。
   其中一体 IPA `188,300,635 B / 7,939 条目 / sha256 e45ff6756ab06772…`，纯补丁 IPA `135,720,976 B / 3,568 条目 / fe3871230b6de853…`，
   一键 deb `49,755,774 B`(rootless) / `49,752,732 B`(rootful)。
4. **一键重建**：`tools/build-all.mjs` 七步串起来（组装运行时 → tweak → 运行时 tar → 一键 deb → 一体 IPA → 纯补丁 IPA → 汇总哈希），
   参数 `--ipa=` / `--distro=` / `--no-runtime` / `--keep-work`。改完任何源码只要跑它一次，就得到一致的整套产物。
5. **文档回填**：`docs/DELIVERY-standalone.md` §1 的 SHA256 锚点块已填实测值（含 dylib 体积变化原因）；
   `docs/INSTALL-jailbreak.md` 补依赖说明（`mobilesubstrate | ellekit`；本 tweak 只用 constructor、不调 MS API，必要时可忽略依赖安装）。

**未做（下一轮）**：
1. **上机验证**（唯一挡住交付的事，需用户动手）：装 `SpCnEmbedded-full-rootless.deb` + `spcn-ios-patched-only.ipa`，看悬浮球面板状态与 `spcn-server.log`。
2. 资源导入的**真机行为**未验证（编译期已自证；PC 侧只做过「同布局跑 Node 18 服务端」的等价验证，导入 10 GB 归档本身没跑过）。
3. 仓库 push（需先在 GitHub 建空仓库 `NSDelta/startpoint-cn-ios-embedded`；本机无 `gh`）。

