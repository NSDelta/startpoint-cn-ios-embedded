// SpCnIdentityDiag.m —— 见 .h 的说明。诊断 + 可选的身份谎报（swizzle，不用 interpose 以免引入未定义符号）。
#import "SpCnIdentityDiag.h"
#import "SpCnConfig.h"
#import "SpCnLog.h"
#import <objc/runtime.h>
#import <dlfcn.h>
#import <CoreFoundation/CoreFoundation.h>
#import <setjmp.h>
#import <execinfo.h>
#import <stdlib.h>
#import <stdio.h>
#import <string.h>
#import <stdarg.h>
#import <fcntl.h>
#import <unistd.h>
#import <sys/syscall.h>

extern void longjmp(jmp_buf, int);
extern void _longjmp(jmp_buf, int);
extern void siglongjmp(sigjmp_buf, int);

// 自己声明（theos 的 iPhoneOS16.5.sdk 里没有 cxxabi.h / objc-exception.h）
extern void objc_exception_throw(id exception);
extern void __cxa_throw(void *thrown_exception, void *tinfo, void (*dest)(void *));
extern char *__cxa_demangle(const char *mangled_name, char *output_buffer, size_t *length, int *status);
extern CFTypeRef SecTaskCopyValueForEntitlement(void *task, CFStringRef entitlement, CFErrorRef *error);
extern CFStringRef CFBundleGetIdentifier(CFBundleRef bundle);
extern CFTypeRef CFBundleGetValueForInfoDictionaryKey(CFBundleRef bundle, CFStringRef key);

static NSString *gLieTo = nil;
static double gLieSeconds = 8.0;
static double gStart = 0;
static NSBundle *gMainBundle = nil;
static int gLieLogCount = 0;
static BOOL gInstalled = NO;

// 前置声明：spcn_log_backtrace 定义在下面的 CFBundle 段里，而 SecTask 那段在它上面就用了。
static void spcn_log_backtrace (const char *label);
// 同理：文件访问探针要惰性解析原函数（interpose 比构造函数早得多），而 spcn_original_of 定义在更后面。
static const void *spcn_original_of (const void *replacement);

#pragma mark - 诊断：ObjC / C++ 异常（用 dlsym 拿不到「谁抛」的栈，这里只记异常本身）

static void (*gOrigObjcThrow)(id) = NULL;
static void spcn_objc_exception_throw (id exception) {
    @try {
        if ([exception isKindOfClass:[NSException class]]) {
            NSException *e = (NSException *)exception;
            [SpCnLog line:@"[DIAG] ObjC 异常：%@ — %@", e.name, e.reason];
        } else {
            [SpCnLog line:@"[DIAG] ObjC 异常（非 NSException）：%@", NSStringFromClass([exception class])];
        }
    } @catch (...) { }
    if (gOrigObjcThrow) gOrigObjcThrow(exception);
}

static void (*gOrigCxaThrow)(void *, void *, void (*)(void *)) = NULL;
static void spcn_cxa_throw (void *thrown, void *tinfo, void (*dest)(void *)) {
    @try {
        const char *mangled = tinfo ? ((const char **)tinfo)[1] : NULL;   // libc++abi: type_info{ vtable, const char* }
        char *demangled = NULL;
        if (mangled) demangled = __cxa_demangle(mangled, NULL, NULL, NULL);
        [SpCnLog line:@"[DIAG] C++ 异常：%s", demangled ? demangled : (mangled ? mangled : "(?)")];
        if (demangled) free(demangled);
    } @catch (...) { }
    if (gOrigCxaThrow) gOrigCxaThrow(thrown, tinfo, dest);
}

#pragma mark - 诊断：entitlements 读取

static CFTypeRef (*gOrigSecTask)(void *, CFStringRef, CFErrorRef *) = NULL;
static CFTypeRef spcn_SecTaskCopyValueForEntitlement (void *task, CFStringRef entitlement, CFErrorRef *error) {
    CFTypeRef v = gOrigSecTask ? gOrigSecTask(task, entitlement, error) : NULL;
    @try {
        [SpCnLog line:@"[DIAG] SecTaskCopyValueForEntitlement(%@) ⇒ %@", (__bridge id)entitlement, v ? (__bridge id)v : @"nil"];
        NSString *e = (__bridge NSString *)entitlement;
        if ([e isEqualToString:@"application-identifier"] || [e isEqualToString:@"com.apple.private.security.container-required"]) {
            spcn_log_backtrace("SecTaskCopyValueForEntitlement(身份) 的调用方");
        }
    } @catch (...) { }
    return v;
}

