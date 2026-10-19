# 单机版交付说明（com.leiting.wf，2026-10-19 定稿）

> 目标：原版《世界弹射物语》iOS 1.8.4 里，服务端**跑在 App 进程内**（NodeMobile.framework + node_start），
> 由悬浮球 / 悬浮窗托管；数据全在本机，不依赖电脑。本文件只讲「拿哪个产物、怎么装、怎么导资源、怎么自查」。

## 一、产物清单（`dist/`，哈希见 `dist/BUILDS.json`）

| # | 文件 | 体积 | 用途 |
|---|---|---|---|
| 1 | `SpCnEmbedded-rootless.deb` | 128,126 B | 越狱机（Dopamine 无根）：只装插件本体，运行时另行铺 |
| 2 | `SpCnEmbedded-rootful.deb` | 128,018 B | rootful 越狱 |
| 3 | `SpCnEmbedded-full-rootless.deb` | 49,773,838 B | **推荐**：插件 + 220 MB 运行时一体装完 |
| 4 | `SpCnEmbedded-full-rootful.deb` | 49,769,612 B | 同上 rootful |
| 5 | `SpCnEmbedded-rootless.dylib` / `-rootful.dylib` | 438,288 B | 只要 dylib（自己注入 IPA 时用） |
| 6 | `spcn-ios-standalone.ipa` | 188,317,345 B | **一体 IPA**：补丁 + dylib + 内嵌运行时 + framework，侧载/TrollStore 直装 |
| 7 | `spcn-ios-patched-only.ipa` | 135,720,976 B | 纯补丁 IPA（配 deb 用，不含 dylib/运行时） |
| 8 | `SpCnCdn-20261019-204532.tar.part00..05` | 合计 10,965,791,456 B | CDN 主资源包（`cn/`），分 6 片 |
| 9 | `SpCnPatches-20261019-204523.tar.gz` | 114,202,602 B | 增量包（`patches/` 1.4.55/56/57） |

`spcn-ios-standalone.ipa` sha256 = `a14280f4b815259820070536b61eec21ed76c1c82c5ecd9142210e82332f173c`
`SpCnPatches-…tar.gz` sha256 = `92475b17767e271e873a96c35a5882d7d416a6f9202bd52d0d9be334f3412fe8`

## 二、装法

**A. 越狱机（本机 iPhone 7 Plus / iOS 15.8.3 / Dopamine）**
1. Sileo 装 `SpCnEmbedded-full-rootless.deb`（一条命令装完插件 + 运行时）。
2. 游戏本体用**纯补丁 IPA**（`spcn-ios-patched-only.ipa`）覆盖安装，或保留原版（原版已装的话 deb 会直接注入）。
3. 首次启动等 5–10 s：悬浮球出现 → 点球 → 面板显示「运行中 · 内嵌」、`/healthz` ready。

**B. 非越狱（TrollStore / Sideloadly）**
1. 直装 `spcn-ios-standalone.ipa`（装的是同一个 bundle id，覆盖安装；数据容器保留）。
2. 必须用 TrollStore 或 Sideloadly/AltStore 重签（IPA 未签名）。
3. **bundle id 不能改**：AIR 会在启动 150 ms 内做一次打包自检，要求 `Info.plist CFBundleIdentifier = application.xml <id> = com.leiting.wf`，改成别的 id 会黑屏（我们试过改 testdj + 重签 entitlements + 改描述符 + 改二进制里的身份记录，全部无效）。

## 三、资源导入（面板「资源」按钮）

1. 把 CDN 分片解到同一个父目录：
   `cat SpCnCdn-20261019-204532.tar.part* | tar -xzf - -C <父目录>` ⇒ `<父目录>/cn/`
2. 把增量包解到**同一个父目录**：`tar -xzf SpCnPatches-20261019-204523.tar.gz -C <父目录>` ⇒ `<父目录>/patches/`
3. 面板 →「资源」→「选目录…」→ 选 `<父目录>` →「导入」。
4. 导入前可先「扫描」（`dryRun`）看缺包/多余；导入中会显示归档进度与文件数；结束后写
   `<容器>/Library/Application Support/<bundle id>/Local Store/asset/asset_download/dummy/info.json`
   （`version = 1.4.57`、`totalSize = 计划表 size 列之和`）。

> 引擎按 **basename** 匹配导入计划（`ios/src/importer/CdnImportPlan.generated.m`，646 条），
> 所以目录层级多深都不影响；1.4.55/56/57 的 12 个归档已在计划里，且**顺序在 1.4.54 之后**（后写覆盖先写）。

## 四、导入前自查（不需要真机）

```bash
node tools/verify-import-plan.mjs            # 计划 646 条 ↔ 目录归档对账（体积 + 补丁 sha256 + diff 链）
```

期望输出结尾：`✓ 对账通过：646 条计划 ↔ 760 个归档，可以放心导入`。
它还会报「同名重复归档内容一致性」（`cn/` 与 `patches/` 里那 10 组）与「目录里多余、计划没有」的归档（111 B 空 diff，忽略即可）。

## 五、本机专用事实（换机前必读）

- 资源真实路径**没有 bundle id 段**的老路径也存在过；当前容器里是
  `<AS>/com.leiting.wf/…`，并做了 `<AS>/com.leiting.wf → com.testdj.wf` 的符号链接（早期改 id 实验遗留，无害）。
- 服务端 env 由 `ios/src/SpCnConfig.m` 生成：全回环监听 `127.0.0.1`（8001/8003/8004）、`ASSET_MODE=client-owned`、
  `IOS_COMPAT_ENABLED=1`、`IOS_API_HOST=127.0.0.1:8001`、`EMBEDDED_RUNTIME=1`、`DATA_DIR=<容器>/Documents/SpCn/data`。
- 三条运行时补丁（`runtime/SpCnRuntime/`）：`ios-entry.js` 的 TextDecoder 降级（framework 无 ICU）+ 沙盒安全 realpath；
  `out/content/sync/ordered-map.js` 的 `fatal` 兜底；`out/runtime/lifecycle.js` 的启动诊断行。
- 服务端两份都打过「单机版」补丁（`tools/patch-single-player.mjs`）：绑定闸门恒关、iOS 公告换成「单机版：无需绑定账号」、
  后台 7 条绑定路由改 410。
- 日志：`<容器>/tmp/SpCnBoot-stdout.log`（进程 stdout，AIR 报错在这里）、`<容器>/tmp/SpCnEmbedded.log`（引导期）、
  `<DATA>/SpCnEmbedded.log`、`<DATA>/spcn-server.log`（服务端）。
