# 越狱机上机步骤（deb + 补丁 IPA）

> 目标：手机上不连电脑、不开 PC，游戏自己带着服务端跑（悬浮球「弹」→ 面板 → 启动）。
> 需要：**已越狱**的 iPhone（装了 Filza；有 Sileo 更好）+ 本仓库 `dist/` 里的两个包。
> 走这条线**不要**装 `spcn-ios-standalone.ipa`（它自己带 dylib）—— 会与 deb 里的 dylib 撞成两份同名类
> （虽然新版 dylib 有重复注册守卫会自我退出，但没必要冒这个险）。

## 0. 先判断你的越狱是 rootless 还是 rootful

用 Filza 看根目录有没有 `/var/jb`：

| 看到 | 你的越狱 | 装哪个 deb |
| --- | --- | --- |
| 有 `/var/jb` | rootless（Dopamine、palera1n rootless 等） | **`SpCnEmbedded-full-rootless.deb`** |
| 没有 `/var/jb`，但有 `/Library/MobileSubstrate` | rootful（unc0ver、Taurine、checkra1n 等） | **`SpCnEmbedded-full-rootful.deb`** |
| 只有 `jbroot`/随机前缀（roothide Bootstrap） | roothide 系 | ❗告诉我，我另出一个包（前缀不固定，需要脚本适配） |

装哪个都可以先装错再换：两个包内容一样，只是安装前缀不同（`/var/jb` 前缀 vs 无前缀）。

## 1. 把两个包弄到手机里

最省事：PC 上起一个只读文件服务，手机 Safari 直接点下载——

```powershell
# PC（Windows）侧：
node D:\spcntweak\tools\serve-dist.mjs --port=8088
# 然后手机 Safari 打开： http://192.168.0.105:8088/
```

（也可以走你自己的通道：QQ/爱思/AirDrop 随便；只要能把这两个文件放进手机就行。）

## 2. 装 deb（一条命令搞定 dylib + 运行时）

`SpCnEmbedded-full-*.deb` 里装的是**三样东西**：

| 内容 | rootless 落点 | rootful 落点 |
| --- | --- | --- |
| `SpCnEmbedded.dylib` + 过滤器 `SpCnEmbedded.plist` | `/var/jb/Library/MobileSubstrate/DynamicLibraries/` | `/Library/MobileSubstrate/DynamicLibraries/` |
| 运行时（node + server-bundle + node_modules + NodeMobile.framework + ios-entry.js） | `/var/jb/usr/share/spcn/runtime/` | `/usr/share/spcn/runtime/` |

装法（任选）：
- **Sileo**：用 Filza 点 deb → 「用 Sileo 打开」→ 安装（推荐，能看依赖报错）。
- **Filza**：点 deb → `Install`。
- **命令行**（有 NewTerm/SSH 的话）：`dpkg -i /var/mobile/Downloads/SpCnEmbedded-full-rootless.deb`。

> 依赖声明是 `mobilesubstrate | ellekit`（注入引擎）。若 Sileo 报依赖错：Dopamine/rootless 装的是 **Ellekit**，
> 它一般已声明 `Provides: mobilesubstrate`；实在不行就忽略依赖安装 —— 本 tweak 只用 `__attribute__((constructor))`，
> **不调用任何 MobileSubstrate API**（同一份 dylib 也用于非越狱注入），所以只要有注入引擎在就够。

装完自检（Filza 里看一眼就行）：
- rootless：`/var/jb/usr/share/spcn/runtime/node-ios-arm64/node` 存在，且 `spcn-runtime.json` 在同级目录里；
- 插件目录里有 `SpCnEmbedded.dylib`（约 124 KB）与 `SpCnEmbedded.plist`。

## 3. 装补丁 IPA（游戏本体）

必须用**打了端点补丁**的包（`dist/spcn-ios-patched-only.ipa`，129.4 MB）：150 处官方端点被等长改写成 `http://127.0.0.1:8001`，
sohu 外联被指向死回环，6 项站点补丁 + 11 处自杀式 guard NOP。**官方原版包不行**（它会连真服务器）。
你手上如果只有「LAN 直连版」（指向 `192.168.0.105:8001`），那也不是单机包 —— 换这个。