#pragma mark - 诊断 + 谎报：CFBundle / NSBundle 的 Info.plist 身份读取
//
// 为什么加这一层：`-[NSBundle bundleIdentifier]` 撒谎**完全无效** ⇒ AIR（或某个 ANE）不是走这个 ObjC 方法
// 拿身份的，更可能是 CoreFoundation 的 `CFBundleGetIdentifier` / `CFBundleGetValueForInfoDictionaryKey`，
// 或 `-[NSBundle objectForInfoDictionaryKey:]`。这三个都记一遍，顺便也谎报，看错误会不会消失。

static CFStringRef (*gOrigCFBundleGetIdentifier)(CFBundleRef) = NULL;
static CFTypeRef (*gOrigCFBundleGetValue)(CFBundleRef, CFStringRef) = NULL;
static id (*gOrigObjectForInfo)(id, SEL, NSString *) = NULL;
static CFStringRef gLieCF = NULL;
static int gInfoKeyLogCount = 0;
static int gIdReadBtCount = 0;

/// 打一条调用栈（用来找「谁在读身份」—— AIR 的 DRM 校验就在读身份的调用者里）
static void spcn_log_backtrace (const char *label) {
    @try {
        [SpCnLog line:@"[DIAG] 调用栈（%s）：", label];
        void *bt[28];
        int n = backtrace(bt, 28);
        for (int i = 0; i < n; i++) {
            Dl_info fi;
            if (dladdr(bt[i], &fi) && fi.dli_fname) {
                const char *base = strrchr(fi.dli_fname, '/');
                base = base ? base + 1 : fi.dli_fname;
                [SpCnLog line:@"[DIAG]     #%-2d %s +0x%lx %s", i, base,
                    (unsigned long)((uintptr_t)bt[i] - (uintptr_t)fi.dli_fbase),
                    fi.dli_sname ? fi.dli_sname : ""];
            } else {
                [SpCnLog line:@"[DIAG]     #%-2d %p", i, bt[i]];
            }
        }
    } @catch (...) { }
}

static CFStringRef spcn_lie_cfstring (void) {
    if (!gLieTo.length) return NULL;
    if (!gLieCF) gLieCF = (CFStringRef)CFBridgingRetain([gLieTo copy]);
    return gLieCF;
}

static CFStringRef spcn_cfBundleGetIdentifier (CFBundleRef bundle) {
    CFStringRef real = gOrigCFBundleGetIdentifier ? gOrigCFBundleGetIdentifier(bundle) : NULL;
    if (bundle && bundle == CFBundleGetMainBundle() && gIdReadBtCount < 3) {
        gIdReadBtCount++;
        spcn_log_backtrace("CFBundleGetIdentifier(主 bundle) 的调用方");
    }
    if (gLieTo.length && bundle && bundle == CFBundleGetMainBundle()) {
        [SpCnLog line:@"[DIAG] CFBundleGetIdentifier 谎报 %@（真 %@）", gLieTo, (__bridge id)real];
        return spcn_lie_cfstring();
    }
    [SpCnLog line:@"[DIAG] CFBundleGetIdentifier ⇒ %@", (__bridge id)real];
    return real;
}

static CFTypeRef spcn_cfBundleGetValue (CFBundleRef bundle, CFStringRef key) {
    CFTypeRef real = gOrigCFBundleGetValue ? gOrigCFBundleGetValue(bundle, key) : NULL;
    NSString *k = (__bridge NSString *)key;
    if (gLieTo.length && bundle == CFBundleGetMainBundle() &&
        [k isEqualToString:(__bridge NSString *)kCFBundleIdentifierKey]) {
        [SpCnLog line:@"[DIAG] CFBundleGetValueForInfoDictionaryKey(%@) 谎报 %@（真 %@）", k, gLieTo, (__bridge id)real];
        return (CFTypeRef)spcn_lie_cfstring();
    }
    if (gInfoKeyLogCount < 80) {
        gInfoKeyLogCount++;
        [SpCnLog line:@"[DIAG] CFBundleGetValueForInfoDictionaryKey(%@) ⇒ %@", k, (__bridge id)real];
    }
    return real;
}

