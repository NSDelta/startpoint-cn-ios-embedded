# 单机集成交付说明（越狱 deb 线 + 单 IPA 线）

> 本文件记录**当前已构建出什么、怎么装、验到哪一步**。方案与决策见仓库根 `PLAN.md`。
> 时间线（都是 2026-10-17）：第一轮 = 规划 + 可行性（P0）；第二轮 = 运行时落盘 + 交叉编译 + tweak 源码 + 两条线的包；
> **第三轮 = 进程内后端（NodeMobile.framework）落地 + 两条线重新出包**。

## 1. 交付物清单（`dist/`）

> 时间线再补一条：**第四轮 = 越狱线变成「一个 deb 装完」+ 纯补丁 IPA + 资源导入引擎接进面板**（见 `PLAN.md` §10）。

## 1. 交付物清单（`dist/`）

| 文件 | 大小 | 用途 | 状态 |
| --- | --- | --- | --- |
| **`SpCnEmbedded-full-rootless.deb`** | 49,755,774 B（47.5 MB） | **越狱线首选**（一键）：dylib + 过滤器 plist + 完整运行时（含 NodeMobile.framework）；rootless 落 `/var/jb/...` | 已自校验，**未上机** |
| **`SpCnEmbedded-full-rootful.deb`** | 49,752,732 B（47.4 MB） | 同上；rootful 落 `/Library/...` 与 `/usr/share/spcn/runtime` | 已自校验，**未上机** |
| **`spcn-ios-patched-only.ipa`** | 135,720,976 B（129.4 MB） | **越狱线配 deb 用的游戏本体**：只有端点/站点/guard 补丁，不带 dylib 与运行时（`--no-dylib --no-runtime`） | 已自校验，**未上机** |
| `spcn-ios-standalone.ipa` | 188,300,635 B（179.6 MB） | **非越狱线一体包**：补丁 + 注入 `SpCnEmbedded.dylib` + 内嵌 `SpCnRuntime/` + `Frameworks/NodeMobile.framework` | 已自校验，**未上机** |
| `SpCnEmbedded-rootless.deb` / `-rootful.deb` | 116,510 / 116,388 B | 只含 dylib + plist 的「小 deb」（快速迭代 tweak 用；**与 full 同包名**，装哪个以最后装的为准） | 已构建 |
| `SpCnEmbedded-rootless.dylib` / `-rootful.dylib` | 各 402,160 B | 注入用 dylib（两者只差 LC_UUID）。**体积从 127 KB 涨到 402 KB 是因为资源导入引擎（ZIP/TAR + 634 条计划 + 四阶段导入）已编进去** | 已构建 |
| `SpCnRuntime.tar.gz` | 49,653,611 B（47.4 MB） | 运行时打包（手工铺运行时/排查用；解开 219.8 MB） | 已构建 |
| `BUILDS.json` | 2 KB | 本轮全部产物的 sha256/字节数/mtime（`node tools/build-all.mjs` 生成） | — |
| `*.report.json` | 1 KB 级 | 总装报告（sha256 + 断言） | — |

**SHA256 锚点**（`node tools/build-all.mjs` 末尾实测，取前 16 位；完整值见 `dist/BUILDS.json` 与 `dist/*.report.json`）：

```
f4d21c18eb358594  SpCnEmbedded-full-rootless.deb     49,755,774 B
b18c9a9811d31779  SpCnEmbedded-full-rootful.deb      49,752,732 B
fe3871230b6de853  spcn-ios-patched-only.ipa         135,720,976 B
e45ff6756ab06772  spcn-ios-standalone.ipa           188,300,635 B
30626661f614a492  SpCnEmbedded-rootless.dylib           402,160 B
38b6aa774408ad18  SpCnEmbedded-rootful.dylib            402,160 B
f8b406676b06a9af  SpCnEmbedded-rootless.deb             116,510 B
f93a0b789adcb394  SpCnEmbedded-rootful.deb              116,388 B
e5257eb1113467e1  SpCnRuntime.tar.gz                 49,653,611 B
775ae7bd7db6fb97  spcn-ios-standalone.report.json         1,172 B
9dabe34a3b667bac  spcn-ios-patched-only.report.json         905 B
```

