#!/bin/bash
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
if [ -z "${JAVA_HOME:-}" ]; then
  for candidate in /opt/homebrew/opt/openjdk@21/libexec/openjdk.jdk/Contents/Home /usr/local/opt/openjdk@21/libexec/openjdk.jdk/Contents/Home; do
    if [ -x "$candidate/bin/java" ]; then export JAVA_HOME="$candidate"; break; fi
  done
  if [ -z "${JAVA_HOME:-}" ] && [ -x /usr/libexec/java_home ]; then export JAVA_HOME=$(/usr/libexec/java_home -v 21 2>/dev/null || true); fi
fi
[ -x "${JAVA_HOME:-}/bin/java" ] || { echo "Set JAVA_HOME to a JDK 21 installation" >&2; exit 2; }
export ANDROID_HOME="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-$HOME/Library/Android/sdk}}"
[ -d "$ANDROID_HOME/platforms/android-36" ] || { echo "Set ANDROID_HOME to an SDK containing android-36" >&2; exit 2; }
cd "$ROOT/platforms/android"
if [ "$#" -eq 0 ]; then set -- assembleDebug testDebugUnitTest lintDebug; fi
exec ./gradlew --no-daemon "$@"
