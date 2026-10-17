#import "SpCnSupervisor.h"
#import "SpCnConfig.h"
#import "SpCnLog.h"
#import "SpCnNodeFramework.h"
#import <spawn.h>
#import <signal.h>
#import <sys/wait.h>
#import <fcntl.h>
#import <errno.h>

extern char **environ;

@implementation SpCnSupervisor {
    pid_t _pid;
    BOOL _stopping;                 // 主动停止中 ⇒ 不重启
    NSInteger _attempts;
    NSString *_lastError;
    NSDictionary *_lastHealth;
    NSDate *_startedAt;
}

+ (instancetype)shared {
    static SpCnSupervisor *s = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [SpCnSupervisor new]; });
    return s;
}

- (instancetype)init {
    if ((self = [super init])) { _state = SpCnServerStateIdle; }
    return self;
}

#pragma mark - 后端

- (BOOL)backendIsFramework {
    return [[[SpCnConfig shared] effectiveBackend] isEqualToString:@"framework"];
}

- (NSString *)backendText { return [[SpCnConfig shared] backendText]; }

- (BOOL)canStop { return ![[SpCnNodeFramework shared] isAlive]; }

#pragma mark - 状态

- (SpCnServerState)state {
    // 进程内后端：node 死在游戏进程里，宿主没有人给它收尸 ⇒ 状态要现问
    if (self.backendIsFramework && _state == SpCnServerStateRunning) {
        SpCnFrameworkState fs = [SpCnNodeFramework shared].state;
        if (fs == SpCnFrameworkStateExited || fs == SpCnFrameworkStateFailed) return SpCnServerStateFailed;
    }
    return _state;
}

- (NSString *)stateText {
    if (self.backendIsFramework) {
        switch (_state) {
            case SpCnServerStateIdle:     return @"未启动（内嵌后端）";
            case SpCnServerStateStarting: return @"启动中…（内嵌 node）";
            case SpCnServerStateRunning:  return [NSString stringWithFormat:@"运行中 · 内嵌 %@", [SpCnNodeFramework shared].stateText];
            case SpCnServerStateAdopted:  return @"已收编既有服务端（内嵌请求未重启）";
            case SpCnServerStateStopped:  return @"已停止";
            case SpCnServerStateFailed:   return @"内嵌 node 失败";
        }
        return @"?";
    }
    switch (_state) {
        case SpCnServerStateIdle:     return @"未启动";
        case SpCnServerStateStarting: return @"启动中…";
        case SpCnServerStateRunning:  return [NSString stringWithFormat:@"运行中 (pid %d)", _pid];
        case SpCnServerStateAdopted:  return [NSString stringWithFormat:@"已收编既有进程 (pid %d)", _pid];
        case SpCnServerStateStopped:  return @"已停止";
        case SpCnServerStateFailed:   return @"启动失败";
    }
    return @"?";
}

- (pid_t)pid { return _pid; }
- (NSInteger)startAttempts { return _attempts; }

- (NSString *)lastError {
    if (self.backendIsFramework) {
        NSString *e = [SpCnNodeFramework shared].lastError;
        if (e.length) return e;
    }
    return _lastError;
}

- (NSDictionary *)lastHealth { return _lastHealth; }

- (void)setState:(SpCnServerState)s {
    if (_state == s) return;
    _state = s;
    [SpCnLog line:@"[SUP] 状态 ⇒ %@", [self stateText]];
    dispatch_async(dispatch_get_main_queue(), ^{ if (self.onStateChange) self.onStateChange(); });
}

