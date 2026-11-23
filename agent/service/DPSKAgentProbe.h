#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// The read-only half: what is running, what is loaded, what is in memory.
///
/// Everything here returns plain Foundation objects so the caller can put them
/// into its JSON reply without a second translation.

/// One dictionary per process: pid, uid, name, path, bundleId (when it has one).
NSArray<NSDictionary *> *DPSKAgentListProcesses(void);

/// The mapped images of `pid`, as path/base/size, in address order.
NSArray<NSDictionary *> *DPSKAgentModulesForPID(pid_t pid);

/// The bundle id of the app at `pid`, or nil when it is not an app bundle.
NSString *_Nullable DPSKAgentBundleIdForPID(pid_t pid);

/// `length` bytes at `address` of `pid`. Requires `task_for_pid`.
NSData *_Nullable DPSKAgentReadMemory(pid_t pid, uint64_t address, NSUInteger length, NSError *_Nullable *_Nullable error);

/// Replace `data.count` bytes at `address` of `pid`.
BOOL DPSKAgentWriteMemory(pid_t pid, uint64_t address, NSData *data, NSError *_Nullable *_Nullable error);

NS_ASSUME_NONNULL_END
