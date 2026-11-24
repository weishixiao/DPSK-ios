#import "DshGoAgentProbe.h"

#import "DshGoAgentLog.h"
#import "DshGoAgentSafety.h"

#include <libproc.h>
#include <mach/mach.h>
#include <string.h>
#include <sys/proc_info.h>

NSString *DshGoAgentBundleIdForPID(pid_t pid) {
    char path[PROC_PIDPATHINFO_MAXSIZE] = {0};
    if (proc_pidpath(pid, path, sizeof(path)) <= 0) return nil;

    NSString *executable = @(path);
    // An app's bundle is the .app that contains the executable. Anything else
    // (a system daemon, a dylib host) has no bundle id and cannot be named in an
    // allowlist, which is the point: those are not targets.
    NSRange range = [executable rangeOfString:@".app/" options:NSBackwardsSearch];
    if (range.location == NSNotFound) return nil;

    NSString *bundle = [executable substringToIndex:range.location + 4];
    NSString *plist = [bundle stringByAppendingPathComponent:@"Info.plist"];
    NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:plist];
    id identifier = info[@"CFBundleIdentifier"];
    return [identifier isKindOfClass:[NSString class]] ? identifier : nil;
}

NSArray<NSDictionary *> *DshGoAgentListProcesses(void) {
    int count = proc_listallpids(NULL, 0);
    if (count <= 0) return @[];

    // Room for the pids that appear while the buffer is being filled.
    int capacity = count + 64;
    pid_t *pids = calloc((size_t)capacity, sizeof(pid_t));
    if (pids == NULL) return @[];

    int filled = proc_listallpids(pids, capacity * (int)sizeof(pid_t));
    NSMutableArray<NSDictionary *> *processes = [NSMutableArray arrayWithCapacity:(NSUInteger)MAX(filled, 0)];

    for (int index = 0; index < filled; index++) {
        pid_t pid = pids[index];
        if (pid <= 0) continue;

        char path[PROC_PIDPATHINFO_MAXSIZE] = {0};
        if (proc_pidpath(pid, path, sizeof(path)) <= 0) continue;

        struct proc_bsdinfo info = {0};
        int size = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, (int)sizeof(info));

        NSString *fullPath = @(path);
        NSMutableDictionary *entry = [NSMutableDictionary dictionary];
        entry[@"pid"] = @(pid);
        entry[@"path"] = fullPath;
        entry[@"name"] = fullPath.lastPathComponent ?: @"";
        if (size == (int)sizeof(info)) {
            entry[@"uid"] = @(info.pbi_uid);
            NSString *name = @(info.pbi_name);
            if (name.length > 0) entry[@"name"] = name;
        }
        NSString *bundleId = DshGoAgentBundleIdForPID(pid);
        if (bundleId) entry[@"bundleId"] = bundleId;

        [processes addObject:entry];
    }
    free(pids);

    [processes sortUsingComparator:^NSComparisonResult(NSDictionary *left, NSDictionary *right) {
        return [left[@"name"] localizedCaseInsensitiveCompare:right[@"name"]];
    }];
    return processes;
}

NSArray<NSDictionary *> *DshGoAgentModulesForPID(pid_t pid) {
    NSMutableArray<NSDictionary *> *modules = [NSMutableArray array];
    NSMutableSet<NSString *> *seen = [NSMutableSet set];

    // Walk the target's memory map and keep the images. `PROC_PIDREGIONPATHINFO`
    // reports the file behind a mapping, so this needs no `task_for_pid` and
    // cannot disturb the target.
    uint64_t address = 0;
    while (true) {
        struct proc_regionwithpathinfo info = {0};
        int size = proc_pidinfo(pid, PROC_PIDREGIONPATHINFO, (uint64_t)address, &info, (int)sizeof(info));
        if (size != (int)sizeof(info)) break;

        uint64_t next = info.prp_prinfo.pri_address + info.prp_prinfo.pri_size;
        if (next <= address) break;
        address = next;

        const char *path = info.prp_vip.vip_path;
        if (path == NULL || path[0] == '\0') continue;

        // Only the executable and the images that are code or bundles: a target
        // maps data files too, and those are noise in a module list.
        NSString *file = @(path);
        if (!([file hasSuffix:@".dylib"] || [file containsString:@".app/"] || [file containsString:@".framework/"])) continue;
        if ([seen containsObject:file]) continue;
        [seen addObject:file];

        [modules addObject:@{
            @"path": file,
            @"base": [NSString stringWithFormat:@"%llx", info.prp_prinfo.pri_address],
            @"size": @(info.prp_prinfo.pri_size),
        }];
    }
    return modules;
}

static kern_return_t DshGoaskForPID(pid_t pid, mach_port_t *task) {
    // Never `mach_task_self()`: writing to our own task by accident is not a
    // failure mode worth leaving open.
    return task_for_pid(mach_task_self(), pid, task);
}

NSData *DshGoAgentReadMemory(pid_t pid, uint64_t address, NSUInteger length, NSError **error) {
    mach_port_t task = MACH_PORT_NULL;
    kern_return_t kr = DshGoaskForPID(pid, &task);
    if (kr != KERN_SUCCESS) {
        if (error) *error = DshGoAgentMakeError(DshGoAgentErrorAttachFailed,
                                              [NSString stringWithFormat:@"task_for_pid(%d) failed: %s", pid, mach_error_string(kr)]);
        return nil;
    }

    NSMutableData *buffer = [NSMutableData dataWithLength:length];
    mach_vm_size_t read_bytes = 0;
    kr = mach_vm_read_overwrite(task, (mach_vm_address_t)address, (mach_vm_size_t)length,
                                (mach_vm_address_t)buffer.mutableBytes, &read_bytes);
    mach_port_deallocate(mach_task_self(), task);

    if (kr != KERN_SUCCESS) {
        if (error) *error = DshGoAgentMakeError(DshGoAgentErrorAttachFailed,
                                              [NSString stringWithFormat:@"mach_vm_read at %llx failed: %s", address, mach_error_string(kr)]);
        return nil;
    }
    buffer.length = (NSUInteger)read_bytes;
    return buffer;
}

BOOL DshGoAgentWriteMemory(pid_t pid, uint64_t address, NSData *data, NSError **error) {
    mach_port_t task = MACH_PORT_NULL;
    kern_return_t kr = DshGoaskForPID(pid, &task);
    if (kr != KERN_SUCCESS) {
        if (error) *error = DshGoAgentMakeError(DshGoAgentErrorAttachFailed,
                                              [NSString stringWithFormat:@"task_for_pid(%d) failed: %s", pid, mach_error_string(kr)]);
        return NO;
    }

    // `mach_vm_write` takes a byte count, not a page count, and fails on the
    // first unmapped byte: a short write is a refused write, not a partial edit.
    kr = mach_vm_write(task, (mach_vm_address_t)address, (vm_offset_t)data.bytes,
                       (mach_msg_type_number_t)data.length);
    mach_port_deallocate(mach_task_self(), task);

    if (kr != KERN_SUCCESS) {
        if (error) *error = DshGoAgentMakeError(DshGoAgentErrorAttachFailed,
                                              [NSString stringWithFormat:@"mach_vm_write at %llx failed: %s", address, mach_error_string(kr)]);
        return NO;
    }
    return YES;
}
