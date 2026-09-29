#!/usr/bin/env bash
#
# 在 macOS 上把 joeme-watch 的 iOS 源码编成静态 framework，供 HBuilderX 云打包引用。
#
# ── 为什么必须有这一步 ────────────────────────────────────────────────
# HBuilderX 云打包只自动引用 nativeplugins/<插件>/ios/ 下的 .a / .framework，
# **不会编译 .m 源码**。证据是 2026-09-29 那次 iOS Appstore 打包的完整日志
# （开头 Command line invocation、结尾 ** ARCHIVE FAILED **，是整份不是片段）：
# 整个 HBuilder target 只编译了 main.m 一个 .m，全文 0 处出现 DCUniModule。
#
# 所以下面这些文件以前都是死代码，从来不参与编译：
#     ios/JoemeWatchModule.m        ← 插件本体，等于 iOS 端插件是空壳
#     ios/FMDB/*.m                  ← 第 13 个 undefined symbol 的来源
#     ios/MJExtension/*.m
# 报错形态：链接期 `Undefined symbols: _OBJC_CLASS_$_FMDatabaseQueue`
#           （referenced from VeepooBleSDK[252](DBStoreManager.o)）
#
# ── 产物 ─────────────────────────────────────────────────────────────
#   JoemeWatchModule.framework（静态 framework，arm64）
#   放回 nativeplugins/joeme-watch/ios/ 后，HBuilderX 会用
#       -F<插件ios目录> -weak_framework JoemeWatchModule
#   链进来 —— VeepooBleSDK.framework 就是这么被链的（日志 tail 可见
#   `-weak_framework VeepooBleSDK`），所以这条路子同构、风险最低。
#   云打包已带 -ObjC，静态库里的 ObjC 类与分类会被强制加载，
#   运行时 NSClassFromString("JoemeWatchModule") 能找到类。
#
# ── 用法 ─────────────────────────────────────────────────────────────
#   DCUNI_INC=<uni-app iOS 离线打包 SDK 的 inc 目录> \
#       bash build-ios-framework.sh [输出目录]
#
# DCUNI_INC 必须指向含 DCUniModule.h 的目录（离线 SDK 解压后的 SDK/inc/
# 或 HBuilder-Hello/inc/）。也可以把它直接放进 ios/dcuni-inc/ 当作默认值。
#
# ⚠ 不要自己写 DCUniModule.h 的 stub：UNI_EXPORT_METHOD 的展开负责把方法
#   注册给运行时（展开定义未公开），DCUniModule 基类还带 uniInstance /
#   uniExecuteQueue / uniExecuteThread 等 ivar，猜错会静默失效或 ivar 错位。
#
set -euo pipefail

IOS_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$IOS_DIR/../../.." && pwd)"
OUT_DIR="${1:-$PROJECT_ROOT/build-ios-plugin}"
FRAMEWORK_NAME="JoemeWatchModule"
FW="$OUT_DIR/$FRAMEWORK_NAME.framework"

# 部署目标：DCloud 基座实际链接时是 -target arm64-apple-ios15.0（见构建日志）。
# 静态库本身不带这个约束，取 12.0 只是为了兼容 Xcode 15+ 已放弃 iOS 11 的限制。
MIN_IOS="${MIN_IOS:-12.0}"

# ── 前置检查 ─────────────────────────────────────────────────────────
command -v xcrun >/dev/null || { echo "!! 需要 macOS + Xcode（xcrun 不存在）" >&2; exit 1; }

# DCUniModule.h 的位置：环境变量 > 仓库内 build-ios/dcuni-inc/ > 插件目录内 dcuni-inc/
# 放仓库根而不是插件目录，是为了不把 DCloud 的头文件混进 nativeplugins（它们只参与构建）。
# 注意：SDK 的 inc/ 是嵌套结构，DCUniModule.h 在 inc/DCUni/ 子目录，不是 inc/ 根。
# 所以 DCUNI_INC 应指向"解压后含 DCUni/ 的 inc 目录"，判断条件用 DCUni/DCUniModule.h。
DCUNI_INC="${DCUNI_INC:-}"
if [ -z "$DCUNI_INC" ] || [ ! -f "$DCUNI_INC/DCUni/DCUniModule.h" ]; then
  DCUNI_INC=""
  for c in "$PROJECT_ROOT/build-ios/dcuni-inc" "$IOS_DIR/dcuni-inc"; do
    if [ -f "$c/DCUni/DCUniModule.h" ]; then DCUNI_INC="$c"; break; fi
  done