## 2. 两条安装路线

### 2.1 越狱线（**推荐：一个 deb 装完** → 详见 `docs/INSTALL-jailbreak.md`）
前置：设备已越狱、有 Filza/Sileo、已装游戏本体（`com.leiting.wf`）。

1. **判断 rootless / rootful**：Filza 里看有没有 `/var/jb`（有 ⇒ 装 `-rootless.deb`；没有 ⇒ `-rootful.deb`）。
2. **装 `SpCnEmbedded-full-<你的越狱>.deb`**（Sileo 打开 / Filza 点安装 / `dpkg -i`）——这一个包就装完
   dylib + 过滤器 plist + **完整运行时**（node + server-bundle + node_modules + NodeMobile.framework + ios-entry.js），
   不需要再手工铺任何文件。
3. **装补丁 IPA** `spcn-ios-patched-only.ipa`（TrollStore 直装 / Sideloadly 自签；**原地升级**，别先删游戏 —— 容器里的
   1.4.54 资源是整套方案的前提）。
4. 开游戏 → 悬浮球「弹」→ 面板 → 状态应为 `● 运行中（进程）` → 「后台」进管理页、「资源」进资源导入。

`tools/install-device.sh`（SSH + scp + dpkg 那条路）**目前不可用**：设备的 SSH 密码已忘 —— 保留脚本作将来备用。
现在的手工/无 SSH 路径就是上面 1–4 + `tools/serve-dist.mjs`（PC 起只读文件服务，手机 Safari 下载两个包）。

### 2.2 单 IPA 线（一体包）
`dist/spcn-ios-standalone.ipa` 已把运行时塞进 `Payload/worldflipper.app/SpCnRuntime/`（node 保持 `0755`），
并把 `NodeMobile.framework` 放进了 `Payload/worldflipper.app/Frameworks/`（**嵌套代码的标准位置** —— 侧载工具重签名时会递归签 `Frameworks/`，
放在自定义目录里的 dylib 有被漏签的风险 ⇒ dyld 起不来）。
- **越狱机**：TrollStore 直装（无需重签），或 Filza/`appinst`。
- **非越狱机**：Sideloadly / AltStore 用 Apple ID 自签（会重签整包，**含新加的 dylib、node 二进制与 framework**）。免费证书 7 天到期，重签是原地升级、不丢存档。
- 安装后**不要**再改 `CFBundleIdentifier`（补丁已把 bundleId 校验打成 return 0，允许改，但没必要）。

## 3. 架构（三层，落地位置）

```
① 静态补丁层（离线、一次性）：官方 1.8.4 IPA
     ├─ 150 处端点 URL → http://127.0.0.1:8001（AIR ABC 常量池等长覆盖，一个字节都不挪）
     ├─ pv.sohu.com → 127.0.0.1:1（断掉唯一的域外请求）
     ├─ 6 项功能站点补丁（实名提示/登录弹窗/欢迎横幅/协议门/bundleId 校验/首启 guard）
     └─ 11 处自杀式 guard NOP
② 注入层：Frameworks/SpCnEmbedded.dylib + LC_LOAD_DYLIB（ncmds 67→68，其余 16 项不变量全过）
③ 运行时层（游戏进程外的确定性数据）：
     <App 包>/SpCnRuntime/            ← 非越狱线（IPA 内）      /  /var/mobile/Library/SpCn/runtime ← 越狱线
     ├─ node-ios-arm64/node            v18.20.4, ABI 108, 70.78 MB（0o100755）
     ├─ server-bundle/                 out/cn-server.js + web/dist(后台) + assets
     ├─ node_modules/                  含交叉编译的 better_sqlite3.node（1,847,512 B）
     ├─ ios-entry.js                   进程内后端入口（拦 process.exit/abort）
     ├─ NodeMobile.framework/          52.84 MB，v18.20.4 / ABI 108（越狱线就地；IPA 线去 .app/Frameworks/）
     └─ spcn-runtime.json              清单（版本/ABI/sha256/角色）
```

