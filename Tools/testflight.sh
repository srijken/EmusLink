#!/bin/sh
# Archives the app and uploads it to TestFlight.
#
#   Tools/testflight.sh                  archive and upload
#   Tools/testflight.sh --archive-only   archive only (checks that a release build signs)
#
# Needs Config/Local.xcconfig with your own APP_BUNDLE_ID and DEVELOPMENT_TEAM, and an
# app with that bundle identifier in App Store Connect.
#
# Signing and uploading use the Apple account that is signed in to Xcode. To use an
# App Store Connect API key instead (for example on a machine without Xcode accounts),
# set ASC_KEY_PATH (the .p8 file), ASC_KEY_ID and ASC_ISSUER_ID in the environment.
set -eu
cd "$(dirname "$0")/.."

if [ ! -f Config/Local.xcconfig ]; then
    echo "Config/Local.xcconfig is missing: copy Config/Local.xcconfig.example and fill it in." >&2
    exit 1
fi

# Every upload needs a higher build number: use the time of the build.
BUILD=$(date +%Y%m%d%H%M)
ARCHIVE=build/EmusLink.xcarchive
OPTIONS=build/ExportOptions.plist

AUTH=""
if [ -n "${ASC_KEY_PATH:-}" ]; then
    AUTH="-authenticationKeyPath $ASC_KEY_PATH -authenticationKeyID $ASC_KEY_ID -authenticationKeyIssuerID $ASC_ISSUER_ID"
fi

mkdir -p build
xcodegen
# shellcheck disable=SC2086
xcodebuild archive -project EmusLink.xcodeproj -scheme EmusLink -configuration Release \
    -destination 'generic/platform=iOS' -archivePath "$ARCHIVE" \
    -allowProvisioningUpdates $AUTH CURRENT_PROJECT_VERSION="$BUILD"
echo "Archived build $BUILD in $ARCHIVE"

[ "${1:-}" = "--archive-only" ] && exit 0

cat > "$OPTIONS" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key><string>app-store-connect</string>
    <key>destination</key><string>upload</string>
    <key>signingStyle</key><string>automatic</string>
</dict>
</plist>
PLIST

# shellcheck disable=SC2086
xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportOptionsPlist "$OPTIONS" \
    -exportPath build/export -allowProvisioningUpdates $AUTH
echo "Uploaded build $BUILD. It shows up in TestFlight after Apple has processed it (a few minutes)."
