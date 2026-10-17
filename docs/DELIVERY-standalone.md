# 单机集成交付说明（越狱 deb 线 + 单 IPA 线）

> 本文件记录**当前已构建出什么、怎么装、验到哪一步**。方案与决策见仓库根 `PLAN.md`。
> 时间线：2026-10-17 第一轮 = 规划 + 可行性（P0）；第二轮 = 运行时落盘 + 交叉编译 + tweak 源码 + 两条线的包（P1/P2/P4 大部分）。

## 1. 交付物清单（`dist/`）

| 文件 | 大小 | 用途 | 状态 |
| --- | --- | --- | --- |
| `spcn-ios-standalone.ipa` | 163.9 MB | **单机一体 IPA**：官方 1.8.4 dump 打端点补丁 + 注入 `SpCnEmbedded.dylib` + 内嵌 `SpCnRuntime/`（node 70.8 MB + 服务端 67.4 MB + 原生模块） | 已自校验，**未上机** |
| `SpCnEmbedded-rootless.deb` | 23,690 B | 越狱（Dopamine/rootless，装到 `/var/jb`） | 已构建，**未上机** |
| `SpCnEmbedded-rootful.deb` | 23,630 B | 越狱（rootful，装到 `/Library`） | 已构建，**未上机** |
| `SpCnEmbedded-rootless.dylib` / `-rootful.dylib` | 109,216 B | 注入用 dylib（同源码，rootless/rootful 二进制相同） | 已构建 |
| `SpCnRuntime.tar.gz` | 33.7 MB | 越狱线用的运行时（node + server-bundle + node_modules，解开 166.9 MB） | 已构建 |
| `spcn-ios-standalone.report.json` | 1 KB | 总装报告（三段断言 + sha256） | — |

**唯一 SHA 锚点**：`spcn-ios-standalone.ipa` = `188cd4c94df927a0e01e4e40980afc5dff9b2c6a750f3421a0f5d472b07b2162`（171,856,353 B / 7,934 条目）。

## 2. 两条安装路线

### 2.1 越狱线（deb + 运行时，推荐先验这条）
前置：设备已越狱（Dopamine 等，有 `/var/jb`）、已装 Sileo 的 `openssh`、**已装游戏本体**（App Store 或侧载的 `com.leiting.wf`）。
游戏要连本机服务端，所以**必须装打了端点补丁的那个包**（本仓库的 `spcn-ios-standalone.ipa` 或既有的 LAN 包）；
若只想先看服务端能不能跑，可以只装 deb + 运行时，然后手点悬浮球面板里的「启动」。

```bash
# 在 WSL 里（Windows 侧：wsl -d Ubuntu-24.04 -u ubuntu -- bash -lc "..."）
bash tools/install-device.sh --host 192.168.0.101              # 完整安装 + 等服务端就绪
bash tools/install-device.sh --host 192.168.0.101 --check      # 只自检
bash tools/install-device.sh --host 192.168.0.101 --logs       # 抓日志
bash tools/install-device.sh --host 192.168.0.101 --uninstall  # 卸载（留数据卷）
```
脚本做的事：`scp` 运行时 → `/var/mobile/Library/SpCn/runtime`、`dpkg -i` deb（失败退化为直接铺 dylib+plist）、`killall worldflipper` + `uiopen` 重启游戏、轮询 `http://127.0.0.1:8001/healthz`、不就绪就抓现场日志。

### 2.2 单 IPA 线（一体包）
`dist/spcn-ios-standalone.ipa` 已把运行时塞进 `Payload/worldflipper.app/SpCnRuntime/`，node 保持 `0755`。
- **越狱机**：TrollStore 直装（无需重签），或 Filza/`appinst`。
- **非越狱机**：Sideloadly / AltStore 用 Apple ID 自签（会重签整包，**含新加的 dylib 与 node 二进制**）。免费证书 7 天到期，重签是原地升级、不丢存档。
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
     <App 包>/SpCnRuntime/            ← 非越狱线（IPA 内）
     /var/mobile/Library/SpCn/runtime ← 越狱线（deb + 脚本铺）
     ├─ node-ios-arm64/node            v18.20.4, ABI 108, 70.78 MB
     ├─ server-bundle/                 out/cn-server.js + web/dist(后台) + assets
     ├─ node_modules/                  含交叉编译的 better_sqlite3.node
     └─ spcn-runtime.json              清单（版本/ABI/sha256）
