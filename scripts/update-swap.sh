#!/bin/bash
# Замена Tutun.app после выхода приложения. Запускает Updater от имени пользователя.
# Аргументы: PID приложения, путь установленного .app, путь нового .app, рабочая папка, метка.
# Что бы ни случилось, в конце открывается то, что лежит по пути установленного приложения:
# новая версия при успехе, прежняя — при любой ошибке (раньше при ошибке Tutun оставался закрытым).
# Резервная копия удаляется, только если новая версия встала на место.
set -u
PID=$1
DEST=$2
NEW=$3
WORK=$4
TOKEN=$5
OPEN="${TUTUN_UPDATE_OPEN:-/usr/bin/open}"   # подмена только для тестов скрипта
STAGED="$DEST.update.$TOKEN"
BACKUP="$DEST.backup.$TOKEN"

# Ждём выхода Tutun не дольше минуты.
for _ in {1..300}; do /bin/kill -0 "$PID" 2>/dev/null || break; sleep 0.2; done
trap '"$OPEN" "$DEST"; /bin/rm -rf "$WORK"' EXIT
# Приложение так и не закрылось — ничего не меняем.
if /bin/kill -0 "$PID" 2>/dev/null; then exit 1; fi

[ ! -e "$STAGED" ] && [ ! -e "$BACKUP" ] || exit 1
/usr/bin/ditto "$NEW" "$STAGED" || { /bin/rm -rf "$STAGED"; exit 1; }
/usr/bin/codesign --verify --deep --strict "$STAGED" 2>/dev/null || { /bin/rm -rf "$STAGED"; exit 1; }
/bin/mv "$DEST" "$BACKUP" || { /bin/rm -rf "$STAGED"; exit 1; }
if /bin/mv "$STAGED" "$DEST"; then
  /bin/rm -rf "$BACKUP"
else
  /bin/mv "$BACKUP" "$DEST" || exit 1
  exit 1
fi
