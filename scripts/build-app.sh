#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
configuration=release
if [[ "${1:-}" == "--debug" ]]; then configuration=debug; shift; fi
if [[ $# -ne 0 ]]; then echo "Usage: $0 [--debug]" >&2; exit 2; fi
signing_identity=${TRANO_SIGNING_IDENTITY:--}
build_version=${TRANO_BUILD_VERSION:-1}
python3 scripts/configure-updates.py --check
build_args=(-c "$configuration")
if [[ "${TRANO_UNIVERSAL:-0}" == 1 ]]; then build_args+=(--arch arm64 --arch x86_64); fi
swift build "${build_args[@]}"
binary_dir=$(swift build "${build_args[@]}" --show-bin-path)
build_identity=$(python3 scripts/build-id.py)
mkdir -p build
staging=$(mktemp -d build/.bundle.XXXXXX)
trap 'rm -rf "$staging"' EXIT
app="$staging/Trano.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources" "$app/Contents/Frameworks"
swift scripts/generate-icon.swift "$staging/Trano.icns" >/dev/null
cp "$staging/Trano.icns" "$app/Contents/Resources/Trano.icns"
python3 scripts/generate-sbom.py --version "${TRANO_APP_VERSION:-0.1.0}" --output "$app/Contents/Resources/sbom.json" >/dev/null
cp "$binary_dir/TranoApp" "$app/Contents/MacOS/TranoApp"
cp "$binary_dir/trano" "$app/Contents/MacOS/trano"
for resource in "$binary_dir"/*.bundle; do
    if [[ -d "$resource" ]]; then cp -R "$resource" "$app/Contents/Resources/"; fi
done
sparkle=.build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework
[[ -d "$sparkle" ]] || { echo "Sparkle framework is missing; resolve pinned packages first." >&2; exit 1; }
ditto "$sparkle" "$app/Contents/Frameworks/Sparkle.framework"
mkdir -p "$app/Contents/Resources/Licenses"
cp .build/artifacts/sparkle/Sparkle/LICENSE "$app/Contents/Resources/Licenses/Sparkle.txt"
if [[ -d licenses ]]; then cp licenses/*.txt "$app/Contents/Resources/Licenses/"; fi
if [[ -f LICENSE ]]; then cp LICENSE "$app/Contents/Resources/Licenses/Trano.txt"; fi
if [[ -x scripts/bundle-remote.sh ]]; then scripts/bundle-remote.sh "$app/Contents/Resources"; fi
cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>Trano</string>
<key>CFBundleDisplayName</key><string>Trano</string>
<key>CFBundleIdentifier</key><string>dev.trano.app</string>
<key>CFBundleExecutable</key><string>TranoApp</string>
<key>CFBundleIconFile</key><string>Trano.icns</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.1.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>CFBundleURLTypes</key><array><dict><key>CFBundleURLName</key><string>Session</string><key>CFBundleURLSchemes</key><array><string>trano</string></array></dict></array>
<key>NSMicrophoneUsageDescription</key><string>Record speech only when you start voice input.</string>
<key>NSSpeechRecognitionUsageDescription</key><string>Convert your voice into editable terminal input.</string>
</dict></plist>
PLIST
python3 scripts/configure-updates.py "$app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :TranoBuildID string $build_identity" "$app/Contents/Info.plist"
helper="$app/Contents/Helpers/Trano Service.app"
mkdir -p "$helper/Contents/MacOS"
cp "$binary_dir/TranoApp" "$helper/Contents/MacOS/TranoApp"
cp "$binary_dir/trano" "$helper/Contents/MacOS/trano"
cat > "$helper/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>Trano Activity</string>
<key>CFBundleIdentifier</key><string>dev.trano.activity</string>
<key>CFBundleExecutable</key><string>TranoApp</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSUIElement</key><true/>
<key>LSMinimumSystemVersion</key><string>14.0</string>
</dict></plist>
PLIST
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $build_version" "$helper/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :CFBundleShortVersionString string ${TRANO_APP_VERSION:-0.1.0}" "$helper/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :TranoBuildID string $build_identity" "$helper/Contents/Info.plist"
sign_args=(--force --sign "$signing_identity")
if [[ "$signing_identity" != - ]]; then sign_args+=(--options runtime --timestamp); fi
framework="$app/Contents/Frameworks/Sparkle.framework/Versions/B"
for nested in "$framework/Autoupdate" "$framework/Updater.app" "$framework/XPCServices/Downloader.xpc" "$framework/XPCServices/Installer.xpc"; do
    codesign "${sign_args[@]}" --preserve-metadata=entitlements "$nested"
done
codesign "${sign_args[@]}" "$app/Contents/Frameworks/Sparkle.framework"
codesign "${sign_args[@]}" "$app/Contents/MacOS/trano"
codesign "${sign_args[@]}" "$helper/Contents/MacOS/trano"
codesign "${sign_args[@]}" "$helper"
codesign "${sign_args[@]}" --entitlements scripts/app-entitlements.plist "$app"
plutil -lint "$app/Contents/Info.plist"
codesign --verify --deep --strict "$app"
if [[ -e build/Trano.app ]]; then mv build/Trano.app "$staging/Previous.app"; fi
mv "$app" build/Trano.app
printf '%s\n' "$PWD/build/Trano.app"
