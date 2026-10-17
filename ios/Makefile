# ─────────────────────────────────────────────────────────────────────────────
# SpCnEmbedded —— 世界弹射物语 CN「服务端单机内嵌」tweak
#
# 同一份代码、两种装法：
#   · 越狱线：theos 出 deb（rootless iphoneos-arm64 / rootful iphoneos-arm），
#             由 MobileSubstrate 按 layout 里的过滤器注入官方 App。
#   · 非越狱线：同一份 .dylib 由 tools/inject-dylib.mjs 注入补丁后的 IPA（重签后安装）。
#
# ⇒ 因此源码里**不得**出现 MobileSubstrate / CydiaSubstrate API，
#   入口只能是 __attribute__((constructor))（CdnImporter 那份非越狱 dylib 的既有做法）。
#
# 构建：本机用 WSL 的 theos（见 tools/build-wsl.sh）：
#   wsl -d Ubuntu-24.04 -u ubuntu -- bash tools/build-wsl.sh package
# ─────────────────────────────────────────────────────────────────────────────

ARCHS = arm64
TARGET = iphone:clang:latest:14.0

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = SpCnEmbedded
# src/importer/*.m = 资源导入引擎（移植自 wf-cdn-importer-iOS：ZIP/TAR 解析 + 导入计划 + 引擎）
SpCnEmbedded_FILES = Tweak.xm $(wildcard src/*.m) $(wildcard src/importer/*.m)
SpCnEmbedded_CFLAGS = -fobjc-arc -Wno-deprecated-declarations -Wno-unused-function -Isrc -Isrc/importer
SpCnEmbedded_FRAMEWORKS = UIKit Foundation WebKit QuartzCore
# -U,_objc_msgSend：允许对 objc_msgSend 取地址（我们在 hook 之外不改用它，但保留该惯例）
# -lz：CdnZipArchive 逐条解压要用 zlib（SDK 里的 libz.tbd）
SpCnEmbedded_LDFLAGS = -Wl,-U,_objc_msgSend -lz
SpCnEmbedded_INSTALL_PATH = /Library/MobileSubstrate/DynamicLibraries

include $(THEOS_MAKE_PATH)/tweak.mk

after-install::
	install.exec "killall -9 worldflipper || true"
