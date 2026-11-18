#!/bin/bash
# Удаление службы Tutun: останавливает VPN, убирает службу и ядра. Настройки приложения не трогает.
set -uo pipefail
LABEL="local.tutun.daemon"
launchctl bootout "system/$LABEL" 2>/dev/null
for _ in $(seq 1 150); do
  launchctl print "system/$LABEL" >/dev/null 2>&1 || break
  sleep 0.2
done
if launchctl print "system/$LABEL" >/dev/null 2>&1; then
  echo "Служба ещё работает. Повторите удаление." >&2
  exit 1
fi
pkill -f "/Library/Application Support/Tutun/bin/" 2>/dev/null
# Правила блокировки трафика вне VPN убираем в любом случае: с ними без службы интернета не будет.
/sbin/pfctl -a com.apple/tutun -F rules || exit 1
PF_TOKEN_FILE="/Library/Application Support/Tutun/run/pf-token"
if [ -f "$PF_TOKEN_FILE" ]; then
  PF_TOKEN=$(cat "$PF_TOKEN_FILE")
  case "$PF_TOKEN" in ''|*[!0-9]*) echo "Некорректный reference PF" >&2; exit 1;; esac
  PF_BOOT_FILE="/Library/Application Support/Tutun/run/pf-boot"
  if [ -f "$PF_BOOT_FILE" ] && [ "$(cat "$PF_BOOT_FILE")" = "$(/usr/sbin/sysctl -n kern.boottime)" ]; then
    /sbin/pfctl -X "$PF_TOKEN" || exit 1
  fi
fi
# Служба при остановке сама возвращает DNS мака. Если не успела (снимок остался) — возвращаем здесь.
# Снимок system-dns.plist создаёт только служба 2.11+, которая понимает --restore-network.
if [ -f "/Library/Application Support/Tutun/run/system-dns.plist" ]; then
  "/Library/Application Support/Tutun/bin/tutund" --restore-network || exit 1
fi
rm -f "/Library/LaunchDaemons/$LABEL.plist" /var/run/tutun.sock
# Журнал службы: в нём названия серверов и время подключений.
rm -f /var/log/tutun.log /var/log/tutun.log.1 /var/log/tutun.stdout.log
group_marker="/Library/Application Support/Tutun/group.uuid"
if [ -s "$group_marker" ] && [ "$(cat "$group_marker")" = "$(dscl . -read /Groups/_tutun GeneratedUID 2>/dev/null | awk '{print $2}')" ]; then
  dscl . -delete /Groups/_tutun || exit 1
fi
rm -rf "/Library/Application Support/Tutun"
echo "ok"
