TARGET := iphone:clang:16.5:15.0
ARCHS = arm64 arm64e
INSTALL_TARGET_PROCESSES = QQ

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = QQLocalPush

QQLocalPush_FILES = Tweak.x
QQLocalPush_FRAMEWORKS = UserNotifications UIKit
QQLocalPush_CFLAGS = -fobjc-arc -Wno-unguarded-availability-new -Wno-deprecated-declarations

include $(THEOS_MAKE_PATH)/tweak.mk
