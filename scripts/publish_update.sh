#!/usr/bin/env bash
# Makes the update site for GitHub Pages from a new alpha archive: the feed Sparkle reads, the new archive,
# and deltas to it from the builds before, so an installed alpha downloads only what changed.
#
# The full archives already published are fetched back, since Sparkle makes deltas from them, and only what
# the feed names is kept, which leaves the latest three builds and their deltas.
#
# Usage: publish_update.sh <new archive> <site folder>, with the private EdDSA key in SPARKLE_PRIVATE_KEY.
set -euo pipefail
archive="$1"
site="$2"
base="https://maimai-l.github.io/spot-chat"
sparkle_version="2.10.1"

if [ -z "${SPARKLE_PRIVATE_KEY:-}" ]; then
  echo "No SPARKLE_PRIVATE_KEY: nothing is published"
  exit 1
fi
mkdir -p "$site"

# What is published now. The first run finds nothing, and publishes the new build alone.
if curl -fsSL "$base/appcast.xml" -o "$site/appcast.xml"; then
  python3 - "$site/appcast.xml" <<'PY' > "$site/.published"
import sys, xml.etree.ElementTree as ET
for enclosure in ET.parse(sys.argv[1]).getroot().iter("enclosure"):
    print(enclosure.get("url"))
PY
  while read -r url; do
    echo "Fetching $(basename "$url")"
    curl -fsSL "$url" -o "$site/$(basename "$url")" || echo "Couldn't fetch $url; no delta from it"
  done < "$site/.published"
  rm "$site/.published"
else
  echo "Nothing is published yet"
  rm -f "$site/appcast.xml"
fi
cp "$archive" "$site/"

tools="$(mktemp -d)"
curl -fsSL "https://github.com/sparkle-project/Sparkle/releases/download/$sparkle_version/Sparkle-$sparkle_version.tar.xz" \
  | tar -xJ -C "$tools"
# The key goes in on standard input, never into a file or the log.
printf '%s' "$SPARKLE_PRIVATE_KEY" | "$tools/bin/generate_appcast" --ed-key-file - \
  --channel alpha --maximum-versions 3 --maximum-deltas 3 \
  --download-url-prefix "$base/" "$site"

# Only what the feed names is served.
python3 - "$site" <<'PY'
import os, sys, xml.etree.ElementTree as ET
site = sys.argv[1]
named = {os.path.basename(e.get("url")) for e in ET.parse(os.path.join(site, "appcast.xml")).getroot().iter("enclosure")}
for name in os.listdir(site):
    path = os.path.join(site, name)
    if name != "appcast.xml" and name not in named and os.path.isfile(path):
        os.remove(path)
for name in sorted(os.listdir(site)):
    print(f"{os.path.getsize(os.path.join(site, name)) / 1e6:8.1f} MB  {name}")
PY
