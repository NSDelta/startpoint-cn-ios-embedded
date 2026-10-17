//
//  CdnImporterConfig.m
//  SpCnEmbedded —— CDN 归档导入引擎（移植自 wf-cdn-importer-iOS 的 ios/importer/）
//
//  只搬「Local Store 根解析 + asset_download 子目录探测 + 引擎用到的辅助函数」；
//  参考实现里属于 UI 层的部分（悬浮球位置/强制显示/资源完整度判断/导出日志）没有搬过来 ——
//  那些由本项目的 SpCnOverlay / SpCnPanelViewController / SpCnResourceImporter 承担。
//  日志不再落自己的文件：CdnImporterLog 宏在头文件里重定向到 SpCnLog。
//

#import "CdnImporterConfig.h"

#import <mach/mach.h>
#import <mach/task_info.h>

NSString *const CdnImporterPatchBaseKey = @"CdnImporterPatchBase";
NSString *const CdnImporterStorageRootKey = @"CdnImporterStorageRoot";
NSString *const CdnImporterDeepVerifyKey = @"CdnImporterDeepVerify";
NSString *const CdnImporterVerifyContentKey = @"CdnImporterVerifyContent";

NSString *const CdnImporterErrorDomain = @"com.starpoint.cdnimporter";
NSString *const CdnImporterDetailsKey = @"CdnImporterDetails";

