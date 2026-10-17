// SpCnNodeFramework —— 「进程内后端」：把 Node 引擎（NodeMobile.framework）加载进游戏进程，node 与游戏同进程跑。
//
// 为什么需要它：
//   · 非越狱线上，App 沙盒里 posix_spawn 一个自己写进去的 node 可执行体大概率被拦（exec 的可执行性由 AMFI 判），
//     而 dyld 从**已签名**的 App 包里加载一个 dylib 是正常路径 —— NodeMobile.framework 就是这种「一个 dylib 形态的 node」。
//   · 越狱线仍推荐独立进程后端（JIT 可用、能单独重启、崩溃不连累游戏）；两条腿由 SpCnConfig.effectiveBackend 选。
//
// 硬约束（写代码时踩过的）：
//   1) nodejs-mobile 只导出 int node_start(int argc, char **argv)，**没有 node_stop**。node 会一直跑事件循环，
//      所以必须另起线程，且**停止 = 重启游戏**（面板会提示）。重复 node_start 会造出两个 V8 实例 ⇒ 不允许。
//   2) V8 启动时递归很深：pthread 默认栈（iOS 512 KB）不够 ⇒ 显式 8 MB。
//   3) RTLD_GLOBAL 是必须的：扩展（better_sqlite3.node）靠 dynamic_lookup 找 node/v8 符号。
//   4) 进程内后端**绝不能让服务端把游戏带走**：process.exit / abort 的拦截在 ios-entry.js 里做（见该文件）。
#import "SpCnNodeFramework.h"
#import "SpCnConfig.h"
#import "SpCnLog.h"
#import <dlfcn.h>
#import <pthread.h>
#import <unistd.h>
#import <stdio.h>
#import <stdlib.h>
#import <string.h>
#import <errno.h>

typedef int (*SpCnNodeStartFn)(int, char **);

/// 传给 node 线程的启动参数。**故意 malloc 且永不释放**：node 事件循环活多久，argv 就必须活多久。
typedef struct {
    SpCnNodeStartFn start;
    int argc;
    char *argv[12];
} SpCnNodeBoot;

@interface SpCnNodeFramework ()
- (void)noteThreadExit:(int)rc;
- (BOOL)failWithMessage:(NSString *)msg error:(NSError **)error;
@end

static void *spcn_node_thread_main(void *raw) {
    SpCnNodeBoot *b = (SpCnNodeBoot *)raw;
    @autoreleasepool {
        NSMutableArray<NSString *> *parts = [NSMutableArray array];
        for (int i = 0; i < b->argc; i++) [parts addObject:[NSString stringWithUTF8String:b->argv[i]]];
        [SpCnLog line:@"[FW] node 启动：%@", [parts componentsJoinedByString:@" "]];
        int rc = b->start(b->argc, b->argv);
        [SpCnLog line:@"[FW] node_start 返回 rc=%d ⇒ node 事件循环已结束（服务端停了，游戏不受影响）", rc];
        [[SpCnNodeFramework shared] noteThreadExit:rc];
    }
    return NULL;
}

@implementation SpCnNodeFramework {
    SpCnFrameworkState _state;
    NSString *_lastError;
    NSString *_loadedPath;
    void *_handle;
    int _exitCode;
    pthread_t _thread;
}

+ (instancetype)shared {
    static SpCnNodeFramework *s = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [SpCnNodeFramework new]; });
    return s;
}

- (instancetype)init {
    if ((self = [super init])) { _state = SpCnFrameworkStateIdle; _exitCode = -1; }
    return self;
}

- (SpCnFrameworkState)state { return _state; }
- (NSString *)lastError { return _lastError; }
- (NSString *)loadedPath { return _loadedPath; }
- (int)exitCode { return _exitCode; }

- (BOOL)isAlive { return _state == SpCnFrameworkStateRunning || _state == SpCnFrameworkStateStarting; }

- (NSString *)stateText {
    switch (_state) {
        case SpCnFrameworkStateIdle:     return @"内嵌 node 未启动";
        case SpCnFrameworkStateStarting: return @"内嵌 node 启动中…";
        case SpCnFrameworkStateRunning:  return @"内嵌 node 运行中（与游戏同进程）";
        case SpCnFrameworkStateExited:   return [NSString stringWithFormat:@"内嵌 node 已退出（rc=%d）", _exitCode];
        case SpCnFrameworkStateFailed:   return @"内嵌 node 启动失败";
    }
    return @"?";
}

- (void)noteThreadExit:(int)rc {
    _exitCode = rc;
    _state = SpCnFrameworkStateExited;
    if (rc != 0) _lastError = [NSString stringWithFormat:@"node_start 返回 %d", rc];
    [[NSNotificationCenter defaultCenter] postNotificationName:@"SpCnSupervisorStateChanged" object:nil];
}

/// 统一的失败出口：置 Failed、记 _lastError、填 NSError，恒返回 NO。
/// （原来写成 SPCN_FAIL 宏，参数里带逗号的 [NSString stringWithFormat:…] 会被
/// 预处理器当成两个宏参数 ⇒ too many arguments provided to function-like macro invocation）
- (BOOL)failWithMessage:(NSString *)msg error:(NSError **)error {
    _state = SpCnFrameworkStateFailed;
    _lastError = [msg copy];
    [SpCnLog line:@"[FW] 失败：%@", _lastError];
    if (error) {
        *error = [NSError errorWithDomain:@"SpCnNodeFramework" code:1
                                 userInfo:@{NSLocalizedDescriptionKey: _lastError ?: @"内嵌 node 启动失败"}];
    }
    return NO;
}

