//
//  CdnImporterConfig.h
//  SpCnEmbedded —— CDN 归档导入引擎（移植自 wf-cdn-importer-iOS 的 ios/importer/）
//
//  职责：构建期常量、沙盒路径解析（Local Store / asset_download）、日志、通用小工具。
//
//  与参考实现的三处差异（本项目特有，务必留意）：
//   ① 日志统一走本项目的 SpCnLog（见下面的 CdnImporterLog 宏）：参考实现自开
//      `Library/Application Support/CdnImporter/CdnImporter.log`，本项目不另开日志文件；
//   ② 参考实现是个独立 App，要满磁盘找游戏容器；**这份 dylib 就跑在游戏进程里** ⇒
//      NSHomeDirectory() 就是游戏容器根，Local Store 直接按
//      `<容器>/Library/Application Support/<bundle id>/Local Store` 定位；
//      只有它不存在时才退回参考实现那套「扫 Application Support 找带 Local Store 的目录」的探测；
//   ③ 未移植 UI 三件套（悬浮球 / 面板 / 「资源已完整」判断）—— 那些由本项目自己的
//      SpCnOverlay / SpCnPanelViewController / SpCnResourceImporter 承担。
//

#import <Foundation/Foundation.h>
#import "SpCnLog.h"

NS_ASSUME_NONNULL_BEGIN

/// info.json 的 baseUrl。客户端只把它当 Recovery 直链前缀（base_url + file.hash），而服务端
/// files_list 恒为空的 recovery/empty.csv ⇒ 该字段近乎惰性。构建期用 -DCDN_IMPORT_PATCH_BASE
/// 覆盖，运行期可用 NSUserDefaults 键覆写。
#ifndef CDN_IMPORT_PATCH_BASE
#define CDN_IMPORT_PATCH_BASE @"http://192.168.1.10:8001/patch/cn/"
#endif

/// info.json 的 latestModifiedTimeOfArchive。客户端只把它抄进 info.json / partial_downloaded.json，
/// 没有任何比较逻辑 ⇒ 写一个固定字符串即可。
#ifndef CDN_IMPORT_ARCHIVE_TIME
#define CDN_IMPORT_ARCHIVE_TIME @"Sat, 09 Aug 2025 09:35:28 GMT"
#endif

/// NSUserDefaults 覆写键。
extern NSString *const CdnImporterPatchBaseKey;      ///< NSString，覆盖 baseUrl
extern NSString *const CdnImporterStorageRootKey;    ///< NSString，覆盖 Local Store 根（只该用于调试）
extern NSString *const CdnImporterDeepVerifyKey;     ///< BOOL，逐归档校验 sha256（历史键）
extern NSString *const CdnImporterVerifyContentKey;  ///< BOOL，解压前先验内容（默认 YES，见下面的取值函数）

#pragma mark - 错误

extern NSString *const CdnImporterErrorDomain;

typedef NS_ENUM(NSInteger, CdnImporterErrorCode) {
    CdnImporterErrorIO = 1,
    CdnImporterErrorFormat,
    CdnImporterErrorPlan,
    CdnImporterErrorCancelled,
    CdnImporterErrorMissingArchives,
};

/// userInfo 里附「逐条明细」的键（如缺归档清单）；面板会把它逐行打印出来。
extern NSString *const CdnImporterDetailsKey;

NSError *CdnError(CdnImporterErrorCode code, NSString *format, ...) NS_FORMAT_FUNCTION(2, 3);
NSError *CdnErrorWithDetails(CdnImporterErrorCode code, NSArray<NSString *> * _Nullable details,
                             NSString *format, ...) NS_FORMAT_FUNCTION(3, 4);

#pragma mark - 日志

/// 参考实现里 CdnImporterLog 是「NSLog + 追加写自己的日志文件」的函数；这里整体重定向到本项目的
/// SpCnLog（同一份 dylib 的其余部分也用它 ⇒ 日志只有一个落点，也不会再开日志文件）。
/// 调用写法与原来完全一致：CdnImporterLog(@"[引擎] %@", line);
#define CdnImporterLog(...) [SpCnLog line:__VA_ARGS__]

#pragma mark - 目标目录（游戏容器内）

/// 解析 Local Store 根（**不要求任何特定 bundle id / app id**）：
///   1) NSUserDefaults 键 `CdnImporterStorageRoot` 覆写优先（调试用）；
///   2) `<Application Support>/<bundle id>/Local Store` —— 本进程就在游戏容器里，这是首选；
///   3) 它不存在 → 扫 `<Application Support>/*/Local Store`，按磁盘证据取最强的那个
///      （有 `asset/asset_download` > 有 `asset` > 只是存在）—— AIR 的
///      File.applicationStorageDirectory 落在这里，而它的目录名既可能是 Info.plist 的
///      CFBundleIdentifier，也可能是 SWF 描述符里的 app id，重签名后两者可能不一致；
///   4) 一个都不存在（游戏还没跑过）才按 bundle id 预置路径，交给 CdnImporterEnsureDirectory 创建。
NSString *CdnImporterStorageRoot(void);