static id spcn_objectForInfoDictionaryKey (id self, SEL _cmd, NSString *key) {
    id v = gOrigObjectForInfo ? gOrigObjectForInfo(self, _cmd, key) : nil;
    if (self == gMainBundle && [key isEqualToString:@"CFBundleIdentifier"] && gIdReadBtCount < 6) {
        gIdReadBtCount++;
        spcn_log_backtrace("[NSBundle objectForInfoDictionaryKey:CFBundleIdentifier] 的调用方");
    }
    if (gLieTo.length && self == gMainBundle && [key isEqualToString:@"CFBundleIdentifier"]) {
        [SpCnLog line:@"[DIAG] objectForInfoDictionaryKey:CFBundleIdentifier 谎报 %@（真 %@）", gLieTo, v];
        return gLieTo;
    }
    if (gInfoKeyLogCount < 80) {
        gInfoKeyLogCount++;
        [SpCnLog line:@"[DIAG] [NSBundle objectForInfoDictionaryKey:%@] ⇒ %@", key, v];
    }
    return v;
}

#pragma mark - 诊断：longjmp（AIR 的 DRM 失败路径走 _setjmp/_longjmp，不抛异常）

// 为什么盯 longjmp：`sub_100011B94`（AIR 启动）里是 `_setjmp` + catch 分支打印
// 「AdobeAIR: application packaging error」，而 interpose objc_exception_throw / __cxa_throw 一无所获
// ⇒ 失败是通过 longjmp 展开的。记下「谁调的 + 主二进制里的偏移」，就能定位到底哪个检查没过。
static void (*gOrigLongjmp)(jmp_buf, int) = NULL;
static void (*gOrigLongjmpU)(jmp_buf, int) = NULL;
static void (*gOrigSiglongjmp)(sigjmp_buf, int) = NULL;

static void spcn_report_jump (const char *name) {
    static int sJumpCount = 0;
    if (sJumpCount >= 6) return;   // 限流：AIR 正常流程也可能 longjmp，别把日志刷爆
    sJumpCount++;
    @try {
        void *ret = __builtin_return_address(0);
        Dl_info ri; const char *who = "?";
        if (ret && dladdr(ret, &ri)) who = ri.dli_sname ? ri.dli_sname : (ri.dli_fname ? ri.dli_fname : "?");
        [SpCnLog line:@"[DIAG] %s 被调用（调用方 %s）—— 失败现场的调用栈：", name, who];
        void *bt[24];
        int n = backtrace(bt, 24);
        for (int i = 0; i < n; i++) {
            Dl_info fi;
            if (dladdr(bt[i], &fi) && fi.dli_fname) {
                const char *base = strrchr(fi.dli_fname, '/');
                base = base ? base + 1 : fi.dli_fname;
                [SpCnLog line:@"[DIAG]     #%-2d %s +0x%lx %s", i, base,
                    (unsigned long)((uintptr_t)bt[i] - (uintptr_t)fi.dli_fbase),
                    fi.dli_sname ? fi.dli_sname : ""];
            } else {
                [SpCnLog line:@"[DIAG]     #%-2d %p", i, bt[i]];
            }
        }
    } @catch (...) { }
}

static void spcn_longjmp (jmp_buf env, int val) {
    spcn_report_jump("longjmp");
    if (gOrigLongjmp) gOrigLongjmp(env, val);
    else { [SpCnLog line:@"[DIAG] 没有拿到原 longjmp ⇒ 只能 abort()"]; abort(); }
}
static void spcn__longjmp (jmp_buf env, int val) {
    spcn_report_jump("_longjmp");
    if (gOrigLongjmpU) gOrigLongjmpU(env, val);
    else { [SpCnLog line:@"[DIAG] 没有拿到原 _longjmp ⇒ 只能 abort()"]; abort(); }
}
static void spcn_siglongjmp (sigjmp_buf env, int val) {
    spcn_report_jump("siglongjmp");
    if (gOrigSiglongjmp) gOrigSiglongjmp(env, val);
    else { [SpCnLog line:@"[DIAG] 没有拿到原 siglongjmp ⇒ 只能 abort()"]; abort(); }
}

#pragma mark - 诊断 + 谎报：-bundleIdentifier

