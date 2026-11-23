// The privileged half of the workbench.
//
// It runs from launchd, outside the app's sandbox, which is the only place
// `task_for_pid` and `mach_vm_write` work on a RootHide device. The app and the
// harness never link any of this: they send JSON to the Mach service below, and
// what comes back is a record of what happened, never a live handle.
//
// Everything a request can reach is in `DPSKAgentSafety` first: this file has no
// path around the allowlist or around the confirmation flag.

#import <Foundation/Foundation.h>

#import "DPSKAgentLog.h"
#import "DPSKAgentProbe.h"
#import "DPSKAgentSafety.h"

#include <signal.h>
#include <spawn.h>
#include <sys/wait.h>
#include <unistd.h>

extern char **environ;

static const NSUInteger kMaxPayload = 1024 * 1024;
static const NSUInteger kMaxReadLength = 64 * 1024;
static const NSUInteger kMaxWriteLength = 4 * 1024;

@protocol DPSKAgentXPC <NSObject>
- (void)call:(NSData *)payload reply:(void (^)(NSData *reply))reply;
@end

#pragma mark - Handlers

static NSDictionary *DPSKPing(void) {
    return @{
        @"version": @"0.1.0",
        @"pid": @(getpid()),
        @"uptime": @([[NSProcessInfo processInfo] systemUptime]),
        @"allowlist": [[DPSKAgentSafety shared] allowedBundleIds],
    };
}

/// Resolve `pid`, check the allowlist, and answer the refusal as an error.
static BOOL DPSKResolveTarget(NSDictionary *params, pid_t *pid, NSError **error) {
    NSInteger value = 0;
    if (!DPSKAgentIntegerParam(params, @"pid", 1, 99999, &value, error)) return NO;
    NSString *reason = nil;
    if (![[DPSKAgentSafety shared] allowsPID:(pid_t)value reason:&reason]) {
        if (error) *error = DPSKAgentMakeError(DPSKAgentErrorTargetNotAllowed, reason ?: @"target not allowed");
        return NO;
    }
    *pid = (pid_t)value;
    return YES;
}

static id DPSKHandleRead(NSDictionary *params, NSError **error) {
    pid_t pid = 0;
    if (!DPSKResolveTarget(params, &pid, error)) return nil;

    uint64_t address = 0;
    if (!DPSKAgentAddressParam(params, @"address", &address, error)) return nil;

    NSInteger length = 0;
    if (!DPSKAgentIntegerParam(params, @"length", 1, (NSInteger)kMaxReadLength, &length, error)) return nil;

    NSData *data = DPSKAgentReadMemory(pid, address, (NSUInteger)length, error);
    if (data == nil) return nil;

    NSMutableString *hex = [NSMutableString stringWithCapacity:data.length * 2];
    const uint8_t *bytes = data.bytes;
    for (NSUInteger index = 0; index < data.length; index++) {
        [hex appendFormat:@"%02x", bytes[index]];
    }
    return @{@"hex": hex, @"base": [NSString stringWithFormat:@"%llx", address], @"length": @(data.length)};
}

static id DPSKHandleWrite(NSDictionary *params, BOOL confirmed, NSError **error) {
    pid_t pid = 0;
    if (!DPSKResolveTarget(params, &pid, error)) return nil;

    uint64_t address = 0;
    if (!DPSKAgentAddressParam(params, @"address", &address, error)) return nil;

    NSData *data = DPSKAgentHexParam(params, @"hex", kMaxWriteLength, error);
    if (data == nil) return nil;

    // A write is the one method that changes the target, so it is the one method
    // that cannot run on a request the human did not confirm. The refusal names
    // the target so the log line is worth reading later.
    if (!confirmed) {
        if (error) {
            *error = DPSKAgentMakeError(DPSKAgentErrorConfirmationRequired,
                                        [NSString stringWithFormat:@"writing %lu bytes to pid %d needs a confirmed request",
                                         (unsigned long)data.length, pid]);
        }
        return nil;
    }

    if (!DPSKAgentWriteMemory(pid, address, data, error)) return nil;
    return @{@"written": @(data.length), @"address": [NSString stringWithFormat:@"%llx", address]};
}

