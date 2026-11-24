#import "DshGoAgentProbe.h"

#import "DshGoAgentLog.h"
#import "DshGoAgentSafety.h"

#include <mach/mach.h>
#include <mach/mach_vm.h>
#include <string.h>
#include <sys/sysctl.h>
#include <sys/types.h>

/// The executable path of a pid, without libproc.
///
/// libproc is macOS-only, so on iOS the same answer comes from KERN_PROCARGS2,
/// which starts with the argument count followed by the nul-separated argv.
static NSString *DshGoAgentExecutablePath(pid_t pid) {
    int mib[3] = {CTL_KERN, KERN_PROCARGS2, pid};
    size_t size = 0;
    if (sysctl(mib, 3, NULL, &size, NULL, 0) != 0 || size == 0) return nil;
    char *buffer = (char *)malloc(size);
    if (buffer == NULL) return nil;
    if (sysctl(mib, 3, buffer, &size, NULL, 0) != 0) {
        free(buffer);
        return nil;
    }
    int count = 0;
    memcpy(&count, buffer, sizeof(count));
    if (count <= 0) {
        free(buffer);
        return nil;
    }
    // argv[0] follows the count and the executable path, each nul-terminated.
    char *cursor = buffer + sizeof(count);
    char *end = buffer + size;
    while (cursor < end && *cursor != '\0') cursor++;
    while (cursor < end && *cursor == '\0') cursor++;
    NSString *executable = cursor < end ? @(cursor) : nil;
    free(buffer);
    return executable;
}

NSString *DshGoAgentBundleIdForPID(pid_t pid) {
    NSString *executable = DshGoAgentExecutablePath(pid);
    if (executable.length == 0) return nil;
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
    // KERN_PROC_ALL rather than libproc: that header is macOS-only.
    int mib[4] = {CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0};
    size_t size = 0;
    if (sysctl(mib, 4, NULL, &size, NULL, 0) != 0 || size == 0) return @[];
    // Ask again with a little headroom: the table grows between the two calls.
    size += size / 8;
    struct kinfo_proc *table = (struct kinfo_proc *)malloc(size);
    if (table == NULL) return @[];
    if (sysctl(mib, 4, table, &size, NULL, 0) != 0) {
        free(table);
        return @[];
    }

    size_t count = size / sizeof(struct kinfo_proc);
    NSMutableArray<NSDictionary *> *processes = [NSMutableArray arrayWithCapacity:count];
    for (size_t index = 0; index < count; index++) {
        pid_t pid = table[index].kp_proc.p_pid;
        if (pid <= 0) continue;

        NSMutableDictionary *entry = [NSMutableDictionary dictionary];
        entry[@"pid"] = @(pid);
        entry[@"name"] = @(table[index].kp_proc.p_comm);
        entry[@"uid"] = @(table[index].kp_eproc.e_ucred.cr_uid);
        NSString *executable = DshGoAgentExecutablePath(pid);
        if (executable.length > 0) {
            entry[@"path"] = executable;
            entry[@"name"] = executable.lastPathComponent ?: entry[@"name"];
        }
        NSString *bundleId = DshGoAgentBundleIdForPID(pid);
        if (bundleId) entry[@"bundleId"] = bundleId;
        [processes addObject:entry];
    }
    free(table);
    [processes sortUsingComparator:^NSComparisonResult(NSDictionary *left, NSDictionary *right) {
        return [left[@"name"] localizedCaseInsensitiveCompare:right[@"name"]];
    }];
    return processes;
}

NSArray<NSDictionary *> *DshGoAgentModulesForPID(pid_t pid) {
    // Not implemented on iOS. libproc (which reports the file behind a
    // mapping) is macOS-only, and dyld_all_image_infos lives in the target's
    // own address space, so reading it means parsing remote structures that
    // change shape between iOS releases. An empty list is honest about that;
    // guessing at offsets would be worse than saying nothing.
    (void)pid;
    return @[];
}
static kern_return_t DshGoAskForPID(pid_t pid, mach_port_t *task) {
    // Never `mach_task_self()`: writing to our own task by accident is not a
    // failure mode worth leaving open.
    return task_for_pid(mach_task_self(), pid, task);
}

NSData *DshGoAgentReadMemory(pid_t pid, uint64_t address, NSUInteger length, NSError **error) {
    mach_port_t task = MACH_PORT_NULL;
    kern_return_t kr = DshGoAskForPID(pid, &task);
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
    kern_return_t kr = DshGoAskForPID(pid, &task);
    if (kr != KERN_SUCCESS) {
        if (error) *error = DshGoAgentMakeError(DshGoAgentErrorAttachFailed,
                                              [NSString stringWithFormat:@"task_for_pid(%d) failed: %s", pid, mach_error_string(kr)]);
        return NO;
    }

    // `mach_vm_write` takes a byte count, not a page count, and fails on the
    // first unmapped byte: a short write is a refused write, not a partial edit.
    kr = mach_vm_write(task, (mach_vm_address_t)address, (vm_offset_t)(uintptr_t)data.bytes,
                       (mach_msg_type_number_t)data.length);
    mach_port_deallocate(mach_task_self(), task);

    if (kr != KERN_SUCCESS) {
        if (error) *error = DshGoAgentMakeError(DshGoAgentErrorAttachFailed,
                                              [NSString stringWithFormat:@"mach_vm_write at %llx failed: %s", address, mach_error_string(kr)]);
        return NO;
    }
    return YES;
}
