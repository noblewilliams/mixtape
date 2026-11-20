#!/usr/bin/env bash
# Over-the-air patch for an iOS release built by scripts/build-ios-release.sh
# (decision 2026-11-20). Ships Dart changes only: anything native (Info.plist,
# entitlements, pods, Swift, assets the native side reads, a new plugin) needs
# a TestFlight/App Store release instead; `shorebird patch` warns when it sees
# native changes, and that warning means stop.
#
# Run from a clean worktree of committed HEAD, like a Worker deploy.
#
#   scripts/patch-ios.sh                 # patch the newest release
#   scripts/patch-ios.sh 1.1.0+14        # patch a specific release
#   STAGING=1 scripts/patch-ios.sh       # staging track: test with `shorebird preview`
set -euo pipefail

cd "$(dirname "$0")/../client"
release_version="${1:-latest}"
command -v shorebird >/dev/null || {
  echo "shorebird is not on PATH (~/.shorebird/bin)." >&2; exit 1; }

for file in config/production.json config/google-ios.json; do
  [[ -f "$file" ]] || { echo "missing client/$file" >&2; exit 1; }
done

if [[ -n "$(git status --porcelain)" ]]; then
  echo "Uncommitted changes: patch from a clean worktree of committed HEAD." >&2
  exit 1
fi

track_args=()
[[ -n "${STAGING:-}" ]] && track_args=(--track=staging)

# The defines must match the release's: they are compiled into the Dart
# snapshot the patch replaces.
shorebird patch ios \
  --release-version="$release_version" \
  ${track_args[@]+"${track_args[@]}"} \
  -- \
  --dart-define-from-file=config/production.json \
  --dart-define-from-file=config/google-ios.json
