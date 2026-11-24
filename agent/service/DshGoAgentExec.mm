#import "DshGoAgentExec.h"

#import "DshGoAgentLog.h"
#import "DshGoAgentSafety.h"

#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <spawn.h>
#include <sys/wait.h>
#include <unistd.h>

extern char **environ;

/// The jailbreak root on this device, or "" when the install is rootful.
///
/// RootHide randomizes the root per boot and leaves `/var/jb` nonexistent, so
/// the hardcoded rootless paths below are only part of the answer. The reliable
/// source is the daemon's own launch path: launchd starts it from
/// `<root>/usr/libexec`, and the toolchain it runs (make, ldid, dpkg, frida) is
/// in `<root>/usr/bin` beside it. Deriving it once keeps every later path -
/// tweak install, package install - pointed at the root that is actually there.
NSString *DshGoJailbreakRoot(void) {
    static NSString *root;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSString *executable = [[NSBundle mainBundle] executablePath];
        if (executable.length == 0) {
            root = @"";
            return;
        }
        // <root>/usr/libexec/dsh-go-agentd -> <root>/usr -> <root>
        NSString *libexec = [executable stringByDeletingLastPathComponent];
        NSString *usr = [libexec stringByDeletingLastPathComponent];
        root = [usr stringByDeletingLastPathComponent] ?: @"";
        if ([root isEqualToString:@"/"]) root = @"";
    });
    return root;
}

/// Where a request may execute from. These are where a jailbreak toolchain
/// installs; anything else is refused even though the daemon could run it.
static NSArray<NSString *> *DshGoExecutableDirectories(void) {
    static NSArray<NSString *> *directories;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSMutableArray<NSString *> *list = [NSMutableArray arrayWithArray:@[
            @"/usr/bin", @"/usr/sbin", @"/bin", @"/sbin", @"/usr/local/bin",
            @"/var/jb/usr/bin", @"/var/jb/bin",
        ]];
        NSString *root = DshGoJailbreakRoot();
        if (root.length > 0) {
            for (NSString *component in @[@"usr/bin", @"usr/sbin", @"usr/local/bin", @"bin"]) {
                NSString *candidate = [root stringByAppendingPathComponent:component];
                if (![list containsObject:candidate]) [list addObject:candidate];
            }
        }
        directories = [list copy];
    });
    return directories;
}

static const NSUInteger kMaxOutputBytes = 256 * 1024;

@implementation DshGoAgentExec

+ (nullable NSString *)resolveBinary:(NSString *)name {
    if (name.length == 0 || [name containsString:@"/"] || [name hasPrefix:@"."]) return nil;
    NSFileManager *files = [NSFileManager defaultManager];
    for (NSString *directory in DshGoExecutableDirectories()) {
        NSString *candidate = [directory stringByAppendingPathComponent:name];
        if ([files isExecutableFileAtPath:candidate]) return candidate;
    }
    return nil;
}

+ (nullable NSNumber *)spawnDetached:(NSString *)path
                           arguments:(NSArray<NSString *> *)arguments
                               error:(NSError *_Nullable *_Nullable)error {
    NSString *parent = [path stringByDeletingLastPathComponent];
    if (![DshGoExecutableDirectories() containsObject:parent]) {
        if (error) *error = DshGoAgentMakeError(DshGoAgentErrorTargetNotAllowed,
            [NSString stringWithFormat:@"%@ is outside the executable directories", path]);
        return nil;
    }
    if (![[NSFileManager defaultManager] isExecutableFileAtPath:path]) {
        if (error) *error = DshGoAgentMakeError(DshGoAgentErrorBadParams,
            [NSString stringWithFormat:@"%@ is not executable", path]);
        return nil;
    }

    NSMutableArray<NSString *> *words = [NSMutableArray arrayWithObject:path];
    for (NSString *argument in arguments) [words addObject:argument];
    char **argv = (char **)calloc(words.count + 1, sizeof(char *));
    if (argv == NULL) {
        if (error) *error = DshGoAgentMakeError(DshGoAgentErrorInternal, @"out of memory");
        return nil;
    }
    for (NSUInteger index = 0; index < words.count; index++) argv[index] = strdup(words[index].UTF8String);

    // Output goes to /dev/null on purpose: a server that wrote into a pipe or a
    // capture file nobody drains would eventually block on a full buffer, and
    // nothing here is going to read it. Its life is tracked by its pid.
    posix_spawn_file_actions_t actions;
    posix_spawn_file_actions_init(&actions);
    posix_spawn_file_actions_addopen(&actions, STDOUT_FILENO, "/dev/null", O_WRONLY, 0);
    posix_spawn_file_actions_addopen(&actions, STDERR_FILENO, "/dev/null", O_WRONLY, 0);

    pid_t child = 0;
    int spawned = posix_spawn(&child, path.fileSystemRepresentation, &actions, NULL, (char *const *)argv, environ);
    posix_spawn_file_actions_destroy(&actions);
    for (NSUInteger index = 0; index < words.count; index++) free(argv[index]);
    free(argv);

    if (spawned != 0) {
        if (error) *error = DshGoAgentMakeError(DshGoAgentErrorInternal,
            [NSString stringWithFormat:@"cannot start %@: %s", path, strerror(spawned)]);
        return nil;
    }
    return @(child);
}

