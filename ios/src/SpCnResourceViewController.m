// SpCnResourceViewController.m —— 资源导入面板
//
// 它只做四件事：① 选源目录（系统文件选择器，open-in-place 拿真路径）② 扫描 ③ 导入（进度 + 日志）④ 取消。
// 真正的引擎在 SpCnResourceImporter（移植自 wf-cdn-importer-iOS），本类不含任何归档解析逻辑。
//
// 关键点（踩过才知道）：
//   * 游戏是沙盒 App，源目录通常在沙盒外 ⇒ 必须 startAccessingSecurityScopedResource，
//     并且**整个导入期间都要持有这个 URL**（提前 stop 会让读文件 EPERM）；
//   * 默认源目录候选包含数据卷里的 `cdn-in/`（把归档丢进去最省事）+ 越狱常见的 /var/mobile 几个位置；
//   * 文本选择器用 iOS 14 就能用的 `initWithDocumentTypes:inMode:`（`public.folder`），
//     不引 UniformTypeIdentifiers 框架（少一个链接项；-Wno-deprecated-declarations 已开）。
#import "SpCnResourceViewController.h"
#import "SpCnResourceImporter.h"
#import "SpCnConfig.h"
#import "SpCnLog.h"

@interface SpCnResourceViewController () <UIDocumentPickerDelegate>
@property (nonatomic, strong) UILabel *stateLabel;
@property (nonatomic, strong) UILabel *sourceLabel;
@property (nonatomic, strong) UILabel *targetLabel;
@property (nonatomic, strong) UIProgressView *progressView;
@property (nonatomic, strong) UITextView *logView;
@property (nonatomic, strong) UIButton *scanButton;
@property (nonatomic, strong) UIButton *importButton;
@property (nonatomic, strong) UIButton *cancelButton;
@property (nonatomic, strong) NSURL *sourceScopedURL;   // 持有 security scope 直到面板关闭
@property (nonatomic, strong) NSTimer *refreshTimer;
@end

@implementation SpCnResourceViewController

- (void)viewDidLoad
{
    [super viewDidLoad];
    self.title = @"资源导入";
    self.view.backgroundColor = [UIColor systemBackgroundColor];

    UINavigationBar *bar = [[UINavigationBar alloc] initWithFrame:CGRectMake(0, 0, self.view.bounds.size.width, 88)];
    bar.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    UINavigationItem *item = [[UINavigationItem alloc] initWithTitle:@"资源导入"];
    item.rightBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone
                                                                           target:self action:@selector(closeTapped)];
    [bar pushNavigationItem:item animated:NO];
    [self.view addSubview:bar];

    CGFloat top = 96, pad = 12, w = self.view.bounds.size.width;
    self.stateLabel = [self labelAt:CGRectMake(pad, top, w - pad * 2, 20) size:15 bold:YES];
    self.sourceLabel = [self labelAt:CGRectMake(pad, top + 22, w - pad * 2, 32) size:12 bold:NO];
    self.sourceLabel.numberOfLines = 2;
    self.sourceLabel.textColor = [UIColor secondaryLabelColor];
    self.targetLabel = [self labelAt:CGRectMake(pad, top + 56, w - pad * 2, 32) size:12 bold:NO];
    self.targetLabel.numberOfLines = 2;
    self.targetLabel.textColor = [UIColor secondaryLabelColor];

    self.progressView = [[UIProgressView alloc] initWithFrame:CGRectMake(pad, top + 92, w - pad * 2, 4)];
    [self.view addSubview:self.progressView];

    // 按钮两行：① 选目录 / 扫描 / 导入  ② 取消 / 默认源 / 定位归档
    NSArray *titles = @[ @"选目录…", @"扫描", @"导入" ];
    NSArray *sels = @[ @"pickTapped", @"scanTapped", @"importTapped" ];
    CGFloat bw = (w - pad * 2 - 2 * 8) / 3.0, by = top + 104;
    for (NSUInteger i = 0; i < titles.count; i++) {
        UIButton *b = [self buttonAt:CGRectMake(pad + i * (bw + 8), by, bw, 38) title:titles[i]
                              action:NSSelectorFromString(sels[i])];
        [self.view addSubview:b];
        if (i == 1) self.scanButton = b;
        if (i == 2) self.importButton = b;
    }
    NSArray *titles2 = @[ @"取消", @"默认源", @"打开目录" ];
    NSArray *sels2 = @[ @"cancelTapped", @"defaultSourceTapped", @"openTargetTapped" ];
    for (NSUInteger i = 0; i < titles2.count; i++) {
        UIButton *b = [self buttonAt:CGRectMake(pad + i * (bw + 8), by + 46, bw, 38) title:titles2[i]
                              action:NSSelectorFromString(sels2[i])];
        [self.view addSubview:b];
        if (i == 0) self.cancelButton = b;
    }

    CGFloat logY = by + 92;
    self.logView = [[UITextView alloc] initWithFrame:CGRectMake(pad, logY, w - pad * 2, self.view.bounds.size.height - logY - 12)];
    self.logView.autoresizingMask = UIViewAutoresizingFlexibleHeight | UIViewAutoresizingFlexibleWidth;
    self.logView.editable = NO;
    self.logView.font = [UIFont fontWithName:@"Menlo" size:9] ?: [UIFont systemFontOfSize:9];
    self.logView.textColor = [UIColor labelColor];
    self.logView.backgroundColor = [UIColor secondarySystemBackgroundColor];
    self.logView.layer.cornerRadius = 6;
    [self.view addSubview:self.logView];

    __weak typeof(self) weakSelf = self;
    [SpCnResourceImporter shared].onChange = ^{ [weakSelf refresh]; };
    // onChange 是「有变化才调」；再加一条 1 s 兜底轮询，保证进度/日志不会停在旧值
    self.refreshTimer = [NSTimer scheduledTimerWithTimeInterval:1.0 target:self selector:@selector(refresh) userInfo:nil repeats:YES];

    NSString *def = [self defaultSourceDir];
    self.sourceLabel.text = def ? [@"默认源：" stringByAppendingString:def] : @"默认源：未找到（点「选目录…」指定）";
    [self refresh];
}

