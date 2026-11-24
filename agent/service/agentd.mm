// The privileged half of the workbench.
//
// It runs from launchd, outside the app's sandbox, which is the only place
// `task_for_pid` and `vm_read_overwrite` work on a RootHide device. The app and
// the harness never link any of this: they send JSON to the Mach service below,
// and what comes back is a record of what happened, never a live handle.
//
// Everything a request can reach is in `DshGoAgentSafety` first: this file has no
// path around the allowlist or around the confirmation flag.

#import <Foundation/Foundation.h>

#import "DshGoAgentExec.h"
#import "DshGoAgentFrida.h"
#import "DshGoAgentLog.h"
#import "DshGoAgentProbe.h"
#import "DshGoAgentProcess.h"
#import "DshGoAgentProject.h"
#import "DshGoAgentSafety.h"

#include <signal.h>
#include <spawn.h>
#include <sys/wait.h>
#include <unistd.h>

extern char **environ;

static const NSUInteger kMaxPayload = 1024 * 1024;
static const NSUInteger kMaxReadLength = 64 * 1024;
static const NSUInteger kMaxWriteLength = 4 * 1024;
static const NSUInteger kMaxPatternBytes = 256;
static const NSUInteger kMaxScanMatches = 4096;

@protocol DshGoAgentXPC <NSObject>
- (void)call:(NSData *)payload reply:(void (^)(NSData *reply))reply;
@end

#pragma mark - Handlers

