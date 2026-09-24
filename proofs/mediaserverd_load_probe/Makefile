TARGET := iphone:clang:latest:15.0
ARCHS := arm64
THEOS_PACKAGE_SCHEME := rootless

include $(THEOS)/makefiles/common.mk

TWEAK_NAME := VCAMProLoadProbe
VCAMProLoadProbe_FILES := LoadProbe.c
VCAMProLoadProbe_INSTALL_PATH := /usr/lib/TweakInject
VCAMProLoadProbe_CFLAGS := -Wall -Wextra -Werror

include $(THEOS_MAKE_PATH)/tweak.mk
