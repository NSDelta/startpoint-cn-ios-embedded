#import "SpCnOverlay.h"
#import "SpCnLog.h"
#import "SpCnConfig.h"
#import "SpCnSupervisor.h"
#import "SpCnPanelViewController.h"

#pragma mark - 空白穿透容器

@interface SpCnPassView : UIView
@end

@implementation SpCnPassView
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *v = [super hitTest:point withEvent:event];
    return (v == self) ? nil : v;         // 命中自己 = 空白处 ⇒ 穿透给游戏
}
@end

#pragma mark - 空白穿透根视图控制器

// ⚠️ 2026-10-17 23:2x 实机事故：窗口根 VC 用的是普通 UIViewController，它的 view 是全屏普通 UIView
//    ⇒ 球以外的点 hitTest 会命中「根视图自己」⇒ 整个窗口把游戏的手势全吃掉（用户报「标题页点不动」）。
//    修法：根 VC 的 view 也用 SpCnPassView（命中自己就返回 nil），这样球/面板以外的触摸会落到下面游戏窗口。
@interface SpCnPassViewController : UIViewController
@end

@implementation SpCnPassViewController
- (void)loadView {
    SpCnPassView *v = [[SpCnPassView alloc] initWithFrame:[UIScreen mainScreen].bounds];
    v.backgroundColor = [UIColor clearColor];
    v.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.view = v;
}
@end

#pragma mark - 穿透窗口（★ 触控问题的真正修法）

// 照 SPLogin-iOS 的实战结论（D:\wfcnmod\ios-ref-clone\SpLoginOverlay.m 头部注释 + SpLoginOverlayWindow）：
//   `UIWindow.hitTest:` 在**所有子视图都不认这次触摸**时会返回**窗口自己**，UIKit 于是把这次触摸算给我们的
//   覆盖窗口，游戏窗口一个事件都收不到 —— 只让某个 view 在空白处返回 nil **并不够**。
//   所以必须把窗口本身也换成「命中自己/穿透视图 ⇒ nil」的子类。
//   （实机症状：球在时游戏点不动；把整层关掉（Overlay=0）立刻恢复正常 ⇒ 就是这一层吃掉了手势。）
@interface SpCnOverlayWindow : UIWindow
@end

@implementation SpCnOverlayWindow
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *hit = [super hitTest:point withEvent:event];
    if (hit == self || [hit isKindOfClass:[SpCnPassView class]]) return nil;   // 空白 ⇒ 交给下层游戏窗口
    return hit;
}
@end

#pragma mark - 悬浮球

@interface SpCnBallButton : UIButton
@end

@implementation SpCnBallButton
- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.backgroundColor = [UIColor colorWithRed:0.13 green:0.47 blue:0.85 alpha:0.92];
        self.layer.cornerRadius = frame.size.width / 2.0;
        self.layer.borderWidth = 1.0;
        self.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.55].CGColor;
        self.layer.shadowColor = [UIColor blackColor].CGColor;
        self.layer.shadowOpacity = 0.35;
        self.layer.shadowRadius = 6.0;
        self.layer.shadowOffset = CGSizeMake(0, 2);
        self.titleLabel.font = [UIFont boldSystemFontOfSize:20];
        [self setTitle:@"弹" forState:UIControlStateNormal];
        [self setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
        self.accessibilityLabel = @"单机服务端";
    }
    return self;
}
@end

#pragma mark - Overlay

@implementation SpCnOverlay {
    UIWindow *_window;
    SpCnPassView *_container;
    SpCnBallButton *_ball;
    SpCnPanelViewController *_panel;
    BOOL _attached;
    BOOL _dragging;
    CGPoint _dragStartCenter;
    NSInteger _attachCount;
}

+ (instancetype)shared {
    static SpCnOverlay *s = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [SpCnOverlay new]; });
    return s;
}

- (BOOL)panelVisible { return _panel.view.superview != nil && !_panel.view.hidden; }

#pragma mark 挂载

- (void)attachWithReason:(NSString *)reason {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self attachWithReason:reason]; });
        return;
    }
    _attachCount++;

    UIWindow *host = [self hostWindow];
    if (!host && !_window) {
        [SpCnLog line:@"[UI] attach(%@) 第 %ld 次：还没有可用宿主窗口，等下一次", reason, (long)_attachCount];
        // 三路保活之一：窗口变 key 时再试（游戏切前台/旋转都会触发）
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(hostWindowBecameKey:)
                                                     name:UIWindowDidBecomeKeyNotification object:nil];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ [self attachWithReason:@"retry"]; });
        return;
    }

    if (_attached && _window) {                       // 幂等：只把窗口重新抬到最上层
        _window.hidden = NO;
        [SpCnLog line:@"[UI] attach(%@) 第 %ld 次：已挂载，仅前置", reason, (long)_attachCount];
        return;
    }

    CGRect screen = host.bounds.size.width > 0 ? host.bounds : [UIScreen mainScreen].bounds;
    _window = [[SpCnOverlayWindow alloc] initWithFrame:screen];
    _window.windowLevel = UIWindowLevelStatusBar + 100;
    _window.backgroundColor = [UIColor clearColor];
    // ★ 必须用穿透型根 VC（见 SpCnPassViewController 注释）：否则整屏手势被吃掉，游戏点不动
    _window.rootViewController = [SpCnPassViewController new];
    _window.rootViewController.view.backgroundColor = [UIColor clearColor];

    _container = [[SpCnPassView alloc] initWithFrame:_window.bounds];
    _container.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [_window.rootViewController.view addSubview:_container];

    // 悬浮球：52×52，位置持久化
    CGFloat side = 52.0;
    CGPoint c = [self storedBallCenterWithDefault:CGPointMake(screen.size.width - side / 2 - 8,
                                                              screen.size.height * 0.35)];
    _ball = [[SpCnBallButton alloc] initWithFrame:CGRectMake(c.x - side / 2, c.y - side / 2, side, side)];
    [_ball addTarget:self action:@selector(ballTapped) forControlEvents:UIControlEventTouchUpInside];
    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(ballPanned:)];
    [_ball addGestureRecognizer:pan];
    [_container addSubview:_ball];

    _window.hidden = NO;                              // ← 只 hidden=NO，绝不 makeKeyAndVisible
    _attached = YES;
    [SpCnLog line:@"[UI] 悬浮球已挂载（%@）球心=(%.0f,%.0f) 屏幕=%.0fx%.0f",
            reason, c.x, c.y, screen.size.width, screen.size.height];
}