static NSString *(*gOrigBundleIdentifier)(id, SEL) = NULL;
static NSString *spcn_bundleIdentifier (id self, SEL _cmd) {
    NSString *v = gOrigBundleIdentifier ? gOrigBundleIdentifier(self, _cmd) : nil;
    if (gLieTo.length && self == gMainBundle) {
        BOOL within = (gLieSeconds <= 0) || (CFAbsoluteTimeGetCurrent() - gStart) < gLieSeconds;
        if (within && ![v isEqualToString:gLieTo]) {
            if (gLieLogCount < 30) {
                gLieLogCount++;
                void *ret = __builtin_return_address(0);
                Dl_info info;
                const char *who = "?";
                if (ret && dladdr(ret, &info) && info.dli_sname) who = info.dli_sname;
                [SpCnLog line:@"[DIAG] bundleIdentifier 谎报 %@（真 %@，调用方 %s）", gLieTo, v, who];
            }
            return gLieTo;
        }
    }
    return v;
}

#pragma mark - 诊断 + 谎报：-infoDictionary（★ AIR 就是从这里读 app id 的）

static NSDictionary *(*gOrigInfoDictionary)(id, SEL) = NULL;
static NSDictionary *gLiedInfoDict = nil;
static int gInfoDictLogCount = 0;

// ★ IDA 实证（数据库 wforig，`-[CTAppDescriptor appID]` @0x10000FF78，引用 cfstr_Cfbundleidenti @0x1063DF388）：
//     result = self->_appID;
//     if (!result) { v4 = [[NSBundle mainBundle] infoDictionary];
//                    result = [v4 objectForKey:@"CFBundleIdentifier"];   // ← 读一次就缓存进 _appID
//                    self->_appID = result; … }
//   ⇒ AIR 既不看 `-bundleIdentifier`、也不看 `objectForInfoDictionaryKey:`，只看**整个 infoDictionary**。
//     所以谎报点只能在这里：给主 bundle 换一份 CFBundleIdentifier 被改写过的字典副本（缓存一份，保证对象稳定）。
static NSDictionary *spcn_infoDictionary (id self, SEL _cmd) {
    NSDictionary *d = gOrigInfoDictionary ? gOrigInfoDictionary(self, _cmd) : nil;
    if (gLieTo.length && self == gMainBundle && [d isKindOfClass:[NSDictionary class]]) {
        BOOL within = (gLieSeconds <= 0) || (CFAbsoluteTimeGetCurrent() - gStart) < gLieSeconds;
        NSString *real = d[@"CFBundleIdentifier"];
        if (within && ![real isEqualToString:gLieTo]) {
            if (!gLiedInfoDict) {
                NSMutableDictionary *m = [d mutableCopy];
                m[@"CFBundleIdentifier"] = gLieTo;
                gLiedInfoDict = [m copy];
            }
            if (gInfoDictLogCount < 10) {
                gInfoDictLogCount++;
                [SpCnLog line:@"[DIAG] infoDictionary 谎报 CFBundleIdentifier=%@（真 %@）", gLieTo, real];
                spcn_log_backtrace("[[NSBundle mainBundle] infoDictionary] 的调用方（AIR 在这里读 app id）");
            }
            return gLiedInfoDict;
        }
    }
    return d;
}

#pragma mark - 安装

// 原函数：从**具体镜像**里取（不用 RTLD_NEXT，因为 __interpose 生效后 dlsym 的解析结果依平台而异，
// 取到自己的替换函数就会无限递归）。取回后与自己的替换函数比一次，相同就置空（宁可不 hook 也不能递归）。
static void *spcn_symbol_from_image (const char *image, const char *symbol, const void *self_impl) {
    void *h = dlopen(image, RTLD_NOW);
    if (!h) return NULL;
    void *p = dlsym(h, symbol);
    if (p == self_impl) return NULL;
    return p;
}

#pragma mark - 诊断：启动期到底开了哪些文件（内容加载 / 资源查找路径）