static NSDictionary *DshGoPing(void) {
    return @{
        @"version": @"0.2.0",
        @"pid": @(getpid()),
        @"uptime": @([[NSProcessInfo processInfo] systemUptime]),
        @"allowlist": [[DshGoAgentSafety shared] allowedBundleIds],
        // What the daemon resolved the jailbreak root to be. On RootHide it is
        // randomized per boot and `/var/jb` does not exist, so a caller that
        // needs a path under it should read it here instead of assuming.
        @"root": DshGoJailbreakRoot(),
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
    const uint8_t *bytes = (const uint8_t *)data.bytes;
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

/// One hex byte pair, written out here because `DshGoAgentSafety`'s parser is
/// `static` to its own file and intra-file helpers are not a public interface.
static BOOL DshGoBytePair(NSString *pair, uint8_t *out) {
    int digits[2] = {-1, -1};
    for (NSUInteger index = 0; index < 2; index++) {
        unichar c = [pair characterAtIndex:index];
        if (c >= '0' && c <= '9') digits[index] = c - '0';
        else if (c >= 'a' && c <= 'f') digits[index] = c - 'a' + 10;
        else if (c >= 'A' && c <= 'F') digits[index] = c - 'A' + 10;
        else return NO;
    }
    *out = (uint8_t)((digits[0] << 4) | digits[1]);
    return YES;
}

/// Parse a hex pattern in which `??` is a wildcard byte.
///
/// `mem.write` is strict hex because a write must not have holes; a search is
/// the one caller that legitimately wants "any byte here", so it gets its own
/// parser instead of a flag that loosens the write path.
static NSData *DshGoPatternParam(NSDictionary *params, NSString *key, NSData **maskOut, NSError **error) {
    id value = params[key];
    if (![value isKindOfClass:[NSString class]]) {
        if (error) {
            *error = DshGoAgentMakeError(DshGoAgentErrorBadParams,
                [NSString stringWithFormat:@"`%@` must be a hex string, with ?? for a wildcard byte", key]);
        }
        return nil;
    }
    NSString *text = value;
    NSMutableString *clean = [NSMutableString stringWithCapacity:text.length];
    for (NSUInteger index = 0; index < text.length; index++) {
        unichar c = [text characterAtIndex:index];
        if (c == ' ' || c == '-' || c == ',' || c == '\t' || c == '\n') continue;
        [clean appendFormat:@"%C", c];
    }
    if (clean.length == 0 || clean.length % 2 != 0) {
        if (error) {
            *error = DshGoAgentMakeError(DshGoAgentErrorBadParams,
                [NSString stringWithFormat:@"`%@` must be an even number of hex digits or ??", key]);
        }
        return nil;
    }
    NSUInteger bytes = clean.length / 2;
    if (bytes > kMaxPatternBytes) {
        if (error) {
            *error = DshGoAgentMakeError(DshGoAgentErrorBadParams,
                [NSString stringWithFormat:@"`%@` is limited to %lu bytes", key, (unsigned long)kMaxPatternBytes]);
        }
        return nil;
    }

    NSMutableData *pattern = [NSMutableData dataWithCapacity:bytes];
    NSMutableData *mask = [NSMutableData dataWithCapacity:bytes];
    for (NSUInteger index = 0; index < bytes; index++) {
        NSString *pair = [clean substringWithRange:NSMakeRange(index * 2, 2)];
        uint8_t byte = 0;
        uint8_t maskByte = 0xFF;
        if ([pair isEqualToString:@"??"]) {
            byte = 0;
            maskByte = 0;
        } else if (!DshGoBytePair(pair, &byte)) {
            if (error) {
                *error = DshGoAgentMakeError(DshGoAgentErrorBadParams,
                    [NSString stringWithFormat:@"`%@` has a non-hex byte \"%@\"", key, pair]);
            }
            return nil;
        }
        [pattern appendBytes:&byte length:1];
        [mask appendBytes:&maskByte length:1];
    }
    *maskOut = mask;
    return pattern;
}

/// Search one of the owner's processes for a byte pattern.
///
/// Read-only, and bounded: the pattern is capped, the match count is capped, the
/// byte budget lives in `DshGoAgentScanMemory`, and the default range is the
/// arm64 app space rather than the whole address space.
static id DshGoHandleScan(NSDictionary *params, NSError **error) {
    pid_t pid = 0;
    if (!DshGoResolveTarget(params, &pid, error)) return nil;

    NSData *mask = nil;
    NSData *pattern = DshGoPatternParam(params, @"pattern", &mask, error);
    if (pattern == nil) return nil;

    uint64_t start = 0x100000000ULL;
    uint64_t end = 0x2000000000ULL;
    if (params[@"start"] != nil) {
        if (!DshGoAgentAddressParam(params, @"start", &start, error)) return nil;
    }
    if (params[@"end"] != nil) {
        if (!DshGoAgentAddressParam(params, @"end", &end, error)) return nil;
    }

    NSInteger limit = 64;
    if (params[@"limit"] != nil) {
        if (!DshGoAgentIntegerParam(params, @"limit", 1, (NSInteger)kMaxScanMatches, &limit, error)) return nil;
    }

    NSArray<NSNumber *> *matches = DshGoAgentScanMemory(pid, pattern, mask, start, end, (NSUInteger)limit, error);
    if (matches == nil) return nil;

    NSMutableArray<NSString *> *addresses = [NSMutableArray arrayWithCapacity:matches.count];
    for (NSNumber *address in matches) {
        [addresses addObject:[NSString stringWithFormat:@"%llx", address.unsignedLongLongValue]];
    }
    return @{
        @"pid": @(pid),
        @"matches": addresses,
        @"count": @(addresses.count),
        @"start": [NSString stringWithFormat:@"%llx", start],
        @"end": [NSString stringWithFormat:@"%llx", end],
        @"bounded": @(addresses.count >= (NSUInteger)limit),
    };
}

/// Start the Frida server on loopback.
///
/// The confirmation flag is not ceremony here: a listening Frida server hands
/// full instrumentation of anything the daemon can attach to, to any local
/// process that can open the port - which is a bigger surface than any single
/// `mem.write` and outlives the request that opened it.
static id DshGoHandleFridaStart(NSDictionary *params, BOOL confirmed, NSError **error) {
    if (!confirmed) {
        if (error) {
            *error = DshGoAgentMakeError(DshGoAgentErrorConfirmationRequired,
                @"frida.start opens a listening socket; send it with confirmed:true");
        }
        return nil;
    }
    NSInteger port = 27042;
    if (params[@"port"] != nil) {
        if (!DshGoAgentIntegerParam(params, @"port", 1024, 65535, &port, error)) return nil;
    }
    return DshGoAgentFridaStart((uint16_t)port, error);
}

/// Run one Frida script against one of the owner's processes.
///
/// Also confirmed: the script runs with the daemon's identity, so it can reach
/// exactly what `mem.write` can reach and more, and unlike a memory write its
/// effects are not bounded by a length the caller declared up front.
static id DshGoHandleFridaInject(NSDictionary *params, BOOL confirmed, NSError **error) {
    if (!confirmed) {
        if (error) {
            *error = DshGoAgentMakeError(DshGoAgentErrorConfirmationRequired,
                @"frida.inject runs a script with the daemon's identity; send it with confirmed:true");
        }
        return nil;
    }
    pid_t pid = 0;
    if (!DshGoResolveTarget(params, &pid, error)) return nil;

    NSString *script = DshGoAgentStringParam(params, @"script", error);
    if (script == nil) return nil;

    NSInteger timeoutSeconds = 15;
    if (params[@"timeout"] != nil) {
        if (!DshGoAgentIntegerParam(params, @"timeout", 1, 120, &timeoutSeconds, error)) return nil;
    }
    return DshGoAgentFridaInject(pid, script, (NSTimeInterval)timeoutSeconds, error);
}

/// Build one of the owner's projects with the toolchain on this device.
///
/// `make` is resolved the way every other program is - through the executable
/// directories, which on RootHide live under the root the daemon was launched
/// from - because `/usr/bin/make` is where it *isn't* on a rootless install.
/// The argv is fixed: a request names a project, never a command. `-C` is how the
/// build runs inside the project rather than in the daemon's own directory, which
/// is where a bare `make package` used to run.
///
/// A non-zero exit is not an error reply: the log is the useful part of a failed
/// build, and turning it into a one-line error would throw away the compiler's
/// own answer to what went wrong. The caller reads `exit` and `output`.
static id DshGoHandleBuild(NSDictionary *params, NSError **error) {
    NSString *project = DshGoAgentStringParam(params, @"project", error);
    if (project == nil) return nil;

    NSString *directory = DshGoAgentProjectDirectory(project, NO, error);
    if (directory == nil) return nil;

    NSString *make = [DshGoAgentExec resolveBinary:@"make"];
    if (make == nil) {
        if (error) {
            *error = DshGoAgentMakeError(DshGoAgentErrorNotImplemented,
                [NSString stringWithFormat:@"make is not in any of the executable directories under \"%@\"; install the toolchain for this root",
                                           DshGoJailbreakRoot()]);
        }
        return nil;
    }

    NSMutableArray<NSString *> *arguments = [NSMutableArray arrayWithObjects:
        @"-C", directory, @"package", @"FINALPACKAGE=1", nil];
    id extra = params[@"args"];
    if (extra != nil) {
        if (![extra isKindOfClass:[NSArray class]]) {
            if (error) *error = DshGoAgentMakeError(DshGoAgentErrorBadParams, @"`args` must be an array of strings");
            return nil;
        }
        for (id item in extra) {
            if (![item isKindOfClass:[NSString class]]) {
                if (error) *error = DshGoAgentMakeError(DshGoAgentErrorBadParams, @"`args` must be an array of strings");
                return nil;
            }
            [arguments addObject:item];
        }
    }

    NSDictionary *run = [DshGoAgentExec runPath:make arguments:arguments timeout:600 error:error];
    if (run == nil) return nil;

    NSString *deb = DshGoAgentProjectNewestDeb(directory);
    NSMutableDictionary *reply = [run mutableCopy];
    reply[@"project"] = project;
    reply[@"artifact"] = deb ?: @"";
    return reply;
}

/// Write the files of one of the owner's projects.
///
/// The source is the agent's, the directory is the daemon's: `tweak.write` is how
/// generated code becomes something `build.package` can compile, and it is
/// confined to `projects/` so that it stays that and nothing more.
static id DshGoHandleProjectWrite(NSDictionary *params, NSError **error) {
    NSString *project = DshGoAgentStringParam(params, @"project", error);
    if (project == nil) return nil;
    id files = params[@"files"];
    if (![files isKindOfClass:[NSDictionary class]]) {
        if (error) *error = DshGoAgentMakeError(DshGoAgentErrorBadParams, @"`files` must be an object of name -> contents");
        return nil;
    }
    return DshGoAgentProjectWrite(project, files, error);
}

/// Install the .deb a build produced.
///
/// Needs `confirmed`: `dpkg -i` runs maintainer scripts as root, and the daemon is
/// root. It only ever installs the newest package inside one of the owner's own
/// projects, so "install what I just built" cannot be widened into "install any
/// file on this device" by a single field.
///
/// RootHide keeps its own trust cache: a dylib that `dpkg` placed is not
/// necessarily executable until `jbctl trustcache add` has seen it, which the
/// caller does with `exec.run` because the path depends on the package layout
/// rather than on anything the daemon knows.
static id DshGoHandleInstall(NSDictionary *params, BOOL confirmed, NSError **error) {
    if (!confirmed) {
        if (error) {
            *error = DshGoAgentMakeError(DshGoAgentErrorConfirmationRequired,
                @"installing a package runs its scripts as root; send it with confirmed:true");
        }
        return nil;
    }
    NSString *project = DshGoAgentStringParam(params, @"project", error);
    if (project == nil) return nil;

    NSString *directory = DshGoAgentProjectDirectory(project, NO, error);
    if (directory == nil) return nil;

    NSString *deb = DshGoAgentProjectNewestDeb(directory);
    if (deb == nil) {
        if (error) {
            *error = DshGoAgentMakeError(DshGoAgentErrorBadParams,
                [NSString stringWithFormat:@"no .deb under %@/packages; run build.package first", directory]);
        }
        return nil;
    }

    NSString *dpkg = [DshGoAgentExec resolveBinary:@"dpkg"];
    if (dpkg == nil) {
        if (error) {
            *error = DshGoAgentMakeError(DshGoAgentErrorNotImplemented,
                [NSString stringWithFormat:@"dpkg is not in any of the executable directories under \"%@\"", DshGoJailbreakRoot()]);
        }
        return nil;
    }

    NSDictionary *run = [DshGoAgentExec runPath:dpkg arguments:@[@"-i", deb] timeout:180 error:error];
    if (run == nil) return nil;

    NSMutableDictionary *reply = [run mutableCopy];
    reply[@"project"] = project;
    reply[@"package"] = deb;
    return reply;
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
    } else if ([method isEqualToString:@"proc.info"]) {
        if (DshGoResolveTarget(params, &target, &error)) {
            result = DshGoAgentProcessInfo(target, &error);
        }
    } else if ([method isEqualToString:@"proc.attach"]) {
        // The one call that proves the entitlements are in effect: it asks for
        // the task port and gives it back. A caller that only wants the yes/no
        // should not pay for the Mach-O read in `proc.info`.
        if (DshGoResolveTarget(params, &target, &error)) {
            NSError *attachError = nil;
            BOOL attachable = DshGoAgentAttachable(target, &attachError);
            if (attachError != nil) {
                error = attachError;
            } else {
                result = @{@"pid": @(target), @"attachable": @(attachable)};
            }
        }
    } else if ([method isEqualToString:@"mem.scan"]) {
        result = DshGoHandleScan(params, &error);
    } else if ([method isEqualToString:@"frida.status"]) {
        result = DshGoAgentFridaStatus();
    } else if ([method isEqualToString:@"frida.start"]) {
        result = DshGoHandleFridaStart(params, confirmed, &error);
    } else if ([method isEqualToString:@"frida.stop"]) {
        if (DshGoAgentFridaStop(&error)) result = @{@"stopped": @YES};
    } else if ([method isEqualToString:@"frida.inject"]) {
        result = DshGoHandleFridaInject(params, confirmed, &error);
    } else if ([method isEqualToString:@"exec.run"]) {
        result = DshGoAgentHandleExec(params, confirmed, &error);
    } else if ([method isEqualToString:@"fs.read"]) {
        result = DshGoAgentHandleReadFile(params, &error);
    } else if ([method isEqualToString:@"tweak.write"]) {
        result = DshGoHandleProjectWrite(params, &error);
    } else if ([method isEqualToString:@"tweak.compile"] || [method isEqualToString:@"build.package"]) {
        // `tweak.compile` is the name the protocol had before there was a deb to
        // name; `build.package` is the same work with the artifact it produces.
        // Both answer the same reply, so a caller that learned one keeps working.
        result = DshGoHandleBuild(params, &error);
    } else if ([method isEqualToString:@"pkg.install"]) {
        result = DshGoHandleInstall(params, confirmed, &error);
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
