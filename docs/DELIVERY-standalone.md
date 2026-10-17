# 单机集成交付说明（越狱 deb 线 + 单 IPA 线）

> 本文件记录**当前已构建出什么、怎么装、验到哪一步**。方案与决策见仓库根 `PLAN.md`。
> 时间线（都是 2026-10-17）：第一轮 = 规划 + 可行性（P0）；第二轮 = 运行时落盘 + 交叉编译 + tweak 源码 + 两条线的包；
> **第三轮 = 进程内后端（NodeMobile.framework）落地 + 两条线重新出包**。

## 1. 交付物清单（`dist/`）

| 文件 | 大小 | 用途 | 状态 |
| --- | --- | --- | --- |
| `spcn-ios-standalone.ipa` | 188,192,209 B（179.5 MB） | **单机一体 IPA**：官方 1.8.4 dump + 端点/站点补丁 + 注入 `SpCnEmbedded.dylib` + 内嵌 `SpCnRuntime/`（node 70.8 MB + 服务端 67.4 MB + 原生模块）+ `Frameworks/NodeMobile.framework`（52.8 MB） | 已自校验，**未上机** |
| `SpCnEmbedded-rootless.deb` | 29,116 B | 越狱（Dopamine/rootless，装到 `/var/jb`） | 已构建，**未上机** |
| `SpCnEmbedded-rootful.deb` | 29,062 B | 越狱（rootful，装到 `/Library`） | 已构建，**未上机** |
| `SpCnEmbedded-rootless.dylib` / `-rootful.dylib` | 126,848 B | 注入用 dylib（同源码，两者只差 LC_UUID） | 已构建 |
| `SpCnRuntime.tar.gz` | 49,654,202 B（47.4 MB） | 越狱线用的运行时（node + server-bundle + node_modules + **NodeMobile.framework** + `ios-entry.js`，解开 219.8 MB） | 已构建 |
| `spcn-ios-standalone.report.json` | 1,045 B | 总装报告（三段断言 + sha256） | — |

**SHA256 锚点**（前 16 位；完整值见 `spcn-ios-standalone.report.json` 与 `sha256sum dist/*`）：

```
188192209  6b8855b9d478066d  spcn-ios-standalone.ipa      ← 本轮产物（含 framework 后端）
 49654202  5476597eb4edfcff  SpCnRuntime.tar.gz
    29116  d8e8bbd8ee604703  SpCnEmbedded-rootless.deb
    29062  ac33bf452112798e  SpCnEmbedded-rootful.deb
   126848  90ce1138a88e01b7  SpCnEmbedded-rootless.dylib
   126848  581432a482f14109  SpCnEmbedded-rootful.dylib
```

上一轮（无 framework 后端）的 IPA = 171,856,353 B / sha256 `188cd4c94df927a0…`，已被本轮覆盖。

## 2. 两条安装路线

### 2.1 越狱线（deb + 运行时）
前置：设备已越狱（Dopamine 等，有 `/var/jb`）、已装 Sileo 的 `openssh`、**已装游戏本体**（App Store 或侧载的 `com.leiting.wf`）。
游戏要连本机服务端，所以**必须装打了端点补丁的那个包**（本仓库的 `spcn-ios-standalone.ipa` 或既有的 LAN 包）；
若只想先看服务端能不能跑，可以只装 deb + 运行时，然后手点悬浮球面板里的「启动」。

```bash
# 在 WSL 里（Windows 侧：wsl -d Ubuntu-24.04 -u ubuntu -- bash /mnt/d/spcntweak/tools/install-device.sh ...）
bash tools/install-device.sh --host 192.168.0.101              # 完整安装 + 等服务端就绪
bash tools/install-device.sh --host 192.168.0.101 --check      # 只自检
bash tools/install-device.sh --host 192.168.0.101 --logs       # 抓日志
bash tools/install-device.sh --host 192.168.0.101 --uninstall  # 卸载（留数据卷）
```
脚本做的事：`scp` 运行时 → `/var/mobile/Library/SpCn/runtime`、`dpkg -i` deb（失败退化为直接铺 dylib+plist）、
`killall worldflipper` + `uiopen` 重启游戏、轮询 `http://127.0.0.1:8001/healthz`、不就绪就抓现场日志。
（设备 SSH 密码用户已忘记 ⇒ 这条路暂时只能手工：用 Sileo/Filza 装 deb、把 tar.gz 解到 `/var/mobile/Library/SpCn/runtime`。）

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
# ⑤ 体检任意 IPA（输入选型/产物自检）
node tools/inspect-ipa.mjs --ipa=<path.ipa>
```

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
| 资源（10 GB）导入 | ⛔ 未做 | `client-owned` 模式先跳过；要真离线全量资源需接 wf-cdn-importer 引擎 |

## 7. 下一步（按优先级）
1. **上机验越狱线**：装 deb + 铺运行时 → 看 `Documents/SpCnEmbedded.log` 里有没有 `runtime root=`、`面板已挂载`，再看 `<数据卷>/spcn-server.log` 与 `/healthz`。
2. **上机验非越狱线**（TrollStore 直装一体 IPA）：确认面板显示「运行中 · 内嵌」，即 `dlopen` + `node_start` 真的起来了（这是唯一没被静态手段证明的一环）。
3. 日志排障固定套路：**先看沙盒 `Documents/SpCnEmbedded.log`，没有 `[SpCn] constructor` 就是 dylib 没被加载**；有则看 `data/spcn-server.log`。
4. 资源导入（可选）：`client-owned` 下让 wf-cdn-importer 的引擎把 10 GB 资产铺进游戏容器。
5. 文档/CI：把 ①②③④ 串成 `tools/build-all.sh`，一键盘出两个包 + 报告。

## 8. 已知风险（未验前不要当结论）
- **exec 关**：非越狱机上 `posix_spawn` 包内签名的 node 是否被 AMFI 放行，未验证（⇒ 非越狱线默认走 framework 后端绕开它）。
- **进程内后端的两条硬约束**：V8 无法同进程二次启动（重启只能重启游戏）、进程内崩溃/`process.exit` 会带走游戏（`ios-entry.js` 已拦截 exit/abort/uncaughtException，但不是万能的）。
- **内存关**：AIR 游戏 + node（独立进程或同进程）同时常驻，可能在游戏高峰被 jetsam 杀（Node 18 常驻 RSS 待测）。
- **V8 无 JIT**：越狱线的独立 node 带 JIT entitlement（可用 JIT）；非越狱线 framework 是 `--jitless`（V8 解释器模式），服务端性能待测。
- **assets/`client-owned`**：服务端不下发资源，客户端要自己凑齐 10 GB（缺失时印象中是 FileReader 崩溃，不是网络错）。
