#import "SpCnConfig.h"
#import "SpCnLog.h"

static NSString *const kDefaultDataDir = @"/var/mobile/Library/SpCn/data";

@implementation SpCnConfig {
    NSDictionary<NSString *, id> *_prefs;
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
    NSString *confPath = [_dataDir stringByAppendingPathComponent:@"spcn-conf.plist"];
    _prefs = [NSDictionary dictionaryWithContentsOfFile:confPath] ?: @{};

    _httpPort    = [self integerForKey:@"HTTPPort" fallback:8001];
    _sessionPort = [self integerForKey:@"SessionPort" fallback:8003];
    _hubPort     = [self integerForKey:@"HubPort" fallback:8004];
    _assetMode   = [self stringForKey:@"AssetMode" fallback:@"client-owned"];
    _adminPassword = [self stringForKey:@"AdminPassword" fallback:@""];
    _bindGate    = [self boolForKey:@"BindGateEnabled" fallback:NO];

    _httpBase = [NSString stringWithFormat:@"http://127.0.0.1:%ld", (long)_httpPort];
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
    if (![fm isExecutableFileAtPath:_nodePath]) [missing addObject:[NSString stringWithFormat:@"node 可执行：%@", _nodePath]];
    if (![fm fileExistsAtPath:_serverEntry]) [missing addObject:[NSString stringWithFormat:@"服务端入口：%@", _serverEntry]];
    if (![fm fileExistsAtPath:_bindingPath]) [missing addObject:[NSString stringWithFormat:@"原生模块：%@", _bindingPath]];
    if (![fm fileExistsAtPath:[_bundleDir stringByAppendingPathComponent:@"server-manifest.json"]])
        [missing addObject:[NSString stringWithFormat:@"server-manifest.json：%@", _bundleDir]];

    if (missing.count) {
        NSString *msg = [NSString stringWithFormat:@"运行时缺失 %lu 项（%@）：\n  %@",
                         (unsigned long)missing.count, _runtimeDir, [missing componentsJoinedByString:@"\n  "]];
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
    // 契约禁用的一批老变量，显式不出现在环境里（此处不设置即已满足）
    return env;
}

- (NSString *)summary {
    return [NSString stringWithFormat:@"%@\n运行时：%@%@\n数据卷：%@\n端口：%ld / %ld / %ld",
            _runtimeFound ? @"运行时已找到" : @"⚠️ 未找到运行时",
            _runtimeDir ?: @"-", _embeddedInAppBundle ? @" [App 包内·只读]" : @"",
            _dataDir, (long)_httpPort, (long)_sessionPort, (long)_hubPort];
}

@end
