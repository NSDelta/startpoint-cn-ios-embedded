# 单机内嵌版 v0.2.0

把 startpoint-cn（世界弹射物语 CN 1.8.1 服务端）**内嵌进 iOS App**：装一个包、点开就能自己玩，不需要电脑 / 局域网 / 服务器。

- 服务端跑在游戏进程内：`NodeMobile.framework`（Node 18.20.4 / ABI 108，V8 `--jitless`）由注入的 dylib 拉起
- 悬浮球 + 悬浮窗：启动 / 停止 / 重启 / 后台管理 / **资源导入** / 日志 / 后端切换
- 账号绑定已移除：无绑定闸门、无验证码公告、后台「账号绑定」页与 7 条接口一并删除（接口 410）
- 资源导入支持 **1.4.54 / 1.4.55 / 1.4.56 / 1.4.57**（646 条归档计划，带离线对账）

## 附件说明

| 附件 | 用途 |
| --- | --- |
| `SpCnEmbedded-full-rootless.deb` | **越狱（无根 Dopamine/ellekit）一键装**：dylib + 过滤器 plist + 完整运行时（含 framework） |
| `SpCnEmbedded-full-rootful.deb` | 有根越狱（`/Library/MobileSubstrate/DynamicLibraries`）版 |
| `SpCnEmbedded-rootless.dylib` / `-rootful.dylib` | 只要 dylib（自己注入 IPA 用；`install_name = @executable_path/Frameworks/SpCnEmbedded.dylib`） |
| `SpCnEmbedded-rootless.deb` / `-rootful.deb` | 小包：只装 dylib + plist，运行时要另外铺 |
| `SpCnRuntime.tar.gz` | 完整运行时（node 18.20.4 arm64 + NodeMobile.framework + server-bundle + 原生 sqlite 模块 + `ios-entry.js`） |
| `SpCnPatches-*.tar.gz` | CDN 增量补丁 1.4.55 / 1.4.56 / 1.4.57（与 CDN 主包解到同一父目录即可） |
| `BUILDS.json` | 全部产物的体积 / sha256 |

**没有附带的东西**（体积或授权原因）：

- `spcn-ios-standalone.ipa`（179.6 MB，一体包：客户端补丁 + 注入 dylib + 运行时）—— 自己用
  `node tools/build-ipa.mjs --ipa=<你自己的官方 iOS 1.8.4 解密 IPA> --out=dist/spcn-ios-standalone.ipa` 生成。
- CDN 主包（`cn/` 约 10.9 GB）—— 放不进 Release，自行准备后用面板「资源 → 选目录 → 导入」。

## 装法

**越狱机（推荐）**

```bash
dpkg -i SpCnEmbedded-full-rootless.deb     # 或用 Sileo/Filza 点安装
```
装完点游戏图标即可。`uiopen` 在锁屏时拉起的进程不跑代码，需要自己点。

**非越狱（TrollStore / AppSync / Sideloadly）**

装自己生成的 `spcn-ios-standalone.ipa`。若资源为空，用面板导入 CDN。

## 三条硬约束（踩过的坑，别绕）

1. `Info.plist` 的 `CFBundleIdentifier`、`application.xml` 的 `<id>` **必须是 `com.leiting.wf`**：AIR 的启动自检要求如此，改了就黑屏（`AdobeAIR: application packaging error`）。
2. iOS 无 JIT：`node_start` 必须传 `--jitless --no-opt --no-sparkplug --no-wasm-tier-up --no-wasm-code-gc`。
3. 沙盒里 `isExecutableFileAtPath:` 会撒谎、`exec` 被拦（EPERM）⇒ 非越狱线只能用**进程内**后端。

更多细节见仓库 `README.md` 与 `docs/STATUS-final.md`。

## 验证状态

- iPhone 7 Plus / iOS 15.8.3（Dopamine + ellekit）真机：服务端 `/healthz` ready、DB schema 28、客户端登录 + 进游戏 + 教程推进（`/sync_data`、`/api/index.php/tutorial/update_step` 200）
- 资源导入引擎：646 条计划 ↔ 760 个归档离线对账通过；真机完整导入过 13.7 万文件 / 9.8 GB
- 未验证：非越狱 iPhone 上的 TrollStore 安装路径（本机只有越狱机）