**dylib 内的三条腿**：
1. `SpCnConfig` 探测运行时根（顺序：App 包内 → `/var/mobile/Library/SpCn/runtime` → `/var/jb/usr/share/spcn/runtime` → `/usr/share/spcn/runtime`），数据卷落在可写处（包内只读 → `<Documents>/SpCn/data`）；
   framework 搜索顺序：`spcn-conf.plist` 的 `FrameworkPath` → `<运行时>/NodeMobile.framework/NodeMobile` → **`<App 包>/Frameworks/NodeMobile.framework/NodeMobile`** → 同级/越狱目录若干。
2. `SpCnSupervisor` 拉起服务端（**两种后端，`NodeBackend` 可切**）：
   - `process`（默认给越狱机）：`posix_spawn` 独立 node 进程，stdout/stderr 重定向到 `data/spcn-server.log`，`/healthz` 已就绪则**收编**既有进程，崩溃退避重启 2/4/8/16/30 s ×5，可单独停/重启。
   - `framework`（默认给非越狱机）：`dlopen(RTLD_NOW|RTLD_GLOBAL)` + `dlsym("node_start")` + 8 MB 栈的 `pthread` ⇒ **node 与游戏同进程、jitless**；`node_stop` 不存在 ⇒ **只能随游戏退出**（面板会禁用「停止/重启」并说明）。
   - `auto`（出厂默认）：**未越狱 && 找到 framework ⇒ framework；否则 process**。
