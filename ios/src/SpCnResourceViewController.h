// SpCnResourceViewController.h —— 资源导入面板（把 CDN 归档铺进游戏容器的 Local Store）
//
// 为什么单独一个 VC：悬浮球面板（SpCnPanelViewController）本身刻意不含输入控件，
// 需要一个能弹系统文件选择器、要进度条、要长日志的界面时，走「present 到宿主 key window 的 rootVC」
// 这条已被后台网页验证过的路径（见 SpCnPanelViewController -presentOnHost:）。
#import <UIKit/UIKit.h>

@interface SpCnResourceViewController : UIViewController
@end
