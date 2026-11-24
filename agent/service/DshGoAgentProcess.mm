#import "DshGoAgentProcess.h"

#import "DshGoAgentLog.h"
#import "DshGoAgentProbe.h"
#import "DshGoAgentSafety.h"

#include <errno.h>
#include <mach/mach.h>
#include <mach/vm_region.h>
#include <string.h>
#include <sys/sysctl.h>

/// The kernel's code-signing query.
///
/// `csops` is not declared in the public SDK headers on every release, and
/// `dlsym` would turn a missing symbol into a nil call at runtime; declaring it
/// keeps a wrong assumption a link error instead. The symbol is in
/// libsystem_kernel and the numbers below are the kernel's own, not guesses:
/// CS_OPS_STATUS is 0 and CS_OPS_ENTITLEMENTS_BLOB is 7.
///
/// `extern "C"` is not decoration: this file is Objective-C++, so a plain
/// declaration would be mangled and the link would fail with
/// `csops(int, unsigned int, void*, unsigned long)` undefined while
/// libsystem_kernel exports `_csops`.
extern "C" int csops(pid_t pid, unsigned int ops, void *useraddr, size_t usersize);

enum {
    DshGoCSOpsStatus = 0,
    DshGoCSOpsEntitlements = 7,

    DshGoCSGetTaskAllow = 0x00000004,
    DshGoCSHard = 0x00000100,
    DshGoCSRestrict = 0x00000800,
    DshGoCSPlatformBinary = 0x04000000,
};

/// How much of one process the scan may read before it stops. A caller asking
/// for a pattern in a 300 MB heap should get an answer, not a hung daemon; this
/// is the ceiling, and the reply says when it was hit.
static const NSUInteger kScanByteBudget = 512u * 1024u * 1024u;

#pragma mark - Mach-O

static uint32_t DshGoBigEndian32(const uint8_t *bytes) {
    return ((uint32_t)bytes[0] << 24) | ((uint32_t)bytes[1] << 16) | ((uint32_t)bytes[2] << 8) | (uint32_t)bytes[3];
}

static uint32_t DshGoLittleEndian32(const uint8_t *bytes) {
    return ((uint32_t)bytes[3] << 24) | ((uint32_t)bytes[2] << 16) | ((uint32_t)bytes[1] << 8) | (uint32_t)bytes[0];
}

static NSString *DshGoArchName(uint32_t cputype, uint32_t cpusubtype) {
    // CPU_TYPE_ARM64 | CPU_ARCH_ABI64, spelled out so the file does not depend on
    // a header that is not in the iOS SDK.
    if (cputype == (12u | 0x01000000u)) {
        switch (cpusubtype & 0x00FFFFFFu) {
            case 1: return @"arm64v8";
            case 2: return @"arm64e";
            default: return @"arm64";
        }
    }
    if (cputype == 12u) return @"armv7";
    if (cputype == (7u | 0x01000000u)) return @"x86_64";
    return [NSString stringWithFormat:@"cputype-%u", cputype];
}

/// The architectures in the file at `path`: one for a thin Mach-O, one per slice
/// for a fat one. Only the header is read - dyld is not involved, so this works
/// for a binary that cannot be launched as well as for a running one.
static NSArray<NSString *> *DshGoArchsAtPath(NSString *path) {
    if (path.length == 0) return @[];
    NSFileHandle *handle = [NSFileHandle fileHandleForReadingAtPath:path];
    if (handle == nil) return @[];
    NSData *head = [handle readDataOfLength:4096];
    [handle closeFile];
    if (head.length < 8) return @[];

    const uint8_t *bytes = (const uint8_t *)head.bytes;
    uint32_t big = DshGoBigEndian32(bytes);
    if (big == 0xCAFEBABEu || big == 0xCAFEBABFu) {
        BOOL wide = big == 0xCAFEBABFu;
        NSUInteger entry = wide ? 32 : 20;
        uint32_t count = DshGoBigEndian32(bytes + 4);
        NSMutableArray<NSString *> *archs = [NSMutableArray array];
        for (uint32_t index = 0; index < count; index++) {
            NSUInteger base = 8 + index * entry;
            if (base + 8 > head.length) break;
            [archs addObject:DshGoArchName(DshGoBigEndian32(bytes + base),
                                           DshGoBigEndian32(bytes + base + 4))];
        }
        return archs;
    }
    if (big == 0xBEBAFECAu || big == 0xBFBAFECAu) {
        BOOL wide = big == 0xBFBAFECAu;
        NSUInteger entry = wide ? 32 : 20;
        uint32_t count = DshGoLittleEndian32(bytes + 4);
        NSMutableArray<NSString *> *archs = [NSMutableArray array];
        for (uint32_t index = 0; index < count; index++) {
            NSUInteger base = 8 + index * entry;
            if (base + 8 > head.length) break;
            [archs addObject:DshGoArchName(DshGoLittleEndian32(bytes + base),
                                           DshGoLittleEndian32(bytes + base + 4))];
        }
        return archs;
    }

    uint32_t little = DshGoLittleEndian32(bytes);
    if (little == 0xFEEDFACFu || little == 0xFEEDFACEu) {
        return @[DshGoArchName(DshGoLittleEndian32(bytes + 4), DshGoLittleEndian32(bytes + 8))];
    }
    return @[];
}

