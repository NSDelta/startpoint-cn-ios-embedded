#import "SpCnLogViewController.h"
#import "SpCnLog.h"
#import "SpCnConfig.h"
#import "SpCnSupervisor.h"

@interface SpCnLogViewController ()
@property (nonatomic, strong) UITextView *textView;
@property (nonatomic, strong) UILabel *hint;
@property (nonatomic, strong) NSTimer *timer;
@property (nonatomic, assign) BOOL paused;
@property (nonatomic, assign) NSUInteger lastLength;
@end

@implementation SpCnLogViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"日志";
    self.view.backgroundColor = [UIColor systemBackgroundColor];

    self.navigationItem.rightBarButtonItem =
        [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone
                                                      target:self action:@selector(doneTapped)];

    NSArray<NSString *> *titles = @[ @"暂停", @"复制全部", @"导出", @"刷新" ];
    UISegmentedControl *seg = [[UISegmentedControl alloc] initWithItems:titles];
    seg.selectedSegmentIndex = UISegmentedControlNoSegment;
    [seg addTarget:self action:@selector(segmentChanged:) forControlEvents:UIControlEventValueChanged];
    seg.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:seg];

    _hint = [[UILabel alloc] init];
    _hint.font = [UIFont systemFontOfSize:11];
    _hint.textColor = [UIColor secondaryLabelColor];
    _hint.numberOfLines = 2;
    _hint.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:_hint];

    _textView = [[UITextView alloc] init];
    _textView.editable = NO;
    _textView.selectable = YES;                     // ← 能选中才有「拷贝」菜单
    _textView.alwaysBounceVertical = YES;
    _textView.font = [UIFont fontWithName:@"Menlo" size:10] ?: [UIFont systemFontOfSize:10];
    _textView.textContainerInset = UIEdgeInsetsMake(6, 6, 6, 6);
    _textView.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:_textView];

    UILayoutGuide *g = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [seg.topAnchor constraintEqualToAnchor:g.topAnchor constant:8],
        [seg.leadingAnchor constraintEqualToAnchor:g.leadingAnchor constant:10],
        [seg.trailingAnchor constraintEqualToAnchor:g.trailingAnchor constant:-10],
        [seg.heightAnchor constraintEqualToConstant:32],
        [_hint.topAnchor constraintEqualToAnchor:seg.bottomAnchor constant:6],
        [_hint.leadingAnchor constraintEqualToAnchor:g.leadingAnchor constant:12],
        [_hint.trailingAnchor constraintEqualToAnchor:g.trailingAnchor constant:-12],
        [_textView.topAnchor constraintEqualToAnchor:_hint.bottomAnchor constant:6],
        [_textView.leadingAnchor constraintEqualToAnchor:g.leadingAnchor constant:8],
        [_textView.trailingAnchor constraintEqualToAnchor:g.trailingAnchor constant:-8],
        [_textView.bottomAnchor constraintEqualToAnchor:g.bottomAnchor constant:-8],
    ]];

    [self reloadKeepSelection:NO];
    __weak typeof(self) weakSelf = self;
    _timer = [NSTimer scheduledTimerWithTimeInterval:2.0 repeats:YES block:^(NSTimer *t) {
        typeof(self) self_ = weakSelf; if (self_) [self_ reloadKeepSelection:YES];
    }];
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    [_timer invalidate]; _timer = nil;
}

- (NSString *)composeText {
    NSMutableString *s = [NSMutableString string];
    for (NSString *l in [SpCnLog recentLines]) [s appendFormat:@"%@\n", l];
    [s appendString:@"\n── 服务端 stdout/stderr ──\n"];
    [s appendString:[[SpCnSupervisor shared] tailOfServerLog:200000]];
    return s;
}

/// 刷新。有选区时**不重设 text**（否则选区被冲掉，这正是面板那条日志不能复制的原因）。
- (void)reloadKeepSelection:(BOOL)keep {
    NSString *s = [self composeText];
    BOOL hasSelection = (_textView.selectedRange.length > 0);
    if (keep && (self.paused || hasSelection)) {
        _hint.text = [NSString stringWithFormat:@"%@（共 %lu 字；%@）",
                      [self statusLine], (unsigned long)s.length,
                      self.paused ? @"已暂停刷新" : @"有选区，暂不刷新以免冲掉选择"];
        return;
    }
    if (![s isEqualToString:_textView.text]) {
        _textView.text = s;
        _lastLength = s.length;
        if (s.length > 2) [_textView scrollRangeToVisible:NSMakeRange(s.length - 2, 1)];
    }
    _hint.text = [NSString stringWithFormat:@"%@（共 %lu 字）", [self statusLine], (unsigned long)_lastLength];
}

- (NSString *)statusLine {
    SpCnConfig *cfg = [SpCnConfig shared];
    return [NSString stringWithFormat:@"后端 %@ · 状态 %@ · 日志文件 %@",
            [cfg backendText], [SpCnSupervisor shared].stateText,
            cfg.logPath.lastPathComponent ?: @"(无)"];
}

#pragma mark 动作

- (void)segmentChanged:(UISegmentedControl *)seg {
    NSInteger i = seg.selectedSegmentIndex;
    seg.selectedSegmentIndex = UISegmentedControlNoSegment;
    if (i == 0) {                       // 暂停/继续
        self.paused = !self.paused;
        _hint.text = self.paused ? @"已暂停刷新（仍可选中/复制）" : @"已继续刷新";
        if (!self.paused) [self reloadKeepSelection:NO];
    } else if (i == 1) {                // 复制全部
        [self copyAll];
    } else if (i == 2) {                // 导出
        [self exportTapped];
    } else {                            // 刷新
        [self reloadKeepSelection:NO];
    }
}

- (void)copyAll {
    NSString *s = _textView.text ?: @"";
    if (!s.length) { _hint.text = @"没有可复制的内容"; return; }
    [UIPasteboard generalPasteboard].string = s;
    [SpCnLog line:@"[UI] 日志已复制到剪贴板（%lu 字）", (unsigned long)s.length];
    _hint.text = [NSString stringWithFormat:@"已复制 %lu 字到剪贴板", (unsigned long)s.length];
}

- (void)exportTapped {
    NSString *text = [self composeText];
    NSDateFormatter *f = [NSDateFormatter new];
    f.dateFormat = @"yyyyMMdd-HHmmss";
    NSString *name = [NSString stringWithFormat:@"SpCnLog-%@.txt", [f stringFromDate:[NSDate date]]];
    NSString *dir = [SpCnConfig shared].dataDir ?: NSTemporaryDirectory();
    NSString *path = [dir stringByAppendingPathComponent:name];
    NSError *e = nil;
    if (![text writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:&e]) {
        [SpCnLog line:@"[UI] 日志导出失败：%@", e.localizedDescription];
        _hint.text = [NSString stringWithFormat:@"导出失败：%@", e.localizedDescription];
        return;
    }
    [SpCnLog line:@"[UI] 日志已导出：%@（%lu 字）", path, (unsigned long)text.length];
    _hint.text = [NSString stringWithFormat:@"已导出 %@", path];

    UIActivityViewController *av = [[UIActivityViewController alloc]
        initWithActivityItems:@[ [NSURL fileURLWithPath:path], text ] applicationActivities:nil];
    av.popoverPresentationController.sourceView = self.view;
    av.popoverPresentationController.sourceRect = self.view.bounds;
    [self presentViewController:av animated:YES completion:nil];
}

- (void)doneTapped { [self dismissViewControllerAnimated:YES completion:nil]; }

@end
