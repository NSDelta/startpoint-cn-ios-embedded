// SpCnSupervisor —— 进程托管：起 node 服务端、探活、崩溃重启、SIGTERM 收尾
//
// 为什么用 posix_spawn 而不是 NSTask：
//   NSTask 在 iOS 上属于未公开可用面（且它对 launch path / 沙箱有额外要求）；
//   posix_spawn 是 libsystem 的稳定接口，重定向 stdout/stderr 用 file_actions 一步到位。
//
// 关键行为：
//   · 启动前先探 /healthz：若上一次 App 生命期留下的 node 还活着，直接**收编**（不重复起）。
//   · 子进程 stdout/stderr 全量重定向到 DATA_DIR/spcn-server.log（脱离父进程也不丢日志）。
//   · 监视线程 waitpid 收尸 → 非主动停止则退避重启（最多 5 次，间隔 2/4/8/16/30 s）。
#import <Foundation/Foundation.h>

typedef NS_ENUM(NSInteger, SpCnServerState) {
    SpCnServerStateIdle = 0,
    SpCnServerStateStarting,
    SpCnServerStateRunning,
    SpCnServerStateAdopted,      // 复用了上一次生命期留下的进程
    SpCnServerStateStopped,
    SpCnServerStateFailed,
};

@interface SpCnSupervisor : NSObject

@property (nonatomic, readonly) SpCnServerState state;
@property (nonatomic, readonly) NSString *stateText;
@property (nonatomic, readonly) pid_t pid;
@property (nonatomic, readonly) NSInteger startAttempts;
@property (nonatomic, readonly) NSString *lastError;
@property (nonatomic, readonly) NSDictionary *lastHealth;      // /healthz 的 JSON
@property (nonatomic, readonly) NSString *healthText;          // 人读摘要
@property (nonatomic, copy) void (^onStateChange)(void);

+ (instancetype)shared;

- (void)startWithReason:(NSString *)reason;
- (void)stopWithReason:(NSString *)reason;
- (void)restart;
- (void)refreshHealthWithCompletion:(void (^)(BOOL ok, NSDictionary *json))completion;
- (NSString *)tailOfServerLog:(NSUInteger)maxBytes;

@end
