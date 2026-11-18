#!/bin/bash
# Установка службы Tutun. Запускается приложением с правами администратора.
# $1 — папка Resources из Tutun.app. Повторный запуск = обновление, настройки и подключение сохраняются.
set -euo pipefail
SRC="$1"
OWNER_UID="${2:?Не указан владелец установки}"
case "$OWNER_UID" in ''|*[!0-9]*) echo "Некорректный UID" >&2; exit 1;; esac
[ "$OWNER_UID" -gt 0 ] || { echo "Нельзя установить для root" >&2; exit 1; }
id "$OWNER_UID" >/dev/null 2>&1 || { echo "Пользователь не найден" >&2; exit 1; }
DST="/Library/Application Support/Tutun"
LABEL="local.tutun.daemon"
PLIST="/Library/LaunchDaemons/$LABEL.plist"

for f in tutund tutun-drop xray sing-box geoip.dat geosite.dat; do
  [ -f "$SRC/$f" ] || { echo "нет файла $SRC/$f" >&2; exit 1; }
done

# Группа для ядер (xray, sing-box): по ней блокировка трафика вне VPN отличает их соединения от остальных.
GROUP="_tutun"
install -d -o root -g wheel -m 755 "$DST"
# Служба 2.15 создавала пустую группу без файла UUID. Заимствованную
# группу не помечаем своей: при удалении приложения она останется в системе.
legacy_tutun_group() {
  local record label gid attr members groups users
  record=$(dscl -plist . -read "/Groups/$GROUP") || return 1
  label=$(plutil -extract 'dsAttrTypeStandard:RealName.0' raw -o - - <<<"$record") || return 1
  gid=$(plutil -extract 'dsAttrTypeStandard:PrimaryGroupID.0' raw -o - - <<<"$record") || return 1
  [[ "$label" == "Tutun VPN" && "$gid" =~ ^[0-9]{3}$ ]] || return 1
  (( 10#$gid >= 350 && 10#$gid <= 499 )) || return 1
  for attr in GroupMembership GroupMembers NestedGroups; do
    if plutil -extract "dsAttrTypeStandard:$attr.0" xml1 -o - - <<<"$record" >/dev/null 2>&1; then return 1; fi
  done
  groups=$(dscl /Search -list /Groups PrimaryGroupID) || return 1
  users=$(dscl /Search -list /Users PrimaryGroupID) || return 1
  [[ $(awk -v id="$gid" '$NF == id {print $1}' <<<"$groups") == "$GROUP" ]] || return 1
  [[ -z $(awk -v id="$gid" '$NF == id {print $1}' <<<"$users") ]]
}
if dscl . -read "/Groups/$GROUP" >/dev/null 2>&1; then
  group_uuid=$(dscl . -read "/Groups/$GROUP" GeneratedUID | awk '{print $2}')
  if [ ! -e "$DST/group.uuid" ] && legacy_tutun_group; then
    : # Совместимая группа от прежней установки.
  elif [ ! -s "$DST/group.uuid" ] || [ "$(cat "$DST/group.uuid")" != "$group_uuid" ]; then
    echo "Имя группы $GROUP уже занято. Служба не изменена." >&2
    exit 1
  fi
else
  USED_GIDS=$(dscl . -list /Groups PrimaryGroupID | awk '{print $2}')
  GROUP_ID=""
  for n in $(seq 350 499); do
    if ! printf '%s\n' "$USED_GIDS" | grep -qx "$n"; then GROUP_ID="$n"; break; fi
  done
  [ -n "$GROUP_ID" ] || { echo "Нет свободного номера для группы $GROUP" >&2; exit 1; }
  group_uuid=$(/usr/bin/uuidgen)
  dscl . -create "/Groups/$GROUP"
  dscl . -create "/Groups/$GROUP" GeneratedUID "$group_uuid"
  dscl . -create "/Groups/$GROUP" PrimaryGroupID "$GROUP_ID"
  dscl . -create "/Groups/$GROUP" RealName "Tutun VPN"
  dscl . -create "/Groups/$GROUP" Password "*"
  printf '%s\n' "$group_uuid" > "$DST/group.uuid"
  chmod 600 "$DST/group.uuid"
fi
dscl . -read "/Groups/$GROUP" PrimaryGroupID >/dev/null || { echo "Не создать группу $GROUP" >&2; exit 1; }

# Служба прошлой версии (Tunnel) — останавливаем и убираем.
if [ -f /Library/LaunchDaemons/local.tunnel.daemon.plist ]; then
  launchctl bootout system/local.tunnel.daemon 2>/dev/null || true
  rm -f /Library/LaunchDaemons/local.tunnel.daemon.plist /var/run/tunnel.sock
  rm -rf "/Library/Application Support/Tunnel"
fi

launchctl bootout "system/$LABEL" 2>/dev/null || true
# bootout только посылает службе сигнал и сразу возвращается. Пока старая служба останавливает ядра,
# новый bootstrap macOS отклоняет («37: Operation already in progress») — из-за этого первый ввод пароля
# раньше оставлял мак без службы (и с аварийной блокировкой). Ждём, пока служба действительно исчезнет (до 30 с).
for _ in $(seq 1 150); do
  launchctl print "system/$LABEL" >/dev/null 2>&1 || break
  sleep 0.2
done

mkdir -p "$DST/bin" "$DST/run"
for f in tutund tutun-drop xray sing-box; do install -m 755 -o root -g wheel "$SRC/$f" "$DST/bin/$f"; done
# Гео-базы: не затираем обновлённые службой, если они свежее.
for f in geoip.dat geosite.dat; do
  if [ ! -f "$DST/bin/$f" ] || [ "$SRC/$f" -nt "$DST/bin/$f" ]; then install -m 644 -o root -g wheel "$SRC/$f" "$DST/bin/$f"; fi
done
chown root:wheel "$DST" "$DST/run" "$DST/bin"; chmod 755 "$DST" "$DST/bin"; chmod 700 "$DST/run"
printf '%s\n' "$OWNER_UID" > "$DST/owner.uid"
chown root:wheel "$DST/owner.uid"; chmod 600 "$DST/owner.uid"
xattr -cr "$DST/bin" 2>/dev/null || true

cat > "$PLIST" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key><array><string>$DST/bin/tutund</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ProcessType</key><string>Interactive</string>
  <key>StandardOutPath</key><string>/var/log/tutun.stdout.log</string>
  <key>StandardErrorPath</key><string>/var/log/tutun.stdout.log</string>
</dict>
</plist>
PL
chown root:wheel "$PLIST"; chmod 644 "$PLIST"
# На случай, если launchd ещё не закончил уборку: несколько попыток, последняя — с текстом ошибки для приложения.
for _ in 1 2 3 4 5; do
  if launchctl bootstrap system "$PLIST" 2>/dev/null; then echo "ok"; exit 0; fi
  sleep 1
done
launchctl bootstrap system "$PLIST"
echo "ok"
