#import "DshGoAgentFrida.h"

#import "DshGoAgentExec.h"
#import "DshGoAgentLog.h"
#import "DshGoAgentSafety.h"

#include <errno.h>
#include <signal.h>
#include <string.h>
#include <sys/wait.h>
#include <unistd.h>

/// Where the pid file lives, so a server started before a daemon restart can
/// still be found. It sits beside `allowlist.json` and `agentd.log`, which are
/// the daemon's own files and not the app's.
static NSString *DshGoFridaPidFile(void) {
    return [DshGoAgentStateDirectory() stringByAppendingPathComponent:@"frida-server.pid"];
}

/// pid:port, the two things a later request needs to decide what to do. A file
/// rather than a static: the daemon is restarted by the system more often than a
/// server outlives it, and losing track of a listening socket is not acceptable.
static NSDictionary *_Nullable DshGoFridaRecord(void) {
    NSString *text = [NSString stringWithContentsOfFile:DshGoFridaPidFile()
                                               encoding:NSUTF8StringEncoding
                                                  error:NULL];
    if (text.length == 0) return nil;
    NSArray<NSString *> *parts = [text componentsSeparatedByCharactersInSet:
        [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    NSMutableArray<NSString *> *fields = [NSMutableArray array];
    for (NSString *part in parts) {
        if (part.length > 0) [fields addObject:part];
    }
    if (fields.count < 2) return nil;
    return @{@"pid": @(fields[0].intValue), @"port": @(fields[1].intValue)};
}

static void DshGoFridaForget(void) {
    [[NSFileManager defaultManager] removeItemAtPath:DshGoFridaPidFile() error:NULL];
}

static BOOL DshGoFridaAlive(pid_t pid, BOOL reap) {
    if (pid <= 0) return NO;
    if (kill(pid, 0) != 0 && errno == ESRCH) {
        if (reap) {
            int status = 0;
            // Reap it if it is ours to reap; ECHILD means it was not, and either
            // way the answer to "is it running" is no.
            (void)waitpid(pid, &status, WNOHANG);
        }
        return NO;
    }
    return YES;
}

NSDictionary *DshGoAgentFridaStatus(void) {
    NSString *server = [DshGoAgentExec resolveBinary:@"frida-server"];
    NSString *inject = [DshGoAgentExec resolveBinary:@"frida-inject"];

    NSMutableDictionary *status = [NSMutableDictionary dictionary];
    status[@"available"] = @(server != nil);
    status[@"server"] = server ?: @"";
    status[@"inject"] = inject ?: @"";
    // The root the daemon resolved, because "frida is not installed" on RootHide
    // usually means it is installed somewhere this build is not looking.
    status[@"root"] = DshGoJailbreakRoot();

    NSDictionary *record = DshGoFridaRecord();
    BOOL running = record != nil && DshGoFridaAlive([record[@"pid"] intValue], YES);
    if (record != nil && !running) DshGoFridaForget();
    status[@"running"] = @(running);
    if (running) {
        status[@"pid"] = record[@"pid"];
        status[@"port"] = record[@"port"];
    }
    return status;
}

NSDictionary *DshGoAgentFridaStart(uint16_t port, NSError **error) {
    NSDictionary *current = DshGoAgentFridaStatus();
    if ([current[@"running"] boolValue]) {
        if (error) {
            *error = DshGoAgentMakeError(DshGoAgentErrorBadParams,
                [NSString stringWithFormat:@"frida-server is already running as pid %@ on port %@; stop it first",
                                           current[@"pid"], current[@"port"]]);
        }
        return nil;
    }
    NSString *server = [DshGoAgentExec resolveBinary:@"frida-server"];
    if (server == nil) {
        if (error) {
            *error = DshGoAgentMakeError(DshGoAgentErrorNotImplemented,
                [NSString stringWithFormat:@"frida-server is not in any of the executable directories under \"%@\"; install the frida package for this root",
                                           DshGoJailbreakRoot()]);
        }
        return nil;
    }
    if (port < 1024) port = 27042;

    NSString *listen = [NSString stringWithFormat:@"127.0.0.1:%u", port];
    NSError *spawnError = nil;
    NSNumber *pid = [DshGoAgentExec spawnDetached:server arguments:@[@"-l", listen] error:&spawnError];
    if (pid == nil) {
        if (error) *error = spawnError;
        return nil;
    }

    // Give it a moment to bind before claiming it is up: a server that died on a
    // busy port should be reported as failed now, not on the next call.
    BOOL alive = NO;
    for (int attempt = 0; attempt < 15; attempt++) {
        if (!DshGoFridaAlive(pid.intValue, NO)) break;
        if (attempt == 14) alive = YES;
        usleep(100 * 1000);
    }
    if (!alive) {
        (void)kill(pid.intValue, SIGKILL);
        if (error) {
            *error = DshGoAgentMakeError(DshGoAgentErrorInternal,
                [NSString stringWithFormat:@"frida-server exited while starting on %@", listen]);
        }
        return nil;
    }

    NSString *record = [NSString stringWithFormat:@"%d %u\n", pid.intValue, port];
    [record writeToFile:DshGoFridaPidFile() atomically:YES encoding:NSUTF8StringEncoding error:NULL];
    DshGoAgentLog(@"frida: server pid %@ listening on %@", pid, listen);
    return @{@"pid": pid, @"port": @(port), @"address": listen};
}

BOOL DshGoAgentFridaStop(NSError **error) {
    NSDictionary *record = DshGoFridaRecord();
    if (record == nil) {
        if (error) *error = DshGoAgentMakeError(DshGoAgentErrorBadParams, @"no frida-server was started by this daemon");
        return NO;
    }
    pid_t pid = [record[@"pid"] intValue];
    if (!DshGoFridaAlive(pid, YES)) {
        DshGoFridaForget();
        if (error) *error = DshGoAgentMakeError(DshGoAgentErrorBadParams,
            [NSString stringWithFormat:@"frida-server pid %d is no longer running", pid]);
        return NO;
    }

    (void)kill(pid, SIGTERM);
    for (int attempt = 0; attempt < 20; attempt++) {
        if (!DshGoFridaAlive(pid, YES)) {
            DshGoFridaForget();
            return YES;
        }
        usleep(100 * 1000);
    }
    // A server that ignores SIGTERM is still the daemon's own child, and leaving
    // a listener up because it did not feel like stopping is worse than killing it.
    (void)kill(pid, SIGKILL);
    for (int attempt = 0; attempt < 10; attempt++) {
        if (!DshGoFridaAlive(pid, YES)) {
            DshGoFridaForget();
            return YES;
        }
        usleep(100 * 1000);
    }
    if (error) {
        *error = DshGoAgentMakeError(DshGoAgentErrorInternal,
            [NSString stringWithFormat:@"frida-server pid %d did not exit", pid]);
    }
    return NO;
}

NSDictionary *DshGoAgentFridaInject(pid_t pid, NSString *source, NSTimeInterval timeout, NSError **error) {
    if (source.length == 0) {
        if (error) *error = DshGoAgentMakeError(DshGoAgentErrorBadParams, @"`script` must not be empty");
        return nil;
    }
    NSString *inject = [DshGoAgentExec resolveBinary:@"frida-inject"];
    if (inject == nil) {
        if (error) {
            *error = DshGoAgentMakeError(DshGoAgentErrorNotImplemented,
                [NSString stringWithFormat:@"frida-inject is not in any of the executable directories under \"%@\"",
                                           DshGoJailbreakRoot()]);
        }
        return nil;
    }

    // The script goes in the daemon's own directory, not /tmp: a world-writable
    // directory would let another process swap it between writing and running it.
    NSString *path = [DshGoAgentStateDirectory()
        stringByAppendingPathComponent:[NSString stringWithFormat:@"script-%@.js", [[NSUUID UUID] UUIDString]]];
    NSError *writeError = nil;
    if (![source writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:&writeError]) {
        if (error) {
            *error = DshGoAgentMakeError(DshGoAgentErrorInternal,
                [NSString stringWithFormat:@"cannot write the script: %@", writeError.localizedDescription]);
        }
        return nil;
    }

    if (timeout <= 0) timeout = 15;
    if (timeout > 120) timeout = 120;
    NSError *runError = nil;
    NSDictionary *result = [DshGoAgentExec runPath:inject
                                         arguments:@[@"-p", [NSString stringWithFormat:@"%d", pid], @"-s", path]
                                           timeout:timeout
                                             error:&runError];
    [[NSFileManager defaultManager] removeItemAtPath:path error:NULL];
    if (result == nil) {
        if (error) *error = runError;
        return nil;
    }

    NSMutableDictionary *reply = [result mutableCopy];
    reply[@"pid"] = @(pid);
    return reply;
}