装法：**TrollStore**（最省事，永久签名）或 **Sideloadly**（PC 上用 Apple ID 自签，7 天）。要点：
- 同一 bundle id（`com.leiting.wf`）**原地升级**安装 ⇒ 存档与已下载的 1.4.54 资源保留；
- ⚠️ **别先把游戏删掉再装** —— 容器被清空后，客户端会去本地服务端要 iOS 资源，而我们这版是 `client-owned`（不下发资源），会卡住进不去；
- 资源是整套方案的前提：客户端自己的 `Local Store` 里要有 1.4.54 的资产（你说已经下全了）。

## 4. 第一次启动

1. 打开游戏 → 左上/右上会出现 52×52 的**悬浮球**，文字「弹」。
2. 点它 → 面板：状态行应该是 `● 运行中（进程）`（越狱机默认后端 = `process`，即 `posix_spawn` 起的独立 node）。
   - 若是 `失败`/`已停止`：点「启动」，等 3–20 s（首次建库 + content 准备）。
3. 点「后台」→ 面板内弹出 `http://127.0.0.1:8001/admin/`（管理端：账号/存档/服务器时间/邮件）。
4. 点「日志」→ 看服务端 stdout（启动行应该出现 `Server listening at http://127.0.0.1:8001`）。
5. 回游戏正常开局（登录走服务端内置的雷霆 mock，登录弹窗/协议门/欢迎横幅都已被补丁跳过）。

## 5. 出问题看哪儿（按顺序）

| 现象 | 先看 | 说明 |
| --- | --- | --- |
| 连悬浮球都没有 | `<游戏容器>/Documents/SpCnEmbedded.log` | 没有 `[BOOT]` 行 ⇒ dylib 根本没被加载：deb 装错前缀 / 注入引擎（Ellekit·Substitute）没生效 / 过滤器 plist 的 bundle id 不匹配。 |
| 有球，点「启动」没反应或失败 | 同上 + `/var/mobile/Library/SpCn/data/spcn-server.log` | 数据卷在 App 包外，所以是 `/var/mobile/Library/SpCn/data`；日志里有 node 的报错原文（缺库 / ABI 不符 / 端口占用）。 |
| 状态是「运行中」，但游戏进不去 | 面板「日志」 | 看客户端请求有没有打到 `127.0.0.1:8001`；重点看 `/healthz` 是否 200（面板顶部摘要会显示）。 |
| 起来一会儿就没了 | `spcn-server.log` + 系统日志 | 内存被 jetsam 杀（游戏 + node 同时常驻）；或 node 崩了（dylib 会自动重启，最多 5 次，退避 2/4/8/16/30 s）。 |
| 进游戏卡读条/黑屏 | — | 客户端资源不全（`client-owned` 模式下服务端不下发资源）。先保证 `Local Store` 里是完整的 1.4.54。 |

## 6. 可调项（不用重装）

在 `<数据卷>/spcn-conf.plist`（= `/var/mobile/Library/SpCn/data/spcn-conf.plist`）里放键值，重启游戏生效；
面板的「后端」按钮也会写这个文件（`NodeBackend` = `auto|process|framework`）。

| 键 | 默认 | 作用 |
| --- | --- | --- |
| `HTTPPort` / `SessionPort` / `HubPort` | 8001 / 8003 / 8004 | 服务端端口（补丁里的端点是 8001，改端口要同时改补丁） |
| `AssetMode` | `client-owned` | `local` 才会用 CDN 目录下发资源（需要 `.cdn` 齐全） |
| `AdminPassword` | 空 | 空 = 只有本机（回环）能进后台 |
| `BindGateEnabled` | `NO` | 打开后未绑定 QQ/KOOK 的账号不能登录（单机不需要） |
| `NodeBackend` | `auto` | `process`（独立进程，越狱默认）/ `framework`（进程内 dlopen NodeMobile，非越狱线） |
| `ServerRoot` | 自动 | 手动指定运行时根目录 |

## 7. 卸载

```text
# 删插件 + 运行时
Sileo/Filza 卸载 com.starpoint.spcnembedded
# 删数据（存档/账目/日志）
/var/mobile/Library/SpCn/
# 游戏本体还原：重装官方 1.8.4 包（App Store 或你的原始 IPA）
```
