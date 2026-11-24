#import "DshGoAgentSafety.h"

#import "DshGoAgentLog.h"
#import "DshGoAgentProbe.h"

NSString *const DshGoAgentErrorDomain = @"io.github.ccch1mneyyy.dshgo.agentd";

NSString *DshGoAgentErrorCodeName(DshGoAgentErrorCode code) {
    switch (code) {
        case DshGoAgentErrorBadParams: return @"ERR_BAD_PARAMS";
        case DshGoAgentErrorTargetNotAllowed: return @"ERR_TARGET_NOT_ALLOWED";
        case DshGoAgentErrorConfirmationRequired: return @"ERR_CONFIRMATION_REQUIRED";
        case DshGoAgentErrorAttachFailed: return @"ERR_ATTACH_FAILED";
        case DshGoAgentErrorNotImplemented: return @"ERR_NOT_IMPLEMENTED";
        case DshGoAgentErrorInternal: return @"ERR_INTERNAL";
    }
    return @"ERR_INTERNAL";
}

NSError *DshGoAgentMakeError(DshGoAgentErrorCode code, NSString *message) {
    return [NSError errorWithDomain:DshGoAgentErrorDomain
                               code:code
                           userInfo:@{NSLocalizedDescriptionKey: message}];
}

/// Accept only hex digits. A string with a `0x` prefix, a decimal number, or a
/// stray character is rejected rather than guessed at: an address that is one
/// byte off is a daemon writing into the wrong page.
static BOOL DshGoarseHex(NSString *text, uint64_t *out) {
    if (text.length == 0 || text.length > 16) return NO;
    uint64_t value = 0;
    for (NSUInteger index = 0; index < text.length; index++) {
        unichar c = [text characterAtIndex:index];
        uint64_t digit;
        if (c >= '0' && c <= '9') {
            digit = c - '0';
        } else if (c >= 'a' && c <= 'f') {
            digit = c - 'a' + 10;
        } else if (c >= 'A' && c <= 'F') {
            digit = c - 'A' + 10;
        } else {
            return NO;
        }
        value = (value << 4) | digit;
    }
    *out = value;
    return YES;
}

BOOL DshGoAgentIntegerParam(NSDictionary *params, NSString *key, NSInteger min, NSInteger max, NSInteger *out, NSError **error) {
    id value = params[key];
    if (![value isKindOfClass:[NSNumber class]]) {
        if (error) *error = DshGoAgentMakeError(DshGoAgentErrorBadParams,
                                              [NSString stringWithFormat:@"`%@` must be a number", key]);
        return NO;
    }
    NSInteger number = [value integerValue];
    if (number < min || number > max) {
        if (error) *error = DshGoAgentMakeError(DshGoAgentErrorBadParams,
                                              [NSString stringWithFormat:@"`%@` must be in %ld...%ld", key, (long)min, (long)max]);
        return NO;
    }
    *out = number;
    return YES;
}

BOOL DshGoAgentAddressParam(NSDictionary *params, NSString *key, uint64_t *out, NSError **error) {
    id value = params[key];
    if (![value isKindOfClass:[NSString class]] || !DshGoarseHex(value, out) || *out == 0) {
        if (error) *error = DshGoAgentMakeError(DshGoAgentErrorBadParams,
                                              [NSString stringWithFormat:@"`%@` must be a hex address", key]);
        return NO;
    }
    return YES;
}

