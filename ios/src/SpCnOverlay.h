// SpCnOverlay —— 悬浮球 + 悬浮窗（独立 UIWindow，绝不抢 key window）
//
// 纪律（逐条来自 SpLogin 线在真机上踩出来的教训，别改）：
//   1. 独立 UIWindow，`windowLevel = UIWindowLevelStatusBar + 100`；只 `hidden = NO`，
//      **绝不 makeKeyAndVisible** —— 否则会抢走游戏窗口的 key 状态，输入/切后台全乱。
//   2. 空白处必须穿透：容器视图重写 -hitTest:withEvent:，命中自身时返回 nil。
//   3. 挂载幂等，并且三路保活：didFinishLaunching（Tweak.xm 调）+ 1.5s 定时兜底 +
//      UIWindowDidBecomeKeyNotification 再来一次（游戏切前台会重排窗口层级）。
//   4. 悬浮球 52×52、可拖拽并 clamp 在安全区内、位置持久化；点击开合面板。
//   5. 需要键盘的界面（后台 WKWebView）不在本窗口里做 —— 走宿主窗口的 presentViewController。
#import <UIKit/UIKit.h>

@interface SpCnOverlay : NSObject

@property (nonatomic, readonly) BOOL panelVisible;

+ (instancetype)shared;

/// 幂等挂载（可重复调用）。
- (void)attachWithReason:(NSString *)reason;
- (void)setPanelVisible:(BOOL)visible;
- (void)togglePanel;

@end