// 起因：包装自检解掉、服务端已 ready，但客户端一个请求都不发、日志停在 splash ⇒ 必须看清「AIR 有没有真去
// 开 worldflipper_ios_release.swf」「客户端到底在哪个目录找 Local Store」。NSData 那条探针没看到 SWF（AIR
// 大概是 mmap 读的），所以直接在 syscall 层拦 open/openat/fopen，按路径关键字过滤后打一行。
static int (*gOrigOpen)(const char *, int, ...) = NULL;
static int (*gOrigOpenat)(int, const char *, int, ...) = NULL;
static FILE *(*gOrigFopen)(const char *, const char *) = NULL;
static int gFileLogCount = 0;
static __thread BOOL gInFileLog = NO;   // ★ 防递归：SpCnLog 自己写日志也要 open，不加这个会无限套娃

static BOOL spcn_interesting_file (const char *p) {
    if (!p || !*p) return NO;
    static const char *needles[] = { ".swf", "META-INF", "Local Store", "asset_download",
                                     "application.xml", "license.txt", "__swf__", "extensions", ".ane" };
    for (size_t i = 0; i < sizeof(needles) / sizeof(needles[0]); i++) {
        if (strstr(p, needles[i])) return YES;
    }
    return NO;
}

static void spcn_log_file (const char *how, const char *p, int ok) {
    // ★ gInstalled 兼作「探针已武装」标志：我们的构造函数跑之前，绝不能碰 SpCnLog（那时它自己还没初始化）。
    if (!gInstalled || gInFileLog || gFileLogCount >= 150) return;
    if (!spcn_interesting_file(p)) return;
    gInFileLog = YES;
    gFileLogCount++;
    [SpCnLog line:@"[DIAG] %s %s ⇒ %d", how, p, ok];
    gInFileLog = NO;
}

// ★ 惰性解析原函数：interpose 从 dyld 加载那一刻就生效，比我们的构造函数早得多；
//   早先「拿不到就 return -1」的写法等于让 App（以及别的插件，实测 systemhook.dylib 的构造函数）
//   在构造函数之前打不开任何文件 ⇒ 启动即闪退。所以这里惰性解析，并在真拿不到时用裸 syscall 兜底。
static int spcn_fd_open (const void *replacement, const char *path, int flags, mode_t mode, int dirfd) {
    if (!gOrigOpen) gOrigOpen = (int (*)(const char *, int, ...))spcn_original_of(replacement);
    if (gOrigOpen && (const void *)gOrigOpen != replacement) return gOrigOpen(path, flags, mode);
#ifdef SYS_openat
    return (int)syscall(SYS_openat, dirfd, path, flags, mode);   // 兜底：绕过我们自己的 interpose
#else
    return -1;
#endif
}

static int spcn_open (const char *path, int flags, ...) {
    mode_t mode = 0;
    if (flags & O_CREAT) { va_list ap; va_start(ap, flags); mode = (mode_t)va_arg(ap, int); va_end(ap); }
    int fd = spcn_fd_open((const void *)spcn_open, path, flags, mode, AT_FDCWD);
    spcn_log_file("open", path, fd);
    return fd;
}

static int spcn_openat (int dirfd, const char *path, int flags, ...) {
    mode_t mode = 0;
    if (flags & O_CREAT) { va_list ap; va_start(ap, flags); mode = (mode_t)va_arg(ap, int); va_end(ap); }
    if (!gOrigOpenat) gOrigOpenat = (int (*)(int, const char *, int, ...))spcn_original_of((const void *)spcn_openat);
    int fd;
    if (gOrigOpenat && gOrigOpenat != spcn_openat) {
        fd = gOrigOpenat(dirfd, path, flags, mode);
    } else {
#ifdef SYS_openat
        fd = (int)syscall(SYS_openat, dirfd, path, flags, mode);
#else
        fd = -1;
#endif
    }
    spcn_log_file("openat", path, fd);
    return fd;
}

static FILE *spcn_fopen (const char *path, const char *mode) {
    if (!gOrigFopen) gOrigFopen = (FILE *(*)(const char *, const char *))spcn_original_of((const void *)spcn_fopen);
    if (gOrigFopen && gOrigFopen != spcn_fopen) {
        FILE *f = gOrigFopen(path, mode);
        spcn_log_file("fopen", path, f ? 0 : -1);
        return f;
    }
    // 兜底：没有原函数就用 open + fdopen 自己拼一个（fopen 的 mode 串与 open 的 flags 只在这几种组合里用）
    int flags = O_RDONLY;
    if (mode && mode[0] == 'w') flags = O_WRONLY | O_CREAT | O_TRUNC;
    else if (mode && mode[0] == 'a') flags = O_WRONLY | O_CREAT | O_APPEND;
    else if (mode && mode[0] == 'r' && strchr(mode, '+')) flags = O_RDWR;
    int fd = spcn_fd_open((const void *)spcn_fopen, path, flags, 0644, AT_FDCWD);
    FILE *f = fd >= 0 ? fdopen(fd, mode) : NULL;
    spcn_log_file("fopen", path, f ? 0 : -1);
    return f;
}

