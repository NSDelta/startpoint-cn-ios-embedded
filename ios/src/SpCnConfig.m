#import "SpCnConfig.h"
#import "SpCnLog.h"
#import <unistd.h>
#import <spawn.h>
#import <signal.h>
#import <errno.h>
#import <sys/wait.h>

static NSString *const kDefaultDataDir = @"/var/mobile/Library/SpCn/data";

/// 真去跑一次 `<node> --version`：YES = 这个二进制在我们的沙盒里能 exec。
/// 只看文件权限/越狱标志不够 —— 沙盒里的 App 常常看不到 /var/jb（本次真机就是），而 exec 会给出确定答案。
/// 起不来或超时都返回 NO（调用方退回进程内 framework），绝不在这里把启动卡死。
static BOOL SpCnNodeExecProbe(NSString *nodePath, int *outRc) {
    if (!nodePath.length) return NO;
    extern char **environ;
    const char *argv[] = { nodePath.UTF8String, "--version", NULL };
    posix_spawn_file_actions_t fa;
    posix_spawn_file_actions_init(&fa);
    posix_spawn_file_actions_addopen(&fa, STDOUT_FILENO, "/dev/null", O_WRONLY, 0);
    posix_spawn_file_actions_addopen(&fa, STDERR_FILENO, "/dev/null", O_WRONLY, 0);
    pid_t pid = 0;
    int rc = posix_spawn(&pid, nodePath.UTF8String, &fa, NULL, (char *const *)argv, environ);
    posix_spawn_file_actions_destroy(&fa);
    if (rc != 0) { if (outRc) *outRc = -rc; return NO; }
    int status = 0;
    for (int i = 0; i < 100; i++) {          // 最多等 10 s（74 MB 二进制首次从闪存读起来要几秒）
        pid_t w = waitpid(pid, &status, WNOHANG);
        if (w == pid) {
            int code = WIFEXITED(status) ? WEXITSTATUS(status) : -1;
            if (outRc) *outRc = code;
            return WIFEXITED(status) && code == 0;
        }
        usleep(100 * 1000);
    }
    kill(pid, SIGKILL);
    waitpid(pid, &status, 0);
    if (outRc) *outRc = -2;                  // -2 = 超时
    return NO;
}

/// 越狱判定的粗探针：只要命中任一路径就认为「设备能跑独立进程后端」
/// （越狱环境下 exec 自己的可执行体没问题；非越狱环境要靠 NodeMobile.framework 走 dyld 加载）
static BOOL SpCnDeviceLooksJailbroken(void) {
    const char *probes[] = {
        "/var/jb",                      // rootless 越狱根
        "/var/lib/dpkg/status",         // dpkg（Sileo/Zebra）
        "/Library/MobileSubstrate",     // rootful 注入
        "/Applications/Sileo.app",
        "/var/binpack",
        NULL,
    };
    for (int i = 0; probes[i]; i++) {
        if (access(probes[i], F_OK) == 0) return YES;
    }
    return NO;
}

@implementation SpCnConfig {
    NSDictionary<NSString *, id> *_prefs;
    NSString *_confPath;
}

+ (instancetype)shared {
    static SpCnConfig *s = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [SpCnConfig new]; [s detect]; });
    return s;
}

- (void)detect {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *bundle = [NSBundle mainBundle].bundlePath ?: @"";

    NSArray<NSString *> *roots = @[
        [bundle stringByAppendingPathComponent:@"SpCnRuntime"],
        @"/var/mobile/Library/SpCn/runtime",
        @"/var/jb/usr/share/spcn/runtime",
        @"/usr/share/spcn/runtime",
    ];
    NSString *found = nil;
    for (NSString *r in roots) {
        if ([fm fileExistsAtPath:[r stringByAppendingPathComponent:@"spcn-runtime.json"]]) { found = r; break; }
    }
    if (!found) {                                  // 退一步：只要 node 可执行存在就算找到了（便于手工排障）
        for (NSString *r in roots) {
            if ([fm fileExistsAtPath:[r stringByAppendingPathComponent:@"node-ios-arm64/node"]]) { found = r; break; }
        }
    }
    _runtimeDir = [found copy];
    _runtimeFound = (found != nil);
    _embeddedInAppBundle = found ? [found hasPrefix:bundle] : NO;

    if (!_runtimeDir) _runtimeDir = roots[1];       // 仍然给出一组可诊断的默认路径
    _nodePath = [_runtimeDir stringByAppendingPathComponent:@"node-ios-arm64/node"];
    _bundleDir = [_runtimeDir stringByAppendingPathComponent:@"server-bundle"];
    _modulesDir = [_runtimeDir stringByAppendingPathComponent:@"node_modules"];
    _serverEntry = [_bundleDir stringByAppendingPathComponent:@"out/cn-server.js"];
    _bindingPath = [_modulesDir stringByAppendingPathComponent:@"better-sqlite3/build/Release/better_sqlite3.node"];

    // 数据卷：只读挂载（App 包内）⇒ 落容器 Documents；否则落用户分区
    if (_embeddedInAppBundle) {
        NSString *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
        _dataDir = [(docs ?: NSTemporaryDirectory()) stringByAppendingPathComponent:@"SpCn/data"];
    } else {
        _dataDir = kDefaultDataDir;
    }
    _logPath = [_dataDir stringByAppendingPathComponent:@"spcn-server.log"];

    [fm createDirectoryAtPath:_dataDir withIntermediateDirectories:YES attributes:nil error:NULL];

    // 可选偏好：<DATA_DIR>/spcn-conf.plist（键见 README；缺省即单机离线那套）
    _confPath = [_dataDir stringByAppendingPathComponent:@"spcn-conf.plist"];
    _prefs = [NSDictionary dictionaryWithContentsOfFile:_confPath] ?: @{};

    [self resolvePreferences];
}

