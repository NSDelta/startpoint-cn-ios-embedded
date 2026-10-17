// SpCnPanelViewController —— 悬浮窗（状态 / 开关 / 日志 / 后台入口）
//
// 这一层是"后台"的人机界面：用户看到的只有这个面板 + 一个悬浮球。
// 面板本身**不含输入框**（避开键盘与 key window 的纠缠）；需要输入的后台网页走
// 宿主窗口的 presentViewController（见本文件末尾的 SpCnAdminWebViewController）。
#import <UIKit/UIKit.h>

@interface SpCnPanelViewController : UIViewController

/// 刷新状态与日志（悬浮层展开时调用；另有 2s 定时器自刷）。
- (void)reloadAll;

@end
