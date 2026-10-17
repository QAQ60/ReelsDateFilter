TARGET := iphone:clang:latest:14.0
ARCHS = arm64 arm64e
INSTALL_TARGET_PROCESSES = Instagram

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = ReelsDateFilter
ReelsDateFilter_FILES = Tweak.xm rg_date_filter.c
ReelsDateFilter_CFLAGS = -fobjc-arc

include $(THEOS_MAKE_PATH)/tweak.mk
