#import <UIKit/UIKit.h>

/// 独立日志页。
///
/// 为什么要单独一个页面：悬浮窗面板里那条日志视图每 2 秒被 `reloadAll` 重设一次 text，
/// 任何选区/复制菜单都会被立刻冲掉（真机反馈「日志无法复制也无法导出」）。
/// 这一页把刷新与选择解耦：可暂停、可全选、一键复制全部、导出成 txt 再走系统分享面板。
@interface SpCnLogViewController : UIViewController
@end