- (void)hostWindowBecameKey:(NSNotification *)n {
    if (!_attached) [self attachWithReason:@"hostKey"];
    else if (_window) _window.hidden = NO;
}

- (UIWindow *)hostWindow {
    UIApplication *app = [UIApplication sharedApplication];
    for (UIWindow *w in app.windows) if (w.isKeyWindow) return w;
    if (@available(iOS 13.0, *)) {
        for (UIScene *scene in app.connectedScenes) {
            if (![scene isKindOfClass:[UIWindowScene class]]) continue;
            for (UIWindow *w in ((UIWindowScene *)scene).windows) if (w.isKeyWindow) return w;
        }
    }
    return app.windows.firstObject;
}

#pragma mark 悬浮球交互

- (void)ballTapped {
    if (_dragging) return;
    [self togglePanel];
}

- (void)ballPanned:(UIPanGestureRecognizer *)g {
    CGPoint t = [g translationInView:_container];
    if (g.state == UIGestureRecognizerStateBegan) {
        _dragging = NO;
        _dragStartCenter = _ball.center;
    } else if (g.state == UIGestureRecognizerStateChanged) {
        if (fabs(t.x) > 4 || fabs(t.y) > 4) _dragging = YES;
        _ball.center = CGPointMake(_dragStartCenter.x + t.x, _dragStartCenter.y + t.y);
    } else if (g.state == UIGestureRecognizerStateEnded || g.state == UIGestureRecognizerStateCancelled) {
        CGRect b = _container.bounds;
        CGFloat side = _ball.bounds.size.width;
        CGFloat x = MIN(MAX(_ball.center.x, side / 2 + 4), b.size.width - side / 2 - 4);
        CGFloat y = MIN(MAX(_ball.center.y, 40 + side / 2), b.size.height - side / 2 - 4);
        [UIView animateWithDuration:0.15 animations:^{ self->_ball.center = CGPointMake(x, y); }];
        [[NSUserDefaults standardUserDefaults] setObject:NSStringFromCGPoint(CGPointMake(x, y)) forKey:@"SpCnBallCenter"];
        if (_panel.view.superview) [self layoutPanel];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.2 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ self->_dragging = NO; });
    }
}

- (CGPoint)storedBallCenterWithDefault:(CGPoint)d {
    NSString *s = [[NSUserDefaults standardUserDefaults] stringForKey:@"SpCnBallCenter"];
    return s ? CGPointFromString(s) : d;
}

#pragma mark 面板

- (void)togglePanel { [self setPanelVisible:![self panelVisible]]; }

- (void)setPanelVisible:(BOOL)visible {
    if (!_attached) { [SpCnLog line:@"[UI] 面板请求被忽略：悬浮层还没挂上"]; return; }
    if (!_panel) _panel = [SpCnPanelViewController new];
    if (visible) {
        if (!_panel.view.superview) {
            _window.rootViewController.view.autoresizesSubviews = YES;
            [_window.rootViewController.view addSubview:_panel.view];
        }
        _panel.view.hidden = NO;
        [self layoutPanel];
        [_panel reloadAll];
        [SpCnLog line:@"[UI] 面板已展开"];
    } else {
        _panel.view.hidden = YES;
        [SpCnLog line:@"[UI] 面板已收起"];
    }
}

/// 面板贴着球摆：球在右半屏 ⇒ 面板向左展开，反之亦然；并 clamp 在屏内。
- (void)layoutPanel {
    CGRect b = _container.bounds;
    CGSize ps = CGSizeMake(MIN(340.0, b.size.width - 24.0), MIN(430.0, b.size.height - 80.0));
    CGFloat y = MIN(MAX(_ball.center.y - ps.height / 2, 60.0), b.size.height - ps.height - 20.0);
    BOOL right = _ball.center.x > b.size.width / 2;
    CGFloat x = right ? MAX(12.0, _ball.center.x - ps.width - 24.0) : MIN(b.size.width - ps.width - 12.0, _ball.center.x + 24.0);
    _panel.view.frame = CGRectMake(x, y, ps.width, ps.height);
}

@end
