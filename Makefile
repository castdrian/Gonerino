TARGET := iphone:clang:latest:12.0
ARCHS = arm64
INSTALL_TARGET_PROCESSES = YouTube

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = Gonerino

Gonerino_FILES = Tweak.x Settings.x
Gonerino_CFLAGS = -fobjc-arc

include $(THEOS_MAKE_PATH)/tweak.mk

before-stage::
	$(ECHO_NOTHING)find . -name ".DS_Store" -type f -delete$(ECHO_END)
