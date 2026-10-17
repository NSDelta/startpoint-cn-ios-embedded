//  SpCnResourceImporter.m
//  SpCnEmbedded —— 资源导入门面（面板只跟它打交道）
//
//  线程模型：
//    · 一份串行队列 `_work` 跑扫描与导入（10 GB 级的长活）；
//    · 状态/进度/日志/当前引擎都在 `_lock`（NSLock）保护下读写，任何线程读都安全；
//    · `onChange` 一定经 dispatch_async 回主线程；进度类回调做 4 次/秒的节流（状态变化不节流）；
//    · 所有对外方法都套 @try/@catch —— 引擎里再怎么样也不该把游戏进程带崩。
//

#import "SpCnResourceImporter.h"

#import "CdnArchiveIndex.h"
#import "CdnImportEngine.h"
#import "CdnImportPlan.h"
#import "CdnImporterConfig.h"
#import "SpCnLog.h"

/// 面板日志环形缓冲的上限（先进先出）。
static NSUInteger const kSpCnImporterLogLimit = 200;
/// 进度类回调的最小间隔（秒）：引擎解压时每个条目都会回调，不节流会把主线程刷爆。
static NSTimeInterval const kSpCnImporterNotifyInterval = 0.25;
/// 报错明细（缺归档清单等）最多往面板日志里抄多少条。
static NSUInteger const kSpCnImporterDetailLimit = 50;

NSString *SpCnImportStateName(SpCnImportState state) {
    switch (state) {
        case SpCnImportStateIdle:      return @"未开始";
        case SpCnImportStateScanning:  return @"扫描中";
        case SpCnImportStateReady:     return @"待导入";
        case SpCnImportStateImporting: return @"导入中";
        case SpCnImportStateDone:      return @"已完成";
        case SpCnImportStateFailed:    return @"失败";
        case SpCnImportStateCancelled: return @"已取消";
    }
    return @"未知";
}

@interface SpCnResourceImporter ()
- (void)performScanWithSource:(NSString *)dir;
- (void)performImportWithInputURLs:(NSArray<NSURL *> *)urls verifyContent:(BOOL)verifyContent;
- (void)handleProgress:(CdnImportProgress *)progress;
- (void)appendLog:(NSString *)line;
- (void)appendDetails:(NSArray *)details;
- (void)applyState:(SpCnImportState)state status:(NSString *)status progress:(double)progress;
- (NSString *)availableSpaceText;
- (BOOL)isCancelRequested;
- (void)notifyChange;
- (void)notifyThrottled;
- (void)notifyNow;
@end

@implementation SpCnResourceImporter {
    NSLock *_lock;
    dispatch_queue_t _work;
    NSMutableArray<NSString *> *_logs;

    SpCnImportState _state;
    NSString *_statusText;
    double _progress;
    NSString *_targetDir;
    NSString *_sourceDir;          ///< 最近一次 scanSourceDir: 的源目录（startImport 用它）
    CdnImportEngine *_engine;      ///< 正在跑的那一个（cancel 要够得着它）
    BOOL _cancelRequested;
    BOOL _verifyContent;

    NSTimeInterval _lastNotify;
    void (^_onChange)(void);
}

@synthesize onChange = _onChange;

+ (instancetype)shared {
    static SpCnResourceImporter *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[SpCnResourceImporter alloc] init];
    });
    return instance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _lock = [[NSLock alloc] init];
        _work = dispatch_queue_create("com.spcn.resource-importer", DISPATCH_QUEUE_SERIAL);
        _logs = [NSMutableArray arrayWithCapacity:kSpCnImporterLogLimit];
        _state = SpCnImportStateIdle;
        _statusText = @"未开始";
        _progress = 0.0;
        _targetDir = [CdnImporterAssetDownloadDir() copy];
        _verifyContent = CdnImporterVerifyContentEnabled();
    }
    return self;
}

#pragma mark - 只读属性（都过锁）

- (SpCnImportState)state {
    [_lock lock];
    SpCnImportState value = _state;
    [_lock unlock];
    return value;
}

- (NSString *)statusText {
    [_lock lock];
    NSString *value = [_statusText copy];
    [_lock unlock];
    return value ?: @"";
}

- (double)progress {
    [_lock lock];
    double value = _progress;
    [_lock unlock];
    return value;
}

- (NSArray<NSString *> *)logLines {
    [_lock lock];
    NSArray<NSString *> *value = [_logs copy];
    [_lock unlock];
    return value;
}

- (NSString *)targetDir {
    [_lock lock];
    NSString *value = [_targetDir copy];
    [_lock unlock];
    return value ?: @"";
}

- (BOOL)verifyContent {
    [_lock lock];
    BOOL value = _verifyContent;
    [_lock unlock];
    return value;
}