// dyld 在加载时读这一段：把我们这些函数插到对应符号前面
__attribute__((used)) static struct { const void *replacement; const void *replacee; }
spcn_interposers[] __attribute__((section("__DATA,__interpose"))) = {
    { (const void *)spcn_objc_exception_throw,           (const void *)objc_exception_throw },
    { (const void *)spcn_cxa_throw,                      (const void *)__cxa_throw },
    { (const void *)spcn_SecTaskCopyValueForEntitlement, (const void *)SecTaskCopyValueForEntitlement },
    { (const void *)spcn_cfBundleGetIdentifier,           (const void *)CFBundleGetIdentifier },
    { (const void *)spcn_cfBundleGetValue,                (const void *)CFBundleGetValueForInfoDictionaryKey },
    // longjmp 系重新挂上（2026-10-17 22:5x）：这次用 spcn_original_of 从 interpose 表的 replacee 字段取真身
    // （上次用 dlsym 拿到的是我们自己 ⇒ 自我保护 NULL ⇒ 兜底 abort() 把黑屏变成闪退）。
    { (const void *)spcn_longjmp,                     (const void *)longjmp },
    { (const void *)spcn__longjmp,                    (const void *)_longjmp },
    { (const void *)spcn_siglongjmp,                  (const void *)siglongjmp },
    // ⚠️ 文件访问探针（open/openat/fopen）**不能挂**：2026-10-17 23:09 与 23:16 两次「启动即闪退」的崩溃报告
    //    都落在越狱注入链上（`systemhook.dylib initializer`、`libinjector.dylib injection_init` → `Shadow.dylib`
    //    → `HookKit`/`HookKitFishhookModule` 的 `_dyld_register_func_for_add_image`），而 437,584 B 那份
    //    （不加这三个 interpose）能正常启动 ⇒ 是这三个 libc interpose 把这套 fishhook 注入器搞崩的。
    //    代码留着（下面 spcn_open/openat/fopen 与 gOrig* 都还在），要再试只改这里。
    // { (const void *)spcn_open,                        (const void *)open },
    // { (const void *)spcn_openat,                      (const void *)openat },
    // { (const void *)spcn_fopen,                       (const void *)fopen },
};

#pragma mark - 诊断：AIR 有没有读到 __swf__ / license.txt / 有没有真去读 SWF

// 起因：包装自检被 infoDictionary 谎报解掉之后，AIR 只走到 splash（CTDefaultImageViewController）就停住，
// 客户端零请求。要分清「内容解密/加载失败」还是「加载成功但 AS3 卡住」，先看这两件事：
//   ① -[NSBundle pathForResource:ofType:inDirectory:] 有没有成功拿到 META-INF/AIR/__swf__ 与 license.txt
//   ② +[NSData dataWithContentsOfFile:] 有没有真去读 worldflipper_ios_release.swf（多大）
static id (*gOrigPathForResource)(id, SEL, NSString *, NSString *, NSString *) = NULL;
static id (*gOrigDataWithContentsOfFile)(id, SEL, NSString *) = NULL;
static int gPathLogCount = 0;
static int gReadLogCount = 0;

static id spcn_pathForResource (id self, SEL _cmd, NSString *name, NSString *ext, NSString *dir) {
    id r = gOrigPathForResource ? gOrigPathForResource(self, _cmd, name, ext, dir) : nil;
    if (gPathLogCount < 60) {
        BOOL airish = (dir.length > 0 && [dir rangeOfString:@"AIR"].location != NSNotFound);
        BOOL swfish = (ext.length > 0 && [ext caseInsensitiveCompare:@"swf"] == NSOrderedSame);
        if (airish || swfish || r == nil) {
            gPathLogCount++;
            [SpCnLog line:@"[DIAG] pathForResource %@.%@ inDirectory=%@ ⇒ %@", name, ext, dir.length ? dir : @"(nil)", r ?: @"(nil)"];
        }
    }
    return r;
}

