TARGET := iphone:clang:latest:14.0
ARCHS = arm64
INSTALL_TARGET_PROCESSES = YouTube
THEOS_PACKAGE_SCHEME = rootless
FINALPACKAGE = 1

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = Gonerino

$(TWEAK_NAME)_FILES = $(shell find sources -name "*.x*" -o -name "*.m*")
$(TWEAK_NAME)_FRAMEWORKS = UIKit Foundation UniformTypeIdentifiers MobileCoreServices
$(TWEAK_NAME)_CFLAGS = -fobjc-arc -DPACKAGE_VERSION='@"$(shell grep '^Version:' control | cut -d' ' -f2)"' -I$(THEOS_PROJECT_DIR)/headers

include $(THEOS_MAKE_PATH)/tweak.mk

before-stage::
	$(ECHO_NOTHING)find . -name ".DS_Store" -type f -delete$(ECHO_END)
