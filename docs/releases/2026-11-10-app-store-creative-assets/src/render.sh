#!/usr/bin/env bash
# Renders the App Store creative assets from the HTML sources at exact pixel sizes.
# Needs Playwright's chrome-headless-shell (any version) and the server's sharp module.
#   bash docs/releases/2026-11-10-app-store-creative-assets/src/render.sh [#debug]
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
out="$(dirname "$here")"
repo="$(cd "$here/../../../.." && pwd)"
hash="${1:-}"
chrome="${CHROME:-$(ls -d "$HOME"/Library/Caches/ms-playwright/chromium_headless_shell-*/chrome-*/chrome-headless-shell 2>/dev/null | tail -1)}"
sharp="${SHARP_MODULE_PATH:-$repo/server/node_modules/sharp}"
tmp="$(mktemp -d)"

shot() { # name css-width css-height final-width final-height
  # Fail on any page script error before taking the picture.
  errs="$("$chrome" --headless --enable-logging=stderr --v=0 --virtual-time-budget=3000 --dump-dom \
    "file://$here/$1.html" 2>&1 >/dev/null | grep -E 'CONSOLE.*(Error|Uncaught)' || true)"
  [ -z "$errs" ] || { echo "$1: $errs" >&2; exit 1; }
  "$chrome" --headless --hide-scrollbars --force-device-scale-factor=2 \
    --window-size="$2,$3" --virtual-time-budget=4000 --run-all-compositor-stages-before-draw \
    --screenshot="$tmp/$1.png" "file://$here/$1.html$hash" >/dev/null 2>&1
  # Apple rejects alpha channels: flatten onto the page background and drop alpha.
  node -e '
    const sharp = require(process.argv[1]);
    const [src, dst, w, h] = process.argv.slice(2);
    sharp(src).flatten({ background: "#120e1b" }).removeAlpha()
      .toColorspace("srgb").png({ compressionLevel: 9 }).toFile(dst)
      .then(i => { if (i.width != w || i.height != h || i.channels !== 3) { console.error("bad output", i); process.exit(1); }
                   console.log(dst.split("/").pop(), i.width + "x" + i.height, "channels=" + i.channels); });
  ' "$sharp" "$tmp/$1.png" "$out/$1${hash:+-debug}.png" "$4" "$5"
}

shot header 1920 823 3840 1646
[ -f "$here/search-results.html" ] && shot search-results 1920 1280 3840 2560
rm -rf "$tmp"
