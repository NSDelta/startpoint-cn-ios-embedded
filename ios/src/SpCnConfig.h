// SpCnConfig —— 运行时定位与启动环境拼装
//
// 定位顺序（越狱/非越狱两条线共用，自动探测 ⇒ 同一份 tweak 两边都能跑）：
//   ① <App 包>/SpCnRuntime       非越狱侧载：运行时随 IPA 一起进 .app（只读挂载）
//   ② /var/mobile/Library/SpCn/runtime    越狱：deb 或手动放到用户分区（可写、空间大）
//   ③ /var/jb/usr/share/spcn/runtime      rootless deb 默认位置
//   ④ /usr/share/spcn/runtime             rootful deb 默认位置
//
// 数据卷（唯一可写目录）：
//   · 运行时在 App 包内（只读）⇒ <App 容器>/Documents/SpCn/data
//   · 运行时在用户分区        ⇒ /var/mobile/Library/SpCn/data
//   契约要求 DATA_DIR 是绝对路径且不与 server-bundle/CDN 嵌套 —— 上面两种都满足。
#import <Foundation/Foundation.h>

@interface SpCnConfig : NSObject

@property (nonatomic, copy, readonly) NSString *runtimeDir;      // 运行时根（含 spcn-runtime.json）
@property (nonatomic, copy, readonly) NSString *nodePath;        // node-ios-arm64/node
@property (nonatomic, copy, readonly) NSString *serverEntry;     // server-bundle/out/cn-server.js
@property (nonatomic, copy, readonly) NSString *bundleDir;       // server-bundle
@property (nonatomic, copy, readonly) NSString *modulesDir;      // node_modules
@property (nonatomic, copy, readonly) NSString *bindingPath;     // better_sqlite3.node
@property (nonatomic, copy, readonly) NSString *dataDir;         // DATA_DIR
@property (nonatomic, copy, readonly) NSString *logPath;         // DATA_DIR/spcn-server.log（node stdout/stderr）
@property (nonatomic, copy, readonly) NSString *httpBase;        // http://127.0.0.1:<port>
@property (nonatomic, assign, readonly) BOOL embeddedInAppBundle; // 运行时是否在只读的 App 包里
@property (nonatomic, assign, readonly) NSInteger httpPort;
@property (nonatomic, assign, readonly) NSInteger sessionPort;
@property (nonatomic, assign, readonly) NSInteger hubPort;
@property (nonatomic, assign, readonly) BOOL runtimeFound;

// 可选偏好（<DATA_DIR>/spcn-conf.plist；缺省即单机离线那套）
@property (nonatomic, copy, readonly) NSString *assetMode;        // 默认 client-owned
@property (nonatomic, copy, readonly) NSString *adminPassword;    // 默认 @""（只允许回环访问后台）
@property (nonatomic, assign, readonly) BOOL bindGate;            // 默认 NO（单机不需要 QQ/KOOK 绑定）

// ── 后端选择：同一份 dylib 两条腿 ──
//   process   独立 node 进程（posix_spawn）：越狱首选 —— 有 JIT、能单独重启、崩了不连累游戏
//   framework 进程内（dlopen NodeMobile.framework + node_start）：非越狱唯一稳的路
//             （非越狱 exec 自己的可执行体过不去，dyld 加载已签名的 dylib 则没问题）
// 偏好键：<DATA_DIR>/spcn-conf.plist 的 NodeBackend = auto|process|framework（缺省 auto）
@property (nonatomic, copy, readonly) NSString *backendPref;        // 原样存：auto|process|framework
@property (nonatomic, copy, readonly) NSString *effectiveBackend;   // 已解析：process|framework
@property (nonatomic, copy, readonly) NSString *frameworkBinary;    // 命中的 NodeMobile.framework/NodeMobile，未找到为 nil
@property (nonatomic, copy, readonly) NSArray<NSString *> *frameworkSearchPaths;
@property (nonatomic, assign, readonly) BOOL deviceJailbroken;

+ (instancetype)shared;

/// 重新读 <DATA_DIR>/spcn-conf.plist（面板切换后端后无需重启 App）
- (void)reloadPreferences;

/// 写回后端偏好；backend ∈ auto|process|framework
- (BOOL)setBackendPreference:(NSString *)backend error:(NSError **)error;

/// 把 environment 全量 setenv 进本进程（进程内后端用）
- (void)applyEnvironmentToProcess;

/// 人读后端名：「进程（独立 node·越狱）」/「内嵌（NodeMobile.framework）」
- (NSString *)backendText;

/// 校验运行时完整性（node 可执行、server-bundle、原生模块、可写数据卷）。失败填 error。
- (BOOL)validateWithError:(NSError **)error;

/// 拼出 posix_spawn 用的完整环境（契约 v1 / EMBEDDED_RUNTIME=1）。
- (NSDictionary<NSString *, NSString *> *)environment;

/// 人类可读的一行摘要（悬浮窗顶栏用）。
- (NSString *)summary;

@end
