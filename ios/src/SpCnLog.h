// SpCnLog —— 诊断日志：内存环形缓冲（给悬浮窗看）+ 落盘（给 scp/idevicesyslog 看）
//
// 纪律（来自 SpLogin 线的取证教训）：**先看设备上的取证标记，再谈别的** ——
// 没有日志就说明 dylib 根本没被加载，别浪费时间猜别的。
#import <Foundation/Foundation.h>

@interface SpCnLog : NSObject

/// constructor 里调用：先把日志落到 App 容器 tmp，保证"有没有被加载"这一条一定能落盘。
+ (void)bootstrap;
/// 切换日志文件到最终位置（DATA_DIR 确定后调用）。
+ (void)setLogFile:(NSString *)path;
+ (NSString *)logFilePath;

/// 追加一行（自动加时间戳；同时走 NSLog 便于 idevicesyslog 抓）。
+ (void)line:(NSString *)format, ... NS_FORMAT_FUNCTION(1, 2);
/// 最近 N 行（默认全部，最多 500 行），给悬浮窗的日志视图用。
+ (NSArray<NSString *> *)recentLines;

@end
