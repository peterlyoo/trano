#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mode=${1:---build}
[[ "$mode" == --check || "$mode" == --build ]] || { echo "Usage: $0 [--check|--build]" >&2; exit 2; }
for variable in TRANO_SIGNING_IDENTITY TRANO_NOTARY_PROFILE TRANO_UPDATE_FEED_URL TRANO_UPDATE_PUBLIC_KEY TRANO_UPDATE_DOWNLOAD_URL TRANO_APP_VERSION TRANO_BUILD_VERSION; do
    [[ -n "${!variable:-}" ]] || { echo "$variable is required for a signed update release." >&2; exit 1; }
done
[[ "$TRANO_SIGNING_IDENTITY" == "Developer ID Application:"* ]] || { echo "TRANO_SIGNING_IDENTITY must be a Developer ID Application certificate." >&2; exit 1; }
[[ "$TRANO_UPDATE_DOWNLOAD_URL" == https://* && "$TRANO_UPDATE_DOWNLOAD_URL" != *'@'* && "$TRANO_UPDATE_DOWNLOAD_URL" != *'#'* ]] || { echo "TRANO_UPDATE_DOWNLOAD_URL must be an HTTPS download directory without credentials or a fragment." >&2; exit 1; }
python3 scripts/configure-updates.py --check
security find-identity -v -p codesigning | grep -F -- "$TRANO_SIGNING_IDENTITY" >/dev/null || { echo "The requested Developer ID signing identity is not installed." >&2; exit 1; }
sparkle_tools=.build/artifacts/sparkle/Sparkle/bin
[[ -x "$sparkle_tools/generate_appcast" ]] || { echo "Resolve pinned Swift packages before preparing an update." >&2; exit 1; }
if [[ "$mode" == --check ]]; then
    echo "Release configuration and signing identity are present; notarization and update signing are verified during --build."
    exit 0
fi
export TRANO_UNIVERSAL=1
scripts/build-app.sh
release_dir="$PWD/build/releases/$TRANO_APP_VERSION-$TRANO_BUILD_VERSION"
[[ ! -e "$release_dir" ]] || { echo "Release directory already exists; choose a new increasing build version." >&2; exit 1; }
mkdir -p "$release_dir"
archive="$release_dir/Trano-$TRANO_APP_VERSION.zip"
ditto -c -k --sequesterRsrc --keepParent build/Trano.app "$archive"
xcrun notarytool submit "$archive" --keychain-profile "$TRANO_NOTARY_PROFILE" --wait --output-format plist > "$release_dir/notarization.plist"
[[ "$(plutil -extract status raw "$release_dir/notarization.plist")" == Accepted ]] || { echo "Notarization was not accepted; no update feed was produced." >&2; exit 1; }
xcrun stapler staple build/Trano.app
xcrun stapler validate build/Trano.app
codesign --verify --deep --strict build/Trano.app
spctl --assess --type execute --verbose build/Trano.app
rm "$archive"
ditto -c -k --sequesterRsrc --keepParent build/Trano.app "$archive"
"$sparkle_tools/generate_appcast" --account "${TRANO_UPDATE_KEY_ACCOUNT:-dev.trano.updates}" --download-url-prefix "${TRANO_UPDATE_DOWNLOAD_URL%/}/" --maximum-deltas 0 -o "$release_dir/appcast.xml" "$release_dir"
"$sparkle_tools/sign_update" --account "${TRANO_UPDATE_KEY_ACCOUNT:-dev.trano.updates}" --verify "$release_dir/appcast.xml"
(cd "$release_dir" && shasum -a 256 "$(basename "$archive")" > SHA256SUMS)
printf 'Signed, notarized update artifacts: %s\n' "$release_dir"