/// 把偏好解析成实际参数（reloadPreferences 也只跑这一段，路径不重算）
- (void)resolvePreferences {
    _httpPort    = [self integerForKey:@"HTTPPort" fallback:8001];
    _sessionPort = [self integerForKey:@"SessionPort" fallback:8003];
    _hubPort     = [self integerForKey:@"HubPort" fallback:8004];
    _assetMode   = [self stringForKey:@"AssetMode" fallback:@"client-owned"];
    _adminPassword = [self stringForKey:@"AdminPassword" fallback:@""];
    _bindGate    = [self boolForKey:@"BindGateEnabled" fallback:NO];
    _backendPref = [self stringForKey:@"NodeBackend" fallback:@"auto"];
    _overlayEnabled = [self integerForKey:@"Overlay" fallback:1] != 0;

    _httpBase = [NSString stringWithFormat:@"http://127.0.0.1:%ld", (long)_httpPort];

    // ── NodeMobile.framework 探测（进程内后端用）──
    NSString *bundle = [NSBundle mainBundle].bundlePath ?: @"";
    NSString *override = [self stringForKey:@"FrameworkPath" fallback:nil];
    NSMutableArray<NSString *> *paths = [NSMutableArray array];
    if (override.length) [paths addObject:override];
    [paths addObject:[_runtimeDir stringByAppendingPathComponent:@"NodeMobile.framework/NodeMobile"]];
    [paths addObject:[bundle stringByAppendingPathComponent:@"Frameworks/NodeMobile.framework/NodeMobile"]];
    [paths addObject:[_runtimeDir stringByAppendingPathComponent:@"../Frameworks/NodeMobile.framework/NodeMobile"]];
    [paths addObject:@"/var/mobile/Library/SpCn/runtime/NodeMobile.framework/NodeMobile"];
    [paths addObject:@"/var/jb/usr/share/spcn/runtime/NodeMobile.framework/NodeMobile"];
    [paths addObject:@"/usr/share/spcn/runtime/NodeMobile.framework/NodeMobile"];
    _frameworkSearchPaths = [paths copy];

    NSString *fw = nil;
    for (NSString *p in paths) {
        if ([[NSFileManager defaultManager] fileExistsAtPath:p]) { fw = p; break; }
    }
    _frameworkBinary = [fw copy];

    _deviceJailbroken = SpCnDeviceLooksJailbroken();

    // 后端解析：显式偏好优先；auto = **先问「独立 node 到底能不能跑」**。
    // 为什么不是看越狱：沙盒里的 App 常常看不到 /var/jb（本次真机就是这样），只看越狱标志会误判；
    // 而两种后端的差别很实在 —— 独立进程有 ICU、能单独重启、崩了不连累游戏，进程内的 NodeMobile.framework
    // 是 --with-intl=none 编的（用 TextDecoder fatal 就报 ERR_NO_ICU）。所以能 exec 就优先 process。
    // 注意：**不要**用 isExecutableFileAtPath: 当门禁 —— 真机实测它在 App 沙盒里对包内 0755 的 node
    // 也返回 NO（`ls -l` 明明有 x 位），于是永远退不进独立进程后端（真机日志：node能跑=0[没有可执行体]）。
    // 直接 posix_spawn 才是唯一可信的判据，顺便把 errno / X_OK 结果打进日志备查。
    BOOL nodeRuns = NO;
    NSString *nodeWhy = @"没有 node 可执行体";
    if (_nodePath.length) {
        int rc = 0;
        nodeRuns = SpCnNodeExecProbe(_nodePath, &rc);
        if (nodeRuns) {
            nodeWhy = [NSString stringWithFormat:@"rc=%d", rc];
        } else {
            nodeWhy = [NSString stringWithFormat:@"exec 失败 rc=%d（X_OK=%d errno=%d）",
                       rc, access(_nodePath.UTF8String, X_OK), errno];
        }
    }

    if ([_backendPref isEqualToString:@"process"] || [_backendPref isEqualToString:@"framework"]) {
        _effectiveBackend = [_backendPref copy];
    } else if (nodeRuns) {
        _effectiveBackend = @"process";
    } else if (_frameworkBinary) {
        _effectiveBackend = @"framework";
    } else {
        _effectiveBackend = @"process";
    }

    [SpCnLog line:@"[CFG] 后端=%@（偏好=%@ 越狱=%d node能跑=%d[%@] framework=%@）", _effectiveBackend, _backendPref,
     _deviceJailbroken, nodeRuns, nodeWhy, _frameworkBinary ?: @"未找到"];
}

