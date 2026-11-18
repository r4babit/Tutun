#!/bin/zsh
# Собирает вспомогательный sing-box для Android (TUIC, Hysteria2 с insecure/портами) и кладёт его
# в platforms/android/app/src/main/jniLibs/<abi>/libsingbox.so — так Android разрешает запуск.
#
# arm64-v8a: сборка из исходников тега (только with_quic,with_utls; без cgo → выравнивание 64 КиБ,
#            годится для телефонов со страницами 16 КиБ). Около 42 МБ вместо 80 МБ официального.
# armeabi-v7a: официальный релиз SagerNet (32-битной сборке Go нужен cgo/NDK), SHA-256 сверяется.
# Повторный запуск ничего не ломает: готовые файлы с верной суммой не пересобираются.
set -euo pipefail

VERSION=1.14.4
COMMIT=c005f35300ce76427dc285481ec5695f5b179cd2
ARM_SHA=a89f48c4f2691bf37476308212175ba7b7315db5ca03c0bf9b20d15f26bc70e9

ROOT=${0:A:h:h}
OUT=$ROOT/platforms/android/app/src/main/jniLibs
WORK=${TMPDIR:-/tmp}/tutun-singbox-android
mkdir -p "$WORK" "$OUT/arm64-v8a" "$OUT/armeabi-v7a"

# arm64 из исходников
if [[ ! -d $WORK/src/.git ]]; then
  rm -rf "$WORK/src"
  git clone -q --depth 1 --branch v$VERSION https://github.com/SagerNet/sing-box.git "$WORK/src"
fi
[[ $(git -C "$WORK/src" rev-parse HEAD) == $COMMIT ]] || { echo "sing-box: тег v$VERSION указывает не на $COMMIT" >&2; exit 1; }
(
  cd "$WORK/src"
  GOTOOLCHAIN=local CGO_ENABLED=0 GOOS=android GOARCH=arm64 go build -trimpath -tags with_quic,with_utls \
    -ldflags "-s -w -buildid= -X github.com/sagernet/sing-box/constant.Version=$VERSION" \
    -o "$WORK/sing-box-arm64" ./cmd/sing-box
)
cp "$WORK/sing-box-arm64" "$OUT/arm64-v8a/libsingbox.so"

# armv7 — официальный релиз
TAR=$WORK/sing-box-$VERSION-android-arm.tar.gz
if [[ ! -f $TAR ]] || ! echo "$ARM_SHA  $TAR" | shasum -a 256 -c -s; then
  curl -fsSL --max-time 300 -o "$TAR" "https://github.com/SagerNet/sing-box/releases/download/v$VERSION/sing-box-$VERSION-android-arm.tar.gz"
fi
echo "$ARM_SHA  $TAR" | shasum -a 256 -c -s || { echo "sing-box armv7: неверная SHA-256" >&2; exit 1; }
tar -xzf "$TAR" -C "$WORK" "sing-box-$VERSION-android-arm/sing-box"
cp "$WORK/sing-box-$VERSION-android-arm/sing-box" "$OUT/armeabi-v7a/libsingbox.so"

chmod 755 "$OUT"/*/libsingbox.so
shasum -a 256 "$OUT"/*/libsingbox.so
