#!/usr/bin/env bash
set -euo pipefail

# 一键构建 macOS Universal 2 App，并生成标准拖拽安装 DMG。
# 用法：
#   ./build_dmg.sh
#   SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" TEAM_ID="TEAMID" ./build_dmg.sh

APP_NAME="Alpha的文件同步工具"
SCHEME="Alpha的文件同步工具"
CONFIGURATION="Release"
PROJECT_PATH="${APP_NAME}.xcodeproj"
BUNDLE_ID="com.alpha.filesync"
ARCHS="arm64 x86_64"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_ROOT="${ROOT_DIR}/build"
DERIVED_DATA="${BUILD_ROOT}/DerivedData"
EXPORT_DIR="${BUILD_ROOT}/Export"
DMG_STAGE="${BUILD_ROOT}/DMGStage"
DMG_TEMP="${BUILD_ROOT}/${APP_NAME}-temp.dmg"
DMG_OUTPUT="${BUILD_ROOT}/${APP_NAME}.dmg"
APP_PATH="${EXPORT_DIR}/${APP_NAME}.app"
VOLUME_NAME="${APP_NAME} Installer"

SIGN_IDENTITY="${SIGN_IDENTITY:-}"
TEAM_ID="${TEAM_ID:-}"

log() {
  printf '\033[1;34m==> %s\033[0m\n' "$1"
}

fail() {
  printf '\033[1;31m错误：%s\033[0m\n' "$1" >&2
  exit 1
}

command -v xcodebuild >/dev/null 2>&1 || fail "未找到 xcodebuild，请先安装 Xcode 并运行：sudo xcode-select -s /Applications/Xcode.app"
command -v hdiutil >/dev/null 2>&1 || fail "未找到 hdiutil，当前系统不是完整 macOS 环境"

cd "${ROOT_DIR}"

log "清理构建目录"
rm -rf "${BUILD_ROOT}"
mkdir -p "${DERIVED_DATA}" "${EXPORT_DIR}" "${DMG_STAGE}"

XCODEBUILD_SETTINGS=(
  -project "${PROJECT_PATH}"
  -scheme "${SCHEME}"
  -configuration "${CONFIGURATION}"
  -derivedDataPath "${DERIVED_DATA}"
  -destination "generic/platform=macOS"
  ARCHS="${ARCHS}"
  ONLY_ACTIVE_ARCH=NO
  MACOSX_DEPLOYMENT_TARGET=13.0
  PRODUCT_BUNDLE_IDENTIFIER="${BUNDLE_ID}"
  ENABLE_HARDENED_RUNTIME=YES
)

if [[ -n "${SIGN_IDENTITY}" ]]; then
  log "启用 Developer ID 签名：${SIGN_IDENTITY}"
  XCODEBUILD_SETTINGS+=(
    CODE_SIGNING_ALLOWED=YES
    CODE_SIGNING_REQUIRED=YES
    CODE_SIGN_STYLE=Manual
    CODE_SIGN_IDENTITY="${SIGN_IDENTITY}"
    OTHER_CODE_SIGN_FLAGS="--timestamp"
  )
  if [[ -n "${TEAM_ID}" ]]; then
    XCODEBUILD_SETTINGS+=(DEVELOPMENT_TEAM="${TEAM_ID}")
  fi
else
  log "未提供 SIGN_IDENTITY，生成本地未签名 App"
  XCODEBUILD_SETTINGS+=(
    CODE_SIGNING_ALLOWED=NO
    CODE_SIGNING_REQUIRED=NO
    CODE_SIGN_IDENTITY=""
  )
fi

log "编译 Universal 2 Release App"
xcodebuild "${XCODEBUILD_SETTINGS[@]}" clean build

BUILT_APP="${DERIVED_DATA}/Build/Products/${CONFIGURATION}/${APP_NAME}.app"
[[ -d "${BUILT_APP}" ]] || fail "编译成功但未找到 ${BUILT_APP}"

log "复制 App 到导出目录"
cp -R "${BUILT_APP}" "${APP_PATH}"

EXECUTABLE="${APP_PATH}/Contents/MacOS/${APP_NAME}"
[[ -f "${EXECUTABLE}" ]] || fail "未找到 App 可执行文件：${EXECUTABLE}"

