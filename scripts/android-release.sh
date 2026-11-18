#!/bin/bash
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
for name in TUTUN_ANDROID_STORE_FILE TUTUN_ANDROID_STORE_PASSWORD TUTUN_ANDROID_KEY_ALIAS TUTUN_ANDROID_KEY_PASSWORD; do
  [ -n "${!name:-}" ] || { echo "Missing $name. Release signing requires a permanent private key; no debug key will be used." >&2; exit 2; }
done
exec "$ROOT/scripts/android.sh" assembleRelease bundleRelease