fi
if [ -z "$DCUNI_INC" ]; then
  echo "!! 找不到 DCUni/DCUniModule.h。它来自 uni-app iOS 离线打包 SDK 解压后的 inc/ 目录" >&2
  echo "   （SDK 下载页 https://nativesupport.dcloud.net.cn/AppDocs/download/ios.html ，" >&2
  echo "     和彩云/百度网盘，提取码 a6sb；版本要和 HBuilderX 对得上）。" >&2
  echo "   用法：DCUNI_INC=<inc目录> bash $0 [输出目录]" >&2
  echo "   或把 inc 里的头文件拷到 $PROJECT_ROOT/build-ios/dcuni-inc/（含 DCUni/ 子目录）" >&2
  exit 1
fi

SDKROOT="$(xcrun --sdk iphoneos --show-sdk-path)"
SDK_VER="$(xcrun --sdk iphoneos --show-sdk-version)"
echo "ios 目录:   $IOS_DIR"
echo "DCUni inc:  $DCUNI_INC"
echo "iPhoneOS SDK: $SDK_VER  ($SDKROOT)"
echo "输出:       $FW"
echo

# ── 收集源码 ─────────────────────────────────────────────────────────
SOURCES=()
[ -f "$IOS_DIR/$FRAMEWORK_NAME.m" ] && SOURCES+=("$IOS_DIR/$FRAMEWORK_NAME.m")
for d in FMDB MJExtension; do
  if [ -d "$IOS_DIR/$d" ]; then
    while IFS= read -r f; do SOURCES+=("$f"); done < <(find "$IOS_DIR/$d" -name '*.m' | sort)
  fi