log "检查二进制架构"
LIPO_INFO="$(lipo -info "${EXECUTABLE}")"
echo "${LIPO_INFO}"
[[ "${LIPO_INFO}" == *"arm64"* ]] || fail "二进制缺少 arm64 架构"
[[ "${LIPO_INFO}" == *"x86_64"* ]] || fail "二进制缺少 x86_64 架构"

if [[ -n "${SIGN_IDENTITY}" ]]; then
  log "校验代码签名"
  codesign --verify --deep --strict --verbose=2 "${APP_PATH}"
  spctl --assess --type execute --verbose=4 "${APP_PATH}" || true
fi

log "准备 DMG 内容"
cp -R "${APP_PATH}" "${DMG_STAGE}/${APP_NAME}.app"
ln -s /Applications "${DMG_STAGE}/Applications"

# 计算 DMG 容量：App 实际大小 + 80MB 余量，避免 hdiutil 空间不足。
APP_SIZE_KB="$(du -sk "${DMG_STAGE}" | awk '{print $1}')"
DMG_SIZE_MB="$((APP_SIZE_KB / 1024 + 80))"

log "创建临时可写 DMG"
hdiutil create \
  -volname "${VOLUME_NAME}" \
  -srcfolder "${DMG_STAGE}" \
  -fs HFS+ \
  -fsargs "-c c=64,a=16,e=16" \
  -format UDRW \
  -size "${DMG_SIZE_MB}m" \
  "${DMG_TEMP}"

MOUNT_DIR=""
cleanup_mount() {
  if [ -n "${MOUNT_DIR}" ]; then
    hdiutil detach "${MOUNT_DIR}" -quiet || true
  fi
}
trap cleanup_mount EXIT

log "设置 DMG Finder 窗口布局"
# 不用 -mountpoint：强制挂载点会让卷不注册为 Finder 的 disk 对象，AppleScript 的
# `tell disk "..."` 取不到它而报 -1728。改为正常挂载（卷出现在 /Volumes 下并注册到 Finder），
# 再从 hdiutil 输出中提取挂载点（卷名含空格，用 grep 取 /Volumes 起始到行尾整段）。
ATTACH_OUTPUT="$(hdiutil attach "${DMG_TEMP}" -readwrite -noverify -noautoopen 2>/dev/null)"
MOUNT_DIR="$(printf '%s\n' "${ATTACH_OUTPUT}" | grep -o '/Volumes/.*' | tail -n1)"
MOUNT_DIR="${MOUNT_DIR%/}"
[ -n "${MOUNT_DIR}" ] || fail "挂载临时 DMG 失败，无法获取挂载点"

# 等待 Finder 识别新挂载的卷，避免 AppleScript 抢在注册前运行取不到 disk。
sleep 1

# 设置图标布局写入卷的 .DS_Store。必须先 open 让 container window 物化，否则取不到 item（-10006）；
# 但不要 close/二次 open/update/delay——这些在无 GUI 的构建会话里会让 Finder AppleEvent 超时（-1712）。
# 失败不阻断打包（|| true），最坏只是打开 DMG 时图标不自动排列。
osascript <<APPLESCRIPT || true
tell application "Finder"
  tell disk "${VOLUME_NAME}"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set bounds of container window to {200, 120, 760, 470}
    set viewOptions to the icon view options of container window
    set arrangement of viewOptions to not arranged
    set icon size of viewOptions to 96
    set position of item "${APP_NAME}.app" of container window to {170, 170}
    set position of item "Applications" of container window to {390, 170}
  end tell
end tell
APPLESCRIPT

sync
hdiutil detach "${MOUNT_DIR}" -quiet
trap - EXIT

log "压缩生成最终 DMG"
rm -f "${DMG_OUTPUT}"
hdiutil convert "${DMG_TEMP}" -format UDZO -imagekey zlib-level=9 -o "${DMG_OUTPUT}"

if [[ -n "${SIGN_IDENTITY}" ]]; then
  log "签名 DMG"
  codesign --force --sign "${SIGN_IDENTITY}" --timestamp "${DMG_OUTPUT}"
  codesign --verify --verbose=2 "${DMG_OUTPUT}"
fi

log "完成"
printf 'App: %s\nDMG: %s\n' "${APP_PATH}" "${DMG_OUTPUT}"
