# 真机验证结果与最终可用配方（2026-10-19）

iPhone 7 Plus（iOS 15.8.3，Dopamine rootless，ellekit 1.1.3）上**已实测可玩**：
`com.testdj.wf` 单机 IPA 进游戏 → 客户端与本机服务端通信 → auto-login 成功 → 可正常操作（悬浮球不挡手）。

## 一、让它跑起来的关键事实（按重要性排序）

### 1. bundle id 必须保持 `com.leiting.wf`
AIR 运行时在 `didFinishLaunching` 后约 150 ms 做打包自检：
`-[CTAppDescriptor appID]`（VA `0x10000FF78`）读 `[[NSBundle mainBundle] infoDictionary][@"CFBundleIdentifier"]`
→ 喂 ADEP 许可证/解密链 `sub_1002EB42C` → 失败则 AS3 抛异常 → `sub_1004D4068` 里 `_longjmp`
→ 被 `sub_100011B94` 的 `_setjmp` 兜住 → 打印 `AdobeAIR: application packaging error`（错误码 2046）
→ **内容永不加载 = 黑屏、零网络请求、不崩溃**。

实验矩阵证明：把 Info.plist id、AIR 描述符 `<id>`、`CFBundleURLName`、进程 entitlements、
二进制里烧死的两份「app id + team id」记录**全部**改成新 id 之后，自检**仍然**失败；
只要 id 回到 `com.leiting.wf`，错误当场消失。
⇒ **单机包就用 `com.leiting.wf`**（代价：会覆盖/替换原版 App，不能与公共服务器那一个共存）。

> 诊断用的 `IdentityLie`（`-[NSBundle infoDictionary]` 谎报 CFBundleIdentifier）保留在 dylib 里但默认关闭；
> 它曾成功骗过自检（`AdobeAIR: application packaging error` 消失），说明自检只认这一个来源。
> 早期「改 bundle id 并存」的做法需要谎报才能过自检，实际使用时不如直接用原 id 干净。

### 2. 进程内 node 必须带 V8 旗标（否则 SIGTRAP 崩游戏）
`ios/src/SpCnNodeFramework.m` 传给 `node_start` 的 argv：
`node --jitless --no-opt --no-sparkplug --no-wasm-tier-up --no-wasm-code-gc <runtime>/ios-entry.js`
（iOS 无 JIT 权限；不带这些旗标时 V8 走 JIT 路径 → `v8::internal::trap_handler::EnableTrapHandler`
→ `EXC_BREAKPOINT/SIGTRAP` 直接带走游戏进程）。

### 3. 三条运行时补丁（都在 `runtime/SpCnRuntime/`，随包发）
- `ios-entry.js`：
  - `installNoIcuShim()`：NodeMobile.framework 是 `--with-intl=none` 编的，
    服务端 `out/content/sync/ordered-map.js:6` 的 `new TextDecoder("utf-8",{fatal:true})` 会抛
    `ERR_NO_ICU` ⇒ 这里把 `fatal`/`ignoreBOM` 降级掉；
  - `installSandboxSafeRealpath()`：iOS 的路径遮蔽会把 `/var/mobile` 重定向进容器，而 `realpath()`
    把 `/var` 解析成 `/private/var` 会绕出遮蔽 ⇒ `lstat('/private/var/mobile')` ENOENT ⇒ 服务端
    `assertIsolatedContentPaths` 抛错（契约 exit 15）。沙盒内 realpath 失败时退化为字面路径；
  - `process.exit`/`abort` 拦截 + `uncaughtException` 兜底：独立进程里 exit code 是契约，
    进程内会直接把游戏杀掉。
- `server-bundle/out/content/sync/ordered-map.js`：TextDecoder 的 try/catch 兜底（`_spcnNoIcu` 标记）。
- `server-bundle/out/runtime/lifecycle.js`：catch 分支打印 `[spcn-diag] 启动失败 stage=… error=…`
  （上游把真实异常吞了，没有这行就看不到 content 阶段为什么失败）。

### 4. 资源（9.8 GB）要在容器的 `Library/Application Support/<app id>/Local Store`
客户端按 app id 找资源。换 id 时用**符号链接**即可，不必复制：
`<容器>/Library/Application Support/com.leiting.wf -> com.testdj.wf`
（脚本 `tools/link-asset-id-ondevice.sh`；`tools/copy-assets-ondevice.sh` 也可整份拷，约 128 s）。

