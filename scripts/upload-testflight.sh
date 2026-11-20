#!/bin/bash
# Builds a release version of the app and uploads it to App Store Connect for TestFlight.
#
#   ./scripts/upload-testflight.sh
#
# Needs the App Store Connect API key on this Mac (never in the repo):
#   ~/.appstoreconnect/private_keys/AuthKey_<KEY ID>.p8
#   ~/.appstoreconnect/spoilnot.env   with ASC_KEY_ID, ASC_ISSUER_ID, ASC_KEY_PATH
# The build number is a timestamp, so every upload is higher than the last. After the upload,
# Apple processes the build for ~10-30 minutes before it shows up in TestFlight.
set -euo pipefail
cd "$(dirname "$0")/../ios"
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer

CONFIG="$HOME/.appstoreconnect/spoilnot.env"
[ -f "$CONFIG" ] || { echo "Missing $CONFIG (see the comment at the top of this script)."; exit 1; }
# shellcheck disable=SC1090
source "$CONFIG"
[ -f "$ASC_KEY_PATH" ] || { echo "Missing API key file $ASC_KEY_PATH"; exit 1; }
AUTH=(-allowProvisioningUpdates -authenticationKeyPath "$ASC_KEY_PATH"
      -authenticationKeyID "$ASC_KEY_ID" -authenticationKeyIssuerID "$ASC_ISSUER_ID")

BUILD=$(date -u +%Y%m%d%H%M)
ARCHIVE=build/release/SpoilNot.xcarchive
rm -rf build/release
mkdir -p build/release
cat > build/release/ExportOptions.plist <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>method</key><string>app-store-connect</string>
  <key>destination</key><string>upload</string>
  <key>teamID</key><string>V2KLBCFV26</string>
  <key>signingStyle</key><string>automatic</string>
  <key>manageAppVersionAndBuildNumber</key><false/>
  <key>uploadSymbols</key><true/>
</dict></plist>
PLIST

xcodegen --quiet
echo "Archiving build ${BUILD}…"
xcodebuild archive -project Fridge.xcodeproj -scheme Fridge -configuration Release \
  -destination "generic/platform=iOS" -archivePath "$ARCHIVE" \
  CURRENT_PROJECT_VERSION="$BUILD" "${AUTH[@]}" -quiet
echo "Uploading…"
xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportOptionsPlist build/release/ExportOptions.plist \
  -exportPath build/release/export "${AUTH[@]}" -quiet
echo "Uploaded build ${BUILD}. It appears in TestFlight once Apple has processed it (~10-30 min)."
