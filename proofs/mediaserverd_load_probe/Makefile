TARGET := iphone:clang:latest:15.0
ARCHS := arm64
THEOS_PACKAGE_SCHEME := rootless

include $(THEOS)/makefiles/common.mk

TWEAK_NAME := VCAMProLoadProbe
VCAMProLoadProbe_FILES := LoadProbe.c
VCAMProLoadProbe_INSTALL_PATH := /usr/lib/TweakInject
VCAMProLoadProbe_CFLAGS := -Wall -Wextra -Werror\nVCAMProLoadProbe_LDFLAGS := -Wl,-rpath,@loader_path/.jbroot/Library/Frameworks -Wl,-rpath,@loader_path/.jbroot/usr/lib -Wl,-install_name,@loader_path/VCAMProLoadProbe.dylib

include $(THEOS_MAKE_PATH)/tweak.mk