NSData *DshGoAgentHexParam(NSDictionary *params, NSString *key, NSUInteger maxBytes, NSError **error) {
    id value = params[key];
    if (![value isKindOfClass:[NSString class]]) {
        if (error) *error = DshGoAgentMakeError(DshGoAgentErrorBadParams,
                                              [NSString stringWithFormat:@"`%@` must be a hex string", key]);
        return nil;
    }
    NSString *text = value;
    if (text.length == 0 || text.length % 2 != 0) {
        if (error) *error = DshGoAgentMakeError(DshGoAgentErrorBadParams,
                                              [NSString stringWithFormat:@"`%@` must have an even number of hex digits", key]);
        return nil;
    }
    NSUInteger bytes = text.length / 2;
    if (bytes > maxBytes) {
        if (error) *error = DshGoAgentMakeError(DshGoAgentErrorBadParams,
                                              [NSString stringWithFormat:@"`%@` is limited to %lu bytes", key, (unsigned long)maxBytes]);
        return nil;
    }
    NSMutableData *data = [NSMutableData dataWithCapacity:bytes];
    for (NSUInteger index = 0; index < bytes; index++) {
        uint64_t byte = 0;
        NSString *pair = [text substringWithRange:NSMakeRange(index * 2, 2)];
        if (!DshGoarseHex(pair, &byte)) {
            if (error) *error = DshGoAgentMakeError(DshGoAgentErrorBadParams,
                                                  [NSString stringWithFormat:@"`%@` is not hexadecimal", key]);
            return nil;
        }
        uint8_t value8 = (uint8_t)byte;
        [data appendBytes:&value8 length:1];
    }
    return data;
}

NSString *DshGoAgentStringParam(NSDictionary *params, NSString *key, NSError **error) {
    id value = params[key];
    if (![value isKindOfClass:[NSString class]] || [value length] == 0) {
        if (error) *error = DshGoAgentMakeError(DshGoAgentErrorBadParams,
                                              [NSString stringWithFormat:@"`%@` must be a non-empty string", key]);
        return nil;
    }
    return value;
}

@implementation DshGoAgentSafety {
    NSMutableArray<NSString *> *_bundleIds;
    NSMutableSet<NSString *> *_allowed;
    NSLock *_lock;
    time_t _lastReload;
}

+ (instancetype)shared {
    static DshGoAgentSafety *safety;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ safety = [[DshGoAgentSafety alloc] init]; });
    return safety;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _bundleIds = [NSMutableArray array];
        _allowed = [NSMutableSet set];
        _lock = [[NSLock alloc] init];
    }
    return self;
}

- (void)reload {
    // Once a second is enough for a file a human edits, and it keeps a caller
    // that hammers the service from turning every request into a disk read.
    time_t now = time(NULL);
    if (now == _lastReload) return;

    [_lock lock];
    _lastReload = now;
    NSString *path = [DshGoAgentStateDirectory() stringByAppendingPathComponent:@"allowlist.json"];
    NSData *data = [NSData dataWithContentsOfFile:path];
    [_bundleIds removeAllObjects];
    [_allowed removeAllObjects];
    _allowlistLoaded = data != nil;

    if (data) {
        id root = [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];
        if ([root isKindOfClass:[NSDictionary class]]) {
            NSArray *ids = ((NSDictionary *)root)[@"bundleIds"];
            if ([ids isKindOfClass:[NSArray class]]) {
                for (id entry in ids) {
                    if ([entry isKindOfClass:[NSString class]]) {
                        [_bundleIds addObject:entry];
                        [_allowed addObject:entry];
                    }
                }
            }
        } else {
            DshGoAgentLog(@"safety: allowlist.json is not an object; nothing is allowed");
        }
    }
    [_lock unlock];
}

- (NSArray<NSString *> *)allowedBundleIds {
    [self reload];
    [_lock lock];
    NSArray *copy = [_bundleIds copy];
    [_lock unlock];
    return copy;
}

- (BOOL)allowsPID:(pid_t)pid reason:(NSString **)reason {
    [self reload];
    if (pid <= 0) {
        if (reason) *reason = @"pid must be positive";
        return NO;
    }
    NSString *bundleId = DshGoAgentBundleIdForPID(pid);
    if (bundleId == nil) {
        if (reason) *reason = [NSString stringWithFormat:@"pid %d is not an app bundle; only apps can be listed", pid];
        return NO;
    }
    [_lock lock];
    BOOL allowed = [_allowed containsObject:bundleId];
    NSArray *known = [_bundleIds copy];
    [_lock unlock];
    if (!allowed) {
        if (reason) {
            *reason = known.count == 0
                ? @"the allowlist is empty; add the bundle id to allowlist.json"
                : [NSString stringWithFormat:@"%@ is not in allowlist.json", bundleId];
        }
        return NO;
    }
    return YES;
}

@end
