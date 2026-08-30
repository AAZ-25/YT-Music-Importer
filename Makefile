ARCHS = arm64
TARGET = iphone:clang:latest:15.0
INSTALL_TARGET_PROCESSES = YouTube SpringBoard medialibraryd

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = YTMusicImporter YTMIMusicBridge
YTKACE_DIR = $(THEOS_PROJECT_DIR)/Vendor/YTKACE

YTMusicImporter_FILES = Tweak.x \
	Native/YTMINativeStreamResolver.m \
	Native/YTMIMusicImporter.m \
	Native/YTMISABRBridge.mm \
	Native/YTMIVendorSupport.mm \
	Native/YTMIVendorBundle.mm \
	Native/YTMILogMaintenance.m
YTMusicImporter_CFLAGS = -fobjc-arc \
	-Wno-nullability-completeness \
	-I$(THEOS_PROJECT_DIR)/Shared \
	-I$(THEOS_PROJECT_DIR)/Native \
	-I$(YTKACE_DIR)/Tweak/Features/Downloads \
	-I$(YTKACE_DIR)/Tweak/Runtime \
	-DYTKACE_COMBINED_SABR=1
YTMusicImporter_CCFLAGS = -std=c++17 -Wno-nullability-completeness
YTMusicImporter_FRAMEWORKS = UIKit Foundation AVFoundation VideoToolbox CoreMedia CoreFoundation
YTMusicImporter_LIBRARIES = z

YTMIMusicBridge_FILES = SpringBoard/YTMISpringBoardBridge.m \
	Native/YTMIMusicDatabaseImporter.m \
	Native/YTMIMusicLibraryCompatibility.m
YTMIMusicBridge_CFLAGS = -fobjc-arc \
	-Wno-nullability-completeness \
	-include objc/runtime.h \
	-I$(THEOS_PROJECT_DIR)/Shared \
	-I$(THEOS_PROJECT_DIR)/Native
YTMIMusicBridge_FRAMEWORKS = Foundation AVFoundation CoreMedia CoreFoundation

include $(THEOS_MAKE_PATH)/tweak.mk

after-install::
	install.exec "killall YouTube || true"