#pragma mark - codesign

static uint32_t DshGoStatusForPID(pid_t pid, BOOL *answered) {
    uint32_t status = 0;
    int result = csops(pid, DshGoCSOpsStatus, &status, sizeof(status));
    if (answered) *answered = result == 0;
    return status;
}

/// The entitlement names `pid` runs with, or nil when the kernel will not say.
///
/// The blob is a property list; rather than assume it starts at byte zero (some
/// releases prefix it), the parser is handed the slice from the first `<` to the
/// last `>` so a prefix or a trailing sentinel cannot make it look corrupt.
static NSArray<NSString *> *_Nullable DshGoEntitlementNamesForPID(pid_t pid) {
    uint8_t buffer[32768];
    memset(buffer, 0, sizeof(buffer));
    if (csops(pid, DshGoCSOpsEntitlements, buffer, sizeof(buffer)) != 0) return nil;

    const char *begin = (const char *)memchr(buffer, '<', sizeof(buffer));
    if (begin == NULL) return nil;
    size_t length = strnlen(begin, sizeof(buffer) - (size_t)(begin - (const char *)buffer));
    if (length == 0) return nil;

    NSData *data = [NSData dataWithBytes:begin length:length];
    id plist = [NSPropertyListSerialization propertyListWithData:data
                                                        options:NSPropertyListImmutable
                                                         format:NULL
                                                          error:NULL];
    if (![plist isKindOfClass:[NSDictionary class]]) return nil;
    NSArray<NSString *> *keys = [[(NSDictionary *)plist allKeys] sortedArrayUsingSelector:@selector(compare:)];
    NSMutableArray<NSString *> *names = [NSMutableArray arrayWithCapacity:keys.count];
    for (id key in keys) {
        if ([key isKindOfClass:[NSString class]]) [names addObject:key];
    }
    return names;
}

#pragma mark - probe

BOOL DshGoAgentAttachable(pid_t pid, NSError **error) {
    mach_port_t task = MACH_PORT_NULL;
    kern_return_t kr = task_for_pid(mach_task_self(), pid, &task);
    if (kr != KERN_SUCCESS) {
        if (error) {
            *error = DshGoAgentMakeError(DshGoAgentErrorAttachFailed,
                [NSString stringWithFormat:@"task_for_pid(%d) failed: %s; the daemon needs com.apple.private.cs.debugger and a trust cache entry",
                                           pid, mach_error_string(kr)]);
        }
        return NO;
    }
    mach_port_deallocate(mach_task_self(), task);
    return YES;
}

NSDictionary *DshGoAgentProcessInfo(pid_t pid, NSError **error) {
    int mib[4] = {CTL_KERN, KERN_PROC, KERN_PROC_PID, pid};
    struct kinfo_proc entry;
    size_t size = sizeof(entry);
    memset(&entry, 0, sizeof(entry));
    if (sysctl(mib, 4, &entry, &size, NULL, 0) != 0 || size == 0) {
        if (error) {
            *error = DshGoAgentMakeError(DshGoAgentErrorBadParams,
                                         [NSString stringWithFormat:@"no process with pid %d", pid]);
        }
        return nil;
    }

    NSMutableDictionary *info = [NSMutableDictionary dictionary];
    info[@"pid"] = @(pid);
    info[@"uid"] = @(entry.kp_eproc.e_ucred.cr_uid);
    info[@"ppid"] = @(entry.kp_eproc.e_ppid);

    NSString *path = DshGoAgentExecutablePathForPID(pid);
    if (path.length > 0) {
        info[@"path"] = path;
        info[@"name"] = path.lastPathComponent;
    } else {
        info[@"name"] = @(entry.kp_proc.p_comm);
    }

    NSString *bundleId = DshGoAgentBundleIdForPID(pid);
    if (bundleId.length > 0) info[@"bundleId"] = bundleId;

    // The executable's own header says which architectures it can be: a fat app
    // is arm64 + arm64e, and a caller that hooks it needs to know which one the
    // running process is. kp_proc.p_flag cannot answer that.
    NSArray<NSString *> *archs = DshGoArchsAtPath(path);
    if (archs.count > 0) {
        info[@"archs"] = archs;
        info[@"arch"] = archs.firstObject;
    }

    BOOL statusAnswered = NO;
    uint32_t status = DshGoStatusForPID(pid, &statusAnswered);
    if (statusAnswered) {
        info[@"platformBinary"] = @((status & DshGoCSPlatformBinary) != 0);
        info[@"restricted"] = @((status & DshGoCSRestrict) != 0);
        info[@"hardened"] = @((status & DshGoCSHard) != 0);
        info[@"debuggable"] = @((status & DshGoCSGetTaskAllow) != 0);
    }

    NSArray<NSString *> *entitlements = DshGoEntitlementNamesForPID(pid);
    if (entitlements != nil) info[@"entitlements"] = entitlements;

    // The one field that decides whether any of the rest is actionable. Asking
    // for the port and giving it straight back changes nothing about the target
    // but proves the entitlements and the trust cache are in effect.
    NSError *attachError = nil;
    info[@"attachable"] = @(DshGoAgentAttachable(pid, &attachError));
    if (attachError != nil) info[@"attachError"] = attachError.localizedDescription ?: @"";
    return info;
}

