#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// The owner's tweak projects, as files on the device.
///
/// A Theos project is a directory: `Makefile`, a source file, `control`, and
/// often a `Filter.plist`. The daemon does not invent any of them - the agent
/// writes the source it wants built - but it owns the directory they may live in
/// and the rules for writing there, because "write a file" as a privileged
/// service is one path traversal away from writing anywhere.

/// The directory for `name`, created (with its parent) when `create` is YES.
///
/// `name` is a plain directory name: letters, digits, dot, underscore, dash. No
/// separators, no leading dot, no `..` - the same rule `tweak.compile` applies,
/// kept in one place so a name that builds can also be written.
NSString *_Nullable DshGoAgentProjectDirectory(NSString *name, BOOL create, NSError *_Nullable *_Nullable error);

/// Write `files` (name -> contents) into the project, creating it if needed.
///
/// File names are flat: a source file, a Makefile, a control, a filter. Nothing
/// here accepts a slash, because the moment it does, the directory check above is
/// no longer the thing that decides where the write lands. Returns the directory
/// and the names written, so a caller can list what the project now holds.
NSDictionary *_Nullable DshGoAgentProjectWrite(NSString *name,
                                               NSDictionary<NSString *, NSString *> *files,
                                               NSError *_Nullable *_Nullable error);

/// The most recently written `.deb` under `<project>/packages`, or nil.
///
/// Theos names packages after the control file, so the caller cannot guess the
/// name it just built; modification time is what answers "which one is this
/// build's".
NSString *_Nullable DshGoAgentProjectNewestDeb(NSString *directory);

NS_ASSUME_NONNULL_END