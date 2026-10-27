THEOS ?= /Users/yanghuai/theos
TARGET := iphone:clang:latest:15.0
ARCHS := arm64 arm64e
THEOS_PACKAGE_SCHEME := rootless
FINALPACKAGE := 1
DEBUG := 0
INSTALL_TARGET_PROCESSES := AMapiPhone
include $(THEOS)/makefiles/common.mk
TWEAK_NAME := GaodeClean
GaodeClean_FILES := src/GaodeClean.m
GaodeClean_CFLAGS := -fobjc-arc -Wall -Wextra -fmodules-cache-path=$(THEOS_PROJECT_DIR)/.theos/ModuleCache
ifneq ($(GCC_DEVICE_TEST),)
GaodeClean_CFLAGS += -DGCC_DEVICE_TEST=1
endif
GaodeClean_FRAMEWORKS := UIKit Foundation
include $(THEOS_MAKE_PATH)/tweak.mk
