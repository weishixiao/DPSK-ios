#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// The jailbreak root on this device: "" when the install is rootful, otherwise
/// the directory the daemon was launched from (`<root>/usr/libexec/<daemon>`).
/// RootHide randomizes it per boot, so this is the only reliable way to name a
/// path under it - `/var/jb` does not exist there at all.
NSString *DshGoJailbreakRoot(void);

/// Running a binary on behalf of the app.
///
/// The daemon is the only process the system lets spawn outside the app
/// sandbox, so this is where "run another program" has to live. It is
/// deliberately small: a fixed search path, no shell, an argument vector
/// rather than a command string, and a hard timeout. A caller that wants a
/// pipeline composes several calls; there is no way to reach a shell here.
@interface DshGoAgentExec : NSObject

/// Absolute path of `name` if it lives in a directory the daemon may execute
/// from, otherwise nil. `name` may not contain a slash.
+ (nullable NSString *)resolveBinary:(NSString *)name;

/// Start `path` and return its pid without waiting for it.
///
/// `runPath:arguments:timeout:error:` blocks until the child exits, which is
/// right for a build and wrong for a service the daemon has to keep: this is the
/// same `posix_spawn` with no wait, so the caller gets a pid it can watch. The
/// child's output goes to /dev/null - nobody would drain it, and a full pipe
/// would stop the child.
+ (nullable NSNumber *)spawnDetached:(NSString *)path
                           arguments:(NSArray<NSString *> *)arguments
                               error:(NSError *_Nullable *_Nullable)error;

/// Run `path` with `arguments`. Returns stdout+stderr and the exit status.
///
/// Refuses a path outside the executable directories, so a caller cannot point
/// this at its own copy of a binary and skip the review that placing it in
/// /usr/bin represents.
+ (nullable NSDictionary *)runPath:(NSString *)path
                          arguments:(NSArray<NSString *> *)arguments
                           timeout:(NSTimeInterval)timeout
                             error:(NSError *_Nullable *_Nullable)error;

@end

NS_ASSUME_NONNULL_END
