#!/usr/bin/env bash
# App Store / TestFlight build: production API plus the public Google config.
# A bare `flutter build ipa` keeps the localhost API default, which main.dart
# refuses in release. Upload the .ipa with Transporter or
# `xcrun altool --upload-app`, or open the .xcarchive in Xcode's Organizer.
#
#   scripts/build-ios-release.sh            # build number = UTC timestamp
#   scripts/build-ios-release.sh 42         # explicit build number
set -euo pipefail

cd "$(dirname "$0")/../client"
build_number="${1:-$(date -u +%Y%m%d%H%M)}"

for file in config/production.json config/google-ios.json; do
  [[ -f "$file" ]] || { echo "missing client/$file" >&2; exit 1; }
done

flutter build ipa --release \
  --build-number="$build_number" \
  --dart-define-from-file=config/production.json \
  --dart-define-from-file=config/google-ios.json

# flutter exits 0 when only the export step fails (signing, agreements), so
# check for the .ipa rather than trusting the status.
if ! ls build/ios/ipa/*.ipa >/dev/null 2>&1; then
  echo "Archive built but no .ipa was exported. Fix the signing errors above, or" >&2
  echo "distribute build/ios/archive/Runner.xcarchive from Xcode's Organizer." >&2
  exit 1
fi
echo "Built build $build_number: client/build/ios/ipa/"
