// jbhelper.m — 越狱侧常驻守护进程
//
// 作用：DSH Go（App 沙盒内，Node 引擎，不能 exec 任何外部程序）通过
//       127.0.0.1:8787 让它代为执行：跑 make / dpkg / killall / 写文件到 /var/jb。
//
// 编译（在设备上 rootless 环境，或 Mac 上交叉编译）：
//   clang -fobjc-arc -O2 -framework Foundation -o jbhelper jbhelper.m
//   install -m 0755 jbhelper /var/jb/usr/bin/jbhelper
//
// 首次运行会在 /var/jb/etc/jbhelper.token 生成 48 位十六进制令牌，
// 之后所有请求必须带 X-JB-Token 头。

#import <Foundation/Foundation.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <unistd.h>
#include <fcntl.h>
#include <errno.h>
#include <stdlib.h>
#include <string.h>
#include <spawn.h>
#include <signal.h>
#include <sys/wait.h>
#include <sys/stat.h>
#include <limits.h>
#include <mach-o/loader.h>
#include <mach-o/fat.h>

extern char **environ;

// iOS 全是小端；Mach-O 的 fat 头与其中的偏移字段是大端，这里统一翻转
#define BE32(x) __builtin_bswap32(x)
#define BE64(x) __builtin_bswap64(x)

static NSString *const kTokenPath = @"/var/jb/etc/jbhelper.token";
static NSString *const kLogDir = @"/var/jb/tmp";
static const int kPort = 8787;
static NSString *gToken = nil;

#pragma mark - 令牌