- (void)setVerifyContent:(BOOL)verifyContent {
    [_lock lock];
    _verifyContent = verifyContent;
    [_lock unlock];
}

- (void)setOnChange:(void (^)(void))onChange {
    [_lock lock];
    _onChange = [onChange copy];
    [_lock unlock];
}

- (void (^)(void))onChange {
    [_lock lock];
    void (^handler)(void) = _onChange;
    [_lock unlock];
    return handler;
}

#pragma mark - 对外：扫描 / 导入 / 取消 / 重置

- (void)scanSourceDir:(NSString *)dir {
    if (dir.length == 0) return;
    @try {
        NSString *target = [CdnImporterAssetDownloadDir() copy];
        BOOL busy = NO;
        [_lock lock];
        busy = (_state == SpCnImportStateScanning || _state == SpCnImportStateImporting);
        if (!busy) {
            _state = SpCnImportStateScanning;
            _statusText = [NSString stringWithFormat:@"扫描中：%@", dir];
            _progress = 0.0;
            _sourceDir = [dir copy];
            _targetDir = target;
            _cancelRequested = NO;
        }
        [_lock unlock];

        if (busy) {
            [self appendLog:[NSString stringWithFormat:@"正在%@，忽略这次扫描请求（先 -cancel 或等它跑完）",
                             SpCnImportStateName(self.state)]];
            return;
        }

        CdnImporterLog(@"[导入器] 开始扫描源目录：%@", dir);
        [self notifyNow];
        NSString *source = [dir copy];
        dispatch_async(_work, ^{
            [self performScanWithSource:source];
        });
    } @catch (NSException *exception) {
        [self applyState:SpCnImportStateFailed
                  status:[NSString stringWithFormat:@"扫描启动异常：%@", exception.reason ?: @"未知"]
                progress:-1.0];
    }
}

- (BOOL)startImport {
    @try {
        NSArray<NSURL *> *urls = nil;
        BOOL verify = NO;
        BOOL allowed = NO;
        [_lock lock];
        if (_state == SpCnImportStateReady && _sourceDir.length > 0) {
            allowed = YES;
            _state = SpCnImportStateImporting;
            _statusText = @"导入中：准备…";
            _progress = 0.0;
            _cancelRequested = NO;
            verify = _verifyContent;
            urls = @[[NSURL fileURLWithPath:_sourceDir isDirectory:YES]];
        }
        [_lock unlock];

        if (!allowed) {
            [self appendLog:[NSString stringWithFormat:@"现在不能开始导入（状态=%@）：先 -scanSourceDir: 等它进「待导入」",
                             SpCnImportStateName(self.state)]];
            return NO;
        }

        CdnImporterLog(@"[导入器] 开始导入：目标 %@（内容校验=%@）", self.targetDir, verify ? @"开" : @"关");
        [self notifyNow];
        dispatch_async(_work, ^{
            [self performImportWithInputURLs:urls verifyContent:verify];
        });
        return YES;
    } @catch (NSException *exception) {
        [self applyState:SpCnImportStateFailed
                  status:[NSString stringWithFormat:@"导入启动异常：%@", exception.reason ?: @"未知"]
                progress:-1.0];
        return NO;
    }
}

- (void)cancel {
    @try {
        [_lock lock];
        _cancelRequested = YES;
        CdnImportEngine *engine = _engine;
        [_lock unlock];

        // 引擎每个条目检查一次取消标志；扫描阶段没有取消点，靠扫描收尾时看标志。
        if (engine != nil) [engine cancel];

        CdnImporterLog(@"[导入器] 收到取消请求（当前条目跑完就停）");
        [self appendLog:@"收到取消请求：当前条目跑完就停（已解开的文件留在原地，partial 标记保留）"];
        [self notifyNow];
    } @catch (NSException *exception) {
        CdnImporterLog(@"[导入器] 取消时异常：%@", exception.reason);
    }
}

- (void)reset {
    @try {
        BOOL busy = NO;
        [_lock lock];
        busy = (_state == SpCnImportStateScanning || _state == SpCnImportStateImporting);
        if (!busy) {
            _state = SpCnImportStateIdle;
            _statusText = @"未开始";
            _progress = 0.0;
            _sourceDir = nil;
            _cancelRequested = NO;
            [_logs removeAllObjects];
        }
        [_lock unlock];

        if (busy) {
            [self appendLog:@"正在扫描/导入中，reset 被忽略（先 -cancel）"];
            return;
        }
        CdnImporterLog(@"[导入器] 已重置");
        [self notifyNow];
    } @catch (NSException *exception) {
        CdnImporterLog(@"[导入器] 重置时异常：%@", exception.reason);
    }
}

