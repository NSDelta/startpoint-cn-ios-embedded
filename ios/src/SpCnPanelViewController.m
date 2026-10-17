#import "SpCnPanelViewController.h"
#import "SpCnSupervisor.h"
#import "SpCnConfig.h"
#import "SpCnLog.h"
#import "SpCnOverlay.h"
#import "SpCnResourceViewController.h"
#import <WebKit/WebKit.h>

#pragma mark - 后台网页（在宿主窗口上模态呈现，键盘归它自己管）

@interface SpCnAdminWebViewController : UIViewController
@property (nonatomic, copy) NSString *urlString;
@end

@implementation SpCnAdminWebViewController {
    WKWebView *_web;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"后台";
    self.view.backgroundColor = [UIColor systemBackgroundColor];
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone
                                                                                          target:self
                                                                                          action:@selector(done)];
    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemRefresh
                                                                                           target:self
                                                                                           action:@selector(reload)];
    WKWebViewConfiguration *cfg = [WKWebViewConfiguration new];
    _web = [[WKWebView alloc] initWithFrame:self.view.bounds configuration:cfg];
    _web.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self.view addSubview:_web];
    NSURL *u = [NSURL URLWithString:_urlString];
    [SpCnLog line:@"[UI] 打开后台 %@", _urlString];
    [_web loadRequest:[NSURLRequest requestWithURL:u]];
}

- (void)done { [self dismissViewControllerAnimated:YES completion:nil]; }
- (void)reload { [_web loadRequest:[NSURLRequest requestWithURL:[NSURL URLWithString:self.urlString]]]; }

@end

#pragma mark - 面板

@implementation SpCnPanelViewController {
    UILabel *_stateLabel;
    UILabel *_healthLabel;
    UILabel *_runtimeLabel;
    UITextView *_logView;
    UIButton *_startBtn, *_stopBtn, *_restartBtn, *_adminBtn, *_logBtn, *_backendBtn, *_resBtn;
    NSTimer *_timer;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor colorWithWhite:0.08 alpha:0.94];
    self.view.layer.cornerRadius = 14.0;
    self.view.layer.masksToBounds = YES;
    self.view.layer.borderWidth = 1.0;
    self.view.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.18].CGColor;

    CGFloat pad = 12.0;
    CGFloat w = self.view.bounds.size.width;

    UILabel *title = [[UILabel alloc] initWithFrame:CGRectMake(pad, 10, w - 60, 22)];
    title.text = @"世界弹射物语 · 单机服务端";
    title.textColor = [UIColor whiteColor];
    title.font = [UIFont boldSystemFontOfSize:15];
    title.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    [self.view addSubview:title];

    UIButton *close = [UIButton buttonWithType:UIButtonTypeSystem];
    close.frame = CGRectMake(w - 46, 6, 40, 30);
    close.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin;
    [close setTitle:@"✕" forState:UIControlStateNormal];
    [close addTarget:self action:@selector(closeTapped) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:close];

    _stateLabel = [self labelAt:CGRectMake(pad, 34, w - 2 * pad, 18) font:[UIFont systemFontOfSize:13] color:[UIColor systemGreenColor]];
    _healthLabel = [self labelAt:CGRectMake(pad, 52, w - 2 * pad, 18) font:[UIFont systemFontOfSize:11] color:[UIColor colorWithWhite:0.75 alpha:1]];
    _healthLabel.numberOfLines = 2;
    _runtimeLabel = [self labelAt:CGRectMake(pad, 88, w - 2 * pad, 48) font:[UIFont systemFontOfSize:10] color:[UIColor colorWithWhite:0.6 alpha:1]];
    _runtimeLabel.numberOfLines = 5;

    // 按钮行（7 个：启动/停止/重启/后台/资源/日志/后端）
    CGFloat gap = 4.0;
    CGFloat bw = (w - 2 * pad - 6 * gap) / 7.0;
    _startBtn   = [self buttonAt:CGRectMake(pad + 0 * (bw + gap), 140, bw, 32) title:@"启动"];
    _stopBtn    = [self buttonAt:CGRectMake(pad + 1 * (bw + gap), 140, bw, 32) title:@"停止"];
    _restartBtn = [self buttonAt:CGRectMake(pad + 2 * (bw + gap), 140, bw, 32) title:@"重启"];
    _adminBtn   = [self buttonAt:CGRectMake(pad + 3 * (bw + gap), 140, bw, 32) title:@"后台"];
    _resBtn     = [self buttonAt:CGRectMake(pad + 4 * (bw + gap), 140, bw, 32) title:@"资源"];
    _logBtn     = [self buttonAt:CGRectMake(pad + 5 * (bw + gap), 140, bw, 32) title:@"日志"];
    _backendBtn = [self buttonAt:CGRectMake(pad + 6 * (bw + gap), 140, bw, 32) title:@"后端"];

    _logView = [[UITextView alloc] initWithFrame:CGRectMake(pad, 180, w - 2 * pad, self.view.bounds.size.height - 192)];
    _logView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    _logView.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.55];
    _logView.textColor = [UIColor colorWithWhite:0.88 alpha:1];
    _logView.font = [UIFont fontWithName:@"Menlo" size:9] ?: [UIFont systemFontOfSize:9];
    _logView.editable = NO;
    _logView.layer.cornerRadius = 8.0;
    _logView.text = @"（等待日志…）";
    [self.view addSubview:_logView];

    __weak typeof(self) weakSelf = self;
    [SpCnSupervisor shared].onStateChange = ^{ [weakSelf reloadAll]; };
    _timer = [NSTimer scheduledTimerWithTimeInterval:2.0 repeats:YES block:^(NSTimer *t) {
        typeof(self) self_ = weakSelf; if (self_) [self_ reloadAll];
    }];
    [self reloadAll];
}