+ (nullable NSDictionary *)runPath:(NSString *)path
                          arguments:(NSArray<NSString *> *)arguments
                           timeout:(NSTimeInterval)timeout
                             error:(NSError *_Nullable *_Nullable)error {
    NSString *parent = [path stringByDeletingLastPathComponent];
    if (![DshGoExecutableDirectories() containsObject:parent]) {
        if (error) *error = DshGoAgentMakeError(DshGoAgentErrorTargetNotAllowed,
            [NSString stringWithFormat:@"%@ is outside the executable directories", path]);
        return nil;
    }
    if (![[NSFileManager defaultManager] isExecutableFileAtPath:path]) {
        if (error) *error = DshGoAgentMakeError(DshGoAgentErrorBadParams,
            [NSString stringWithFormat:@"%@ is not executable", path]);
        return nil;
    }
    if (timeout <= 0) timeout = 30;
    if (timeout > 300) timeout = 300;

    NSMutableArray<NSString *> *words = [NSMutableArray arrayWithObject:path];
    for (NSString *argument in arguments) [words addObject:argument];
    char **argv = (char **)calloc(words.count + 1, sizeof(char *));
    if (argv == NULL) {
        if (error) *error = DshGoAgentMakeError(DshGoAgentErrorInternal, @"out of memory");
        return nil;
    }
    for (NSUInteger index = 0; index < words.count; index++) argv[index] = strdup(words[index].UTF8String);

    // A temporary file rather than a pipe: a child that outlives its parent
    // cannot then deadlock the daemon on a full pipe, and reading it back is
    // one seek away.
    NSString *capture = [NSTemporaryDirectory() stringByAppendingPathComponent:[[NSUUID UUID] UUIDString]];
    int fd = open(capture.fileSystemRepresentation, O_CREAT | O_TRUNC | O_RDWR, 0600);
    if (fd < 0) {
        for (NSUInteger index = 0; index < words.count; index++) free(argv[index]);
        free(argv);
        if (error) *error = DshGoAgentMakeError(DshGoAgentErrorInternal, @"cannot open capture file");
        return nil;
    }

    posix_spawn_file_actions_t actions;
    posix_spawn_file_actions_init(&actions);
    posix_spawn_file_actions_adddup2(&actions, fd, STDOUT_FILENO);
    posix_spawn_file_actions_adddup2(&actions, fd, STDERR_FILENO);
    posix_spawn_file_actions_addclose(&actions, fd);

    pid_t child = 0;
    int spawned = posix_spawn(&child, path.fileSystemRepresentation, &actions, NULL, (char *const *)argv, environ);
    posix_spawn_file_actions_destroy(&actions);
    for (NSUInteger index = 0; index < words.count; index++) free(argv[index]);
    free(argv);
    if (spawned != 0) {
        close(fd);
        [[NSFileManager defaultManager] removeItemAtPath:capture error:NULL];
        if (error) *error = DshGoAgentMakeError(DshGoAgentErrorInternal,
            [NSString stringWithFormat:@"spawn failed: %s", strerror(spawned)]);
        return nil;
    }

    // Poll the child so a hung binary costs the timeout and nothing more.
    int status = 0;
    BOOL exited = NO;
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:timeout];
    while ([deadline timeIntervalSinceNow] > 0) {
        pid_t waited = waitpid(child, &status, WNOHANG);
        if (waited == child) { exited = YES; break; }
        if (waited < 0 && errno != EINTR) break;
        usleep(20000);
    }
    BOOL timedOut = !exited;
    if (timedOut) {
        kill(child, SIGKILL);
        waitpid(child, &status, 0);
    }

    off_t size = lseek(fd, 0, SEEK_END);
    BOOL truncated = size > (off_t)kMaxOutputBytes;
    if (truncated) size = (off_t)kMaxOutputBytes;
    NSMutableData *data = [NSMutableData dataWithLength:(NSUInteger)(size > 0 ? size : 0)];
    lseek(fd, 0, SEEK_SET);
    if (size > 0) read(fd, data.mutableBytes, (size_t)size);
    close(fd);
    [[NSFileManager defaultManager] removeItemAtPath:capture error:NULL];

    if (timedOut) {
        if (error) *error = DshGoAgentMakeError(DshGoAgentErrorInternal,
            [NSString stringWithFormat:@"%@ did not exit within %.0fs", path, timeout]);
        return nil;
    }

    NSInteger code = WIFEXITED(status) ? WEXITSTATUS(status) : -(int)WTERMSIG(status);
    NSString *text = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] ?: @"";
    DshGoAgentLog(@"exec %@ -> %ld (%lu bytes%@)", path, (long)code, (unsigned long)data.length,
                  truncated ? @", truncated" : @"");
    return @{@"path": path, @"exit": @(code), @"output": text, @"truncated": @(truncated)};
}

@end
