#!/usr/bin/env bash
set -euo pipefail

HOST="${HOST:-news}"
BROWSER_USER="${BROWSER_USER:-news-browser}"

ssh "${HOST}" "sudo bash -s -- '${BROWSER_USER}'" <<'REMOTE'
set -euo pipefail

browser_user="$1"
browser_uid="$(id -u "${browser_user}")"
user_runtime="/run/user/${browser_uid}"
user_bus="unix:path=${user_runtime}/bus"

echo "== Packages =="
dpkg-query -W -f='${binary:Package} ${Version}\n' \
  lightdm \
  xfce4 \
  x11vnc \
  xserver-xorg-video-dummy \
  google-chrome-stable

echo
echo "== Account =="
getent passwd "${browser_user}"
passwd --status "${browser_user}"

echo
echo "== Sessions =="
loginctl list-sessions --no-legend
loginctl user-status "${browser_user}" --no-pager | sed -n '1,35p'

echo
echo "== System services =="
systemctl is-enabled lightdm.service newspaper-x11vnc.service
systemctl is-active lightdm.service newspaper-x11vnc.service

echo
echo "== Browser service =="
sudo -u "${browser_user}" \
  XDG_RUNTIME_DIR="${user_runtime}" \
  DBUS_SESSION_BUS_ADDRESS="${user_bus}" \
  systemctl --user is-active newspaper-chrome.service

echo
echo "== Display =="
session_pid="$(pgrep -u "${browser_user}" -f -n xfce4-session || true)"
xauthority=""

if [[ -n "${session_pid}" && -r "/proc/${session_pid}/environ" ]]; then
  xauthority="$(
    tr '\0' '\n' <"/proc/${session_pid}/environ" |
      sed -n 's/^XAUTHORITY=//p' |
      head -1
  )"
fi

if [[ -z "${xauthority}" ]]; then
  xauthority="/home/${browser_user}/.Xauthority"
fi

sudo -u "${browser_user}" \
  DISPLAY=:0 \
  XAUTHORITY="${xauthority}" \
  xdpyinfo | sed -n '/dimensions:/p;/depth of root window:/p'

echo
echo "== Chrome =="
pgrep -a -u "${browser_user}" -f 'chrome.*newspaper-chrome' | head -5
curl --fail --silent --show-error http://127.0.0.1:9222/json/version
echo

echo
echo "== Listeners =="
ss -lntp | awk 'NR == 1 || /:5900|:9222/'

echo
echo "== VNC credential =="
test -s /etc/newspaper-browser/vnc-password
test -s /etc/newspaper-browser/x11vnc.pass
stat -c '%a %U:%G %n' \
  /etc/newspaper-browser/vnc-password \
  /etc/newspaper-browser/x11vnc.pass
REMOTE