#pragma mark - 启动

- (BOOL)startWithConfig:(SpCnConfig *)cfg error:(NSError **)error {
    if (_state == SpCnFrameworkStateRunning || _state == SpCnFrameworkStateStarting) {
        [SpCnLog line:@"[FW] 已在运行，忽略重复启动（node_start 不可重入）"];
        return YES;
    }
    if (_state == SpCnFrameworkStateExited) {
        return [self failWithMessage:@"内嵌 node 已经启动过一次并退出；V8 不支持同进程二次启动，请重启游戏" error:error];
    }

    NSString *fw = cfg.frameworkBinary;
    if (!fw || ![[NSFileManager defaultManager] fileExistsAtPath:fw]) {
        return [self failWithMessage:[NSString stringWithFormat:@"未找到 NodeMobile.framework（找过：%@）",
                                      cfg.frameworkSearchPaths ? [cfg.frameworkSearchPaths componentsJoinedByString:@" / "] : @"-"]
                               error:error];
    }

    _state = SpCnFrameworkStateStarting;
    _lastError = nil;
    [SpCnLog line:@"[FW] 进程内后端：framework=%@ 运行时=%@", fw, cfg.runtimeDir];

    // 环境与工作目录：与进程后端完全一致（同一份 environment）。
    [cfg applyEnvironmentToProcess];
    if (chdir(cfg.runtimeDir.UTF8String) != 0) {
        [SpCnLog line:@"[FW] chdir 失败：%s（继续，服务端用的是绝对路径）", strerror(errno)];
    }

    // node 的 stdout/stderr 进同一份服务端日志（面板里能看到 console.log）
    NSString *logPath = cfg.logPath;
    if (logPath.length) {
        freopen(logPath.UTF8String, "a", stdout);
        freopen(logPath.UTF8String, "a", stderr);
        setvbuf(stdout, NULL, _IOLBF, 0);
    }

    NSString *entry = [cfg.runtimeDir stringByAppendingPathComponent:@"ios-entry.js"];
    if (![[NSFileManager defaultManager] fileExistsAtPath:entry]) entry = cfg.serverEntry;
    if (![[NSFileManager defaultManager] fileExistsAtPath:entry]) {
        return [self failWithMessage:[NSString stringWithFormat:@"入口脚本不存在：%@", entry] error:error];
    }

    void *h = dlopen(fw.UTF8String, RTLD_NOW | RTLD_GLOBAL);
    if (!h) {
        const char *de = dlerror();
        return [self failWithMessage:[NSString stringWithFormat:@"dlopen 失败：%s", de ? de : "?"] error:error];
    }
    _handle = h;

    SpCnNodeStartFn start = (SpCnNodeStartFn)dlsym(h, "node_start");
    if (!start) {
        return [self failWithMessage:@"framework 里没有 node_start 符号" error:error];
    }

    SpCnNodeBoot *boot = (SpCnNodeBoot *)calloc(1, sizeof(SpCnNodeBoot));
    boot->start = start;
    boot->argc = 0;
    boot->argv[boot->argc++] = strdup("node");
    // ★ V8 旗标必须由调用方给：nodejs-mobile 的 NodeMobile.cpp 里只有 int node_start(int, char**)，
    //   从来不调 SetFlagsFromString；framework 里那行 "node_v8_options": "--jitless" 只是 process.config
    //   的构建信息字符串，不是运行时旗标。不给旗标时 V8 会去装 JIT trap handler
    //   （栈：v8::internal::trap_handler::EnableTrapHandler ← node::InitializeOncePerProcess ← node::Start），
    //   在无 JIT 权限的 iOS 上直接 SIGTRAP 带走整个游戏进程 —— .work/crash 里 190022/190118/192814
    //   三份 .ips 就是这个。旗标组合抄 imcynic/nodejs-ios 的 iOS 配方（runtime/node-ios-arm64/node-wrapper.sh 同款）。
    static const char *kV8Flags[] = {
        "--jitless",           // 不生成机器码（iOS 无 JIT 权限，装了 trap handler 就是崩）
        "--no-opt",            // 关 TurboFan/Maglev 优化管线
        "--no-sparkplug",      // 关 baseline 编译器
        "--no-wasm-tier-up",   // wasm 不升级到优化层
        "--no-wasm-code-gc",   // 不做 wasm 代码 GC
    };
    for (size_t i = 0; i < sizeof(kV8Flags) / sizeof(kV8Flags[0]); i++) boot->argv[boot->argc++] = strdup(kV8Flags[i]);
    boot->argv[boot->argc++] = strdup(entry.UTF8String);
    boot->argv[boot->argc] = NULL;

    pthread_attr_t attr;
    pthread_attr_init(&attr);
    pthread_attr_setstacksize(&attr, 8 * 1024 * 1024);   // V8 启动递归很深，512 KB 默认栈不够
    int rc = pthread_create(&_thread, &attr, spcn_node_thread_main, boot);
    pthread_attr_destroy(&attr);
    if (rc != 0) {
        return [self failWithMessage:[NSString stringWithFormat:@"pthread_create 失败：%s (%d)", strerror(rc), rc] error:error];
    }

    _loadedPath = fw;
    _state = SpCnFrameworkStateRunning;
    [SpCnLog line:@"[FW] node_start 已在线程里跑起来（argc=%d，入口=%@）", boot->argc, entry];
    return YES;
}

@end