NSError *CdnErrorWithDetails(CdnImporterErrorCode code, NSArray<NSString *> * _Nullable details, NSString *format, ...) {
    va_list args;
    va_start(args, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    NSMutableDictionary *userInfo = [NSMutableDictionary dictionaryWithCapacity:2];
    userInfo[NSLocalizedDescriptionKey] = message;
    if (details.count > 0) userInfo[CdnImporterDetailsKey] = details;
    return [NSError errorWithDomain:CdnImporterErrorDomain code:code userInfo:userInfo];
}

NSError *CdnError(CdnImporterErrorCode code, NSString *format, ...) {
    va_list args;
    va_start(args, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    return CdnErrorWithDetails(code, nil, @"%@", message);
}

#pragma mark - 路径

static NSString *CdnImporterApplicationSupport(void) {
    return [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Application Support"];
}

/// 给一个候选 Local Store 打分（0 = 不存在，不参与竞选）。
/// 分数只看磁盘证据 —— 导入器不要求任何特定 bundle id。
static NSInteger CdnImporterLocalStoreScore(NSString *localStore, BOOL matchesBundleID) {
    NSFileManager *manager = [NSFileManager defaultManager];
    BOOL isDirectory = NO;
    if (![manager fileExistsAtPath:localStore isDirectory:&isDirectory] || !isDirectory) return 0;
    NSInteger score = 1;
    if ([manager fileExistsAtPath:[localStore stringByAppendingPathComponent:@"asset"]]) score += 2;
    if ([manager fileExistsAtPath:[localStore stringByAppendingPathComponent:@"asset/asset_download"]]) score += 8;
    if (matchesBundleID) score += 1;
    return score;
}

/// 解析 Local Store 根，并把「为什么是它」写进 *outNote。
///
/// 参考实现是独立 App，要满磁盘找游戏容器，所以它的主路径是「扫 Application Support 按磁盘
/// 证据打分」；本 dylib 跑在游戏进程里 ⇒ NSHomeDirectory() 就是游戏容器根，bundle id 目录
/// 是首选（少一次全目录扫描，也避免同容器里有第二个带 Local Store 的目录时选错）。
/// 兜底仍然保留参考实现那套打分：iOS 上 AIR 的 File.applicationStorageDirectory 落在
/// `<Application Support>/<app id>/Local Store`，这个 id 既可能是 Info.plist 的 CFBundleIdentifier，
/// 也可能是 SWF 描述符里的 AIR app id —— 重签名换个 bundle id 之后两者就可能不一致。
static NSString *CdnImporterResolveStorageRoot(NSString **outNote) {
    NSFileManager *manager = [NSFileManager defaultManager];
    NSString *appSupport = CdnImporterApplicationSupport();
    NSString *bundleID = [NSBundle mainBundle].bundleIdentifier ?: @"";

    // ① 覆写键优先（调试用）。
    NSString *override = [[NSUserDefaults standardUserDefaults] stringForKey:CdnImporterStorageRootKey];
    if (override.length > 0) {
        if (outNote != NULL) *outNote = [NSString stringWithFormat:@"CdnImporterStorageRoot 覆写：%@", override];
        return override;
    }

    // ② bundle id 目录（本进程就在游戏容器里，这是正常路径）。
    if (bundleID.length > 0) {
        NSString *preferred = [[appSupport stringByAppendingPathComponent:bundleID]
                               stringByAppendingPathComponent:@"Local Store"];
        if (CdnImporterLocalStoreScore(preferred, YES) > 0) {
            if (outNote != NULL) *outNote = [NSString stringWithFormat:@"%@（与 bundle id 一致）", bundleID];
            return preferred;
        }
    }

    // ③ 兜底：扫 <Application Support>/*，按磁盘证据取最强的那个。
    NSString *bestRoot = nil;
    NSString *bestID = nil;
    NSInteger bestScore = 0;
    for (NSString *entry in [manager contentsOfDirectoryAtPath:appSupport error:NULL]) {
        if (bundleID.length > 0 && [entry isEqualToString:bundleID]) continue;   // ② 已经判过它不存在
        NSString *localStore = [[appSupport stringByAppendingPathComponent:entry]
                                stringByAppendingPathComponent:@"Local Store"];
        NSInteger score = CdnImporterLocalStoreScore(localStore, NO);
        if (score <= 0) continue;
        if (bestRoot == nil || score > bestScore) {
            bestRoot = localStore;
            bestID = entry;
            bestScore = score;
        }
    }
    if (bestRoot != nil) {
        if (outNote != NULL) {
            *outNote = [NSString stringWithFormat:@"%@（bundle id 是 %@，但游戏把资产写在这个目录）",
                        bestID, bundleID.length > 0 ? bundleID : @"未知"];
        }
        return bestRoot;
    }

    // ④ 一个都没有（游戏还没跑过一次资源下载）⇒ 按 bundle id 预置路径，交给 CdnImporterEnsureDirectory 创建。
    NSString *fallbackID = bundleID.length > 0 ? bundleID : @"com.leiting.wf";
    if (outNote != NULL) {
        *outNote = bundleID.length > 0
            ? [NSString stringWithFormat:@"%@（游戏还没跑过、没有资产痕迹，按 bundle id 预置）", fallbackID]
            : [NSString stringWithFormat:@"%@（连 bundle id 都取不到，用与国服一致的默认值）", fallbackID];
    }
    return [[appSupport stringByAppendingPathComponent:fallbackID]
            stringByAppendingPathComponent:@"Local Store"];
}

NSString *CdnImporterStorageRoot(void) {
    return CdnImporterResolveStorageRoot(NULL);
}

NSString *CdnImporterStorageRootNote(void) {
    NSString *note = nil;
    (void)CdnImporterResolveStorageRoot(&note);
    return note ?: @"未知";
}

// asset_download 下的实际子目录名（解析一次后进程内缓存）。
//
// 为什么要探测：这个子目录是「游戏开始联网下载资源时」才创建的，info.json 与 download/ 都写在里面；
// 所以「游戏还没跑过资源下载」的手机上它根本不存在，只能按参考实现回退到 dummy。dummy 这个推断
// 的证据是：① 参考 APK（cn.startpoint.importer，逐字面量反编译）写的路径就是
// `<...>/asset/asset_download/dummy`；② 仓库 docs/cdn/client-flow.md 的
// `{appStorage}/asset/asset_download/dummy/info.json`；③ iOS 主二进制里只有 `asset/asset_download`
// 常量与 AIR 的 `Local Store` 字面量，没有与资产路径同现的 dummy。
// 探测优先级：
//   1) 某个子目录带 info.json / download/（客户端正在用它）→ 采用；
//   2) 某个子目录带 partial_downloaded*（客户端已开始下载、还没解压）→ 采用；
//   3) asset_download 下只有一个子目录（游戏建过，哪怕还空着）→ 采用（防客户端用的名字不是 dummy）；
//   4) 以上都没有 → 回退 dummy，并把「这是推断而非观测」记进 note。
static NSString *gCdnImporterAssetSubdirectory = nil;
static BOOL gCdnImporterAssetSubdirectoryEvidenceBacked = NO;
static NSString *gCdnImporterAssetSubdirectoryNote = nil;

static void CdnImporterResolveAssetSubdirectory(void) {
    NSFileManager *manager = [NSFileManager defaultManager];
    NSString *assetDownload = [CdnImporterStorageRoot() stringByAppendingPathComponent:@"asset/asset_download"];
    NSArray<NSString *> *entries = [manager contentsOfDirectoryAtPath:assetDownload error:NULL];
    NSString *soleCandidate = nil;
    NSUInteger directoryCount = 0;
    for (NSString *entry in entries) {
        if ([entry hasPrefix:@"."]) continue;
        BOOL isDirectory = NO;
        NSString *candidate = [assetDownload stringByAppendingPathComponent:entry];
        if (![manager fileExistsAtPath:candidate isDirectory:&isDirectory] || !isDirectory) continue;
        directoryCount += 1;
        soleCandidate = candidate;
        BOOL hasInfo = [manager fileExistsAtPath:[candidate stringByAppendingPathComponent:@"info.json"]];
        BOOL hasDownload = [manager fileExistsAtPath:[candidate stringByAppendingPathComponent:@"download"]];
        BOOL hasPartial = NO;
        for (NSString *item in [manager contentsOfDirectoryAtPath:candidate error:NULL]) {
            if ([item hasPrefix:@"partial_downloaded"]) {
                hasPartial = YES;
                break;
            }
        }
        if (hasInfo || hasDownload || hasPartial) {
            NSString *reason = hasInfo ? @"有 info.json" : (hasDownload ? @"有 download/" : @"有 partial_downloaded*");
            gCdnImporterAssetSubdirectory = candidate;
            gCdnImporterAssetSubdirectoryEvidenceBacked = YES;
            gCdnImporterAssetSubdirectoryNote = [NSString stringWithFormat:@"发现客户端已使用的目录 %@（%@）", entry, reason];
            CdnImporterLog(@"[导入器] asset_download 下命中 %@（%@）", entry, reason);
            return;
        }
    }
    if (directoryCount == 1 && soleCandidate != nil) {
        gCdnImporterAssetSubdirectory = soleCandidate;
        gCdnImporterAssetSubdirectoryEvidenceBacked = YES;
        gCdnImporterAssetSubdirectoryNote = [NSString stringWithFormat:@"asset_download 下只有 %@ 一个子目录，采用它",
                                             [soleCandidate lastPathComponent]];
        CdnImporterLog(@"[导入器] %@", gCdnImporterAssetSubdirectoryNote);
        return;
    }
    gCdnImporterAssetSubdirectory = [assetDownload stringByAppendingPathComponent:@"dummy"];
    gCdnImporterAssetSubdirectoryEvidenceBacked = NO;
    if (directoryCount == 0) {
        gCdnImporterAssetSubdirectoryNote = @"未发现游戏创建过的目录（游戏还没跑过资源下载），按参考实现用 dummy";
    } else {
        gCdnImporterAssetSubdirectoryNote =
            [NSString stringWithFormat:@"asset_download 下有 %lu 个子目录但都没有下载痕迹，按参考实现用 dummy",
             (unsigned long)directoryCount];
    }
    CdnImporterLog(@"[导入器] 回退目录 dummy：%@", gCdnImporterAssetSubdirectoryNote);
}

static NSString *CdnImporterAssetSubdirectory(void) {
    // 进程内缓存（**故意保留**）：引擎一次运行里会多次调用（空间检查 / info.json / partial / 收尾），
    // 每次都重扫的话，若 asset_download 下有多个候选子目录，可能前半程与后半程解析到不同目录。
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        CdnImporterResolveAssetSubdirectory();
    });
    return gCdnImporterAssetSubdirectory;
}

NSString *CdnImporterAssetDummyDir(void) {
    return CdnImporterAssetSubdirectory();
}

BOOL CdnImporterTargetDirectoryIsEvidenceBacked(void) {
    (void)CdnImporterAssetSubdirectory();
    return gCdnImporterAssetSubdirectoryEvidenceBacked;
}

NSString *CdnImporterTargetDirectoryNote(void) {
    (void)CdnImporterAssetSubdirectory();
    return gCdnImporterAssetSubdirectoryNote != nil ? gCdnImporterAssetSubdirectoryNote : @"";
}

NSString *CdnImporterAssetDownloadDir(void) {
    return [CdnImporterAssetDummyDir() stringByAppendingPathComponent:@"download"];
}

NSString *CdnImporterInfoJsonPath(void) {
    return [CdnImporterAssetDummyDir() stringByAppendingPathComponent:@"info.json"];
}

NSArray<NSString *> *CdnImporterPartialFilePaths(void) {
    NSString *dummy = CdnImporterAssetDummyDir();
    NSString *root = CdnImporterStorageRoot();
    return @[
        [dummy stringByAppendingPathComponent:@"partial_downloaded.json"],
        [dummy stringByAppendingPathComponent:@"partial_downloaded.platform"],
        [dummy stringByAppendingPathComponent:@"partial_downloaded_android_thread.json"],
        [root stringByAppendingPathComponent:@"partial_downloaded.json"],
    ];
}

NSString *CdnImporterEffectivePatchBase(void) {
    NSString *override = [[NSUserDefaults standardUserDefaults] stringForKey:CdnImporterPatchBaseKey];
    if (override.length > 0) return override;
    return CDN_IMPORT_PATCH_BASE;
}

BOOL CdnImporterDeepVerifyEnabled(void) {
    id value = [[NSUserDefaults standardUserDefaults] objectForKey:CdnImporterDeepVerifyKey];
    if (value == nil) return NO;
    return [value boolValue];
}

/// 新键优先；没设过就看历史键（老用户可能把「深度校验」关过）；两个键都没有 → 默认开。
BOOL CdnImporterVerifyContentEnabled(void) {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    if ([defaults objectForKey:CdnImporterVerifyContentKey] != nil) {
        return [defaults boolForKey:CdnImporterVerifyContentKey];
    }
    if ([defaults objectForKey:CdnImporterDeepVerifyKey] != nil) {
        return CdnImporterDeepVerifyEnabled();
    }
    return YES;
}

#pragma mark - 小工具

BOOL CdnImporterEnsureDirectory(NSString *path, NSError **error) {
    if (path.length == 0) {
        if (error != NULL) *error = CdnError(CdnImporterErrorIO, @"空目录路径");
        return NO;
    }
    NSFileManager *manager = [NSFileManager defaultManager];
    BOOL isDirectory = NO;
    if ([manager fileExistsAtPath:path isDirectory:&isDirectory]) {
        if (isDirectory) return YES;
        if (error != NULL) *error = CdnError(CdnImporterErrorIO, @"路径已存在且不是目录: %@", path);
        return NO;
    }
    return [manager createDirectoryAtPath:path withIntermediateDirectories:YES attributes:nil error:error];
}

BOOL CdnImporterRemoveItem(NSString *path) {
    return [[NSFileManager defaultManager] removeItemAtPath:path error:NULL];
}

NSString *CdnImporterNearestExistingPath(NSString *path) {
    NSFileManager *manager = [NSFileManager defaultManager];
    NSString *candidate = path;
    while (candidate.length > 1) {
        if ([manager fileExistsAtPath:candidate]) return candidate;
        NSString *parent = [candidate stringByDeletingLastPathComponent];
        if (parent.length == 0 || [parent isEqualToString:candidate]) break;
        candidate = parent;
    }
    return candidate;
}

NSString *CdnImporterHumanBytes(uint64_t bytes) {
    static NSArray<NSString *> *units = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        units = @[@"B", @"KB", @"MB", @"GB", @"TB"];
    });
    double value = (double)bytes;
    NSUInteger unit = 0;
    while (value >= 1024.0 && unit + 1 < units.count) {
        value /= 1024.0;
        unit++;
    }
    if (unit == 0) return [NSString stringWithFormat:@"%llu B", bytes];
    return [NSString stringWithFormat:@"%.2f %@", value, units[unit]];
}