3. `SpCnOverlay` 悬浮球（52×52「弹」，可拖拽 clamp + 位置持久化）+ 悬浮窗面板（启动/停止/重启/后台/日志/**后端**切换，`WKWebView` 开 `127.0.0.1:8001/admin/`）；独立 `UIWindow`（level = StatusBar+100，**只 hidden=NO，绝不 makeKeyAndVisible**），空白处 `hitTest` 透传，三路保活。

## 4. 服务端在设备上的配置
环境（`ios/src/SpCnConfig.m -environment` 运行时拼装，`iOS.env.template` 是同名参考件）：
`EMBEDDED_RUNTIME=1`、`DATA_DIR=<数据卷>`、`HOME/TMPDIR=<数据卷>`、`CN_LISTEN_HOST=127.0.0.1`、端口 `8001/8003/8004`、
`SESSION_PUBLIC_HOST=127.0.0.1`、`ASSET_MODE=client-owned`、`CDN_BASE_URL=http://127.0.0.1:8001/patch/cn`、
`IOS_COMPAT_ENABLED=1` + `IOS_API_HOST=127.0.0.1:8001`（不含 scheme）、`IOS_SDK_BEAN_KEY/IV/IDENTITY_SECRET`（与前作一致）、
`ADMIN_PASSWORD` 空 = 只回环可进后台、`BIND_GATE_ENABLED=0`、`SP_PROBE_UDID=0`、
`BETTER_SQLITE3_NATIVE_BINDING=<运行时>/node_modules/better-sqlite3/build/Release/better_sqlite3.node`（**包内已签名的那个**，不是数据卷里的副本）。
可覆盖偏好：`<数据卷>/spcn-conf.plist`（HTTPPort / SessionPort / HubPort / AssetMode / AdminPassword / BindGateEnabled / **NodeBackend**(auto|process|framework) / FrameworkPath / ServerRoot）。

## 5. 复现构建（全部在 WSL，无 macOS）
```bash
# ① 运行时组装（Windows 侧）：校验 arm64/清单/原生模块 + 塞 framework + ios-entry.js ⇒ spcn-runtime.json
node tools/assemble-runtime.mjs --node runtime/node-ios-arm64/node \
     --bundle runtime/SpCnRuntime/server-bundle --modules runtime/SpCnRuntime/node_modules \
     --out runtime/SpCnRuntime
# ② tweak/deb（WSL，theos 唯一构建入口；只编 rootless 时用 tools/wsl-rebuild.sh，带完整诊断）
wsl -d Ubuntu-24.04 -u ubuntu -- bash /mnt/d/spcntweak/tools/build-wsl.sh package
# ③ 运行时 tarball（WSL，保证 node 带可执行位）
wsl -d Ubuntu-24.04 -u ubuntu -- bash /mnt/d/spcntweak/tools/build-wsl.sh runtime
# ④ 单机一体 IPA（Windows 侧，三段串起来，约 37 s）
node tools/build-ipa.mjs --ipa=<官方解密 iOS-1.8.4.ipa> --out=dist/spcn-ios-standalone.ipa --force
# ⑤ 体检任意 IPA（**补丁前**的输入选型门禁）
node tools/inspect-ipa.mjs --ipa=<path.ipa>
# ⑥ 一键 deb（越狱线：dylib + 过滤器 plist + 完整运行时；约 1 分钟）
wsl -d Ubuntu-24.04 -u ubuntu -- bash /mnt/d/spcntweak/tools/build-runtime-deb.sh both
# ⑦ 纯补丁 IPA（越狱线用；dylib 与运行时都由 deb 提供）
node tools/build-ipa.mjs --ipa=<官方 iOS-1.8.4.ipa> --out=dist/spcn-ios-patched-only.ipa --no-dylib --no-runtime --force
# ⑧ 手机取包（PC 起只读文件服务，手机 Safari 直接下载）
node tools/serve-dist.mjs --port=8088      # → http://192.168.0.105:8088/
```

> ⚠️ `tools/inspect-ipa.mjs` 是**输入门禁**：拿它去验**已打补丁的产物**必然得到 `VERDICT ❌`
> （12 处站点签名已被补丁改写、包里已出现回环端点）。那是**正常且期望**的结果 —— 恰恰证明补丁生效，
> 不要当成失败。产物的自校验在 `tools/build-ipa.mjs` 终检与 `dist/*.report.json` 里。

### 5.1 `better_sqlite3.node` 交叉编译（可复用，78 s）
```bash
CC=$THEOS/toolchain/linux/iphone/bin/clang CXX=$THEOS/toolchain/linux/iphone/bin/clang++ \
SDK=$THEOS/sdks/iPhoneOS16.5.sdk H=~/bs3/headers/node-v18.20.4/include/node
FLAGS="-target arm64-apple-ios14.0 -isysroot $SDK -O2 -DNDEBUG -fPIC -fvisibility=hidden -Wno-everything"
$CC  $FLAGS $DEFS -c deps/sqlite3/sqlite3.c        -o out/sqlite3.o            # DEFS = deps/defines.gypi 全量 29 项
$CXX $FLAGS $DEFS -std=c++20 -stdlib=libc++ -I$H -I deps/sqlite3 -c src/better_sqlite3.cpp -o out/better_sqlite3.o
$CXX -target arm64-apple-ios14.0 -isysroot $SDK -arch arm64 -bundle -undefined dynamic_lookup \
     -o out/better_sqlite3.node out/sqlite3.o out/better_sqlite3.o
```
要点：better-sqlite3 11.3.0 是**纯 V8 老式 addon**（只用 `node.h` / `node_object_wrap.h` / `node_buffer.h`，不用 NAN / node-addon-api）
⇒ 只要 Node 头文件即可，`-bundle -undefined dynamic_lookup` 让符号在运行时由宿主 node 解析，**不需要 libnode.a**。

### 5.2 NodeMobile.framework 抽取（`tools/extract-framework.mjs`）
```bash
node tools/extract-framework.mjs --ipa="<含 NodeMobile.framework 的 IPA>" \
     --out=runtime/node-framework-ios-arm64        # 默认源：C:/Users/relea/Downloads/StarPointCN-iOS-Server.ipa
```
它从 `Payload/<X>.app/Frameworks/NodeMobile.framework/**` 抠出 framework（**跳过 `_CodeSignature`** —— 侧载重签后旧封条反而误导校验），
写 `PROVENANCE.json`（源包 sha256 / 条目 index / 二进制 sha256），并强制门禁：arm64 Mach-O `MH_DYLIB` + 有 `node_start` 符号 + ABI 与我们的 node 一致（108）。
`tools/fetch-nodemobile.mjs` 是同一件事的另一个入口（可从任意 URL/本机路径取）。

## 6. 验证状态（诚实表）

| 项 | 状态 | 证据 |
| --- | --- | --- |
| 服务端在 Node 18.20.4 上能跑 | ✅ 实测 | Windows 侧隔离实验：建库 + HTTP/TCP 起 + `/healthz` 200（`_probe/srv18.log`） |
| ios-arm64 `better_sqlite3.node` 能编 | ✅ | 1,847,512 B，导出 `_node_register_module_v108` |
| theos 能出 dylib/deb（含进程内后端代码） | ✅ | `dist/*.deb` 两个 + dylib 126,848 B；二进制里 `node_start`/`SpCnNodeFramework`/`NodeMobile.framework` 字符串探针全中 |
| IPA 补丁（端点/站点/guard） | ✅ 自校验 | 150 站点改写、0 跳过、12/12 站点签名匹配；3569 条原条目逐字节不变 |
| dylib 注入（16 项不变量） | ✅ 自校验 | `ncmds 67→68`、`sizeofcmds 7584→7656`、section 偏移全不变、回读 sha256 一致 |
| 运行时内嵌（可执行位/内容一致） | ✅ 自校验 | node 条目 `mode=100755` sha256 `7cf4013d…`；framework 条目 `mode=100644` sha256 `557d1849…`；共 7,939 条目 |
| framework 抽出（ABI/符号门禁） | ✅ | `NodeMobile` 55,406,768 B、v18.20.4、ABI 108、有 `node_start` |
| **设备上 node 能被拉起并监听 8001** | ⛔ 未验 | 待上机（两条后端都未在真机跑过） |
| **游戏客户端连上本地服务端进游戏** | ⛔ 未验 | 待上机 |
| 一键 deb 布局/权限/内容 | ✅ 自校验 | `dpkg-deb -c` 9 项门禁全过（node 0755 / spcn-runtime.json / ios-entry.js / NodeMobile / server-bundle 入口 / 原生模块 / dylib / plist / 条目数 5117·5115） |
| 纯补丁 IPA（越狱线用） | ✅ 自校验 | 3,568 条目、主二进制 mode 100755、150 处端点改写、报告 `dist/spcn-ios-patched-only.report.json` |
| 资源导入引擎（UI 接线） | ⛔ 未验 | 代码已进 `ios/src/importer/` 与面板第 7 个按钮「资源」；**归档解析与导入本身未在设备上跑过** |

## 7. 下一步（按优先级）
1. **上机验越狱线**（唯一挡在交付前的事）：Filza/Sileo 装 `SpCnEmbedded-full-*.deb` → 装 `spcn-ios-patched-only.ipa` → 开游戏看悬浮球与面板状态。
2. 出问题的第一现场（按顺序看）：`<游戏容器>/Documents/SpCnEmbedded.log` → `/var/mobile/Library/SpCn/data/spcn-server.log` → 面板「后台」里的 `/healthz`。
3. **上机验非越狱线**（TrollStore 直装一体 IPA）：确认面板显示「运行中 · 内嵌」，即 `dlopen` + `node_start` 真的起来了（唯一没被静态手段证明的一环）。
4. **资源导入**：把 1.4.54 的归档放到数据卷 `cdn-in/`（或面板「选目录」）→ 面板「资源」→ 扫描 → 导入；导入完客户端就不再需要外部资源。
5. 仓库 push 到 `NSDelta/startpoint-cn-ios-embedded`（公开 GPL-3.0）——**需要先在 GitHub 上把空仓库建出来**（本机没装 `gh`）。

## 8. 已知风险（未验前不要当结论）
- **exec 关**：非越狱机上 `posix_spawn` 包内签名的 node 是否被 AMFI 放行，未验证（⇒ 非越狱线默认走 framework 后端绕开它）。
- **进程内后端的两条硬约束**：V8 无法同进程二次启动（重启只能重启游戏）、进程内崩溃/`process.exit` 会带走游戏（`ios-entry.js` 已拦截 exit/abort/uncaughtException，但不是万能的）。
- **内存关**：AIR 游戏 + node（独立进程或同进程）同时常驻，可能在游戏高峰被 jetsam 杀（Node 18 常驻 RSS 待测）。
- **V8 无 JIT**：越狱线的独立 node 带 JIT entitlement（可用 JIT）；非越狱线 framework 是 `--jitless`（V8 解释器模式），服务端性能待测。
- **assets/`client-owned`**：服务端不下发资源，客户端要自己凑齐 10 GB（缺失时印象中是 FileReader 崩溃，不是网络错）。
