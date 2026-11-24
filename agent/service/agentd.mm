// The privileged half of the workbench.
//
// It runs from launchd, outside the app's sandbox, which is the only place
// `task_for_pid` and `mach_vm_write` work on a RootHide device. The app and the
// harness never link any of this: they send JSON to the Mach service below, and
// what comes back is a record of what happened, never a live handle.
//
// Everything a request can reach is in `DshGoAgentSafety` first: this file has no
// path around the allowlist or around the confirmation flag.

#import <Foundation/Foundation.h>

#import "DshGoAgentExec.h"
#import "DshGoAgentLog.h"
#import "DshGoAgentProbe.h"
#import "DshGoAgentSafety.h"

#include <signal.h>
#include <spawn.h>
#include <sys/wait.h>
#include <unistd.h>

extern char **environ;

static const NSUInteger kMaxPayload = 1024 * 1024;
static const NSUInteger kMaxReadLength = 64 * 1024;
static const NSUInteger kMaxWriteLength = 4 * 1024;

@protocol DshGoAgentXPC <NSObject>
- (void)call:(NSData *)payload reply:(void (^)(NSData *reply))reply;
@end

#pragma mark - Handlers

static NSDictionary *DshGoPing(void) {
    return @{
        @"version": @"0.1.0",
        @"pid": @(getpid()),
        @"uptime": @([[NSProcessInfo processInfo] systemUptime]),
        @"allowlist": [[DshGoAgentSafety shared] allowedBundleIds],
    };
}

/// Resolve `pid`, check the allowlist, and answer the refusal as an error.
static BOOL DshGoResolveTarget(NSDictionary *params, pid_t *pid, NSError **error) {
    NSInteger value = 0;
    if (!DshGoAgentIntegerParam(params, @"pid", 1, 99999, &value, error)) return NO;
    NSString *reason = nil;
    if (![[DshGoAgentSafety shared] allowsPID:(pid_t)value reason:&reason]) {
        if (error) *error = DshGoAgentMakeError(DshGoAgentErrorTargetNotAllowed, reason ?: @"target not allowed");
        return NO;
    }
    *pid = (pid_t)value;
    return YES;
}

static id DshGoHandleRead(NSDictionary *params, NSError **error) {
    pid_t pid = 0;
    if (!DshGoResolveTarget(params, &pid, error)) return nil;

    uint64_t address = 0;
    if (!DshGoAgentAddressParam(params, @"address", &address, error)) return nil;

    NSInteger length = 0;
    if (!DshGoAgentIntegerParam(params, @"length", 1, (NSInteger)kMaxReadLength, &length, error)) return nil;

    NSData *data = DshGoAgentReadMemory(pid, address, (NSUInteger)length, error);
    if (data == nil) return nil;

    NSMutableString *hex = [NSMutableString stringWithCapacity:data.length * 2];
    const uint8_t *bytes = data.bytes;
    for (NSUInteger index = 0; index < data.length; index++) {
        [hex appendFormat:@"%02x", bytes[index]];
    }
    return @{@"hex": hex, @"base": [NSString stringWithFormat:@"%llx", address], @"length": @(data.length)};
}

static id DshGoHandleWrite(NSDictionary *params, BOOL confirmed, NSError **error) {
    pid_t pid = 0;
    if (!DshGoResolveTarget(params, &pid, error)) return nil;

    uint64_t address = 0;
    if (!DshGoAgentAddressParam(params, @"address", &address, error)) return nil;

    NSData *data = DshGoAgentHexParam(params, @"hex", kMaxWriteLength, error);
    if (data == nil) return nil;

    // A write is the one method that changes the target, so it is the one method
    // that cannot run on a request the human did not confirm. The refusal names
    // the target so the log line is worth reading later.
    if (!confirmed) {
        if (error) {
            *error = DshGoAgentMakeError(DshGoAgentErrorConfirmationRequired,
                                        [NSString stringWithFormat:@"writing %lu bytes to pid %d needs a confirmed request",
                                         (unsigned long)data.length, pid]);
        }
        return nil;
    }

    if (!DshGoAgentWriteMemory(pid, address, data, error)) return nil;
    return @{@"written": @(data.length), @"address": [NSString stringWithFormat:@"%llx", address]};
}