done
if [ ${#SOURCES[@]} -eq 0 ]; then
  echo "!! 没找到任何 .m 源码（期望 $FRAMEWORK_NAME.m / FMDB/ / MJExtension/）" >&2
  exit 1
fi
echo "待编译 ${#SOURCES[@]} 个 .m："
for f in "${SOURCES[@]}"; do echo "    ${f#$IOS_DIR/}"; done
echo

# ── 编译 ─────────────────────────────────────────────────────────────
# -fobjc-arc        : JoemeWatchModule.m / MJExtension 用 ARC；FMDB 有
#                     #if !__has_feature(objc_arc) 分支，跟着 ARC 走没问题
# -F<IOS_DIR>       : 让 <VeepooBleSDK/VeepooBleSDK.h> 这种 framework 式导入能解析
# -I<IOS_DIR>       : JoemeWatchModule.h 在本目录
# 第三方 framework（ZipZap/JL_BLEKit/...）只在 SDK 二进制里有引用，头文件里
# 只有注释提到，所以这里不需要它们的 include 路径。
# 另外：inc 是嵌套结构，DCUniModule.h 在 DCUni/ 子目录、DCUniBasePlugin.h 又
# #import "WXComponent.h"（在 weexHeader/），所以除 -I$DCUNI_INC 根外，
# 还要追加 DCUni/ 和 weexHeader/ 两个子目录，否则引号 include 解析不到。
CFLAGS=(
  -target "arm64-apple-ios$MIN_IOS"
  -isysroot "$SDKROOT"
  -fobjc-arc
  -fmodules -fmodules-cache-path="$OUT_DIR/ModuleCache"
  -O2 -DNDEBUG
  -I"$DCUNI_INC"
  -I"$DCUNI_INC/DCUni"
  -I"$DCUNI_INC/weexHeader"
  -I"$IOS_DIR"
  -F"$IOS_DIR"
  -Wno-nullability-completeness
  -Wno-deprecated-declarations
  -Wno-unguarded-availability-new
)

rm -rf "$OUT_DIR"
mkdir -p "$OUT_DIR/obj" "$FW"

OBJS=()
i=0
for src in "${SOURCES[@]}"; do
  i=$((i + 1))
  obj="$OUT_DIR/obj/$(printf '%02d' "$i")-$(basename "${src%.m}").o"
  printf '  [%2d/%d] %s\n' "$i" "${#SOURCES[@]}" "${src#$IOS_DIR/}"
  xcrun -sdk iphoneos clang -c "${CFLAGS[@]}" "$src" -o "$obj"
  OBJS+=("$obj")
done
echo

# ── 打包成静态 framework ─────────────────────────────────────────────
xcrun libtool -static -o "$FW/$FRAMEWORK_NAME" "${OBJS[@]}"

cat > "$FW/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleExecutable</key><string>$FRAMEWORK_NAME</string>
	<key>CFBundleIdentifier</key><string>com.joeme.watch.$FRAMEWORK_NAME</string>
	<key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
	<key>CFBundleName</key><string>$FRAMEWORK_NAME</string>
	<key>CFBundlePackageType</key><string>FMWK</string>
	<key>CFBundleShortVersionString</key><string>1.0.0</string>
	<key>CFBundleVersion</key><string>1</string>
	<key>MinimumOSVersion</key><string>$MIN_IOS</string>
	<key>CFBundleSupportedPlatforms</key><array><string>iPhoneOS</string></array>
	<key>CFBundleDevelopmentRegion</key><string>en</string>
</dict>
</plist>
PLIST

# 刻意不放 Headers/ 和 Modules/：本 framework 只是链接用的静态库，
# 带上没有对应头的 module.modulemap 反而会让别人的 @import 解析失败。

# ── 自检：产物里该有的符号必须在 ──────────────────────────────────────
# 只看"已定义"的全局符号（行首有地址的那些）。不能直接 nm -g | grep 符号名：
# JoemeWatchModule.o 里 _OBJC_CLASS_$_DCUniModule 是 U（未定义引用，正确且必须），
# 不过滤会把这条合法引用误判成"产物里塞了 DCUniModule 本体"。
# 用行首地址而不是 nm -U，是为了不依赖 BSD nm 的 -U 语义。
echo "=== 产物符号自检 ==="
BIN="$FW/$FRAMEWORK_NAME"
DEFINED="$(nm -g "$BIN" 2>/dev/null | grep -E '^[0-9a-f]{8,} ' || true)"
fail=0
for sym in _OBJC_CLASS_\$_JoemeWatchModule _OBJC_CLASS_\$_FMDatabaseQueue _OBJC_CLASS_\$_MJProperty; do
  if printf '%s\n' "$DEFINED" | grep -qF "$sym"; then
    echo "  ✓ $sym"
  else
    echo "  ✗ $sym 缺失" >&2
    fail=1
  fi
done
# 绝不能带进去的：这些由基座 / VeepooBleSDK.framework 提供，重复定义会在最终链接时炸
for sym in _OBJC_CLASS_\$_DCUniModule _OBJC_CLASS_\$_VPDFUOperation _OBJC_CLASS_\$_ZZArchive; do
  if printf '%s\n' "$DEFINED" | grep -qF "$sym"; then
    echo "  ✗ 产物里含 $sym（应由基座/VeepooBleSDK 提供），最终链接会重复符号" >&2
    fail=1
  fi
done
[ "$fail" -eq 0 ] || { echo "!! 自检失败" >&2; exit 1; }

echo
echo "完成：$FW"
du -sh "$FW"
echo
echo "下一步："
echo "  1) 把 $FRAMEWORK_NAME.framework 拷进 nativeplugins/joeme-watch/ios/"
echo "  2) 确认 package.json 的 ios.frameworks 里有 \"$FRAMEWORK_NAME.framework\""
echo "     （静态 framework，只写 frameworks，不要写进 embedFrameworks）"
echo "  3) 重新云端打包。原生插件不能热更新，调试基座也要重做。"
