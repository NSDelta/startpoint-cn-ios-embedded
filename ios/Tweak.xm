// ─────────────────────────────────────────────────────────────────────────────
// Tweak.xm —— 入口（越狱 deb 与非越狱注入共用）
//
// 纪律（照 SpLogin / CdnImporter 两条线的既有做法）：
//   1. 只做一件事：挂起 Supervisor（后台 node 服务端）+ Overlay（悬浮球/悬浮窗）。
//   2. 不 hook 任何官方类名/方法 —— 越狱线的注入是 substrate 过滤器的事，
//      非越狱线是 Mach-O load command 的事，代码里两者都不依赖。
//   3. constructor 里不碰 UI：等 UIApplicationDidFinishLaunchingNotification，
//      另加 1.5s 定时兜底（冷启动竞态），两条路都走幂等的 -attach。
//   4. 任何异常都不许让游戏起不来：整段 @try/@catch，失败只写日志。
//   5. **后端启动与 UI 挂载解耦**：悬浮球立刻挂，node 延后 N 秒（见 SpCnScheduleBackend）。
// ─────────────────────────────────────────────────────────────────────────────

#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import "src/SpCnLog.h"
#import "src/SpCnConfig.h"
#import "src/SpCnSupervisor.h"
#import "src/SpCnOverlay.h"

static BOOL SpCnShouldAttach(void) {
    // 越狱线：substrate 过滤器已限定 com.leiting.wf；非越狱线：dylib 只注入进这个包。
    // 双保险：bundle id 或可执行名任一命中即干活（bundleId 可能被 patchBundleIdCheck 改过装第二份）。
    NSString *bid = [NSBundle mainBundle].bundleIdentifier ?: @"";
    NSString *exe = [NSBundle mainBundle].infoDictionary[@"CFBundleExecutable"] ?: @"";
    return [bid isEqualToString:@"com.leiting.wf"] || [bid isEqualToString:@"com.testdj.wf"] || [exe isEqualToString:@"worldflipper"];
}

#pragma mark - 悬浮球/悬浮窗（永远最先挂）

static void SpCnAttachUI(NSString *reason) {
    @try {
        [SpCnLog line:@"[BOOT] attach (%@) pid=%d", reason, getpid()];
        [[SpCnOverlay shared] attachWithReason:reason];
    } @catch (NSException *e) {
        [SpCnLog line:@"[BOOT] attach 异常：%@", e];
    }
}

#pragma mark - 后端启动（延后）

/// 后端启动延迟秒数：<DATA_DIR>/spcn-conf.plist 的 `StartupDelay`，缺省 4 秒，0 = 立刻。
static double SpCnStartupDelay(void) {
    @try {
        NSString *dir = [SpCnConfig shared].dataDir;
        if (dir.length) {
            NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:
                               [dir stringByAppendingPathComponent:@"spcn-conf.plist"]];
            if (d[@"StartupDelay"] != nil) return [d[@"StartupDelay"] doubleValue];
        }
    } @catch (NSException *e) { }
    return 4.0;
}

static void SpCnStartBackend(NSString *reason) {
    @try {
        [SpCnLog line:@"[BOOT] 启动后端（%@）", reason];
        [[SpCnSupervisor shared] startWithReason:reason];
    } @catch (NSException *e) {
        [SpCnLog line:@"[BOOT] 启动后端异常：%@", e];
    }
}

/// 把后端启动推迟到游戏主循环稳定之后。理由有两条，都来自真机实测：
///   ① dlopen 55 MB 的 NodeMobile.framework 再起 V8，要占主线程数百毫秒到数秒、吃 150–250 MB 内存；
///      在 didFinishLaunching 那一刻做这件事，会和 AIR 的内容加载抢资源（真机症状：黑屏/白屏进不去）。
///   ② 日志里 [BOOT] 与 [SUP] 之间会隔开这段延迟 ⇒ 能一眼区分「游戏自己黑屏」还是「后端把它搞黑」。
static void SpCnScheduleBackend(NSString *reason) {
    static BOOL scheduled = NO;
    if (scheduled) return;
    scheduled = YES;

    double delay = SpCnStartupDelay();
    if (delay <= 0.05) { SpCnStartBackend([reason stringByAppendingString:@"+立即"]); return; }

    [SpCnLog line:@"[BOOT] 后端启动推迟 %.1fs（偏好 StartupDelay，留给 AIR 内容加载）", delay];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        SpCnStartBackend([reason stringByAppendingString:@"+delay"]);
    });
}

__attribute__((constructor))
static void SpCnEmbeddedInit(void) {
    @autoreleasepool {
        if (!SpCnShouldAttach()) return;

        // 日志先落到容器 tmp（DATA_DIR 要等 Config 探测完才能确定，后面会切过去）
        [SpCnLog bootstrap];
        [SpCnLog line:@"[BOOT] SpCnEmbedded constructor，bundle=%@", [NSBundle mainBundle].bundlePath];

        // 同一份 dylib 可能同时存在两份：越狱 deb 装一份 + 又装了一个带注入 dylib 的 IPA（或用户重打包两次）。
        // ObjC 运行时对同名类只认先注册的那个 ⇒ 本份代码里的 [SpCnOverlay class] 与运行时认的不是同一个类，
        // 那就说明「我不是被认的那一份」⇒ 直接退出，否则会出现两套悬浮球 + 两个 node 抢 8001 端口。
        Class registeredOverlay = NSClassFromString(@"SpCnOverlay");
        if (registeredOverlay && registeredOverlay != [SpCnOverlay class]) {
            [SpCnLog line:@"[BOOT] 另一个 dylib 已注册 SpCnOverlay（%p ≠ %p）⇒ 本份不启动",
                           registeredOverlay, [SpCnOverlay class]];
            return;
        }

        static BOOL scheduled = NO;
        if (scheduled) return;
        scheduled = YES;

        NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
        [nc addObserverForName:UIApplicationDidFinishLaunchingNotification
                        object:nil queue:[NSOperationQueue mainQueue]
                    usingBlock:^(NSNotification *n) {
            SpCnAttachUI(@"didFinishLaunching");
            SpCnScheduleBackend(@"didFinishLaunching");
        }];

        // 兜底：有些启动路径（后台唤起/热启动）不重发 didFinishLaunching
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            SpCnAttachUI(@"timer");
            SpCnScheduleBackend(@"timer");
        });
    }
}