NSString *CdnImporterHumanCount(uint64_t count) {
    static NSNumberFormatter *formatter = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        formatter = [[NSNumberFormatter alloc] init];
        formatter.numberStyle = NSNumberFormatterDecimalStyle;
        formatter.groupingSeparator = @",";
    });
    NSString *text = [formatter stringFromNumber:@(count)];
    return text != nil ? text : [NSString stringWithFormat:@"%llu", count];
}

uint64_t CdnImporterResidentMemoryBytes(void) {
    task_vm_info_data_t info;
    mach_msg_type_number_t count = TASK_VM_INFO_COUNT;
    kern_return_t result = task_info(mach_task_self(), TASK_VM_INFO, (task_info_t)&info, &count);
    if (result != KERN_SUCCESS) return 0;
    return (uint64_t)info.phys_footprint;
}

NSString *CdnImporterResidentMemoryDescription(void) {
    uint64_t bytes = CdnImporterResidentMemoryBytes();
    if (bytes == 0) return @"未知";
    return CdnImporterHumanBytes(bytes);
}

NSString * _Nullable CdnImporterSanitizeEntryPath(NSString *name) {
    if (name.length == 0) return nil;
    if ([name hasPrefix:@"/"] || [name hasPrefix:@"~"]) return nil;
    if ([name rangeOfString:@"\0"].location != NSNotFound) return nil;
    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    for (NSString *component in [name componentsSeparatedByString:@"/"]) {
        if (component.length == 0 || [component isEqualToString:@"."]) continue;
        if ([component isEqualToString:@".."]) return nil;
        if ([component rangeOfString:@":"].location != NSNotFound) return nil;   // 防 ADS / 盘符
        [parts addObject:component];
    }
    if (parts.count == 0) return nil;
    return [parts componentsJoinedByString:@"/"];
}

