DEBUG = 0
FINALPACKAGE = 1

export TARGET = iphone:clang:latest:15.0
export ARCHS = arm64 arm64e
THEOS_PACKAGE_SCHEME ?= rootless
export THEOS_PACKAGE_SCHEME

include $(THEOS)/makefiles/common.mk

# ---------- SpringBoard 侧 worker：只做「解包 + 装 descriptor」----------
# route A：不 hook 任何私有 API、不渲染任何图层，
# 所以不需要任何私有头文件，也不需要 QuartzCore / AVFoundation / Metal。
TWEAK_NAME = TendiesX
TendiesX_FILES = Hooks/Worker.xm \
	Sources/TXLogger.m \
	Sources/TXPreferences.m \
	Sources/TXZipArchive.m \
	Sources/TXPosterInstaller.m \
	Sources/TXPosterService.m
TendiesX_CFLAGS = -fobjc-arc \
	-I./Sources \
	-Wno-error \
	-Wno-deprecated-declarations
TendiesX_FRAMEWORKS = Foundation UIKit
TendiesX_LIBRARIES = z

# ---------- 设置面板（单 deb 双产物）----------
# 面板只写偏好 + 发通知，真正的文件操作在 SpringBoard 侧（避开沙盒）
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
