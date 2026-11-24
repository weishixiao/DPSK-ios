#import "DshGoAgentProject.h"

#import "DshGoAgentLog.h"
#import "DshGoAgentSafety.h"

/// A whole tweak project should fit in a request well under the 1 MiB envelope;
/// this is the part of it that may be source text.
static const NSUInteger kMaxProjectBytes = 256 * 1024;

static NSString *DshGoProjectsRoot(void) {
    return [DshGoAgentStateDirectory() stringByAppendingPathComponent:@"projects"];
}

/// A plain name, and why it matters: this string becomes a path component, so a
/// separator or a `..` in it would move the write out of the projects directory.
static BOOL DshGoProjectNameIsPlain(NSString *name) {
    if (name.length == 0 || name.length > 64) return NO;
    if ([name hasPrefix:@"."]) return NO;
    NSCharacterSet *allowed = [NSCharacterSet characterSetWithCharactersInString:
        @"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-"];
    return [name rangeOfCharacterFromSet:[allowed invertedSet]].location == NSNotFound;
}

NSString *DshGoAgentProjectDirectory(NSString *name, BOOL create, NSError **error) {
    if (!DshGoProjectNameIsPlain(name)) {
        if (error) {
            *error = DshGoAgentMakeError(DshGoAgentErrorBadParams,
                @"`project` must be a plain name: letters, digits, dot, underscore, dash");
        }
        return nil;
    }
    NSString *root = DshGoProjectsRoot();
    NSString *directory = [root stringByAppendingPathComponent:name];
    NSFileManager *files = [NSFileManager defaultManager];
    if (![files fileExistsAtPath:directory]) {
        if (!create) {
            if (error) {
                *error = DshGoAgentMakeError(DshGoAgentErrorBadParams,
                    [NSString stringWithFormat:@"no project at %@", directory]);
            }
            return nil;
        }
        NSError *createError = nil;
        if (![files createDirectoryAtPath:directory withIntermediateDirectories:YES
                               attributes:@{NSFilePosixPermissions: @(0700)}
                                    error:&createError]) {
            if (error) {
                *error = DshGoAgentMakeError(DshGoAgentErrorInternal,
                    [NSString stringWithFormat:@"cannot create %@: %@", directory, createError.localizedDescription]);
            }
            return nil;
        }
        DshGoAgentLog(@"projects: created %@", directory);
    }
    return directory;
}

NSDictionary *DshGoAgentProjectWrite(NSString *name, NSDictionary<NSString *, NSString *> *files, NSError **error) {
    if (![files isKindOfClass:[NSDictionary class]] || files.count == 0) {
        if (error) *error = DshGoAgentMakeError(DshGoAgentErrorBadParams, @"`files` must be a non-empty object");
        return nil;
    }
    // Validate every name before writing any of them: a request that is half
    // rejected should not leave a half built project behind.
    NSMutableArray<NSString *> *names = [NSMutableArray arrayWithCapacity:files.count];
    NSUInteger total = 0;
    for (id key in files) {
        if (![key isKindOfClass:[NSString class]]) {
            if (error) *error = DshGoAgentMakeError(DshGoAgentErrorBadParams, @"file names must be strings");
            return nil;
        }
        NSString *file = key;
        if (!DshGoProjectNameIsPlain(file)) {
            if (error) {
                *error = DshGoAgentMakeError(DshGoAgentErrorBadParams,
                    [NSString stringWithFormat:@"\"%@\" is not a plain file name; a project is a flat directory", file]);
            }
            return nil;
        }
        id content = files[file];
        if (![content isKindOfClass:[NSString class]]) {
            if (error) {
                *error = DshGoAgentMakeError(DshGoAgentErrorBadParams,
                    [NSString stringWithFormat:@"the contents of \"%@\" must be a string", file]);
            }
            return nil;
        }
        total += [content length];
        [names addObject:file];
    }
    if (total > kMaxProjectBytes) {
        if (error) {
            *error = DshGoAgentMakeError(DshGoAgentErrorBadParams,
                [NSString stringWithFormat:@"a project is limited to %lu bytes of source", (unsigned long)kMaxProjectBytes]);
        }
        return nil;
    }

    NSString *directory = DshGoAgentProjectDirectory(name, YES, error);
    if (directory == nil) return nil;

    NSFileManager *manager = [NSFileManager defaultManager];
    NSMutableArray<NSString *> *written = [NSMutableArray arrayWithCapacity:names.count];
    for (NSString *file in names) {
        NSString *path = [directory stringByAppendingPathComponent:file];
        NSError *writeError = nil;
        if (![files[file] writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:&writeError]) {
            if (error) {
                *error = DshGoAgentMakeError(DshGoAgentErrorInternal,
                    [NSString stringWithFormat:@"cannot write %@: %@", path, writeError.localizedDescription]);
            }
            return nil;
        }
        // The source is the owner's, but nothing here needs to be world readable,
        // and a `Tweak.xm` that another process can rewrite is not the one that
        // was reviewed.
        [manager setAttributes:@{NSFilePosixPermissions: @(0600)} ofItemAtPath:path error:NULL];
        [written addObject:file];
    }
    DshGoAgentLog(@"projects: wrote %lu files into %@", (unsigned long)written.count, directory);
    return @{@"project": name, @"directory": directory, @"files": written};
}

NSString *DshGoAgentProjectNewestDeb(NSString *directory) {
    if (directory.length == 0) return nil;
    NSString *packages = [directory stringByAppendingPathComponent:@"packages"];
    NSArray<NSString *> *entries = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:packages error:NULL];
    NSString *newest = nil;
    NSDate *newestDate = nil;
    for (NSString *entry in entries) {
        if (![entry.pathExtension isEqualToString:@"deb"]) continue;
        NSString *path = [packages stringByAppendingPathComponent:entry];
        NSDictionary *attributes = [[NSFileManager defaultManager] attributesOfItemAtPath:path error:NULL];
        NSDate *modified = attributes[NSFileModificationDate];
        if (modified == nil) continue;
        if (newestDate == nil || [modified compare:newestDate] == NSOrderedDescending) {
            newest = path;
            newestDate = modified;
        }
    }
    return newest;
}