- (UILabel *)labelAt:(CGRect)f font:(UIFont *)font color:(UIColor *)color {
    UILabel *l = [[UILabel alloc] initWithFrame:f];
    l.font = font; l.textColor = color; l.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    [self.view addSubview:l];
    return l;
}

- (UIButton *)buttonAt:(CGRect)f title:(NSString *)t {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
    b.frame = f;
    b.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.12];
    b.layer.cornerRadius = 7.0;
    b.titleLabel.font = [UIFont systemFontOfSize:12];
    b.titleLabel.adjustsFontSizeToFitWidth = YES;
    b.titleLabel.minimumScaleFactor = 0.7;
    [b setTitle:t forState:UIControlStateNormal];
    [b setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    [self.view addSubview:b];
    if ([t isEqualToString:@"启动"])   [b addTarget:self action:@selector(startTapped) forControlEvents:UIControlEventTouchUpInside];
    if ([t isEqualToString:@"停止"])   [b addTarget:self action:@selector(stopTapped) forControlEvents:UIControlEventTouchUpInside];
    if ([t isEqualToString:@"重启"])   [b addTarget:self action:@selector(restartTapped) forControlEvents:UIControlEventTouchUpInside];
    if ([t isEqualToString:@"后台"])   [b addTarget:self action:@selector(adminTapped) forControlEvents:UIControlEventTouchUpInside];
    if ([t isEqualToString:@"资源"])   [b addTarget:self action:@selector(resourceTapped) forControlEvents:UIControlEventTouchUpInside];
    if ([t isEqualToString:@"日志"])   [b addTarget:self action:@selector(logTapped) forControlEvents:UIControlEventTouchUpInside];
    if ([t isEqualToString:@"后端"])   [b addTarget:self action:@selector(backendTapped) forControlEvents:UIControlEventTouchUpInside];
    return b;
}

#pragma mark 动作

- (void)closeTapped { [[SpCnOverlay shared] setPanelVisible:NO]; }
- (void)startTapped   { [[SpCnSupervisor shared] startWithReason:@"panel"]; [self reloadAll]; }
- (void)stopTapped    { [[SpCnSupervisor shared] stopWithReason:@"panel"];  [self reloadAll]; }
- (void)restartTapped { [[SpCnSupervisor shared] restart];                  [self reloadAll]; }
- (void)logTapped     { [self reloadAll]; }