- (NSString *)healthText {
    if (!_lastHealth) return @"未探活";
    NSDictionary *svc = _lastHealth[@"services"] ?: @{};
    NSDictionary *db  = _lastHealth[@"database"] ?: @{};
    NSDictionary *as  = _lastHealth[@"assets"] ?: @{};
    NSDictionary *rt  = _lastHealth[@"runtime"] ?: @{};
    return [NSString stringWithFormat:@"status=%@ node=%@ schema=%@ http=%@ tcp=%@ assets=%@/%@",
            _lastHealth[@"status"] ?: @"?", rt[@"node"] ?: @"?",
            db[@"schema"] ?: @"?", svc[@"http"] ?: @"?", svc[@"tcp"] ?: @"?",
            as[@"mode"] ?: @"?", as[@"status"] ?: @"?"];
}

#pragma mark - 探活

- (void)refreshHealthWithCompletion:(void (^)(BOOL, NSDictionary *))completion {
    SpCnConfig *cfg = [SpCnConfig shared];
    NSURL *url = [NSURL URLWithString:[cfg.httpBase stringByAppendingString:@"/healthz"]];
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
    req.timeoutInterval = 1.5;
    req.cachePolicy = NSURLRequestReloadIgnoringLocalCacheData;
    [[[NSURLSession sharedSession] dataTaskWithRequest:req
        completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
            BOOL ok = NO; NSDictionary *json = nil;
            NSInteger code = [(NSHTTPURLResponse *)resp statusCode];
            if (data.length) {
                id obj = [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];
                if ([obj isKindOfClass:[NSDictionary class]]) json = obj;
            }
            ok = (code == 200 && json != nil);
            dispatch_async(dispatch_get_main_queue(), ^{
                self->_lastHealth = json;
                if (completion) completion(ok, json);
            });
        }] resume];
}

#pragma mark - 启动

- (void)startWithReason:(NSString *)reason {
    SpCnConfig *cfg = [SpCnConfig shared];
    NSError *err = nil;
    [SpCnLog line:@"[SUP] start(%@) 后端=%@ 运行时=%@", reason, cfg.effectiveBackend, cfg.runtimeDir];

    if (_pid > 0) { [SpCnLog line:@"[SUP] 已有进程 %d，跳过启动", _pid]; [self refreshHealthWithCompletion:nil]; return; }
    if ([[SpCnNodeFramework shared] isAlive]) {
        [SpCnLog line:@"[SUP] 内嵌 node 已在运行，跳过启动"];
        [self refreshHealthWithCompletion:nil];
        return;
    }
    if (![cfg validateWithError:&err]) {
        _lastError = err.localizedDescription;
        [SpCnLog line:@"[SUP] 运行时校验失败：%@", _lastError];
        [self setState:SpCnServerStateFailed];
        return;
    }
    _lastError = nil;
    [self setState:SpCnServerStateStarting];

    // 先看有没有上一次生命期留下的、还活着的服务端（App 被系统回收但 node 还活着的情形）
    __weak typeof(self) weakSelf = self;
    [self refreshHealthWithCompletion:^(BOOL ok, NSDictionary *json) {
        typeof(self) self_ = weakSelf; if (!self_) return;
        if (ok) {
            [SpCnLog line:@"[SUP] /healthz 已就绪 ⇒ 收编既有服务端（不重复起）"];
            self_->_pid = -1;                     // 非本进程持有：不 waitpid，也不在 stop 时杀（见 stop 的分支）
            self_->_startedAt = [NSDate date];
            [self_ setState:SpCnServerStateAdopted];
            return;
        }
        if ([self_ backendIsFramework]) [self_ startFrameworkBackend];
        else                            [self_ spawnNode];
    }];
}