- (void)reloadPreferences {
    _prefs = [NSDictionary dictionaryWithContentsOfFile:_confPath] ?: @{};
    [self resolvePreferences];
}

- (BOOL)setBackendPreference:(NSString *)backend error:(NSError **)error {
    if (![backend isKindOfClass:[NSString class]] ||
        ![@[@"auto", @"process", @"framework"] containsObject:backend]) {
        if (error) *error = [NSError errorWithDomain:@"SpCnConfig" code:3
                                            userInfo:@{NSLocalizedDescriptionKey:
            [NSString stringWithFormat:@"NodeBackend 只能是 auto/process/framework，收到 %@", backend]}];
        return NO;
    }
    NSMutableDictionary *prefs = [NSMutableDictionary dictionaryWithContentsOfFile:_confPath]
                               ?: [NSMutableDictionary dictionary];
    prefs[@"NodeBackend"] = backend;
    if (![prefs writeToFile:_confPath atomically:YES]) {
        if (error) *error = [NSError errorWithDomain:@"SpCnConfig" code:4
                                            userInfo:@{NSLocalizedDescriptionKey:
            [NSString stringWithFormat:@"写入失败：%@", _confPath]}];
        return NO;
    }
    [self reloadPreferences];
    return YES;
}

- (NSString *)backendText {
    if ([_effectiveBackend isEqualToString:@"framework"]) {
        return _frameworkBinary ? @"内嵌（NodeMobile.framework）" : @"内嵌（framework 缺失）";
    }
    return _deviceJailbroken ? @"进程（独立 node·越狱）" : @"进程（独立 node）";
}

- (void)applyEnvironmentToProcess {
    NSDictionary<NSString *, NSString *> *env = [self environment];
    for (NSString *k in env) {
        setenv(k.UTF8String, env[k].UTF8String, 1);
    }
}

- (NSInteger)integerForKey:(NSString *)k fallback:(NSInteger)d {
    id v = _prefs[k]; return [v respondsToSelector:@selector(integerValue)] ? [v integerValue] : d;
}
- (NSString *)stringForKey:(NSString *)k fallback:(NSString *)d {
    id v = _prefs[k]; return [v isKindOfClass:[NSString class]] ? v : d;
}
- (BOOL)boolForKey:(NSString *)k fallback:(BOOL)d {
    id v = _prefs[k]; return [v respondsToSelector:@selector(boolValue)] ? [v boolValue] : d;
}

- (BOOL)validateWithError:(NSError **)error {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSMutableArray<NSString *> *missing = [NSMutableArray array];

    if ([_effectiveBackend isEqualToString:@"framework"]) {
        // 进程内后端不需要 node 可执行体（那正是它存在的理由），但必须有 framework
        if (!_frameworkBinary) {
            [missing addObject:[NSString stringWithFormat:@"NodeMobile.framework（找过：%@）",
                                [_frameworkSearchPaths componentsJoinedByString:@" / "]]];
        }
        if (![fm fileExistsAtPath:[_runtimeDir stringByAppendingPathComponent:@"ios-entry.js"]]) {
            [SpCnLog line:@"[CFG] 提示：运行时里没有 ios-entry.js，将直接用 server-bundle/out/cn-server.js 作入口"];
        }
    } else {
        // 同样不用 isExecutableFileAtPath:（沙盒里对包内 0755 文件也返回 NO）；能不能 exec 由探测说了算
        if (![fm fileExistsAtPath:_nodePath])
            [missing addObject:[NSString stringWithFormat:@"node 可执行体：%@", _nodePath]];
    }
    if (![fm fileExistsAtPath:_serverEntry]) [missing addObject:[NSString stringWithFormat:@"服务端入口：%@", _serverEntry]];
    if (![fm fileExistsAtPath:_bindingPath]) [missing addObject:[NSString stringWithFormat:@"原生模块：%@", _bindingPath]];
    if (![fm fileExistsAtPath:[_bundleDir stringByAppendingPathComponent:@"server-manifest.json"]])
        [missing addObject:[NSString stringWithFormat:@"server-manifest.json：%@", _bundleDir]];

    if (missing.count) {
        NSString *msg = [NSString stringWithFormat:@"运行时缺失 %lu 项（%@，后端=%@）：\n  %@",
                         (unsigned long)missing.count, _runtimeDir, _effectiveBackend,
                         [missing componentsJoinedByString:@"\n  "]];
        if (error) *error = [NSError errorWithDomain:@"SpCnConfig" code:1
                                            userInfo:@{NSLocalizedDescriptionKey: msg}];
        return NO;
    }
    if (![fm isWritableFileAtPath:_dataDir]) {
        if (error) *error = [NSError errorWithDomain:@"SpCnConfig" code:2
                                            userInfo:@{NSLocalizedDescriptionKey:
            [NSString stringWithFormat:@"数据卷不可写：%@", _dataDir]}];
        return NO;
    }
    return YES;
}