### 5. 悬浮窗不能吃手势（照 SPLogin-iOS 的窗口级 hitTest）
`ios/src/SpCnOverlay.m` 的 `SpCnOverlayWindow : UIWindow` 重写 `-hitTest:withEvent:`：
`if (hit == self || [hit isKindOfClass:SpCnPassView.class]) return nil;`
**只让某个 view 返回 nil 不够** —— `UIWindow.hitTest:` 在所有子视图都不认时会返回窗口自己。
（用户实测：只改根 VC 的 view 仍然点不动；改成窗口级后「球在，游戏也能正常点」。）
另有偏好 `Overlay`（`spcn-conf.plist`，默认 1）可整层关掉做 A/B。

### 6. 服务端 env（`SpCnConfig -environment`，全部由 dylib 注入）
`EMBEDDED_RUNTIME=1`、`DATA_DIR=<容器>/Documents/SpCn/data`、
`BETTER_SQLITE3_NATIVE_BINDING=<runtime>/node_modules/better-sqlite3/build/Release/better_sqlite3.node`、
`CN_LISTEN_HOST=127.0.0.1` + 8001/8003/8004、`SESSION_PUBLIC_HOST=127.0.0.1`、
`ASSET_MODE=client-owned`、`CDN_BASE_URL=http://127.0.0.1:8001/patch/cn`、
`IOS_COMPAT_ENABLED=1`、`IOS_API_HOST=127.0.0.1:8001`、`IOS_API_SCHEME=http`、
`IOS_SDK_BEAN_KEY=#LeitingAESKey#!`、`IOS_SDK_BEAN_IV=LeitingAESIVKEY!`、
`IOS_SDK_IDENTITY_SECRET=wfcn-ios-sdk-identity-2026-10-01-8f3a91c4d2e6b705`、
`SP_PROBE_UDID=0`、`ADMIN_PASSWORD=`（空 = 仅回环可进后台）、`BIND_GATE_ENABLED=0`。
启动横幅可见（证明 iOS 兼容确实开着）：
`[iOS-SDK-LOGIN] per-device identity active (strict=false)` / `[iOS-NOTICE] notice endpoints ready (3 paths, shotgun=true, provideCode=injected)`。

## 二、实测通过的项目
- `[FW] node_start 已在线程里跑起来（argc=7，入口=…/ios-entry.js）` → `[SUP] 状态 ⇒ 运行中 · 内嵌`
- `/healthz` = `{"contractVersion":1,"status":"ready","runtime":{"api":1,"node":"v18.20.4"},"database":{"ready":true,"schema":28},"services":{"http":true,"tcp":true},"admin":{"required":true,"available":true},"assets":{"mode":"client-owned",…}}`
- 客户端请求（真机服务端日志）：`/sync_data`、`/wf/210009_config_20200415.json`、`/myip?project=wf`、
  `/shijtswy/version/client_release_ios.dis`（200，下发 `{"default":{"apiPath":"127.0.0.1:8001","apiScheme":"http"}}`）、
  `/sdk/v3-3/check_login.do`（`[iOS-SDK-LOGIN] … user=99872731`）、`/protocols/leiting/switch/switch.txt` 等
- auto-login 成功：`loginCallBack:{"type":"AutoLogin","status":"1","userId":"99872731","token":"sp-…"}`
- **用户实测：能正常进游戏并操作** ✅

## 三、已知问题 / 未做
- `/protocols/leiting/sensitive/part/{wf,common,wf-text,common-text}_version.txt` 返回 404 是**上游设计**
  （`out/routes/cn/ios-leiting.js:689` 注释：故意不实现）。SDK 会提示「获取版本信息失败」但不影响登录与游玩。
- 单机包用 `com.leiting.wf` ⇒ **装它会替换官方 App**；想共存只能靠 `IdentityLie` 谎报（可用但不干净）。
- 新容器没有资源时必须先解决资源：① 从旧容器整份拷（脚本现成）② 或在设备上跑面板里的「资源导入」
  （需要把 10 GB 归档放到设备上）③ 或改 `ASSET_MODE=local` 让服务端供 CDN（需要 CDN 归档）。
- 进程内 node 是 jitless，服务端比桌面慢；V8 不可二次启动 ⇒ 面板的「停止/重启」在 framework 后端下会提示
  「与游戏同进程，退出游戏才能重启」。
- 仓库仍未 push（`NSDelta/startpoint-cn-ios-embedded`，公开 GPL-3.0）。