static NSString *EnsureToken(void) {
    NSString *s = [NSString stringWithContentsOfFile:kTokenPath
                                            encoding:NSUTF8StringEncoding
                                               error:NULL];
    s = [s stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (s.length >= 32) return s;

    uint8_t raw[24];
    arc4random_buf(raw, sizeof raw);
    NSMutableString *hex = [NSMutableString stringWithCapacity:48];
    for (size_t i = 0; i < sizeof raw; i++) [hex appendFormat:@"%02x", raw[i]];

    [[NSFileManager defaultManager] createDirectoryAtPath:@"/var/jb/etc"
                                                 withIntermediateDirectories:YES
                                                                  attributes:nil
                                                                       error:NULL];
    [hex writeToFile:kTokenPath atomically:YES encoding:NSUTF8StringEncoding error:NULL];
    NSLog(@"[jbhelper] 已生成令牌：%@（把这个值填进 jb/config.json 的 token）", hex);
    return hex;
}

#pragma mark - 命令执行

static NSDictionary *RunArgv(NSArray<NSString *> *argv, NSString *cwd, NSTimeInterval timeoutSec) {
    if (argv.count == 0) return @{@"ok": @NO, @"error": @"empty argv"};
    if (timeoutSec <= 0 || timeoutSec > 1800) timeoutSec = 300;

    [[NSFileManager defaultManager] createDirectoryAtPath:kLogDir
                             withIntermediateDirectories:YES
                                              attributes:nil
                                                   error:NULL];
    NSString *logPath = [kLogDir stringByAppendingPathComponent:
                         [NSString stringWithFormat:@"exec-%@-%u.log",
                          @((long)time(NULL)), arc4random()]];

    int fd = open(logPath.fileSystemRepresentation, O_WRONLY | O_CREAT | O_TRUNC, 0644);
    if (fd < 0) return @{@"ok": @NO, @"error": [NSString stringWithFormat:@"open 日志失败: %s", strerror(errno)]};

    posix_spawn_file_actions_t fa;
    posix_spawn_file_actions_init(&fa);
    posix_spawn_file_actions_adddup2(&fa, fd, STDOUT_FILENO);
    posix_spawn_file_actions_adddup2(&fa, fd, STDERR_FILENO);
    posix_spawn_file_actions_addopen(&fa, STDIN_FILENO, "/dev/null", O_RDONLY, 0);

    // iOS SDK 没有 posix_spawn_file_actions_addchdir_np，改在父进程 chdir 再还原；
    // helper 是单线程 accept 循环，不存在并发 cwd 竞争。
    char prevCwd[PATH_MAX] = {0};
    BOOL movedCwd = NO;
    if (cwd.length > 0 && getcwd(prevCwd, sizeof prevCwd) != NULL) {
        movedCwd = (chdir(cwd.fileSystemRepresentation) == 0);
    }

    char **cargv = calloc(argv.count + 1, sizeof(char *));
    for (NSUInteger i = 0; i < argv.count; i++) cargv[i] = strdup(argv[i].UTF8String);

    pid_t pid = 0;
    int rc = posix_spawn(&pid, cargv[0], &fa, NULL, cargv, environ);
    if (movedCwd) chdir(prevCwd);

    for (NSUInteger i = 0; i < argv.count; i++) free(cargv[i]);
    free(cargv);
    posix_spawn_file_actions_destroy(&fa);
    close(fd);

    if (rc != 0) {
        return @{@"ok": @NO,
                 @"error": [NSString stringWithFormat:@"posix_spawn(%@) 失败: %s",
                            argv[0], strerror(rc)]};
    }

    int status = 0;
    BOOL timedOut = NO;
    NSTimeInterval start = CFAbsoluteTimeGetCurrent();
    for (;;) {
        pid_t w = waitpid(pid, &status, WNOHANG);
        if (w == pid || w < 0) break;
        if (CFAbsoluteTimeGetCurrent() - start > timeoutSec) {
            kill(pid, SIGKILL);
            waitpid(pid, &status, 0);
            timedOut = YES;
            break;
        }
        usleep(20000);
    }

    NSData *logData = [NSData dataWithContentsOfFile:logPath] ?: [NSData data];
    const NSUInteger cap = 256 * 1024;
    if (logData.length > cap) logData = [logData subdataWithRange:NSMakeRange(logData.length - cap, cap)];
    NSString *out = [[NSString alloc] initWithData:logData encoding:NSUTF8StringEncoding];
    if (!out) out = @"<输出不是合法 UTF-8>";
    [[NSFileManager defaultManager] removeItemAtPath:logPath error:NULL];

    int code = 0;
    if (WIFEXITED(status)) code = WEXITSTATUS(status);
    else if (WIFSIGNALED(status)) code = 128 + WTERMSIG(status);

    return @{@"ok": @(timedOut ? NO : YES),
             @"code": @(code),
             @"timedOut": @(timedOut),
             @"stdout": out};
}

#pragma mark - Mach-O 检查（对应 TrollFools 的 isProtectedMachO）

static BOOL ReadAt(int fd, off_t off, void *buf, size_t len) {
    ssize_t got = 0, want = (ssize_t)len;
    while (got < want) {
        ssize_t n = pread(fd, (char *)buf + got, (size_t)(want - got), off + got);
        if (n <= 0) return NO;
        got += n;
    }
    return YES;
}

// 读一个 thin Mach-O 的加载命令，返回加密状态，顺带收集 LC_LOAD_DYLIB 名字
static NSDictionary *ScanThinMachO(int fd, off_t sliceOff, NSMutableArray *dylibsOut) {
    uint8_t magic[4] = {0};
    if (!ReadAt(fd, sliceOff, magic, 4)) return nil;

    BOOL is64 = NO;
    uint32_t hdrSize = 0;
    if (magic[0] == 0xCF && magic[1] == 0xFA && magic[2] == 0xED && magic[3] == 0xFE) {
        is64 = YES; hdrSize = 32;                      // MH_MAGIC_64 (小端)
    } else if (magic[0] == 0xCE && magic[1] == 0xFA && magic[2] == 0xED && magic[3] == 0xFE) {
        is64 = NO; hdrSize = 28;                       // MH_MAGIC
    } else {
        return nil;                                     // 不是 Mach-O
    }

    uint32_t ncmds = 0, sizeofcmds = 0;
    // mach_header 与 mach_header_64 的 ncmds/sizeofcmds 都在同一偏移（16/20），
    // 差别只在头部总长（28 vs 32）与末尾多出的 reserved 字段。
    if (!ReadAt(fd, sliceOff + 16, &ncmds, 4)) return nil;
    if (!ReadAt(fd, sliceOff + 20, &sizeofcmds, 4)) return nil;
    if (sizeofcmds == 0 || sizeofcmds > 4 * 1024 * 1024) return nil;

    NSMutableData *cmds = [NSMutableData dataWithLength:sizeofcmds];
    if (!ReadAt(fd, sliceOff + hdrSize, cmds.mutableBytes, sizeofcmds)) return nil;

    const uint8_t *p = cmds.bytes;
    size_t remain = sizeofcmds;
    BOOL hasEncInfo = NO;
    uint32_t cryptid = 0;

    for (uint32_t i = 0; i < ncmds && remain >= 8; i++) {
        uint32_t cmd = 0, cmdsize = 0;
        memcpy(&cmd, p, 4);
        memcpy(&cmdsize, p + 4, 4);
        if (cmdsize < 8 || cmdsize > remain) break;

        if (cmd == LC_ENCRYPTION_INFO || cmd == LC_ENCRYPTION_INFO_64) {
            hasEncInfo = YES;
            if (cmdsize >= 20) memcpy(&cryptid, p + 16, 4);   // cryptoff,cryptsize,cryptid
        } else if (cmd == LC_LOAD_DYLIB || cmd == LC_LOAD_WEAK_DYLIB) {
            uint32_t nameOff = 0;
            memcpy(&nameOff, p + 8, 4);
            if (nameOff < cmdsize) {
                size_t maxLen = cmdsize - nameOff;
                const char *s = (const char *)(p + nameOff);
                size_t len = strnlen(s, maxLen);
                NSString *name = [[NSString alloc] initWithBytes:s length:len encoding:NSUTF8StringEncoding];
                if (name && dylibsOut) [dylibsOut addObject:name];
            }
        }
        p += cmdsize;
        remain -= cmdsize;
    }

    return @{@"bits": @(is64 ? 64 : 32),
             @"hasEncryptionInfo": @(hasEncInfo),
             @"cryptid": @(cryptid),
             @"encrypted": @(cryptid != 0)};
}

static NSDictionary *ScanMachO(NSString *path) {
    int fd = open(path.fileSystemRepresentation, O_RDONLY);
    if (fd < 0) return @{@"ok": @NO, @"error": [NSString stringWithFormat:@"打不开 %@: %s", path, strerror(errno)]};

    NSMutableArray *archs = [NSMutableArray array];
    NSMutableArray *dylibs = [NSMutableArray array];
    NSDictionary *result = nil;

    uint8_t magic[4] = {0};
    if (!ReadAt(fd, 0, magic, 4)) {
        close(fd);
        return @{@"ok": @NO, @"error": @"读不到文件头"};
    }

    BOOL isFat = (magic[0] == 0xCA && magic[1] == 0xFE && magic[2] == 0xBA && magic[3] == 0xBE) ||
                 (magic[0] == 0xCA && magic[1] == 0xFE && magic[2] == 0xBA && magic[3] == 0xBF);
    BOOL fat64 = (magic[3] == 0xBF);

    if (isFat) {
        uint32_t nArch = 0;
        if (!ReadAt(fd, 4, &nArch, 4)) { close(fd); return @{@"ok": @NO, @"error": @"fat 头损坏"}; }
        nArch = BE32(nArch);   // fat 头是大端
        if (nArch == 0 || nArch > 8) { close(fd); return @{@"ok": @NO, @"error": @"fat 架构数异常"}; }

        uint32_t entrySize = fat64 ? 32 : 20;
        for (uint32_t i = 0; i < nArch; i++) {
            uint8_t entry[32] = {0};
            if (!ReadAt(fd, 8 + (off_t)i * entrySize, entry, entrySize)) continue;

            uint32_t cputype = 0, offset = 0;
            memcpy(&cputype, entry, 4);
            cputype = BE32(cputype);
            if (fat64) {
                uint64_t off64 = 0;
                memcpy(&off64, entry + 8, 8);
                offset = (uint32_t)BE64(off64);
            } else {
                memcpy(&offset, entry + 8, 4);
                offset = BE32(offset);
            }

            NSDictionary *thin = ScanThinMachO(fd, (off_t)offset, dylibs);
            if (!thin) continue;
            NSMutableDictionary *m = [thin mutableCopy];
            m[@"cpu"] = (cputype == CPU_TYPE_ARM64)
                ? @"arm64"
                : [NSString stringWithFormat:@"cpu(%u)", cputype];
            [archs addObject:m];
        }
    } else {
        NSDictionary *thin = ScanThinMachO(fd, 0, dylibs);
        if (thin) [archs addObject:thin];
    }

    struct stat st = {0};
    fstat(fd, &st);
    close(fd);

    if (archs.count == 0) return @{@"ok": @NO, @"error": @"没有可解析的 Mach-O 架构"};

    BOOL anyEncrypted = NO;
    for (NSDictionary *a in archs) if ([a[@"encrypted"] boolValue]) anyEncrypted = YES;

    result = @{@"ok": @YES,
                @"size": @((long long)st.st_size),
                @"encrypted": @(anyEncrypted),
                @"archs": archs,
                @"dylibs": dylibs};
    return result;
}

static NSString *FindBundlePathByID(NSString *bundleID) {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *root = @"/var/containers/Bundle/Application";
    for (NSString *dir in [fm contentsOfDirectoryAtPath:root error:NULL] ?: @[]) {
        NSString *appDir = [root stringByAppendingPathComponent:dir];
        for (NSString *item in [fm contentsOfDirectoryAtPath:appDir error:NULL] ?: @[]) {
            if (![item hasSuffix:@".app"]) continue;
            NSString *bundlePath = [appDir stringByAppendingPathComponent:item];
            NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:
                                  [bundlePath stringByAppendingPathComponent:@"Info.plist"]];
            if ([info[@"CFBundleIdentifier"] isEqualToString:bundleID]) return bundlePath;
        }
    }
    return nil;
}

