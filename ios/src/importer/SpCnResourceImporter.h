//  SpCnResourceImporter.h
//  SpCnEmbedded —— 资源导入门面（面板只跟它打交道）
//
//  它把移植过来的 Cdn* 引擎（ZIP/TAR 解析 + 634 条导入计划 + 四阶段导入引擎）收成一个
//  「扫描 → Ready → 导入 → Done/Failed/Cancelled」的小状态机：
//    · 扫描：把一个目录（散装 zip / tar 分卷 / 整包 zip 都可以）索引成「计划基名 → 归档句柄」，
//      报出「归档齐不齐、缺失清单、压缩态总大小、目标目录、可用空间」；
//    · 导入：按计划顺序（后覆盖先）解压进
//      `<Local Store>/asset/asset_download/<子目录>/download/`，写 `info.json`，删 4 个 partial 标记；
//    · 全程后台串行队列；状态/进度/日志都在锁保护下读写，`onChange` 一律回主线程。
//
//  线程约定（面板照这个用就行）：
//    · 所有方法都可以从主线程调；`scanSourceDir:` / `startImport` 立刻返回，真正的活在后台队列；
//    · 扫描中/导入中重复调用会被忽略（返回 / 返回 NO），不会起第二份工作；
//    · `cancel` 只置取消标志（引擎每个条目检查一次），所以真正停下可能还差一个条目的时间。
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, SpCnImportState) {
    SpCnImportStateIdle = 0,      ///< 未开始（初始态 / reset 之后）
    SpCnImportStateScanning,      ///< 后台扫描中
    SpCnImportStateReady,         ///< 扫描完成、归档齐备，可以 startImport
    SpCnImportStateImporting,     ///< 后台导入中
    SpCnImportStateDone,          ///< 导入完成（info.json 已写、partial 已清）
    SpCnImportStateFailed,        ///< 失败（扫描缺包 / 导入出错，看 statusText 与 logLines）
    SpCnImportStateCancelled,     ///< 被 cancel 打断
};

/// 状态的中文名（面板直接用，免得自己再写一遍 switch）。
FOUNDATION_EXPORT NSString *SpCnImportStateName(SpCnImportState state);

@interface SpCnResourceImporter : NSObject

+ (instancetype)shared;

/// 后台扫描一个源目录（目录 / 单个 zip / tar 分卷都可以）：归档齐不齐、总大小；
/// 结束进 Ready 或 Failed。正在扫描/导入时调用会被忽略。
- (void)scanSourceDir:(NSString *)dir;

/// Ready 才允许；后台串行队列跑 CdnImportEngine；可被 -cancel 打断。返回 NO = 这次没起（看 logLines）。
- (BOOL)startImport;

/// 置取消标志（引擎每个条目检查一次）；扫描阶段取消则在扫描收尾时进 Cancelled。
- (void)cancel;

/// 回到 Idle 并清空日志/进度/源目录（扫描/导入中调用会被忽略，先 -cancel）。
- (void)reset;

@property (nonatomic, readonly) SpCnImportState state;
@property (nonatomic, readonly) NSString *statusText;            ///< 一行中文摘要（面板直接显示）
@property (nonatomic, readonly) double progress;                 ///< 0..1（按压缩态字节）
@property (nonatomic, readonly) NSArray<NSString *> *logLines;   ///< 最近 N 条（上限 200，先进先出）
@property (nonatomic, readonly) NSString *targetDir;             ///< 解析到的 download 目标目录（给人看）
@property (nonatomic, copy, nullable) void (^onChange)(void);    ///< 状态/进度/日志变化时回调（**一定在主线程**）

/// 解压之前是否先逐包比一遍 sha256（默认取 CdnImporterVerifyContentEnabled()，即 YES）。
/// 开：多读一遍 10.7 GB（约一半时间），但「名字对、字节数对、内容不对」在动目标目录之前就能拦住；
/// 关：快一倍，代价是内容不对要等解压完才发现（解压阶段仍有整包字节数与逐条目 CRC32 校验）。
@property (nonatomic, assign) BOOL verifyContent;

@end

NS_ASSUME_NONNULL_END
