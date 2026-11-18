#!/bin/bash
# Локальная сборка выпуска: dist/Tutun.zip + dist/Tutun.zip.sha256. Ничего не публикует.
# Без TUTUN_MAC_SIGN_IDENTITY — обычная локальная (ad-hoc) подпись: сертификата нет, решение пользователя 08.11.2026.
#   Обновления у пользователей проверяют SHA-256 и целостность подписи; от взлома аккаунта GitHub это не защищает.
# С TUTUN_MAC_SIGN_IDENTITY (Developer ID) и TUTUN_MAC_NOTARY_PROFILE — подпись, нотаризация и проверка Gatekeeper.
set -euo pipefail
cd "$(dirname "$0")/.."
IDENTITY="${TUTUN_MAC_SIGN_IDENTITY:--}"
scripts/build.sh
codesign --verify --deep --strict build/Tutun.app
mkdir -p dist
if [ "$IDENTITY" != "-" ]; then
  : "${TUTUN_MAC_NOTARY_PROFILE:?Set the local notarytool keychain profile}"
  codesign -d -r- build/Tutun.app 2>&1 | /usr/bin/grep -q 'anchor apple generic'
  /usr/bin/ditto -c -k --keepParent build/Tutun.app dist/Tutun-notary.zip
  xcrun notarytool submit dist/Tutun-notary.zip --keychain-profile "$TUTUN_MAC_NOTARY_PROFILE" --wait
  xcrun stapler staple build/Tutun.app
  xcrun stapler validate build/Tutun.app
  /usr/sbin/spctl --assess --type execute build/Tutun.app
else
  echo "Подпись локальная (ad-hoc), без нотаризации."
fi
rm -f dist/Tutun.zip dist/Tutun.zip.sha256
/usr/bin/ditto -c -k --keepParent build/Tutun.app dist/Tutun.zip
(cd dist && shasum -a 256 Tutun.zip | cut -d' ' -f1 > Tutun.zip.sha256)
# Подпись ключом автора из «Связки ключей» (scripts/sign-release.swift) и манифест отзыва версий.
#   TUTUN_MIN_VERSION=1.0.2  — всё старше считается отозванным;  TUTUN_BLOCKED=1.0.3,1.0.4 — отдельные версии.
V=$(tr -d '[:space:]' < VERSION)
rm -f dist/Tutun.zip.sig dist/Tutun-release.json dist/Tutun-release.json.sig
swift scripts/sign-release.swift sign dist/Tutun.zip
swift scripts/sign-release.swift manifest "$V" "${TUTUN_MIN_VERSION:--}" "${TUTUN_BLOCKED:--}" dist/Tutun-release.json
swift scripts/sign-release.swift sign dist/Tutun-release.json
echo "Готово: dist/Tutun.zip"