/// Run `make package` in one of the owner's projects.
///
/// The argv array is fixed: the request names a project, never a command. `make`
/// itself is the Theos toolchain's entry point, so the compile happens with the
/// same rules the person would get in a terminal.
static id DshGoHandleCompile(NSDictionary *params, NSError **error) {
    NSString *project = DshGoAgentStringParam(params, @"project", error);
    if (project == nil) return nil;

    // A project name is a directory name, nothing more: no separators, no `..`.
    NSCharacterSet *illegal = [[NSCharacterSet characterSetWithCharactersInString:@"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-"] invertedSet];
    if ([project rangeOfCharacterFromSet:illegal].location != NSNotFound) {
        if (error) *error = DshGoAgentMakeError(DshGoAgentErrorBadParams, @"`project` must be a plain directory name");
        return nil;
    }

    NSString *root = [DshGoAgentStateDirectory() stringByAppendingPathComponent:@"projects"];
    NSString *directory = [root stringByAppendingPathComponent:project];
    if (![[NSFileManager defaultManager] fileExistsAtPath:directory]) {
        if (error) *error = DshGoAgentMakeError(DshGoAgentErrorBadParams,
                                              [NSString stringWithFormat:@"no project at %@", directory]);
        return nil;
    }

    int output[2] = {-1, -1};
    if (pipe(output) != 0) {
        if (error) *error = DshGoAgentMakeError(DshGoAgentErrorInternal, @"pipe() failed");
        return nil;
    }

    posix_spawn_file_actions_t actions;
    posix_spawn_file_actions_init(&actions);
    posix_spawn_file_actions_addchdir_np(&actions, directory.fileSystemRepresentation);
    posix_spawn_file_actions_adddup2(&actions, output[1], STDOUT_FILENO);
    posix_spawn_file_actions_adddup2(&actions, output[1], STDERR_FILENO);
    posix_spawn_file_actions_addclose(&actions, output[0]);

    const char *argv[] = {"make", "package", NULL};
    pid_t child = 0;
    int spawned = posix_spawn(&child, "/usr/bin/make", &actions, NULL, argv, environ);
    posix_spawn_file_actions_destroy(&actions);
    close(output[1]);

    if (spawned != 0) {
        close(output[0]);
        if (error) *error = DshGoAgentMakeError(DshGoAgentErrorInternal,
                                              [NSString stringWithFormat:@"posix_spawn: %s", strerror(spawned)]);
        return nil;
    }

    NSMutableData *log = [NSMutableData data];
    char buffer[4096];
    ssize_t read_bytes;
    // The toolchain is slow but not unbounded; a build that has produced nothing
    // for this long is stuck, and leaving it running would hold the service.
    while ((read_bytes = read(output[0], buffer, sizeof(buffer))) > 0) {
        [log appendBytes:buffer length:(NSUInteger)read_bytes];
    }
    close(output[0]);

    int status = 0;
    waitpid(child, &status, 0);
    NSString *text = [[NSString alloc] initWithData:log encoding:NSUTF8StringEncoding] ?: @"";

    if (!WIFEXITED(status) || WEXITSTATUS(status) != 0) {
        if (error) *error = DshGoAgentMakeError(DshGoAgentErrorInternal,
                                              [NSString stringWithFormat:@"make package exited %d", WEXITSTATUS(status)]);
        return @{@"log": text};
    }

    // The newest package is this build's: Theos writes into `packages/`.
    NSString *packages = [directory stringByAppendingPathComponent:@"packages"];
    NSArray<NSString *> *entries = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:packages error:NULL];
    NSString *newest = nil;
    NSDate *newestDate = nil;
    for (NSString *entry in entries) {
        if (![entry.pathExtension isEqualToString:@"deb"]) continue;
        NSString *path = [packages stringByAppendingPathComponent:entry];
        NSDictionary *attributes = [[NSFileManager defaultManager] attributesOfItemAtPath:path error:NULL];
        NSDate *modified = attributes[NSFileModificationDate];
        if (newestDate == nil || [modified compare:newestDate] == NSOrderedDescending) {
            newest = path;
            newestDate = modified;
        }
    }
    return @{@"log": text, @"artifact": newest ?: @""};
}