/// 进程内后端：dlopen NodeMobile.framework + node_start（node 与游戏同进程）
- (void)startFrameworkBackend {
    SpCnConfig *cfg = [SpCnConfig shared];
    [SpCnLog setLogFile:[cfg.dataDir stringByAppendingPathComponent:@"SpCnEmbedded.log"]];
    [SpCnLog line:@"[SUP] 内嵌启动：framework=%@ entry=%@", cfg.frameworkBinary ?: @"?", cfg.serverEntry];

    NSError *err = nil;
    if (![[SpCnNodeFramework shared] startWithConfig:cfg error:&err]) {
        _lastError = err.localizedDescription ?: @"内嵌 node 启动失败";
        [SpCnLog line:@"[SUP] %@", _lastError];
        [self setState:SpCnServerStateFailed];
        return;
    }
    _lastError = nil;
    _startedAt = [NSDate date];
    _attempts++;
    [SpCnLog line:@"[SUP] 内嵌 node 已在后台线程起（第 %ld 次），等事件循环接手", (long)_attempts];
    [self setState:SpCnServerStateRunning];
    [self pollUntilReady];
}

- (void)spawnNode {
    SpCnConfig *cfg = [SpCnConfig shared];
    NSString *node = cfg.nodePath, *entry = cfg.serverEntry, *logPath = cfg.logPath;
    [SpCnLog setLogFile:[cfg.dataDir stringByAppendingPathComponent:@"SpCnEmbedded.log"]];
    [SpCnLog line:@"[SUP] spawn：%@ %@", node, entry];

    NSDictionary<NSString *, NSString *> *env = [cfg environment];
    NSMutableArray<NSString *> *envArr = [NSMutableArray array];
    for (NSString *k in env) [envArr addObject:[NSString stringWithFormat:@"%@=%@", k, env[k]]];

    NSMutableArray<NSString *> *argArr = [NSMutableArray arrayWithObjects:node, entry, nil];
    const char *argv[argArr.count + 1];
    for (NSUInteger i = 0; i < argArr.count; i++) argv[i] = argArr[i].UTF8String;
    argv[argArr.count] = NULL;
    const char *envp[envArr.count + 1];
    for (NSUInteger i = 0; i < envArr.count; i++) envp[i] = envArr[i].UTF8String;
    envp[envArr.count] = NULL;

    posix_spawn_file_actions_t fa;
    posix_spawn_file_actions_init(&fa);
    // stdout/stderr 一并进服务端日志（App 被杀也不丢）
    posix_spawn_file_actions_addopen(&fa, STDOUT_FILENO, logPath.UTF8String, O_WRONLY | O_CREAT | O_APPEND, 0644);
    posix_spawn_file_actions_addopen(&fa, STDERR_FILENO, logPath.UTF8String, O_WRONLY | O_CREAT | O_APPEND, 0644);
    posix_spawn_file_actions_addopen(&fa, STDIN_FILENO, "/dev/null", O_RDONLY, 0);

    pid_t pid = 0;
    int rc = posix_spawn(&pid, node.UTF8String, &fa, NULL, (char *const *)argv, (char *const *)envp);
    posix_spawn_file_actions_destroy(&fa);

    if (rc != 0 || pid <= 0) {
        _lastError = [NSString stringWithFormat:@"posix_spawn 失败：%s (rc=%d)", strerror(rc), rc];
        [SpCnLog line:@"[SUP] %@", _lastError];
        [self setState:SpCnServerStateFailed];
        return;
    }

    _pid = pid;
    _stopping = NO;
    _attempts++;
    _startedAt = [NSDate date];
    [SpCnLog line:@"[SUP] node 已起 pid=%d（第 %ld 次）", pid, (long)_attempts];
    [self setState:SpCnServerStateRunning];
    [self startMonitorForPid:pid];
    [self pollUntilReady];
}

