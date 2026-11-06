ARCHS = arm64 arm64e
TARGET = iphone:clang:latest:14.0
INSTALL_TARGET_PROCESSES = WeChat

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = WCAIChatHelper

# WCAIAutoEngine.m 刻意不在此列表中（主号构建，全自动物理不可达）
WCAIChatHelper_FILES = $(wildcard src/*.m src/*.c)
WCAIChatHelper_FILES := $(filter-out src/WCAIAutoEngine.m,$(WCAIChatHelper_FILES))

# -O2 + 隐藏符号：产物里不留多余的类名/方法名可供特征扫描
WCAIChatHelper_CFLAGS = -fobjc-arc -fvisibility=hidden -O2 \
                        -Wno-unused-function -Wno-deprecated-declarations \
                        -DWCAI_DISABLE_AUTO=1 \
                        -DWCAI_MAIN_ACCOUNT_BUILD=1 \
                        -DWCAI_ENABLE_GOT_PATCH=0
WCAIChatHelper_FRAMEWORKS = Foundation UIKit CoreGraphics
WCAIChatHelper_LIBRARIES = sqlite3

# 安装名伪装成 mars 生态库：dyld 列出的名字与微信自带库风格一致
WCAIChatHelper_LDFLAGS = -install_name @executable_path/Frameworks/libmarsbridge.dylib \
                         -Wl,-dead_strip

include $(THEOS_MAKE_PATH)/tweak.mk

# 打包后处理：改名 + 去符号 + 伪签，产出可直接交给全能签注入的 dylib
after-all::
	@mv -f $(THEOS_OBJ_DIR)/WCAIChatHelper.dylib $(THEOS_OBJ_DIR)/libmarsbridge.dylib 2>/dev/null || true
	@strip -x $(THEOS_OBJ_DIR)/libmarsbridge.dylib 2>/dev/null || true
	@ldid -S $(THEOS_OBJ_DIR)/libmarsbridge.dylib 2>/dev/null || true
	@echo "[WCAI] artifact: $(THEOS_OBJ_DIR)/libmarsbridge.dylib"