- (NSDictionary<NSString *, NSString *> *)environment {
    NSMutableDictionary *env = [NSMutableDictionary dictionary];
    // 最小可用的基础环境：node 与 libuv 会用到 HOME/TMPDIR/PATH
    env[@"HOME"] = _dataDir;
    env[@"TMPDIR"] = NSTemporaryDirectory() ?: @"/tmp";
    env[@"PATH"] = [_dataDir stringByAppendingPathComponent:@"bin:/usr/bin:/bin:/usr/sbin:/sbin"];
    env[@"LANG"] = @"zh_CN.UTF-8";
    env[@"TZ"] = @"Asia/Shanghai";

    // ── 嵌入式运行契约 v1 ──
    env[@"EMBEDDED_RUNTIME"] = @"1";
    env[@"DATA_DIR"] = _dataDir;
    env[@"BETTER_SQLITE3_NATIVE_BINDING"] = _bindingPath;

    // ── 监听：全部只绑回环（单机不出网）──
    env[@"CN_LISTEN_HOST"] = @"127.0.0.1";
    env[@"CN_LISTEN_PORT"] = [@(_httpPort) stringValue];
    env[@"SESSION_HOST"] = @"127.0.0.1";
    env[@"SESSION_PORT"] = [@(_sessionPort) stringValue];
    env[@"MULTI_HUB_PORT"] = [@(_hubPort) stringValue];
    env[@"SESSION_PUBLIC_HOST"] = @"127.0.0.1";

    // ── 资源：客户端自带（单机不跑内容同步、不提供 CDN 下载）──
    env[@"ASSET_MODE"] = _assetMode;
    env[@"CDN_BASE_URL"] = [NSString stringWithFormat:@"%@/patch/cn", _httpBase];

    // ── iOS 兼容层：接管 /shijtswy/version/client_release_ios.dis ──
    env[@"IOS_COMPAT_ENABLED"] = @"1";
    env[@"IOS_API_HOST"] = [NSString stringWithFormat:@"127.0.0.1:%ld", (long)_httpPort];
    env[@"IOS_API_SCHEME"] = @"http";
    env[@"IOS_SDK_BEAN_KEY"] = @"#LeitingAESKey#!";
    env[@"IOS_SDK_BEAN_IV"] = @"LeitingAESIVKEY!";
    env[@"IOS_SDK_IDENTITY_SECRET"] = @"wfcn-ios-sdk-identity-2026-10-01-8f3a91c4d2e6b705";

    // ── 后台与绑定闸门 ──
    env[@"ADMIN_PASSWORD"] = _adminPassword;
    env[@"BIND_GATE_ENABLED"] = _bindGate ? @"1" : @"0";

    env[@"SP_PROBE_UDID"] = @"0";

    // ── 本工程自用（诊断/进程内后端入口）──
    env[@"SPCN_BACKEND"] = _effectiveBackend;
    env[@"SPCN_RUNTIME_ROOT"] = _runtimeDir;
    // 契约禁用的一批老变量，显式不出现在环境里（此处不设置即已满足）
    return env;
}

- (NSString *)summary {
    return [NSString stringWithFormat:@"%@\n运行时：%@%@\n后端：%@（偏好 %@）\n数据卷：%@\n端口：%ld / %ld / %ld",
            _runtimeFound ? @"运行时已找到" : @"⚠️ 未找到运行时",
            _runtimeDir ?: @"-", _embeddedInAppBundle ? @" [App 包内·只读]" : @"",
            [self backendText], _backendPref ?: @"auto",
            _dataDir, (long)_httpPort, (long)_sessionPort, (long)_hubPort];
}

@end
