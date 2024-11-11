TARGET := iphone:clang:latest:14.0
ARCHS = arm64
INSTALL_TARGET_PROCESSES = YouTube

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = Gonerino

Gonerino_FILES = $(wildcard *.x) $(wildcard *.m)
Gonerino_FRAMEWORKS = UIKit Foundation UniformTypeIdentifiers MobileCoreServices
Gonerino_CFLAGS = -fobjc-arc -DPACKAGE_VERSION='@"$(THEOS_PACKAGE_BASE_VERSION)"'

include $(THEOS_MAKE_PATH)/tweak.mk

before-stage::
	$(ECHO_NOTHING)find . -name ".DS_Store" -type f -delete$(ECHO_END)
