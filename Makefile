TARGET := iphone:clang:latest:14.0
ARCHS = arm64
INSTALL_TARGET_PROCESSES = YouTube
THEOS_PACKAGE_SCHEME = rootless
FINALPACKAGE = 1

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = Gonerino

$(TWEAK_NAME)_FILES = $(shell find sources -name "*.x*" -o -name "*.m*")
$(TWEAK_NAME)_FRAMEWORKS = UIKit Foundation UserNotifications UniformTypeIdentifiers MobileCoreServices
$(TWEAK_NAME)_CFLAGS = -fobjc-arc -DPACKAGE_VERSION='@"$(shell grep '^Version:' control | cut -d' ' -f2)"' -Iheaders

include $(THEOS_MAKE_PATH)/tweak.mk

before-all::
	$(ECHO_NOTHING)go run scripts/generate_changelog_header.go$(ECHO_END)

before-stage::
	$(ECHO_NOTHING)find . -name ".DS_Store" -type f -delete$(ECHO_END)