/// 后端切换：auto → process → framework → auto（写进 <DATA_DIR>/spcn-conf.plist，下一次启动生效）
- (void)backendTapped {
    SpCnConfig *cfg = [SpCnConfig shared];
    NSString *cur = cfg.backendPref ?: @"auto";
    NSString *next = [cur isEqualToString:@"auto"] ? @"process"
                   : ([cur isEqualToString:@"process"] ? @"framework" : @"auto");
    NSError *e = nil;
    if ([cfg setBackendPreference:next error:&e]) {
        [SpCnLog line:@"[UI] 后端偏好 %@ → %@（当前实际：%@）", cur, next, cfg.effectiveBackend];
    } else {
        [SpCnLog line:@"[UI] 后端切换失败：%@", e.localizedDescription];
    }
    [self reloadAll];
}

- (void)adminTapped {
    SpCnSupervisor *sup = [SpCnSupervisor shared];
    if (sup.state != SpCnServerStateRunning && sup.state != SpCnServerStateAdopted) {
        [SpCnLog line:@"[UI] 服务端未运行，先把后台拉起来"];
        [sup startWithReason:@"admin"];
    }
    NSString *base = [SpCnConfig shared].httpBase;
    SpCnAdminWebViewController *vc = [SpCnAdminWebViewController new];
    vc.urlString = [base stringByAppendingString:@"/admin/"];
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:vc];
    UIViewController *host = [self hostRootViewController];
    if (!host) { [SpCnLog line:@"[UI] 找不到宿主 VC，后台打不开"]; return; }
    [host presentViewController:nav animated:YES completion:nil];
}

/// 资源导入面板：与后台网页同一条呈现路径（present 在宿主 key window 的 rootVC 上）
- (void)resourceTapped {
    UIViewController *host = [self hostRootViewController];
    if (!host) { [SpCnLog line:@"[UI] 找不到宿主 VC，资源面板打不开"]; return; }
    SpCnResourceViewController *vc = [SpCnResourceViewController new];
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:vc];
    [host presentViewController:nav animated:YES completion:nil];
}

- (UIViewController *)hostRootViewController {
    UIApplication *app = [UIApplication sharedApplication];
    UIWindow *key = nil;
    for (UIWindow *w in app.windows) if (w.isKeyWindow) { key = w; break; }
    if (!key) key = app.windows.firstObject;
    UIViewController *vc = key.rootViewController;
    while (vc.presentedViewController) vc = vc.presentedViewController;
    return vc;
}

#pragma mark 刷新

- (void)reloadAll {
    SpCnSupervisor *sup = [SpCnSupervisor shared];
    _stateLabel.text = [NSString stringWithFormat:@"● %@", sup.stateText];
    switch (sup.state) {
        case SpCnServerStateRunning:
        case SpCnServerStateAdopted:  _stateLabel.textColor = [UIColor systemGreenColor]; break;
        case SpCnServerStateStarting: _stateLabel.textColor = [UIColor systemYellowColor]; break;
        case SpCnServerStateFailed:   _stateLabel.textColor = [UIColor systemRedColor]; break;
        default:                      _stateLabel.textColor = [UIColor lightGrayColor]; break;
    }
    // 内嵌后端与游戏同进程：停止/重启不可用（灰掉，避免误以为点了没反应）
    BOOL canStop = sup.canStop;
    _stopBtn.enabled = _restartBtn.enabled = canStop;
    _stopBtn.alpha = _restartBtn.alpha = canStop ? 1.0 : 0.4;

    NSString *h = sup.healthText;
    if (sup.lastError.length) h = [NSString stringWithFormat:@"%@\n%@", h, sup.lastError];
    _healthLabel.text = h;
    _runtimeLabel.text = [[SpCnConfig shared] summary];

    NSArray<NSString *> *lines = [SpCnLog recentLines];
    NSMutableString *s = [NSMutableString string];
    for (NSString *l in lines) [s appendFormat:@"%@\n", l];
    [s appendString:@"\n── 服务端 stdout/stderr ──\n"];
    [s appendString:[[SpCnSupervisor shared] tailOfServerLog:6000]];
    _logView.text = s;
    if (s.length > 2) [_logView scrollRangeToVisible:NSMakeRange(s.length - 2, 1)];
}

@end