```

**dylib 内的三条腿**：
1. `SpCnConfig` 探测运行时根（顺序：App 包内 → `/var/mobile/Library/SpCn/runtime` → `/var/jb/usr/share/spcn/runtime` → `/usr/share/spcn/runtime`），数据卷落在可写处（包内只读 → `<Documents>/SpCn/data`）。
2. `SpCnSupervisor` 拉起服务端（**Q6：两种后端**）：`process` = `posix_spawn` 独立 node 进程（stdout/stderr 重定向到 `data/spcn-server.log`，`/healthz` 已就绪则收编既有进程，退避重启 2/4/8/16/30 s ×5）；`framework` = `dlopen` NodeMobile.framework 后 `node_start`（非越狱线，免 exec/签名关）。
3. `SpCnOverlay` 悬浮球（52×52「弹」，可拖拽 clamp + 位置持久化）+ 悬浮窗面板（启停/重启/后台/日志，`WKWebView` 开 `127.0.0.1:8001/admin/`）；独立 `UIWindow`（level = StatusBar+100，**只 hidden=NO，绝不 makeKeyAndVisible**），空白处 `hitTest` 透传，三路保活。

## 4. 服务端在设备上的配置（`iOS.env.template`）
`EMBEDDED_RUNTIME=1`（强制读 `server-manifest.json` 校验）、`DATA_DIR=<数据卷>`、`CN_LISTEN_HOST=127.0.0.1`、端口 `8001/8003/8004`、`ASSET_MODE=client-owned`（资源由客户端自己管，服务端不读也不发 CDN）、`IOS_COMPAT_ENABLED=1` + `IOS_API_HOST=127.0.0.1:8001`、`ADMIN_PASSWORD` 空 = 只回环可进后台、`BIND_GATE_ENABLED=0`、`BETTER_SQLITE3_NATIVE_BINDING=<数据卷>/better_sqlite3.node`。
可覆盖偏好：`<数据卷>/spcn-conf.plist`（HTTPPort/SessionPort/HubPort/AssetMode/AdminPassword/BindGateEnabled/**NodeBackend**）。

## 5. 复现构建（全部在 WSL，无 macOS）
```bash
# ① 运行时暂存 + 原生模块（Windows 侧已就位，重做时用）
node tools/assemble-runtime.mjs            # 校验 arm64/清单/原生模块 → runtime/SpCnRuntime + spcn-runtime.json
# ② tweak/deb（WSL，theos 唯一构建入口）
wsl -d Ubuntu-24.04 -u ubuntu -- bash -lc "bash /mnt/d/spcntweak/tools/build-wsl.sh package"
# ③ 运行时 tarball（WSL，保证 node 带可执行位）
wsl -d Ubuntu-24.04 -u ubuntu -- bash -lc "bash /mnt/d/spcntweak/tools/build-wsl.sh runtime"
# ④ 单机一体 IPA（Windows 侧，三段串起来，约 50 s）
node tools/build-ipa.mjs --ipa=<官方解密 iOS-1.8.4.ipa> --out=dist/spcn-ios-standalone.ipa --keep-work
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

## 6. 验证状态（诚实表）

| 项 | 状态 | 证据 |
| --- | --- | --- |
| 服务端在 Node 18.20.4 上能跑 | ✅ 实测 | Windows 侧隔离实验：建库 + HTTP/TCP 起 + `/healthz` 200（`_probe/srv18.log`） |
| ios-arm64 `better_sqlite3.node` 能编 | ✅ | 1,847,512 B，导出 `_node_register_module_v108` |
| theos 能出 dylib/deb | ✅ | `dist/*.deb` 两个 + dylib |
| IPA 补丁（端点/站点/guard） | ✅ 自校验 | 150 站点改写、0 跳过、12/12 站点签名匹配、3569 条原条目逐字节不变 |
| dylib 注入（16 项不变量） | ✅ 自校验 | `ncmds 67→68`、`sizeofcmds 7584→7656`、section 偏移全不变、回读 sha256 一致 |
| 运行时内嵌（可执行位/内容一致） | ✅ 自校验 | node 条目 `mode=100755`、sha256 与源一致、4365 条新增 |
| **设备上 node 能被拉起并监听 8001** | ⛔ 未验 | 待上机（`install-device.sh` 已备） |
| **游戏客户端连上本地服务端进游戏** | ⛔ 未验 | 待上机 |
| 非越狱线 framework 后端 | ⛔ 未实现 | Q6 已拍板，代码未写（见 §7） |
| 资源（10 GB）导入 | ⛔ 未做 | `client-owned` 模式先跳过；要真离线全量资源需接 wf-cdn-importer 引擎 |

## 7. 下一步（按优先级）
1. **上机验越狱线**（`install-device.sh`）：先确认 `[SpCn] loaded` 与 `runtime root=`，再看 `spcn-server.log` 与 `/healthz`。
2. 实现在非越狱线用的 `framework` 后端（`dlopen NodeMobile.framework` + `node_start`）：framework 从用户已持有的 `StarPointCN-iOS-Server.ipa` 里抽取（**只进仓库脚本，不进二进制**），或后续自建。
3. 资源导入（可选，按用户选择）：`client-owned` 下让 wf-cdn-importer 的引擎把 10 GB 资产铺进游戏容器。
4. 文档/CI：把 ①②③④ 串成 `tools/build-all.sh`，一键盘出两个包 + 报告。

## 8. 已知风险（未验前不要当结论）
- **exec 关**：非越狱机上 `posix_spawn` 包内签名的 node 是否被 AMFI 放行，未验证（Q6 的 framework 后端就是为绕过它而留）。
- **内存关**：AIR 游戏 + node 子进程同时常驻，可能在游戏高峰被 jetsam 杀（对照组：Node 18 常驻 RSS 待测）。
- **V8 无 JIT**：现成 node 带 JIT entitlement（越狱可用）；非越狱线走 framework 时是 `--jitless`，服务端性能待测。
- **assets/`client-owned`**：服务端不下发资源，客户端要自己凑齐 10 GB（缺失时印象中是 FileReader 崩溃，不是网络错）。