/// Run a binary from the approved directories. Needs `confirmed`: executing a
/// program the human did not ask for is the one thing this service will not do
/// on its own.
static id DshGoAgentHandleExec(NSDictionary *params, BOOL confirmed, NSError **error) {
    if (!confirmed) {
        if (error) *error = DshGoAgentMakeError(DshGoAgentErrorConfirmationRequired,
            @"running a program needs a confirmed request");
        return nil;
    }
    NSString *path = DshGoAgentStringParam(params, @"path", error);
    if (path == nil) return nil;
    NSString *resolved = path.length ? path : [DshGoAgentExec resolveBinary:(DshGoAgentStringParam(params, @"binary", error) ?: @"")];
    if (resolved == nil) {
        if (error) *error = DshGoAgentMakeError(DshGoAgentErrorBadParams,
            @"`path` or `binary` must name a program");
        return nil;
    }
    NSArray *arguments = params[@"args"];
    if (arguments && ![arguments isKindOfClass:[NSArray class]]) {
        if (error) *error = DshGoAgentMakeError(DshGoAgentErrorBadParams, @"`args` must be an array");
        return nil;
    }
    NSMutableArray<NSString *> *words = [NSMutableArray array];
    for (id item in (arguments ?: @[])) {
        if (![item isKindOfClass:[NSString class]]) {
            if (error) *error = DshGoAgentMakeError(DshGoAgentErrorBadParams, @"`args` must be strings");
            return nil;
        }
        [words addObject:item];
    }
    NSInteger seconds = 30;
    if (!DshGoAgentIntegerParam(params, @"timeout", 1, 300, &seconds, error)) return nil;
    return [DshGoAgentExec runPath:resolved arguments:words timeout:(NSTimeInterval)seconds error:error];
}

/// Read a file the daemon can reach. Read-only: writing from this service is
/// reserved for the confirmed memory path, where the target is explicit.
static id DshGoAgentHandleReadFile(NSDictionary *params, NSError **error) {
    NSString *path = DshGoAgentStringParam(params, @"path", error);
    if (path == nil) return nil;
    if (![path hasPrefix:@"/"]) {
        if (error) *error = DshGoAgentMakeError(DshGoAgentErrorBadParams, @"`path` must be absolute");
        return nil;
    }
    NSInteger length = 0;
    if (!DshGoAgentIntegerParam(params, @"length", 1, 1024 * 1024, &length, error)) return nil;
    NSFileHandle *handle = [NSFileHandle fileHandleForReadingAtPath:path];
    if (handle == nil) {
        if (error) *error = DshGoAgentMakeError(DshGoAgentErrorBadParams,
            [NSString stringWithFormat:@"cannot read %@", path]);
        return nil;
    }
    NSData *data = [handle readDataOfLength:(NSUInteger)length];
    [handle closeFile];
    return @{@"path": path, @"bytes": @(data.length)};
}

static NSDictionary *DshGoHandleRequest(NSDictionary *request) {
    NSString *identifier = request[@"id"];
    NSString *method = request[@"method"];
    NSDictionary *params = request[@"params"];
    BOOL confirmed = [request[@"confirmed"] boolValue];

    if (![identifier isKindOfClass:[NSString class]] || identifier.length == 0) {
        return @{@"id": @"", @"ok": @NO, @"error": @{@"code": @"ERR_BAD_PARAMS", @"message": @"`id` must be a non-empty string"}};
    }
    if (![method isKindOfClass:[NSString class]]) {
        return @{@"id": identifier, @"ok": @NO, @"error": @{@"code": @"ERR_BAD_PARAMS", @"message": @"`method` must be a string"}};
    }
    if (params == nil) params = @{};
    if (![params isKindOfClass:[NSDictionary class]]) {
        return @{@"id": identifier, @"ok": @NO, @"error": @{@"code": @"ERR_BAD_PARAMS", @"message": @"`params` must be an object"}};
    }

    NSError *error = nil;
    id result = nil;
    pid_t target = 0;

    if ([method isEqualToString:@"probe.ping"]) {
        result = DshGoPing();
    } else if ([method isEqualToString:@"probe.listProcesses"]) {
        result = @{@"processes": DshGoAgentListProcesses()};
    } else if ([method isEqualToString:@"probe.modules"]) {
        if (DshGoResolveTarget(params, &target, &error)) {
            result = @{@"pid": @(target), @"modules": DshGoAgentModulesForPID(target)};
        }
    } else if ([method isEqualToString:@"probe.readMemory"]) {
        result = DshGoHandleRead(params, &error);
    } else if ([method isEqualToString:@"mem.write"]) {
        result = DshGoHandleWrite(params, confirmed, &error);
    } else if ([method isEqualToString:@"exec.run"]) {
        result = DshGoAgentHandleExec(params, confirmed, &error);
    } else if ([method isEqualToString:@"fs.read"]) {
        result = DshGoAgentHandleReadFile(params, &error);
    } else if ([method isEqualToString:@"tweak.compile"]) {
        result = DshGoHandleCompile(params, &error);
    } else if ([method isEqualToString:@"tweak.inject"]) {
        // Reserved: answering "not implemented" is how a caller learns the
        // difference between "did nothing" and "cannot do this yet".
        error = DshGoAgentMakeError(DshGoAgentErrorNotImplemented, @"tweak.inject is not implemented in this build");
    } else {
        error = DshGoAgentMakeError(DshGoAgentErrorBadParams,
                                   [NSString stringWithFormat:@"unknown method %@", method]);
    }

    if (error != nil) {
        NSString *code = DshGoAgentErrorCodeName((DshGoAgentErrorCode)error.code);
        DshGoAgentLog(@"%@ %@ target=%d -> %@ (%@)", identifier, method, target, code, error.localizedDescription);
        return @{@"id": identifier, @"ok": @NO, @"error": @{@"code": code, @"message": error.localizedDescription ?: @""}};
    }

    DshGoAgentLog(@"%@ %@ target=%d -> ok", identifier, method, target);
    return @{@"id": identifier, @"ok": @YES, @"result": result ?: @{}};
}

