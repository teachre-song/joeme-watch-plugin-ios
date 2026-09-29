#!/usr/bin/env bash
# 把 Veepoo iOS SDK 缺失的第三方依赖 framework 拷进插件目录。
# 背景：VeepooBleSDK.framework 是静态库，其 .o 引用了 ZipZap / ABParTool / GRDFUSDK /
#       JLDialUnit / JL_BLEKit / DFUnits 这些第三方类，但厂商没把依赖随 framework 一起给，
#       导致 iOS 云打包在链接阶段 Undefined symbols for architecture arm64。
#
# 用法（Windows 上直接在 Git Bash 里跑，或 HBuilderX 终端里跑）：
#   bash nativeplugins/joeme-watch/ios/sync-deps.sh
set -euo pipefail

DEST="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$DEST/../../.." && pwd)"

# 源目录候选，按顺序取第一个存在的：
#   1) 仓库内那份（uni_modules/.../iOS_Ble_SDK，内容完整）
#      ⚠ 该目录被根 .gitignore 的 `/uni_modules/JOEMEFIT SDK 260828/` 排除，
#        所以只在你这台机器上有，别人 clone 下来是空的 → 必须有 2) 兜底。
#   2) 仓库外的原始 SDK 目录。
CANDIDATES=(
  "$PROJECT_ROOT/uni_modules/JOEMEFIT SDK 260828/iOS_Ble_SDK/iOS_sdk_source/doc"
  "E:/正转仓/JOEMEFIT SDK 260828/iOS_Ble_SDK/iOS_sdk_source/doc"
)

SRC=""
for c in "${CANDIDATES[@]}"; do
  if [ -d "$c" ]; then SRC="$c"; break; fi
done

# 静态 framework → package.json 的 ios.frameworks
STATIC=(
  "K系列第三方库/DFUnits.framework"
  "K系列第三方库/JL_BLEKit.framework"
)
# 动态 framework → package.json 的 ios.embedFrameworks（必须嵌进 App 的 Frameworks/ 并签名）
DYNAMIC=(
  "K系列第三方库/ZipZap.framework"
  "K系列第三方库/JLDialUnit.framework"
  "Z系列第三方库/ABParTool.framework"
  "GRDFUSDK.framework"
)

if [ -z "$SRC" ]; then
  echo "!! 找不到 SDK 源目录，以下路径都不存在：" >&2
  for c in "${CANDIDATES[@]}"; do echo "     $c" >&2; done
  echo "   如果 SDK 又换过位置，改这个脚本里的 CANDIDATES 即可。" >&2
  exit 1
fi

echo "源目录: $SRC"
echo "目标:   $DEST"
echo

for f in "${STATIC[@]}" "${DYNAMIC[@]}"; do
  name="$(basename "$f")"
  if [ -e "$DEST/$name" ]; then
    echo "跳过（已存在）: $name"
    continue
  fi
  cp -r "$SRC/$f" "$DEST/"
  echo "已拷贝: $name  ←  $f"
done

echo
echo "=== ios/ 现状 ==="
ls -1 "$DEST"
echo
echo "下一步：确认 package.json 的 ios.frameworks / ios.embedFrameworks 与上面一致，"
echo "        然后重新云端打包（原生插件不能热更新，改完必须重做基座）。"