static NSDictionary *InspectApp(NSString *bundleID, NSString *explicitPath) {
    NSString *bundlePath = explicitPath.length ? explicitPath : FindBundlePathByID(bundleID);
    if (!bundlePath) {
        return @{@"ok": @NO,
                 @"error": explicitPath.length ? @"该路径不存在" : [NSString stringWithFormat:@"找不到 %@ 的 App 包", bundleID]};
    }

    NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:
                          [bundlePath stringByAppendingPathComponent:@"Info.plist"]] ?: @{};
    NSString *exeName = info[@"CFBundleExecutable"];
    if (!exeName.length) exeName = [[bundlePath lastPathComponent] stringByDeletingPathExtension];

    NSString *exePath = [bundlePath stringByAppendingPathComponent:exeName];
    NSDictionary *mainInfo = ScanMachO(exePath);

    // Frameworks/ 里的 framework 与裸 dylib
    NSMutableArray *frameworks = [NSMutableArray array];
    NSString *fwkDir = [bundlePath stringByAppendingPathComponent:@"Frameworks"];
    NSArray *items = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:fwkDir error:NULL] ?: @[];

    for (NSString *item in items) {
        NSString *full = [fwkDir stringByAppendingPathComponent:item];
        NSString *ext = [[item pathExtension] lowercaseString];
        NSString *machoPath = nil;
        if ([ext isEqualToString:@"dylib"]) {
            machoPath = full;
        } else if ([ext isEqualToString:@"framework"]) {
            NSString *inner = [item stringByDeletingPathExtension];
            machoPath = [full stringByAppendingPathComponent:inner];
        } else {
            continue;
        }
        NSDictionary *scan = ScanMachO(machoPath);
        if (![scan[@"ok"] boolValue]) continue;
        [frameworks addObject:@{@"name": item,
                                @"path": machoPath,
                                @"encrypted": scan[@"encrypted"],
                                @"size": scan[@"size"]}];
    }

    NSUInteger injectableCount = 0;
    NSMutableArray *injectableNames = [NSMutableArray array];
    for (NSDictionary *f in frameworks) {
        if (![f[@"encrypted"] boolValue]) {
            injectableCount++;
            if (injectableNames.count < 40) [injectableNames addObject:f[@"name"]];
        }
    }

    NSString *verdict;
    BOOL mainEncrypted = [mainInfo[@"encrypted"] boolValue];
    if (![mainInfo[@"ok"] boolValue]) {
        verdict = @"主二进制读不出来（可能没有读取权限），只能走进程内注入（ElleKit tweak）";
    } else if (!mainEncrypted) {
        verdict = @"主二进制未加密：静态改包与 ElleKit tweak 都可行";
    } else if (injectableCount > 0) {
        verdict = @"主二进制已加密：静态改包只能注入到未加密的 framework；ElleKit tweak 不受影响";
    } else {
        verdict = @"全部 Mach-O 都已加密：静态改包不可行，只能走 ElleKit tweak";
    }

    return @{@"ok": @YES,
             @"bundleID": info[@"CFBundleIdentifier"] ?: bundleID,
             @"displayName": info[@"CFBundleDisplayName"] ?: info[@"CFBundleName"] ?: @"",
             @"bundlePath": bundlePath,
             @"executable": @{@"name": exeName, @"path": exePath, @"scan": mainInfo ?: @{}},
             @"frameworks": frameworks,
             @"injectableCount": @(injectableCount),
             @"injectableNames": injectableNames,
             @"verdict": verdict};
}

