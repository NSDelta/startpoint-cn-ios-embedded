#import "SpCnLog.h"
#import <os/lock.h>

static NSMutableArray<NSString *> *gLines = nil;
static NSString *gLogPath = nil;
static os_unfair_lock gLock = OS_UNFAIR_LOCK_INIT;
static NSISO8601DateFormatter *gFmt = nil;
static const NSUInteger kMaxLines = 500;

@implementation SpCnLog

+ (void)bootstrap {
    os_unfair_lock_lock(&gLock);
    if (!gLines) {
        gLines = [NSMutableArray array];
        gFmt = [NSISO8601DateFormatter new];
        gFmt.formatOptions = NSISO8601DateFormatWithTime | NSISO8601DateFormatWithFractionalSeconds;
    }
    if (!gLogPath) {
        NSString *tmp = NSTemporaryDirectory() ?: @"/tmp";
        gLogPath = [tmp stringByAppendingPathComponent:@"SpCnEmbedded.log"];
    }
    os_unfair_lock_unlock(&gLock);
}

+ (void)setLogFile:(NSString *)path {
    if (path.length == 0) return;
    os_unfair_lock_lock(&gLock);
    gLogPath = [path copy];
    os_unfair_lock_unlock(&gLock);
    [self line:@"[LOG] 日志切到 %@", path];
}

+ (NSString *)logFilePath {
    os_unfair_lock_lock(&gLock);
    NSString *p = [gLogPath copy];
    os_unfair_lock_unlock(&gLock);
    return p;
}

+ (void)line:(NSString *)format, ... {
    va_list ap;
    va_start(ap, format);
    NSString *msg = [[NSString alloc] initWithFormat:format arguments:ap];
    va_end(ap);

    [self bootstrap];
    NSString *stamp = [gFmt stringFromDate:[NSDate date]];
    NSString *full = [NSString stringWithFormat:@"%@ %@", stamp, msg];

    os_unfair_lock_lock(&gLock);
    [gLines addObject:full];
    if (gLines.count > kMaxLines) [gLines removeObjectsInRange:NSMakeRange(0, gLines.count - kMaxLines)];
    NSString *path = [gLogPath copy];
    os_unfair_lock_unlock(&gLock);

    NSLog(@"[SpCn] %@", msg);

    if (path.length) {
        NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:path];
        if (!fh) {
            [[NSFileManager defaultManager] createFileAtPath:path contents:nil attributes:nil];
            fh = [NSFileHandle fileHandleForWritingAtPath:path];
        }
        if (fh) {
            @try {
                [fh seekToEndOfFile];
                NSData *d = [[full stringByAppendingString:@"\n"] dataUsingEncoding:NSUTF8StringEncoding];
                [fh writeData:d];
            } @catch (__unused NSException *e) {}
            [fh closeFile];
        }
    }
}

+ (NSArray<NSString *> *)recentLines {
    os_unfair_lock_lock(&gLock);
    NSArray *copy = [gLines copy] ?: @[];
    os_unfair_lock_unlock(&gLock);
    return copy;
}

@end