- (void)viewDidDisappear:(BOOL)animated
{
    [super viewDidDisappear:animated];
    [self.refreshTimer invalidate];
    self.refreshTimer = nil;
    [SpCnResourceImporter shared].onChange = nil;
    // 释放 security scope（尽量晚 —— 导入可能还在跑，交给 importer 自己读完）
    if (self.sourceScopedURL) { [self.sourceScopedURL stopAccessingSecurityScopedResource]; self.sourceScopedURL = nil; }
}

#pragma mark - UI 小工具

- (UILabel *)labelAt:(CGRect)frame size:(CGFloat)size bold:(BOOL)bold
{
    UILabel *l = [[UILabel alloc] initWithFrame:frame];
    l.font = bold ? [UIFont boldSystemFontOfSize:size] : [UIFont systemFontOfSize:size];
    l.textColor = bold ? [UIColor labelColor] : [UIColor secondaryLabelColor];
    [self.view addSubview:l];
    return l;
}

- (UIButton *)buttonAt:(CGRect)frame title:(NSString *)title action:(SEL)action
{
    UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
    b.frame = frame;
    [b setTitle:title forState:UIControlStateNormal];
    b.titleLabel.font = [UIFont systemFontOfSize:14];
    b.backgroundColor = [UIColor secondarySystemBackgroundColor];
    b.layer.cornerRadius = 6;
    [b addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    return b;
}

#pragma mark - 刷新

- (void)refresh
{
    SpCnResourceImporter *imp = [SpCnResourceImporter shared];
    self.stateLabel.text = imp.statusText ?: @"空闲";
    self.stateLabel.textColor = (imp.state == SpCnImportStateFailed) ? [UIColor systemRedColor]
                              : (imp.state == SpCnImportStateDone) ? [UIColor systemGreenColor]
                              : [UIColor labelColor];
    self.progressView.progress = (float)MAX(0.0, MIN(1.0, imp.progress));
    if (imp.targetDir.length) self.targetLabel.text = [@"目标：" stringByAppendingString:imp.targetDir];

    BOOL scanning = (imp.state == SpCnImportStateScanning || imp.state == SpCnImportStateImporting);
    self.scanButton.enabled = !scanning;
    self.importButton.enabled = (imp.state == SpCnImportStateReady);
    self.cancelButton.enabled = scanning;
    for (UIButton *b in @[ self.scanButton, self.importButton, self.cancelButton ])
        b.alpha = b.enabled ? 1.0 : 0.4;

    NSArray<NSString *> *lines = imp.logLines ?: @[];
    NSString *text = [lines componentsJoinedByString:@"\n"];
    if (![text isEqualToString:self.logView.text]) {
        self.logView.text = text;
        if (text.length) [self.logView scrollRangeToVisible:NSMakeRange(text.length - 1, 1)];
    }
}

#pragma mark - 动作

// 默认源：优先数据卷里的 cdn-in（用户往那儿丢归档最省事），再看越狱常见目录
- (NSString *)defaultSourceDir
{
    NSMutableArray<NSString *> *cands = [NSMutableArray array];
    NSString *dataDir = [SpCnConfig shared].dataDir;
    if (dataDir.length) {
        [cands addObject:[dataDir stringByAppendingPathComponent:@"cdn-in"]];
        [cands addObject:[dataDir stringByAppendingPathComponent:@"cdn"]];
    }
    [cands addObjectsFromArray:@[
        @"/var/mobile/Documents/cdn", @"/var/mobile/Documents/SpCn/cdn",
        @"/var/mobile/Media/cdn", @"/var/mobile/Library/SpCn/cdn",
        [NSHomeDirectory() stringByAppendingPathComponent:@"Documents/cdn"],
        [NSHomeDirectory() stringByAppendingPathComponent:@"Documents/cdn-in"],
    ]];
    NSFileManager *fm = [NSFileManager defaultManager];
    for (NSString *c in cands) {
        BOOL isDir = NO;
        if ([fm fileExistsAtPath:c isDirectory:&isDir] && isDir) return c;
    }
    return nil;
}

- (void)defaultSourceTapped
{
    NSString *dir = [self defaultSourceDir];
    if (!dir) { self.sourceLabel.text = @"默认源：未找到（点「选目录…」指定）"; return; }
    self.sourceLabel.text = [@"源：" stringByAppendingString:dir];
    [[SpCnResourceImporter shared] scanSourceDir:dir];
}

- (void)pickTapped
{
    UIDocumentPickerViewController *p = [[UIDocumentPickerViewController alloc] initWithDocumentTypes:@[ @"public.folder" ]
                                                                                             inMode:UIDocumentPickerModeOpen];
    p.delegate = self;
    p.allowsMultipleSelection = NO;
    [self presentViewController:p animated:YES completion:nil];
}

- (void)documentPicker:(UIDocumentPickerViewController *)controller didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls
{
    NSURL *url = urls.firstObject;
    if (!url) return;
    if ([url startAccessingSecurityScopedResource]) self.sourceScopedURL = url;   // 持有到面板关闭
    self.sourceLabel.text = [@"源：" stringByAppendingString:url.path];
    [SpCnLog line:@"[资源] 选中源目录 %@（security scope=%s）", url.path, self.sourceScopedURL ? "yes" : "no"];
    [[SpCnResourceImporter shared] scanSourceDir:url.path];
}

- (void)scanTapped
{
    NSString *dir = nil;
    NSString *t = self.sourceLabel.text ?: @"";
    NSRange r = [t rangeOfString:@"："];
    if (r.location != NSNotFound) dir = [t substringFromIndex:r.location + r.length];
    if (!dir.length || [dir hasPrefix:@"未找到"]) dir = self.sourceScopedURL.path ?: [self defaultSourceDir];
    if (!dir.length) { [self pickTapped]; return; }
    [[SpCnResourceImporter shared] scanSourceDir:dir];
}

- (void)importTapped { [[SpCnResourceImporter shared] startImport]; }
- (void)cancelTapped { [[SpCnResourceImporter shared] cancel]; }

// 打开目标目录（给 Filza 用；没有 Filza 就什么也不发生）
- (void)openTargetTapped
{
    NSString *dir = [SpCnResourceImporter shared].targetDir;
    if (!dir.length) { [SpCnLog line:@"[资源] 还没有目标目录（先扫描）"]; return; }
    NSURL *u = [NSURL fileURLWithPath:dir isDirectory:YES];
    [[UIApplication sharedApplication] openURL:u options:@{} completionHandler:nil];
}

- (void)closeTapped { [self dismissViewControllerAnimated:YES completion:nil]; }

@end