#pragma mark - scan

NSArray<NSNumber *> *DshGoAgentScanMemory(pid_t pid, NSData *pattern, NSData *mask,
                                          uint64_t start, uint64_t end, NSUInteger limit,
                                          NSError **error) {
    if (pattern.length == 0) {
        if (error) *error = DshGoAgentMakeError(DshGoAgentErrorBadParams, @"`pattern` must not be empty");
        return @[];
    }
    if (mask.length != pattern.length) {
        if (error) *error = DshGoAgentMakeError(DshGoAgentErrorBadParams, @"`pattern` and its mask must have the same length");
        return @[];
    }
    if (end <= start) {
        if (error) *error = DshGoAgentMakeError(DshGoAgentErrorBadParams, @"`end` must be greater than `start`");
        return @[];
    }
    if (limit == 0) limit = 64;

    mach_port_t task = MACH_PORT_NULL;
    kern_return_t kr = task_for_pid(mach_task_self(), pid, &task);
    if (kr != KERN_SUCCESS) {
        if (error) {
            *error = DshGoAgentMakeError(DshGoAgentErrorAttachFailed,
                [NSString stringWithFormat:@"task_for_pid(%d) failed: %s", pid, mach_error_string(kr)]);
        }
        return @[];
    }

    const uint8_t *needle = (const uint8_t *)pattern.bytes;
    const uint8_t *wildcard = (const uint8_t *)mask.bytes;
    NSUInteger needleLength = pattern.length;
    NSMutableArray<NSNumber *> *matches = [NSMutableArray arrayWithCapacity:limit];

    const NSUInteger chunk = 64 * 1024;
    NSUInteger scanned = 0;
    vm_address_t address = (vm_address_t)start;
    natural_t depth = 0;

    while (address < (vm_address_t)end && matches.count < limit && scanned < kScanByteBudget) {
        vm_size_t regionSize = 0;
        vm_region_submap_info_data_64_t info;
        mach_msg_type_number_t count = VM_REGION_SUBMAP_INFO_COUNT_64;
        kern_return_t walked = vm_region_recurse_64(task, &address, &regionSize, &depth,
                                                    (vm_region_info_t)&info, &count);
        if (walked != KERN_SUCCESS) break;

        // A submap is a container of regions, not a region: descend instead of
        // advancing past it, or everything inside it is skipped.
        if (info.is_submap) {
            depth++;
            continue;
        }
        if ((info.protection & VM_PROT_READ) == 0 || regionSize == 0) {
            address += regionSize;
            continue;
        }

        vm_address_t cursor = address;
        vm_address_t regionEnd = address + regionSize;
        if (regionEnd > (vm_address_t)end) regionEnd = (vm_address_t)end;
        address += regionSize;

        while (cursor < regionEnd && matches.count < limit && scanned < kScanByteBudget) {
            uint64_t remaining = (uint64_t)(regionEnd - cursor);
            vm_size_t want = (vm_size_t)(remaining < (uint64_t)chunk ? remaining : (uint64_t)chunk);
            NSMutableData *buffer = [NSMutableData dataWithLength:want];
            vm_size_t got = 0;
            kern_return_t read = vm_read_overwrite(task, cursor, want,
                                                   (vm_address_t)buffer.mutableBytes, &got);
            if (read == KERN_SUCCESS && got >= (vm_size_t)needleLength) {
                const uint8_t *bytes = (const uint8_t *)buffer.bytes;
                NSUInteger span = (NSUInteger)got - needleLength;
                for (NSUInteger offset = 0; offset <= span; offset++) {
                    BOOL hit = YES;
                    for (NSUInteger index = 0; index < needleLength; index++) {
                        if (wildcard[index] != 0) continue;
                        if (bytes[offset + index] != needle[index]) {
                            hit = NO;
                            break;
                        }
                    }
                    if (hit) {
                        [matches addObject:@((uint64_t)(cursor + offset))];
                        if (matches.count >= limit) break;
                    }
                }
            }
            scanned += (NSUInteger)want;
            if (want == 0) break;
            cursor += want;
        }
    }

    mach_port_deallocate(mach_task_self(), task);
    return matches;
}