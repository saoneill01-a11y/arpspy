#!/bin/sh
# Refreshes the manufacturer list (MAC prefix → company) from the IEEE.
set -e
cd "$(dirname "$0")/.."
# Download to a temporary file first: a dropped connection must not leave a half file over the good one.
TMP=$(mktemp)
trap 'rm -f "$TMP"' EXIT
curl -fL https://standards-oui.ieee.org/oui/oui.csv -o "$TMP"
head -1 "$TMP" | grep -q '^Registry,Assignment,' || { echo "Download doesn't look like the IEEE list; kept the old file." >&2; exit 1; }
mv "$TMP" ArpSpy/Resources/oui.csv
trap - EXIT
echo "Updated ArpSpy/Resources/oui.csv"
