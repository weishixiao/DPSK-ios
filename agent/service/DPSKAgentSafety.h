#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// What went wrong, as a code the caller can branch on.
///
/// The name travels in the reply next to the message, so the harness never has
/// to parse prose to tell "you are not allowed to" from "that address is not
/// mapped".
typedef NS_ENUM(NSInteger, DPSKAgentErrorCode) {
    DPSKAgentErrorBadParams = 1,
    DPSKAgentErrorTargetNotAllowed,
    DPSKAgentErrorConfirmationRequired,
    DPSKAgentErrorAttachFailed,
    DPSKAgentErrorNotImplemented,
    DPSKAgentErrorInternal,
};

extern NSString *const DPSKAgentErrorDomain;

/// The wire name of `code`, e.g. `ERR_TARGET_NOT_ALLOWED`.
NSString *DPSKAgentErrorCodeName(DPSKAgentErrorCode code);

NSError *DPSKAgentMakeError(DPSKAgentErrorCode code, NSString *message);

/// The checks every request passes before any syscall runs.
///
/// The daemon *can* look at any process; the allowlist is what keeps that
/// capability pointed at the apps its owner builds. Nothing here trusts the
/// caller: a parameter is validated in this class or rejected, and there is no
/// method that skips it.
/// Validate one parameter of a request.
///
/// These are the checks the protocol promises: a value that is missing, of the
/// wrong type, or out of range is refused here and never reaches a syscall.
BOOL DPSKAgentIntegerParam(NSDictionary *params, NSString *key, NSInteger min, NSInteger max, NSInteger *out, NSError *_Nullable *_Nullable error);
BOOL DPSKAgentAddressParam(NSDictionary *params, NSString *key, uint64_t *out, NSError *_Nullable *_Nullable error);
NSData *_Nullable DPSKAgentHexParam(NSDictionary *params, NSString *key, NSUInteger maxBytes, NSError *_Nullable *_Nullable error);
NSString *_Nullable DPSKAgentStringParam(NSDictionary *params, NSString *key, NSError *_Nullable *_Nullable error);

@interface DPSKAgentSafety : NSObject

+ (instancetype)shared;

/// Re-read `allowlist.json`. Cheap enough to call per request, which is what
/// makes an edit to the file take effect without restarting the daemon.
- (void)reload;

@property (nonatomic, readonly) NSArray<NSString *> *allowedBundleIds;
@property (nonatomic, readonly) BOOL allowlistLoaded;

/// Whether this pid may be inspected. `reason` explains a refusal.
- (BOOL)allowsPID:(pid_t)pid reason:(NSString *_Nullable *_Nullable)reason;

@end

NS_ASSUME_NONNULL_END
