TARGET := iphone:clang:latest:14.0
ARCHS = arm64
INSTALL_TARGET_PROCESSES = YouTube

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = Gonerino

Gonerino_FILES = Tweak.x Settings.x ChannelManager.m
Gonerino_FRAMEWORKS = UIKit Foundation UniformTypeIdentifiers
Gonerino_CFLAGS = -fobjc-arc -Wno-deprecated-declarations -Wno-error=unused-variable -DPACKAGE_VERSION='@"$(THEOS_PACKAGE_BASE_VERSION)"'
Gonerino_LOGOS_DEFAULT_GENERATOR = internal

include $(THEOS_MAKE_PATH)/tweak.mk

before-stage::
	$(ECHO_NOTHING)find . -name ".DS_Store" -type f -delete$(ECHO_END)
