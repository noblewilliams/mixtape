#!/usr/bin/env bash
# App Store / TestFlight build: production API plus the public Google config.
# A bare `flutter build ipa` keeps the localhost API default, which main.dart
# refuses in release. Built with `shorebird release` so the binary carries the
# Shorebird engine: only such a release can take over-the-air patches
# (scripts/patch-ios.sh; decision 2026-11-20). Upload the .ipa with Transporter or
# `xcrun altool --upload-app`, or open the .xcarchive in Xcode's Organizer.
#
#   scripts/build-ios-release.sh            # build number from pubspec.yaml
#   scripts/build-ios-release.sh 42         # explicit build number
set -euo pipefail

cd "$(dirname "$0")/../client"
# Keep in step with pubspec.yaml's Flutter floor.
SHOREBIRD_FLUTTER_VERSION="${SHOREBIRD_FLUTTER_VERSION:-3.50.0}"
command -v shorebird >/dev/null || {
  echo "shorebird is not on PATH (~/.shorebird/bin)." >&2; exit 1; }
# Keep the release number in source control; advance +1 for each new upload.
package_version="$(awk '/^version:/ { print $2; exit }' pubspec.yaml)"
build_number="${1:-${package_version##*+}}"
if [[ ! "$build_number" =~ ^[1-9][0-9]*$ ]]; then
  echo "Build number must be a positive integer (1, 2, 3, ...)." >&2
  exit 1
fi

for file in config/production.json config/google-ios.json; do
  [[ -f "$file" ]] || { echo "missing client/$file" >&2; exit 1; }
done

# A previous build's .ipa would satisfy the check below even when this
# export fails, so start from an empty output folder.
rm -rf build/ios/ipa

# Shorebird builds with its own copy of this Flutter version, so the
# patch and the release it applies to always share an engine.
shorebird release ios \
  --flutter-version="$SHOREBIRD_FLUTTER_VERSION" \
  --export-options-plist=ios/ExportOptions.plist \
  -- \
  --build-number="$build_number" \
  --dart-define-from-file=config/production.json \
  --dart-define-from-file=config/google-ios.json

# flutter (and so shorebird) exits 0 when only the export step fails (signing, agreements), so
# check for the .ipa rather than trusting the status.
if ! ls build/ios/ipa/*.ipa >/dev/null 2>&1; then
  echo "Archive built but no .ipa was exported. Fix the signing errors above, or" >&2
  echo "distribute build/ios/archive/Runner.xcarchive from Xcode's Organizer." >&2
  exit 1
fi
echo "Built build $build_number: client/build/ios/ipa/"
