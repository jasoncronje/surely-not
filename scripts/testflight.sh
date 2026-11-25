#!/usr/bin/env bash
# Builds Surely Not and uploads it to TestFlight.
#
# Needs: Xcode signed in to team 44BZWUR5K9, and the `asc` CLI signed in with an
# App Store Connect API key (`asc auth status`). Config/Local.xcconfig decides
# whether the build carries Wallet sync (FinanceKit).
#
# Each upload needs a higher build number than the last, so the build number is
# the current UTC time (YYYYMMDDHHMM). The version comes from project.yml.
set -euo pipefail

cd "$(dirname "$0")/.."
APP_ID=6839306865
TEAM=44BZWUR5K9
BUILD_NUMBER="${BUILD_NUMBER:-$(date -u +%Y%m%d%H%M)}"
OUT="build/testflight"

rm -rf "$OUT"
mkdir -p "$OUT"

xcodegen generate -q

cat > "$OUT/ExportOptions.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>method</key><string>app-store-connect</string>
<key>destination</key><string>export</string>
<key>teamID</key><string>$TEAM</string>
<key>signingStyle</key><string>automatic</string>
<key>manageAppVersionAndBuildNumber</key><false/>
</dict></plist>
PLIST

# Keep the machine responsive: archive with a few jobs only.
xcodebuild archive \
  -project SurelyNot.xcodeproj -scheme SurelyNot -configuration Release \
  -destination "generic/platform=iOS" -archivePath "$OUT/SurelyNot.xcarchive" \
  DEVELOPMENT_TEAM="$TEAM" CODE_SIGN_STYLE=Automatic \
  CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
  -allowProvisioningUpdates -jobs 3

xcodebuild -exportArchive \
  -archivePath "$OUT/SurelyNot.xcarchive" \
  -exportOptionsPlist "$OUT/ExportOptions.plist" \
  -exportPath "$OUT/export" -allowProvisioningUpdates

asc builds upload --app "$APP_ID" --ipa "$OUT/export/SurelyNot.ipa" --wait
echo "Uploaded build $BUILD_NUMBER. The Internal Testers group gets every build."
