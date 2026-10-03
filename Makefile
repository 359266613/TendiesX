DEBUG = 0
FINALPACKAGE = 1

export TARGET = iphone:clang:latest:15.0
export ARCHS = arm64 arm64e
THEOS_PACKAGE_SCHEME ?= rootless
export THEOS_PACKAGE_SCHEME

include $(THEOS)/makefiles/common.mk

# ---------- 注入 SpringBoard 的壁纸引擎 ----------
TWEAK_NAME = TendiesX
TendiesX_FILES = $(wildcard Hooks/*.xm) $(wildcard Sources/*.m)
TendiesX_CFLAGS = -fobjc-arc \
	-I./Headers \
	-I./Sources \
	-Wno-error \
	-Wno-deprecated-declarations \
	-Wno-objc-missing-super-calls \
	-Wno-unused-variable
TendiesX_FRAMEWORKS = Foundation UIKit QuartzCore CoreVideo CoreMotion CoreImage ImageIO Metal MetalKit AVFoundation
TendiesX_LIBRARIES = z
# 私有类（PBUIWallpaperView 等）不在 SDK stub 里：用动态查找，
# 否则 `SomePrivateClass.class` 会在链接期产生 _OBJC_CLASS_$_xxx 未定义符号
TendiesX_LDFLAGS = -undefined dynamic_lookup

# ---------- 设置面板（单 deb 双产物：tweak.mk + bundle.mk） ----------
BUNDLE_NAME = TendiesXPrefs
TendiesXPrefs_FILES = TendiesXPrefs/TXRootListController.m Sources/TXLogger.m
TendiesXPrefs_CFLAGS = -fobjc-arc \
	-I./TendiesXPrefs \
	-I./Sources \
	-Wno-error
TendiesXPrefs_FRAMEWORKS = Foundation UIKit UniformTypeIdentifiers
TendiesXPrefs_LDFLAGS = -undefined dynamic_lookup
TendiesXPrefs_INSTALL_PATH = /Library/PreferenceBundles
TendiesXPrefs_RESOURCE_DIRS = TendiesXPrefs/Resources

include $(THEOS_MAKE_PATH)/tweak.mk
include $(THEOS_MAKE_PATH)/bundle.mk

after-install::
	install.exec "killall -9 SpringBoard"
