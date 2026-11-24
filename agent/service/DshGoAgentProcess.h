#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// What the daemon can say about a process it did not start.
///
/// This is the half of the workbench the app cannot have: on iOS the app is
/// sandboxed and carries no `task_for_pid` entitlement, so every fact below -
/// the architecture of the executable, the entitlements the target runs with,
/// whether a write would even be possible - has to come from the daemon.
///
/// Nothing here trusts its input: the pid already passed the allowlist check in
/// `DshGoAgentSafety`, and a syscall that fails produces a dictionary missing
/// the field rather than a lie, so a caller can tell "no data" from "empty".

/// One dictionary: pid, name, uid, path, bundleId when the target is an app,
/// archs (thin or fat), arch (the first), and, when `csops` answers: entitlements
/// (the names the target runs with), platformBinary, restricted, hardened,
/// debuggable, plus `attachable` - the result of actually asking for the task
/// port, which is the only answer that matters for ptrace and memory work.
NSDictionary *DshGoAgentProcessInfo(pid_t pid, NSError *_Nullable *_Nullable error);

/// Whether a `task_for_pid` on `pid` succeeds right now. Kept separate from
/// `DshGoAgentProcessInfo` for the callers that only want the yes/no: the full
/// dictionary costs a Mach-O read and a `csops` that a probe does not need.
BOOL DshGoAgentAttachable(pid_t pid, NSError *_Nullable *_Nullable error);

/// Every address in `pid` where `pattern` matches, honouring `mask` (a non-zero
/// mask byte means "compare", zero means "any"), between `start` and `end`.
///
/// Reads through `vm_region_recurse_64` rather than walking the address space:
/// unmapped gaps cost one syscall each, so a scan of a whole app's space is
/// proportional to what it has mapped. The walk is bounded by `limit` matches
/// and by a byte budget, because a caller should not be able to pin the daemon.
NSArray<NSNumber *> *DshGoAgentScanMemory(pid_t pid,
                                          NSData *pattern,
                                          NSData *mask,
                                          uint64_t start,
                                          uint64_t end,
                                          NSUInteger limit,
                                          NSError *_Nullable *_Nullable error);

NS_ASSUME_NONNULL_END