#!/bin/bash
# Выпуск новой версии на GitHub: из неё Tutun у всех получит обновление.
#   1) поднять номер в файле VERSION (например 2.1.0 → 2.2.0);
#   2) scripts/release.sh "Что нового — пара строк"
# Повторный запуск с тем же номером ничего не ломает: если релиз уже есть, скрипт останавливается.
set -euo pipefail
cd "$(dirname "$0")/.."
[ "${1:-}" = "--publish" ] || { echo "Publication requires --publish and a separate user instruction. Use scripts/prepare-release.sh for local preparation." >&2; exit 2; }
shift
REPO=r4babit/Tutun
V=$(tr -d '[:space:]' < VERSION)
NOTES=${1:?Использование: scripts/release.sh \"что нового\"}
[[ "$V" =~ ^[0-9]+(\.[0-9]+)*$ ]] || { echo "В VERSION не номер версии: $V"; exit 1; }
if gh release view "v$V" --repo "$REPO" >/dev/null 2>&1; then
  echo "Релиз v$V уже есть на GitHub. Поднимите номер в VERSION."; exit 1
fi
scripts/prepare-release.sh
gh release create "v$V" dist/Tutun.zip dist/Tutun.zip.sha256 dist/Tutun.zip.sig dist/Tutun-release.json dist/Tutun-release.json.sig --repo "$REPO" --title "Tutun $V" --notes "$NOTES"
echo "Готово: https://github.com/$REPO/releases/tag/v$V"
