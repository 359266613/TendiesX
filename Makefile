export TARGET = iphone:clang:latest:15.0
export ARCHS = arm64 arm64e

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = TendiesX
TendiesX_FILES = $(wildcard Hooks/*.xm) $(wildcard Sources/*.m)
TendiesX_CFLAGS = -fobjc-arc \
	-I$(THEOS_PROJECT_DIR)/Headers \
	-I$(THEOS_PROJECT_DIR)/Headers/Private \
	-I$(THEOS_PROJECT_DIR)/Sources \
	-Wno-deprecated-declarations \
	-Wno-objc-missing-super-calls \
	-Wno-unused-variable
TendiesX_FRAMEWORKS = Foundation UIKit QuartzCore CoreVideo CoreMotion CoreImage ImageIO Metal MetalKit AVFoundation

include $(THEOS_MAKE_PATH)/tweak.mk

after-install::
	install.exec "killall -9 SpringBoard"
