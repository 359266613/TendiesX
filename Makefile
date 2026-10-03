export TARGET = iphone:clang:latest:15.0
export ARCHS = arm64 arm64e
THEOS_PACKAGE_SCHEME ?= rootless
export THEOS_PACKAGE_SCHEME

include $(THEOS)/makefiles/common.mk

# ---------- 注入 SpringBoard 的壁纸引擎 ----------
TWEAK_NAME = TendiesX
TendiesX_FILES = $(wildcard Hooks/*.xm) $(wildcard Sources/*.m)
TendiesX_CFLAGS = -fobjc-arc \
	-I$(THEOS_PROJECT_DIR)/Headers \
	-I$(THEOS_PROJECT_DIR)/Sources \
	-Wno-deprecated-declarations \
	-Wno-objc-missing-super-calls \
	-Wno-unused-variable \
	-Wno-error
TendiesX_FRAMEWORKS = Foundation UIKit QuartzCore CoreVideo CoreMotion CoreImage ImageIO Metal MetalKit AVFoundation
TendiesX_LIBRARIES = z

# ---------- 设置面板 ----------
BUNDLE_NAME = TendiesXPrefs
TendiesXPrefs_FILES = TendiesXPrefs/TXRootListController.m
TendiesXPrefs_CFLAGS = -fobjc-arc -I$(THEOS_PROJECT_DIR)/TendiesXPrefs -Wno-error
TendiesXPrefs_FRAMEWORKS = Foundation UIKit
TendiesXPrefs_LDFLAGS = -undefined dynamic_lookup
TendiesXPrefs_INSTALL_PATH = /Library/PreferenceBundles
TendiesXPrefs_RESOURCE_DIRS = TendiesXPrefs/Resources

include $(THEOS_MAKE_PATH)/tweak.mk
include $(THEOS_MAKE_PATH)/bundle.mk

after-install::
	install.exec "killall -9 SpringBoard"