/// Run `make package` in one of the owner's projects.
///
/// The argv array is fixed: the request names a project, never a command. `make`
/// itself is the Theos toolchain's entry point, so the compile happens with the
/// same rules the person would get in a terminal.
static id DPSKHandleCompile(NSDictionary *params, NSError **error) {
    NSString *project = DPSKAgentStringParam(params, @"project", error);
    if (project == nil) return nil;

    // A project name is a directory name, nothing more: no separators, no `..`.
    NSCharacterSet *illegal = [[NSCharacterSet characterSetWithCharactersInString:@"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-"] invertedSet];
    if ([project rangeOfCharacterFromSet:illegal].location != NSNotFound) {
        if (error) *error = DPSKAgentMakeError(DPSKAgentErrorBadParams, @"`project` must be a plain directory name");
        return nil;
    }

    NSString *root = [DPSKAgentStateDirectory() stringByAppendingPathComponent:@"projects"];
    NSString *directory = [root stringByAppendingPathComponent:project];
    if (![[NSFileManager defaultManager] fileExistsAtPath:directory]) {
        if (error) *error = DPSKAgentMakeError(DPSKAgentErrorBadParams,
                                              [NSString stringWithFormat:@"no project at %@", directory]);
        return nil;
    }

    int output[2] = {-1, -1};
    if (pipe(output) != 0) {
        if (error) *error = DPSKAgentMakeError(DPSKAgentErrorInternal, @"pipe() failed");
        return nil;
    }

    posix_spawn_file_actions_t actions;
    posix_spawn_file_actions_init(&actions);
    posix_spawn_file_actions_addchdir_np(&actions, directory.fileSystemRepresentation);
    posix_spawn_file_actions_adddup2(&actions, output[1], STDOUT_FILENO);
    posix_spawn_file_actions_adddup2(&actions, output[1], STDERR_FILENO);
    posix_spawn_file_actions_addclose(&actions, output[0]);

    char *argv[] = {"make", "package", NULL};
    pid_t child = 0;
    int spawned = posix_spawn(&child, "/usr/bin/make", &actions, NULL, argv, environ);
    posix_spawn_file_actions_destroy(&actions);
    close(output[1]);

    if (spawned != 0) {
        close(output[0]);
        if (error) *error = DPSKAgentMakeError(DPSKAgentErrorInternal,
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
        if (error) *error = DPSKAgentMakeError(DPSKAgentErrorInternal,
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

static NSDictionary *DPSKHandleRequest(NSDictionary *request) {
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
        result = DPSKPing();
    } else if ([method isEqualToString:@"probe.listProcesses"]) {
        result = @{@"processes": DPSKAgentListProcesses()};
    } else if ([method isEqualToString:@"probe.modules"]) {
        if (DPSKResolveTarget(params, &target, &error)) {
            result = @{@"pid": @(target), @"modules": DPSKAgentModulesForPID(target)};
        }
    } else if ([method isEqualToString:@"probe.readMemory"]) {
        result = DPSKHandleRead(params, &error);
    } else if ([method isEqualToString:@"mem.write"]) {
        result = DPSKHandleWrite(params, confirmed, &error);
    } else if ([method isEqualToString:@"tweak.compile"]) {
        result = DPSKHandleCompile(params, &error);
    } else if ([method isEqualToString:@"tweak.inject"]) {
        // Reserved: answering "not implemented" is how a caller learns the
        // difference between "did nothing" and "cannot do this yet".
        error = DPSKAgentMakeError(DPSKAgentErrorNotImplemented, @"tweak.inject is not implemented in this build");
    } else {
        error = DPSKAgentMakeError(DPSKAgentErrorBadParams,
                                   [NSString stringWithFormat:@"unknown method %@", method]);
    }

    if (error != nil) {
        NSString *code = DPSKAgentErrorCodeName((DPSKAgentErrorCode)error.code);
        DPSKAgentLog(@"%@ %@ target=%d -> %@ (%@)", identifier, method, target, code, error.localizedDescription);
        return @{@"id": identifier, @"ok": @NO, @"error": @{@"code": code, @"message": error.localizedDescription ?: @""}};
    }

    DPSKAgentLog(@"%@ %@ target=%d -> ok", identifier, method, target);
    return @{@"id": identifier, @"ok": @YES, @"result": result ?: @{}};
}

#pragma mark - XPC

@interface DPSKAgentListener : NSObject <NSXPCListenerDelegate, DPSKAgentXPC>
@end

@implementation DPSKAgentListener

- (BOOL)listener:(NSXPCListener *)listener shouldAcceptNewConnection:(NSXPCConnection *)connection {
    connection.exportedInterface = [NSXPCInterface interfaceWithProtocol:@protocol(DPSKAgentXPC)];
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
            answer = DPSKHandleRequest(request);
        }
    } @catch (NSException *exception) {
        // A malformed request must not take the service down: the phone's other
        // workbench features are on the other side of this listener.
        DPSKAgentLog(@"exception: %@ %@", exception.name, exception.reason);
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
        DPSKAgentLog(@"agentd 0.1.0 starting (pid %d)", getpid());
        [[DPSKAgentSafety shared] reload];

        NSXPCListener *listener = [[NSXPCListener alloc] initWithMachServiceName:@"com.dpsk.agentd"];
        DPSKAgentListener *delegate = [[DPSKAgentListener alloc] init];
        listener.delegate = delegate;
        [listener resume];
        DPSKAgentLog(@"agentd listening on com.dpsk.agentd");
        [[NSRunLoop currentRunLoop] run];
    }
    return 0;
}