#pragma mark - HTTP 极简实现

static NSDictionary *DispatchRequest(NSString *method, NSString *path, NSDictionary *body) {
    NSString *p = path.length ? path : @"/";

    if ([p isEqualToString:@"/health"]) {
        return @{@"ok": @YES, @"pid": @(getpid()), @"version": @"1"};
    }
    if (![method isEqualToString:@"POST"]) {
        return @{@"ok": @NO, @"error": @"only POST"};
    }

    if ([p isEqualToString:@"/exec"]) {
        NSArray *argv = body[@"argv"];
        if (![argv isKindOfClass:[NSArray class]]) return @{@"ok": @NO, @"error": @"argv 必须是字符串数组"};
        NSNumber *t = body[@"timeoutMs"];
        NSTimeInterval sec = t ? t.doubleValue / 1000.0 : 300;
        return RunArgv(argv, body[@"cwd"], sec);
    }

    if ([p isEqualToString:@"/write"]) {
        NSString *dst = body[@"path"];
        NSString *b64 = body[@"base64"];
        if (!dst.length || !b64) return @{@"ok": @NO, @"error": @"需要 path 与 base64"};
        NSData *data = [[NSData alloc] initWithBase64EncodedString:b64
                                                          options:NSDataBase64DecodingIgnoreUnknownCharacters];
        if (!data) return @{@"ok": @NO, @"error": @"base64 解码失败"};
        NSString *dir = [dst stringByDeletingLastPathComponent];
        [[NSFileManager defaultManager] createDirectoryAtPath:dir
                                 withIntermediateDirectories:YES
                                                  attributes:nil
                                                       error:NULL];
        NSError *err = nil;
        BOOL ok = [data writeToFile:dst options:NSDataWritingAtomic error:&err];
        if (!ok) return @{@"ok": @NO, @"error": err.localizedDescription ?: @"写入失败"};
        NSNumber *mode = body[@"mode"];
        if (mode) chmod(dst.fileSystemRepresentation, (mode_t)mode.unsignedIntValue);
        return @{@"ok": @YES, @"bytes": @(data.length)};
    }

    if ([p isEqualToString:@"/read"]) {
        NSString *src = body[@"path"];
        NSData *data = src ? [NSData dataWithContentsOfFile:src] : nil;
        if (!data) return @{@"ok": @NO, @"error": @"读不到该文件"};
        return @{@"ok": @YES, @"base64": [data base64EncodedStringWithOptions:0]};
    }

    if ([p isEqualToString:@"/inspect"]) {
        NSString *bundleID = body[@"bundle"];
        NSString *path = body[@"path"];
        if (!bundleID.length && !path.length) {
            return @{@"ok": @NO, @"error": @"需要 bundle（bundle id）或 path（.app 路径）"};
        }
        return InspectApp(bundleID, path);
    }

    return @{@"ok": @NO, @"error": [NSString stringWithFormat:@"未知路径 %@", p]};
}