#pragma mark - XPC

@interface DshGoAgentListener : NSObject <NSXPCListenerDelegate, DshGoAgentXPC>
@end

@implementation DshGoAgentListener

- (BOOL)listener:(NSXPCListener *)listener shouldAcceptNewConnection:(NSXPCConnection *)connection {
    connection.exportedInterface = [NSXPCInterface interfaceWithProtocol:@protocol(DshGoAgentXPC)];
    connection.exportedObject = self;
    [connection resume];
    return YES;
}

- (void)call:(NSData *)payload reply:(void (^)(NSData *reply))reply {
    // Every request is answered, including the ones that fail: the caller waits
    // on this block, and a dropped reply is indistinguishable from a hang.
    if (payload.length == 0 || payload.length > kMaxPayload) {
        NSDictionary *answer = @{@"id": @"", @"ok": @NO,
                                 @"error": @{@"code": @"ERR_BAD_PARAMS", @"message": @"payload must be 1 byte to 1 MiB of JSON"}};
        reply([NSJSONSerialization dataWithJSONObject:answer options:0 error:NULL]);
        return;
    }

    NSDictionary *answer = nil;
    @try {
        id request = [NSJSONSerialization JSONObjectWithData:payload options:0 error:NULL];
        if (![request isKindOfClass:[NSDictionary class]]) {
            answer = @{@"id": @"", @"ok": @NO, @"error": @{@"code": @"ERR_BAD_PARAMS", @"message": @"payload must be a JSON object"}};
        } else {
            answer = DshGoHandleRequest(request);
        }
    } @catch (NSException *exception) {
        // A malformed request must not take the service down: the phone's other
        // workbench features are on the other side of this listener.
        DshGoAgentLog(@"exception: %@ %@", exception.name, exception.reason);
        answer = @{@"id": @"", @"ok": @NO, @"error": @{@"code": @"ERR_INTERNAL", @"message": exception.reason ?: @"exception"}};
    }

    NSData *encoded = [NSJSONSerialization isValidJSONObject:answer]
        ? [NSJSONSerialization dataWithJSONObject:answer options:0 error:NULL]
        : [NSJSONSerialization dataWithJSONObject:@{@"id": answer[@"id"] ?: @"", @"ok": @NO,
                                                    @"error": @{@"code": @"ERR_INTERNAL", @"message": @"reply was not serializable"}}
                                           options:0 error:NULL];
    reply(encoded);
}

@end

int main(int argc, char **argv) {
    @autoreleasepool {
        // A dead client must not kill the service with SIGPIPE.
        signal(SIGPIPE, SIG_IGN);
        DshGoAgentLog(@"agentd 0.1.0 starting (pid %d)", getpid());
        [[DshGoAgentSafety shared] reload];

        NSXPCListener *listener = [[NSXPCListener alloc] initWithMachServiceName:@"io.github.ccch1mneyyy.dshgo.agentd"];
        DshGoAgentListener *delegate = [[DshGoAgentListener alloc] init];
        listener.delegate = delegate;
        [listener resume];
        DshGoAgentLog(@"agentd listening on io.github.ccch1mneyyy.dshgo.agentd");
        [[NSRunLoop currentRunLoop] run];
    }
    return 0;
}