static id spcn_dataWithContentsOfFile (id self, SEL _cmd, NSString *path) {
    id r = gOrigDataWithContentsOfFile ? gOrigDataWithContentsOfFile(self, _cmd, path) : nil;
    if (gReadLogCount < 60) {
        NSString *low = [path lowercaseString];
        BOOL hit = [low hasSuffix:@".swf"] || [low rangeOfString:@"meta-inf"].location != NSNotFound ||
                   [low hasSuffix:@"license.txt"] || [low hasSuffix:@"application.xml"];
        if (hit) {
            gReadLogCount++;
            [SpCnLog line:@"[DIAG] NSData 读 %@ ⇒ %@", path, r ? [NSString stringWithFormat:@"%lu 字节", (unsigned long)[r length]] : @"(nil)"];
        }
    }
    return r;
}

// ★ 取原始实现的正确办法：从 **interpose 表自己的 replacee 字段**读 —— dyld 会把那里解析成真实符号地址。
//   用 dlopen+dlsym 是不行的：实测 dlsym 也被 interpose 污染（返回我们自己的替换函数 ⇒ 自我保护返回 NULL），
//   安装日志里就是 `异常 interpose=nil/nil，entitlements=nil`。
static const void *spcn_original_of (const void *replacement) {
    size_t n = sizeof(spcn_interposers) / sizeof(spcn_interposers[0]);
    for (size_t i = 0; i < n; i++) {
        if (spcn_interposers[i].replacement == replacement) return spcn_interposers[i].replacee;
    }
    return NULL;
}