NSString *CdnImporterTempDirectory(void) {
    NSString *directory = [NSTemporaryDirectory() stringByAppendingPathComponent:@"CdnImporter"];
    CdnImporterEnsureDirectory(directory, NULL);
    return directory;
}

NSDictionary<NSString *, id> * _Nullable CdnImporterJSONFromFile(NSString *path, NSError **error) {
    NSData *data = [NSData dataWithContentsOfFile:path options:0 error:error];
    if (data == nil) return nil;
    if (data.length == 0) return @{};
    id object = [NSJSONSerialization JSONObjectWithData:data options:0 error:error];
    if (![object isKindOfClass:[NSDictionary class]]) {
        if (error != NULL) *error = CdnError(CdnImporterErrorFormat, @"JSON 顶层不是对象: %@", path);
        return nil;
    }
    return (NSDictionary<NSString *, id> *)object;
}

BOOL CdnImporterWriteJSONAtomically(NSDictionary<NSString *, id> *object, NSString *path, NSError **error) {
    NSData *data = [NSJSONSerialization dataWithJSONObject:object options:0 error:error];
    if (data == nil) return NO;
    NSString *directory = [path stringByDeletingLastPathComponent];
    if (!CdnImporterEnsureDirectory(directory, error)) return NO;
    NSString *temporary = [path stringByAppendingPathExtension:@"tmp"];
    [NSFileManager.defaultManager removeItemAtPath:temporary error:NULL];
    if (![data writeToFile:temporary options:NSDataWritingAtomic error:error]) return NO;
    NSFileManager *manager = [NSFileManager defaultManager];
    if (![manager fileExistsAtPath:path]) {
        return [manager moveItemAtPath:temporary toPath:path error:error];
    }
    // 用 replaceItemAtURL 而不是「先删再移」：删与移之间崩溃会连旧的 info.json 一起丢。
    NSURL *result = nil;
    NSError *replaceError = nil;
    NSURL *destination = [NSURL fileURLWithPath:path];
    if ([manager replaceItemAtURL:destination
                     withItemAtURL:[NSURL fileURLWithPath:temporary]
                    backupItemName:nil
                           options:0
                  resultingItemURL:&result
                             error:&replaceError]) {
        return YES;
    }
    // 某些文件系统/容器不支持 replace，退化到删+移（此时至少临时文件已经写好）
    [manager removeItemAtPath:temporary error:NULL];
    if ([manager removeItemAtPath:path error:NULL] && [manager moveItemAtPath:temporary toPath:path error:error]) {
        return YES;
    }
    // replace 失败且临时文件已被上面清掉：写回一份，别让调用方拿到「文件不存在」
    if (![manager fileExistsAtPath:path]) {
        if (![data writeToFile:path options:NSDataWritingAtomic error:error]) return NO;
    }
    if (error != NULL && *error == nil) *error = replaceError;
    return [manager fileExistsAtPath:path];
}

#pragma mark - 导入成功标记

NSString *CdnImporterImportedMarkerPath(void) {
    NSString *directory = [CdnImporterApplicationSupport() stringByAppendingPathComponent:@"SpCnImporter"];
    return [directory stringByAppendingPathComponent:@"imported.json"];
}

NSDictionary<NSString *, id> * _Nullable CdnImporterImportedMarker(void) {
    id object = CdnImporterJSONFromFile(CdnImporterImportedMarkerPath(), NULL);
    return [object isKindOfClass:[NSDictionary class]] ? object : nil;
}

BOOL CdnImporterWriteImportedMarker(NSDictionary<NSString *, id> *object, NSError **error) {
    if (object == nil) return NO;
    NSString *path = CdnImporterImportedMarkerPath();
    if (!CdnImporterEnsureDirectory([path stringByDeletingLastPathComponent], error)) return NO;
    return CdnImporterWriteJSONAtomically(object, path, error);
}

BOOL CdnImporterClearImportedMarker(void) {
    return CdnImporterRemoveItem(CdnImporterImportedMarkerPath());
}
