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
#import <Foundation/Foundation.h>

@class SpCnConfig;

typedef NS_ENUM(NSInteger, SpCnFrameworkState) {
    SpCnFrameworkStateIdle = 0,
    SpCnFrameworkStateStarting,
    SpCnFrameworkStateRunning,
    SpCnFrameworkStateExited,   // node 事件循环结束（不该发生；说明服务端自己退了）
    SpCnFrameworkStateFailed,
};

@interface SpCnNodeFramework : NSObject

@property (nonatomic, readonly) SpCnFrameworkState state;
@property (nonatomic, readonly, copy) NSString *stateText;
@property (nonatomic, readonly, copy) NSString *lastError;
@property (nonatomic, readonly) int exitCode;             // node_start 的返回码（仅在 Exited 时有意义）
@property (nonatomic, readonly, copy) NSString *loadedPath;  // 实际 dlopen 的 framework 路径

+ (instancetype)shared;

/// 起进程内 node（只能在框架未运行时调一次；重复调用直接返回 YES/NO 并记日志）
- (BOOL)startWithConfig:(SpCnConfig *)cfg error:(NSError **)error;
- (BOOL)isAlive;

@end