#pragma mark - 扫描（后台队列）

- (void)performScanWithSource:(NSString *)dir {
    @try {
        CdnImportPlan *plan = [CdnImportPlan sharedPlan];
        CdnImporterLog(@"[导入器] Local Store %@（%@）", CdnImporterStorageRoot(), CdnImporterStorageRootNote());
        CdnImporterLog(@"[导入器] 目标目录 %@（%@）", CdnImporterAssetDownloadDir(), CdnImporterTargetDirectoryNote());

        NSURL *url = [NSURL fileURLWithPath:dir isDirectory:YES];
        CdnArchiveIndex *index = [CdnArchiveIndex indexWithInputURLs:@[url]
                                                                plan:plan
                                                          logHandler:^(NSString *line) {
            [self appendLog:line];
        }];

        NSMutableArray<NSString *> *missing = [NSMutableArray array];
        for (CdnImportPlanItem *item in plan.items) {
            if ([index handleForBasename:item.basename] == nil) [missing addObject:item.basename];
        }
        for (NSString *problem in index.problems) [self appendLog:[NSString stringWithFormat:@"问题：%@", problem]];
        for (NSString *warning in index.warnings) [self appendLog:[NSString stringWithFormat:@"注意：%@", warning]];
        for (NSString *unrecognized in index.unrecognizedInputs) {
            [self appendLog:[NSString stringWithFormat:@"未参与：%@", unrecognized]];
        }

        [self appendLog:[NSString stringWithFormat:@"识别到 %lu/%lu 个归档，压缩态 %@；可用空间 %@",
                         (unsigned long)index.handles.count,
                         (unsigned long)plan.items.count,
                         CdnImporterHumanBytes(index.recognizedBytes),
                         [self availableSpaceText]]];

        if ([self isCancelRequested]) {
            [self applyState:SpCnImportStateCancelled status:@"已取消（扫描阶段）" progress:0.0];
            return;
        }

        if (missing.count == 0) {
            NSString *status = [NSString stringWithFormat:@"归档齐备：%lu/%lu，压缩态 %@，可用 %@",
                                (unsigned long)index.handles.count,
                                (unsigned long)plan.items.count,
                                CdnImporterHumanBytes(index.recognizedBytes),
                                [self availableSpaceText]];
            CdnImporterLog(@"[导入器] %@", status);
            [self applyState:SpCnImportStateReady status:status progress:0.0];
            return;
        }

        // 严格模式（与引擎一致）：缺一个都不动目标目录。
        [self appendDetails:missing];
        NSString *status = [NSString stringWithFormat:@"缺少 %lu/%lu 个归档（例：%@）；补齐后再扫描",
                            (unsigned long)missing.count,
                            (unsigned long)plan.items.count,
                            [[missing subarrayWithRange:NSMakeRange(0, MIN(missing.count, (NSUInteger)3))]
                             componentsJoinedByString:@"、"]];
        CdnImporterLog(@"[导入器] %@", status);
        [self applyState:SpCnImportStateFailed status:status progress:0.0];
    } @catch (NSException *exception) {
        CdnImporterLog(@"[导入器] 扫描异常：%@", exception.reason);
        [self applyState:SpCnImportStateFailed
                  status:[NSString stringWithFormat:@"扫描异常：%@", exception.reason ?: @"未知"]
                progress:0.0];
    }
}

#pragma mark - 导入（后台队列）

- (void)performImportWithInputURLs:(NSArray<NSURL *> *)urls verifyContent:(BOOL)verifyContent {
    @try {
        CdnImportEngine *engine = [[CdnImportEngine alloc] init];
        engine.verifyContent = verifyContent;
        engine.clearDownloadDirectoryFirst = YES;   // 清空才能保证终态统计与覆盖语义正确
        engine.allowMissingArchives = NO;           // 严格模式：缺包报 MissingArchives，不动目标目录

        __weak typeof(self) weakSelf = self;
        engine.logHandler = ^(NSString *line) {
            [weakSelf appendLog:line];
        };
        engine.progressHandler = ^(CdnImportProgress *progress) {
            [weakSelf handleProgress:progress];
        };

        BOOL cancelled = NO;
        [_lock lock];
        _engine = engine;
        cancelled = _cancelRequested;
        [_lock unlock];

        if (cancelled) {
            [_lock lock];
            _engine = nil;
            [_lock unlock];
            [self applyState:SpCnImportStateCancelled status:@"已取消（还没有开始写盘）" progress:0.0];
            return;
        }

        NSError *error = nil;
        CdnImportResult *result = [engine runWithInputURLs:urls error:&error];

        [_lock lock];
        _engine = nil;
        [_lock unlock];

        if (result != nil) {
            CdnImporterLog(@"[导入器] 导入完成：%@", result.summaryText);
            [self appendLog:result.summaryText];
            [self applyState:SpCnImportStateDone status:result.summaryText progress:1.0];
            return;
        }

        [self appendDetails:error.userInfo[CdnImporterDetailsKey]];
        NSString *reason = error.localizedDescription ?: @"未知错误";
        if ([error.domain isEqualToString:CdnImporterErrorDomain] && error.code == CdnImporterErrorCancelled) {
            CdnImporterLog(@"[导入器] 导入被取消：%@", reason);
            [self applyState:SpCnImportStateCancelled
                      status:[NSString stringWithFormat:@"已取消：%@", reason]
                    progress:-1.0];
            return;
        }
        CdnImporterLog(@"[导入器] 导入失败：%@", reason);
        [self applyState:SpCnImportStateFailed
                  status:[NSString stringWithFormat:@"失败：%@", reason]
                progress:-1.0];
    } @catch (NSException *exception) {
        [_lock lock];
        _engine = nil;
        [_lock unlock];
        CdnImporterLog(@"[导入器] 导入异常：%@", exception.reason);
        [self applyState:SpCnImportStateFailed
                  status:[NSString stringWithFormat:@"失败（异常）：%@", exception.reason ?: @"未知"]
                progress:-1.0];
    }
}

