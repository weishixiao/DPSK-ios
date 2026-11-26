// Tweak.x —— 「黑洞入侵」广告拦截模板（rootless / ElleKit）
//
// 思路：不是篡改 App，而是在目标进程里把广告 SDK 的「展示」方法变成空实现。
// App 本体、签名、App Store 更新都不受影响；卸载这个 deb 立刻恢复原样。
//
// 前提：先把真实类名查出来（见 README「发现」一节）。下面这些是常见 SDK 的
// 常见类名，绝大多数第三方广告 SDK 是 ObjC 可见的，即使游戏本体是 Unity IL2CPP。
//
// 编译：make package（THEOS_PACKAGE_SCHEME=rootless）

#import <UIKit/UIKit.h>

// ───────────────────────── 通用日志 ─────────────────────────
%hook NSObject
%end

%ctor {
    NSLog(@"[HoleNoAds] injected into %@", [[NSBundle mainBundle] bundleIdentifier]);
}

// ───────────────── Google Mobile Ads (AdMob) ─────────────────
%hook GADInterstitialAd
- (void)presentFromRootViewController:(UIViewController *)vc {}
%end

%hook GADAppOpenAd
- (void)presentFromRootViewController:(UIViewController *)vc {}
%end

%hook GADRewardedAd
- (void)presentFromRootViewController:(UIViewController *)vc
                    userDidEarnRewardHandler:(void (^)(void))handler {}
%end

// ───────────────── 穿山甲 Pangle / CSJ ─────────────────
%hook BUInterstitialAd
- (void)showFromRootViewController:(UIViewController *)vc {}
%end

%hook BUFullscreenVideoAd
- (void)showFromRootViewController:(UIViewController *)vc {}
%end

%hook BURewardedVideoAd
- (void)showFromRootViewController:(UIViewController *)vc {}
%end

// ───────────────── TopOn / AnyThink ─────────────────
%hook ATInterstitial
- (void)showAdWithViewController:(UIViewController *)vc {}
%end

%hook ATRewardedVideoAd
- (void)showAdWithViewController:(UIViewController *)vc {}
%end

// ───────────────── Mintegral ─────────────────
%hook MTGInterstitialAdManager
- (void)showInterstitialAdWithPlacementId:(NSString *)pid
                                    unitId:(NSString *)unitId
                         rootViewController:(UIViewController *)vc {}
%end

// ───────────────── AppLovin / MAX ─────────────────
%hook ALInterstitialAd
- (void)show {}
- (void)showAd {}
%end

// ───────────────── ironSource ─────────────────
%hook ISInterstitialAdAdapter
- (void)showInterstitial {}
%end

// ───────────────── Vungle ─────────────────
%hook VungleInterstitial
- (void)showAd {}
%end

// ───────────────── Chartboost ─────────────────
%hook CHBInterstitial
- (void)showFromViewController:(UIViewController *)vc {}
%end

// ───────────────── Unity Ads ─────────────────
%hook UnityAds
+ (void)show:(id)sender placementId:(NSString *)placementId {}
%end