void SpCnIdentityDiagInstall (void) {
    if (gInstalled) return;
    gInstalled = YES;
    gStart = CFAbsoluteTimeGetCurrent();
    gMainBundle = [NSBundle mainBundle];

    gOrigObjcThrow = (void (*)(id))spcn_original_of((const void *)spcn_objc_exception_throw);
    if (!gOrigObjcThrow) gOrigObjcThrow = spcn_symbol_from_image("/usr/lib/libobjc.A.dylib", "objc_exception_throw", (const void *)spcn_objc_exception_throw);
    gOrigCxaThrow  = (void (*)(void *, void *, void (*)(void *)))spcn_original_of((const void *)spcn_cxa_throw);
    if (!gOrigCxaThrow) gOrigCxaThrow = spcn_symbol_from_image("/usr/lib/libc++abi.dylib", "__cxa_throw", (const void *)spcn_cxa_throw);
    gOrigSecTask   = (CFTypeRef (*)(void *, CFStringRef, CFErrorRef *))spcn_original_of((const void *)spcn_SecTaskCopyValueForEntitlement);
    if (!gOrigSecTask) gOrigSecTask = spcn_symbol_from_image("/System/Library/Frameworks/Security.framework/Security",
                                            "SecTaskCopyValueForEntitlement", (const void *)spcn_SecTaskCopyValueForEntitlement);
    gOrigCFBundleGetIdentifier = (CFStringRef (*)(CFBundleRef))spcn_original_of((const void *)spcn_cfBundleGetIdentifier);
    gOrigCFBundleGetValue      = (CFTypeRef (*)(CFBundleRef, CFStringRef))spcn_original_of((const void *)spcn_cfBundleGetValue);
    // longjmp 系在 libsystem_platform 里（老系统在 libSystem.B）。
    // ⚠️ 只能用 interpose 表的 replacee 取真身：dlsym 会被 interpose 污染（拿回来的是我们自己 ⇒ 自我保护 NULL
    //    ⇒ 上次兜底 abort() 直接把黑屏变成闪退，崩溃报告 worldflipper-2026-10-17-211731.ips 就是那次）。
    gOrigLongjmp    = (void (*)(jmp_buf, int))spcn_original_of((const void *)spcn_longjmp);
    gOrigLongjmpU   = (void (*)(jmp_buf, int))spcn_original_of((const void *)spcn__longjmp);
    gOrigSiglongjmp = (void (*)(sigjmp_buf, int))spcn_original_of((const void *)spcn_siglongjmp);
    if (gOrigLongjmp    == spcn_longjmp)    gOrigLongjmp    = NULL;   // 表里指回我们自己 ⇒ 当作没拿到
    if (gOrigLongjmpU   == spcn__longjmp)   gOrigLongjmpU   = NULL;
    if (gOrigSiglongjmp == spcn_siglongjmp) gOrigSiglongjmp = NULL;

    // 文件访问探针的原函数（同样只能从 interpose 表取）
    gOrigOpen   = (int (*)(const char *, int, ...))spcn_original_of((const void *)spcn_open);
    gOrigOpenat = (int (*)(int, const char *, int, ...))spcn_original_of((const void *)spcn_openat);
    gOrigFopen  = (FILE *(*)(const char *, const char *))spcn_original_of((const void *)spcn_fopen);
    if (gOrigOpen   == spcn_open)   gOrigOpen   = NULL;
    if (gOrigOpenat == spcn_openat) gOrigOpenat = NULL;
    if (gOrigFopen  == spcn_fopen)  gOrigFopen  = NULL;

    // 身份谎报（<DATA>/spcn-conf.plist 里配）
    NSDictionary *conf = [NSDictionary dictionaryWithContentsOfFile:
        [NSString stringWithFormat:@"%@/spcn-conf.plist", [SpCnConfig shared].dataDir]];
    id lie = conf[@"IdentityLie"];
    if ([lie isKindOfClass:[NSString class]] && [lie length]) {
        gLieTo = lie;
        id secs = conf[@"IdentityLieSeconds"];
        if ([secs respondsToSelector:@selector(doubleValue)]) gLieSeconds = [secs doubleValue];
    }

    Method m = class_getInstanceMethod([NSBundle class], @selector(bundleIdentifier));
    if (m) {
        gOrigBundleIdentifier = (NSString *(*)(id, SEL))method_getImplementation(m);
        method_setImplementation(m, (IMP)spcn_bundleIdentifier);
    }
    Method mo = class_getInstanceMethod([NSBundle class], @selector(objectForInfoDictionaryKey:));
    if (mo) {
        gOrigObjectForInfo = (id (*)(id, SEL, NSString *))method_getImplementation(mo);
        method_setImplementation(mo, (IMP)spcn_objectForInfoDictionaryKey);
    }
    Method md = class_getInstanceMethod([NSBundle class], @selector(infoDictionary));
    if (md) {
        gOrigInfoDictionary = (NSDictionary *(*)(id, SEL))method_getImplementation(md);
        method_setImplementation(md, (IMP)spcn_infoDictionary);
    }
    Method mp = class_getInstanceMethod([NSBundle class], @selector(pathForResource:ofType:inDirectory:));
    if (mp) {
        gOrigPathForResource = (id (*)(id, SEL, NSString *, NSString *, NSString *))method_getImplementation(mp);
        method_setImplementation(mp, (IMP)spcn_pathForResource);
    }
    Method mr = class_getClassMethod([NSData class], @selector(dataWithContentsOfFile:));
    if (mr) {
        gOrigDataWithContentsOfFile = (id (*)(id, SEL, NSString *))method_getImplementation(mr);
        method_setImplementation(mr, (IMP)spcn_dataWithContentsOfFile);
    }

    [SpCnLog line:@"[DIAG] 身份诊断已装：异常 interpose=%@/%@，entitlements=%@，CFBundleGetIdentifier=%@，CFBundleGetValue=%@，swizzle bundleIdentifier=%@ / objectForInfoDictionaryKey=%@ / infoDictionary=%@ / pathForResource=%@ / NSData读=%@，longjmp interpose=%@/%@/%@，谎报=%@（%.0fs）",
        gOrigObjcThrow ? @"ok" : @"nil", gOrigCxaThrow ? @"ok" : @"nil",
        gOrigSecTask ? @"ok" : @"nil",
        gOrigCFBundleGetIdentifier ? @"ok" : @"nil", gOrigCFBundleGetValue ? @"ok" : @"nil",
        gOrigBundleIdentifier ? @"ok" : @"nil", gOrigObjectForInfo ? @"ok" : @"nil",
        gOrigInfoDictionary ? @"ok" : @"nil",
        gOrigPathForResource ? @"ok" : @"nil", gOrigDataWithContentsOfFile ? @"ok" : @"nil",
        gOrigLongjmp ? @"ok" : @"nil", gOrigLongjmpU ? @"ok" : @"nil", gOrigSiglongjmp ? @"ok" : @"nil",
        gLieTo.length ? gLieTo : @"关", gLieSeconds];
}