/// Local Store 根的判定说明（人类可读，面板/日志直接展示；永不为 nil）
NSString *CdnImporterStorageRootNote(void);

/// <Local Store>/asset/asset_download/<子目录>
/// 注意：子目录名是「探测」出来的（客户端开始下载时才创建它），解析一次后进程内缓存。
/// 见下面两个函数。
NSString *CdnImporterAssetDummyDir(void);

/// 目标子目录是否由「磁盘证据」确定（客户端已创建过该目录）。
/// NO = 磁盘上什么都没找到，用的是参考实现推断出来的 `dummy` ⇒ 建议先让游戏跑一次资源检查再导入。
BOOL CdnImporterTargetDirectoryIsEvidenceBacked(void);

/// 目标子目录的判定说明（人类可读，面板/日志直接展示；永不为 nil）
NSString *CdnImporterTargetDirectoryNote(void);

/// <子目录>/download —— 解压落盘根（与参考 APK 的 new File(fileResolveStorageDir, "download") 一致）
NSString *CdnImporterAssetDownloadDir(void);

/// <子目录>/info.json
NSString *CdnImporterInfoJsonPath(void);

/// partial_downloaded.json / partial_downloaded.platform / partial_downloaded_android_thread.json
/// （外加 <Local Store>/partial_downloaded.json —— 共 4 个，导入成功后必须删掉）
NSArray<NSString *> *CdnImporterPartialFilePaths(void);

/// 生效的 baseUrl（NSUserDefaults 覆写 > 编译期常量）
NSString *CdnImporterEffectivePatchBase(void);

/// 是否开启逐归档 sha256 深度校验（历史键 CdnImporterDeepVerify；新键没设时作为回退）
BOOL CdnImporterDeepVerifyEnabled(void);

/// 是否在解压之前先逐归档验内容（sha256，默认 **YES**）。
/// 为什么默认开：输入里混进别的版本 / 别的平台（安卓那 677 个）的分卷时，宁可一个字节都不动地
/// 报「这套不是 1.4.54 的 iOS 套装」，也不要把 10 GB 写成半对半错、再让游戏去补下载。
/// 关掉能省一遍全量读取（约一半时间），代价是「归档名对、字节数对、内容不对」要到解压后才发现。
BOOL CdnImporterVerifyContentEnabled(void);

#pragma mark - 导入成功标记

/// 导入成功的标记文件（<Application Support>/SpCnImporter/imported.json）与其读写。
/// 参考实现用它来决定「悬浮球要不要自动收起来」；本项目保留这套读写（面板/悬浮球将来要用），
/// 只是把目录从 `CdnImporter` 改成与本 tweak 同名的 `SpCnImporter`。
NSString *CdnImporterImportedMarkerPath(void);
NSDictionary<NSString *, id> * _Nullable CdnImporterImportedMarker(void);
BOOL CdnImporterWriteImportedMarker(NSDictionary<NSString *, id> *object, NSError **error);
BOOL CdnImporterClearImportedMarker(void);

#pragma mark - 小工具

BOOL CdnImporterEnsureDirectory(NSString *path, NSError **error);
BOOL CdnImporterRemoveItem(NSString *path);
NSString *CdnImporterHumanBytes(uint64_t bytes);
NSString *CdnImporterHumanCount(uint64_t count);

/// 进程当前内存占用（task_vm_info 的 phys_footprint —— jetsam 就是按它杀进程的）。
/// 解压 10 GB 是个长跑，逐归档把它打进日志：数字一路平稳才算正常，
/// 只涨不落说明有东西在攒（真机「Bad address」就是攒到分配失败的表现）。
uint64_t CdnImporterResidentMemoryBytes(void);
NSString *CdnImporterResidentMemoryDescription(void);

/// 向上找到最近的**已存在**目录：`attributesOfFileSystemForPath:` 对不存在的路径会直接报错
/// （"未能打开文件“download”，因为它不存在。"）。同一卷上读到的可用空间是同一个数字。
NSString *CdnImporterNearestExistingPath(NSString *path);

/// ZIP 条目名 → 相对落盘路径：拒绝绝对路径与 `..`，去掉前导 `./`；非法返回 nil。
NSString * _Nullable CdnImporterSanitizeEntryPath(NSString *name);

/// 物化临时目录（<tmp>/CdnImporter，用于整包 zip 里 deflate 成员的懒物化）
NSString *CdnImporterTempDirectory(void);

NSDictionary<NSString *, id> * _Nullable CdnImporterJSONFromFile(NSString *path, NSError **error);
BOOL CdnImporterWriteJSONAtomically(NSDictionary<NSString *, id> *object, NSString *path, NSError **error);

NS_ASSUME_NONNULL_END
