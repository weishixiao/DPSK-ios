#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Append one line to `agentd.log`, and to stderr.
///
/// The chat panel tails this file, so it is the record of what the daemon was
/// asked and what it did — one line per request, never a multi-line blob that
/// the panel would have to reassemble.
void DshGoAgentLog(NSString *format, ...) NS_FORMAT_FUNCTION(1, 2);

/// Where the log lives; the harness reads the same path.
NSString *DshGoAgentLogPath(void);

/// The directory requests may name: allowlist, projects, log.
NSString *DshGoAgentStateDirectory(void);

NS_ASSUME_NONNULL_END
