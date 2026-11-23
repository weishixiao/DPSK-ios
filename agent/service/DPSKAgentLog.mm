#import "DPSKAgentLog.h"

#import <Foundation/Foundation.h>
#include <os/lock.h>
#include <time.h>

static os_unfair_lock gLogLock = OS_UNFAIR_LOCK_INIT;

// The panel tails this file, so it may not grow without bound: past this many
// bytes the log is truncated rather than rotated, because a rotation would leave
// the panel reading a name that no longer receives writes.
static const unsigned long long kLogLimit = 2ULL * 1024 * 1024;

NSString *DPSKAgentStateDirectory(void) {
    static NSString *directory;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        directory = @"/var/mobile/Library/DPSKAgent";
        [[NSFileManager defaultManager] createDirectoryAtPath:directory
                                  withIntermediateDirectories:YES
                                                   attributes:nil
                                                        error:NULL];
    });
    return directory;
}

NSString *DPSKAgentLogPath(void) {
    return [DPSKAgentStateDirectory() stringByAppendingPathComponent:@"agentd.log"];
}

void DPSKAgentLog(NSString *format, ...) {
    va_list arguments;
    va_start(arguments, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:arguments];
    va_end(arguments);

    struct tm broken_down;
    time_t now = time(NULL);
    localtime_r(&now, &broken_down);
    char stamp[32];
    strftime(stamp, sizeof(stamp), "%Y-%m-%dT%H:%M:%S", &broken_down);

    NSString *line = [NSString stringWithFormat:@"%s %@\n", stamp, message];

    os_unfair_lock_lock(&gLogLock);
    NSString *path = DPSKAgentLogPath();
    NSFileManager *manager = [NSFileManager defaultManager];
    if (![manager fileExistsAtPath:path]) {
        [manager createFileAtPath:path contents:nil attributes:nil];
    }
    NSFileHandle *handle = [NSFileHandle fileHandleForWritingAtPath:path];
    unsigned long long size = [handle seekToEndOfFile];
    if (size > kLogLimit) {
        [handle truncateFileAtOffset:0];
    }
    [handle writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
    [handle closeFile];
    os_unfair_lock_unlock(&gLogLock);

    fputs(line.UTF8String, stderr);
}