static NSData *HttpReply(int code, NSData *json) {
    NSString *head = [NSString stringWithFormat:
                      @"HTTP/1.1 %d %@\r\nContent-Type: application/json\r\n"
                      @"Content-Length: %lu\r\nConnection: close\r\n\r\n",
                      code, code == 200 ? @"OK" : @"Error", (unsigned long)json.length];
    NSMutableData *d = [[head dataUsingEncoding:NSUTF8StringEncoding] mutableCopy];
    [d appendData:json];
    return d;
}

static void ServeOne(int cfd) {
    @autoreleasepool {
        NSMutableData *buf = [NSMutableData data];
        uint8_t chunk[8192];
        NSData *headerEnd = nil;
        NSUInteger contentLength = 0;

        for (;;) {
            ssize_t n = read(cfd, chunk, sizeof chunk);
            if (n <= 0) return;
            [buf appendBytes:chunk length:(NSUInteger)n];

            if (!headerEnd) {
                NSRange r = [buf rangeOfData:[@"\r\n\r\n" dataUsingEncoding:NSUTF8StringEncoding]
                                     options:0
                                       range:NSMakeRange(0, buf.length)];
                if (r.location != NSNotFound) {
                    headerEnd = [NSData dataWithBytes:buf.bytes length:NSMaxRange(r)];
                    NSString *head = [[NSString alloc] initWithData:headerEnd encoding:NSUTF8StringEncoding];
                    for (NSString *line in [head componentsSeparatedByString:@"\r\n"]) {
                        NSString *lower = line.lowercaseString;
                        if ([lower hasPrefix:@"content-length:"]) {
                            contentLength = [[line substringFromIndex:15]
                                             stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]].integerValue;
                        }
                    }
                }
            }
            if (headerEnd && buf.length >= headerEnd.length + contentLength) break;
        }

        NSString *head = [[NSString alloc] initWithData:headerEnd encoding:NSUTF8StringEncoding] ?: @"";
        NSArray *lines = [head componentsSeparatedByString:@"\r\n"];
        NSArray *reqParts = [lines.firstObject componentsSeparatedByString:@" "];
        if (reqParts.count < 2) return;
        NSString *method = reqParts[0];
        NSString *path = reqParts[1];

        NSMutableDictionary *headers = [NSMutableDictionary dictionary];
        for (NSUInteger i = 1; i < lines.count; i++) {
            NSRange colon = [lines[i] rangeOfString:@":"];
            if (colon.location == NSNotFound) continue;
            NSString *k = [[lines[i] substringToIndex:colon.location] lowercaseString];
            NSString *v = [[lines[i] substringFromIndex:colon.location + 1]
                           stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
            if (k.length) headers[k] = v;
        }

        NSData *bodyData = nil;
        if (contentLength) {
            NSUInteger off = headerEnd.length;
            if (buf.length >= off + contentLength) bodyData = [buf subdataWithRange:NSMakeRange(off, contentLength)];
        }
        NSDictionary *body = nil;
        if (bodyData.length) {
            id o = [NSJSONSerialization JSONObjectWithData:bodyData options:0 error:NULL];
            if ([o isKindOfClass:[NSDictionary class]]) body = o;
        }

        NSDictionary *reply;
        if (![headers[@"x-jb-token"] isEqualToString:gToken]) {
            reply = @{@"ok": @NO, @"error": @"令牌不匹配"};
            NSData *json = [NSJSONSerialization dataWithJSONObject:reply options:0 error:NULL];
            NSData *resp = HttpReply(403, json);
            write(cfd, resp.bytes, resp.length);
            return;
        }

        @try {
            reply = DispatchRequest(method, path, body ?: @{});
        } @catch (NSException *e) {
            reply = @{@"ok": @NO, @"error": e.reason ?: @"内部异常"};
        }
        NSData *json = [NSJSONSerialization dataWithJSONObject:reply options:0 error:NULL];
        NSData *resp = HttpReply(200, json);
        write(cfd, resp.bytes, resp.length);
    }
}

int main(int argc, char *argv[]) {
    (void)argc; (void)argv;
    @autoreleasepool {
        gToken = EnsureToken();
        signal(SIGPIPE, SIG_IGN);

        int s = socket(AF_INET, SOCK_STREAM, 0);
        if (s < 0) { NSLog(@"[jbhelper] socket 失败"); return 1; }
        int one = 1;
        setsockopt(s, SOL_SOCKET, SO_REUSEADDR, &one, sizeof one);

        struct sockaddr_in addr = {0};
        addr.sin_family = AF_INET;
        addr.sin_port = htons(kPort);
        addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);

        if (bind(s, (struct sockaddr *)&addr, sizeof addr) < 0) {
            NSLog(@"[jbhelper] 绑定 127.0.0.1:%d 失败: %s", kPort, strerror(errno));
            return 1;
        }
        listen(s, 16);
        NSLog(@"[jbhelper] 就绪 http://127.0.0.1:%d pid=%d", kPort, getpid());

        for (;;) {
            int c = accept(s, NULL, NULL);
            if (c < 0) { usleep(50000); continue; }
            ServeOne(c);
            close(c);
        }
    }
    return 0;
}
