#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// The read-only half: what is running, what is loaded, what is in memory.
///
/// Everything here returns plain Foundation objects so the caller can put them
/// into its JSON reply without a second translation.

/// One dictionary per process: pid, uid, name, path, bundleId (when it has one).
NSArray<NSDictionary *> *DshGoAgentListProcesses(void);

/// The mapped images of `pid`, as path/base/size, in address order.
NSArray<NSDictionary *> *DshGoAgentModulesForPID(pid_t pid);

/// The bundle id of the app at `pid`, or nil when it is not an app bundle.
NSString *_Nullable DshGoAgentBundleIdForPID(pid_t pid);

/// The executable path of `pid`, or nil. iOS has no libproc, so this comes from
/// KERN_PROCARGS2; callers that read the file must not assume it is readable -
/// another uid's binary is not, even for the daemon.
NSString *_Nullable DshGoAgentExecutablePathForPID(pid_t pid);

/// `length` bytes at `address` of `pid`. Requires `task_for_pid`.
NSData *_Nullable DshGoAgentReadMemory(pid_t pid, uint64_t address, NSUInteger length, NSError *_Nullable *_Nullable error);

/// Replace `data.count` bytes at `address` of `pid`.
BOOL DshGoAgentWriteMemory(pid_t pid, uint64_t address, NSData *data, NSError *_Nullable *_Nullable error);

NS_ASSUME_NONNULL_END