/// 收尸线程：退出即回调（退避重启）
- (void)startMonitorForPid:(pid_t)pid {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        int status = 0;
        pid_t r = waitpid(pid, &status, 0);
        int code = WIFEXITED(status) ? WEXITSTATUS(status) : -1;
        dispatch_async(dispatch_get_main_queue(), ^{
            [SpCnLog line:@"[SUP] node 退出：waitpid=%d status=0x%x code=%d（stopping=%d）", r, status, code, self->_stopping];
            if (self->_pid == pid) self->_pid = 0;
            if (self->_stopping) { [self setState:SpCnServerStateStopped]; return; }
            self->_lastError = [NSString stringWithFormat:@"node 退出（code=%d）", code];
            [self setState:SpCnServerStateFailed];
            if (self->_attempts < 5) {
                NSTimeInterval backoff = MIN(30.0, pow(2.0, (double)self->_attempts));
                [SpCnLog line:@"[SUP] %.0fs 后重启（第 %ld 次）", backoff, (long)(self->_attempts + 1)];
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(backoff * NSEC_PER_SEC)),
                               dispatch_get_main_queue(), ^{ if (!self->_stopping) [self spawnNode]; });
            }
        });
    });
}

/// 启动后轮询 /healthz：一轮
- (void)pollReadyAttempt:(NSInteger)attempt {
    __weak typeof(self) weakSelf = self;
    [self refreshHealthWithCompletion:^(BOOL ok, NSDictionary *json) {
        typeof(self) self_ = weakSelf; if (!self_) return;
        if (ok) { [SpCnLog line:@"[SUP] /healthz 就绪：%@", [self_ healthText]]; return; }
        if (attempt >= 20) { [SpCnLog line:@"[SUP] /healthz 20 次未就绪（继续后台等）"]; return; }
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ [self_ pollReadyAttempt:attempt + 1]; });
    }];
}

/// 启动后轮询 /healthz（最多 ~20 s），就绪即刷新面板
- (void)pollUntilReady {
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        typeof(self) self_ = weakSelf; if (self_) [self_ pollReadyAttempt:1];
    });
}

#pragma mark - 停止

- (void)stopWithReason:(NSString *)reason {
    SpCnConfig *cfg = [SpCnConfig shared];
    if ([[SpCnNodeFramework shared] isAlive]) {
        _lastError = @"内嵌后端与游戏同进程：node 无法单独停止，退出游戏即随之结束";
        [SpCnLog line:@"[SUP] stop(%@)：%@", reason, _lastError];
        return;
    }
    _stopping = YES;
    if (_state == SpCnServerStateAdopted || _pid <= 0) {
        [SpCnLog line:@"[SUP] stop(%@)：当前是收编态/无进程，不做处理（既有进程不归本进程管）", reason];
        _pid = 0;
        [self setState:SpCnServerStateStopped];
        return;
    }
    pid_t pid = _pid;
    [SpCnLog line:@"[SUP] stop(%@)：SIGTERM → %d", reason, pid];
    kill(pid, SIGTERM);
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        for (int i = 0; i < 50; i++) {                     // 最多等 5 s 优雅退出（SQLite WAL checkpoint）
            if (kill(pid, 0) != 0) return;
            usleep(100 * 1000);
        }
        [SpCnLog line:@"[SUP] 5s 未退出 ⇒ SIGKILL %d", pid];
        kill(pid, SIGKILL);
    });
    (void)cfg;
}

- (void)restart {
    if ([[SpCnNodeFramework shared] isAlive]) {
        _lastError = @"内嵌后端不能单独重启：请退出游戏后重开";
        [SpCnLog line:@"[SUP] restart：%@", _lastError];
        dispatch_async(dispatch_get_main_queue(), ^{ if (self.onStateChange) self.onStateChange(); });
        return;
    }
    [self stopWithReason:@"restart"];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        self->_attempts = 0;
        self->_stopping = NO;
        [self startWithReason:@"restart"];
    });
}

#pragma mark - 日志尾巴

- (NSString *)tailOfServerLog:(NSUInteger)maxBytes {
    NSString *p = [SpCnConfig shared].logPath;
    NSData *d = [NSData dataWithContentsOfFile:p];
    if (!d.length) return @"（暂无服务端日志）";
    if (d.length > maxBytes) d = [d subdataWithRange:NSMakeRange(d.length - maxBytes, maxBytes)];
    NSString *s = [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding];
    return s ?: @"（日志非 UTF-8，无法显示）";
}

@end