- (void)handleProgress:(CdnImportProgress *)progress {
    if (progress == nil) return;
    [_lock lock];
    double fraction = progress.fraction;
    if (fraction < 0.0) fraction = 0.0;
    if (fraction > 1.0) fraction = 1.0;
    _progress = fraction;
    NSString *text = progress.statusText;
    if (text.length > 0) _statusText = [text copy];
    [_lock unlock];
    [self notifyThrottled];
}

#pragma mark - 内部工具

- (BOOL)isCancelRequested {
    [_lock lock];
    BOOL value = _cancelRequested;
    [_lock unlock];
    return value;
}

/// 目标卷可用空间（人读）。download 目录可能还不存在 ⇒ 按最近的已存在目录统计
/// （`attributesOfFileSystemForPath:` 对不存在的路径会直接报错）。
- (NSString *)availableSpaceText {
    NSString *probe = CdnImporterNearestExistingPath([CdnImporterAssetDownloadDir() stringByDeletingLastPathComponent]);
    NSError *error = nil;
    NSDictionary<NSFileAttributeKey, id> *attributes =
        [[NSFileManager defaultManager] attributesOfFileSystemForPath:probe error:&error];
    NSNumber *freeBytes = attributes[NSFileSystemFreeSize];
    if (freeBytes == nil) return @"未知";
    return CdnImporterHumanBytes(freeBytes.unsignedLongLongValue);
}

- (void)appendDetails:(NSArray *)details {
    if (![details isKindOfClass:[NSArray class]] || details.count == 0) return;
    NSUInteger index = 0;
    for (id item in details) {
        if (index >= kSpCnImporterDetailLimit) {
            [self appendLog:[NSString stringWithFormat:@"……另有 %lu 条明细（完整内容见 SpCnLog）",
                             (unsigned long)(details.count - index)]];
            break;
        }
        [self appendLog:[NSString stringWithFormat:@"明细：%@", item]];
        index++;
    }
}

- (void)appendLog:(NSString *)line {
    if (line.length == 0) return;
    [_lock lock];
    [_logs addObject:line];
    if (_logs.count > kSpCnImporterLogLimit) {
        [_logs removeObjectsInRange:NSMakeRange(0, _logs.count - kSpCnImporterLogLimit)];
    }
    [_lock unlock];
    [self notifyThrottled];
}

/// 状态/阶段变化：写状态 + 落 SpCnLog + 立刻通知面板（不节流）。
- (void)applyState:(SpCnImportState)state status:(NSString *)status progress:(double)progress {
    [_lock lock];
    _state = state;
    if (status.length > 0) _statusText = [status copy];
    if (progress >= 0.0) _progress = progress;
    [_lock unlock];
    CdnImporterLog(@"[导入器] %@：%@", SpCnImportStateName(state), status ?: @"");
    [self notifyNow];
}

- (void)notifyChange {
    void (^handler)(void) = self.onChange;
    if (handler == nil) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        handler();
    });
}

- (void)notifyThrottled {
    NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
    BOOL fire = NO;
    [_lock lock];
    if (now - _lastNotify >= kSpCnImporterNotifyInterval) {
        _lastNotify = now;
        fire = YES;
    }
    [_lock unlock];
    if (fire) [self notifyChange];
}

- (void)notifyNow {
    [_lock lock];
    _lastNotify = [NSDate timeIntervalSinceReferenceDate];
    [_lock unlock];
    [self notifyChange];
}

@end
