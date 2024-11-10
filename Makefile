TARGET := iphone:clang:15.6:14.0
ARCHS = arm64
INSTALL_TARGET_PROCESSES = YouTube

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = Gonerino

Gonerino_FILES = Tweak.x Settings.x ChannelManager.m
Gonerino_FRAMEWORKS = UIKit Foundation UniformTypeIdentifiers
Gonerino_CFLAGS = -fobjc-arc -DPACKAGE_VERSION='@"$(THEOS_PACKAGE_BASE_VERSION)"'

include $(THEOS_MAKE_PATH)/tweak.mk

before-stage::
	$(ECHO_NOTHING)find . -name ".DS_Store" -type f -delete$(ECHO_END)
