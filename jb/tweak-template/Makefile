export THEOS_PACKAGE_SCHEME = rootless
export ARCHS = arm64 arm64e
TARGET := iphone:clang:16.5:15.0

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = HoleNoAds
HoleNoAds_FILES = Tweak.x
HoleNoAds_CFLAGS = -fobjc-arc
HoleNoAds_FRAMEWORKS = UIKit Foundation

include $(THEOS_MAKE_PATH)/tweak.mk
