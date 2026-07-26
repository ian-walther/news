#!/usr/bin/env bash
set -euo pipefail

if [[ "${EUID}" -ne 0 ]]; then
  echo "Run this installer as root" >&2
  exit 1
fi

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCE_DIR="${REPO_ROOT}/infrastructure/browser-desktop"
BROWSER_USER="${BROWSER_USER:-news-browser}"
BROWSER_HOME="/home/${BROWSER_USER}"
VNC_PASSWORD_FILE="/etc/newspaper-browser/vnc-password"
VNC_AUTH_FILE="/etc/newspaper-browser/x11vnc.pass"

required_files=(
  "20-newspaper-dummy.conf"
  "50-newspaper-browser.conf"
  "browser-desktop.env"
  "newspaper-chrome.service"
  "newspaper-chrome.desktop"
  "newspaper-x11vnc.service"
  "start-chrome-service"
  "wait-for-x"
)

for file in "${required_files[@]}"; do
  if [[ ! -f "${SOURCE_DIR}/${file}" ]]; then
    echo "Missing browser desktop source file: ${SOURCE_DIR}/${file}" >&2
    exit 1
  fi
done

export DEBIAN_FRONTEND=noninteractive
echo "lightdm shared/default-x-display-manager select lightdm" | debconf-set-selections

apt-get update
apt-get install -y --no-install-recommends \
  ca-certificates \
  curl \
  dbus-x11 \
  gnupg \
  lightdm \
  lightdm-gtk-greeter \
  openssl \
  xfce4 \
  xfce4-terminal \
  x11-utils \
  x11-xserver-utils \
  x11vnc \
  xserver-xorg-core \
  xserver-xorg-input-libinput \
  xserver-xorg-video-dummy

# A locked dedicated account cannot unlock an unattended desktop. Xorg also
# disables blanking and DPMS, so no graphical locker belongs in this session.
apt-get purge -y light-locker xfce4-screensaver || true

chrome_package="$(mktemp --suffix=.deb)"
trap 'rm -f "${chrome_package}"' EXIT
curl --fail --location --silent --show-error \
  https://dl.google.com/linux/direct/google-chrome-stable_current_amd64.deb \
  --output "${chrome_package}"
apt-get install -y "${chrome_package}"

if ! id "${BROWSER_USER}" >/dev/null 2>&1; then
  useradd --create-home --shell /bin/bash "${BROWSER_USER}"
fi

usermod --lock "${BROWSER_USER}"

supplementary_groups=()
for group in audio render video; do
  if getent group "${group}" >/dev/null; then
    supplementary_groups+=("${group}")
  fi
done

if ((${#supplementary_groups[@]} > 0)); then
  groups_csv="$(IFS=,; echo "${supplementary_groups[*]}")"
  usermod --append --groups "${groups_csv}" "${BROWSER_USER}"
fi

install -d -m 0755 /etc/X11/xorg.conf.d
install -d -m 0755 /etc/lightdm/lightdm.conf.d
install -d -m 0755 /usr/local/libexec/newspaper-browser
install -d -m 0700 /etc/newspaper-browser
install -d -m 0755 -o "${BROWSER_USER}" -g "${BROWSER_USER}" \
  "${BROWSER_HOME}/.config" \
  "${BROWSER_HOME}/.config/autostart" \
  "${BROWSER_HOME}/.config/newspaper-chrome" \
  "${BROWSER_HOME}/.config/systemd" \
  "${BROWSER_HOME}/.config/systemd/user" \
  "${BROWSER_HOME}/.config/xfce4" \
  "${BROWSER_HOME}/.config/xfce4/xfconf" \
  "${BROWSER_HOME}/.config/xfce4/xfconf/xfce-perchannel-xml"

install -m 0644 \
  "${SOURCE_DIR}/20-newspaper-dummy.conf" \
  /etc/X11/xorg.conf.d/20-newspaper-dummy.conf
install -m 0644 \
  "${SOURCE_DIR}/50-newspaper-browser.conf" \
  /etc/lightdm/lightdm.conf.d/50-newspaper-browser.conf
install -m 0600 \
  "${SOURCE_DIR}/browser-desktop.env" \
  /etc/newspaper-browser/browser-desktop.env
install -m 0755 \
  "${SOURCE_DIR}/start-chrome-service" \
  /usr/local/libexec/newspaper-browser/start-chrome-service
install -m 0755 \
  "${SOURCE_DIR}/wait-for-x" \
  /usr/local/libexec/newspaper-browser/wait-for-x
install -m 0644 \
  "${SOURCE_DIR}/newspaper-x11vnc.service" \
  /etc/systemd/system/newspaper-x11vnc.service
install -m 0644 -o "${BROWSER_USER}" -g "${BROWSER_USER}" \
  "${SOURCE_DIR}/newspaper-chrome.service" \
  "${BROWSER_HOME}/.config/systemd/user/newspaper-chrome.service"
install -m 0644 -o "${BROWSER_USER}" -g "${BROWSER_USER}" \
  "${SOURCE_DIR}/newspaper-chrome.desktop" \
  "${BROWSER_HOME}/.config/autostart/newspaper-chrome.desktop"

panel_config="/etc/xdg/xfce4/panel/default.xml"
user_panel_config="${BROWSER_HOME}/.config/xfce4/xfconf/xfce-perchannel-xml/xfce4-panel.xml"

if [[ -f "${panel_config}" && ! -f "${user_panel_config}" ]]; then
  install -m 0644 -o "${BROWSER_USER}" -g "${BROWSER_USER}" \
    "${panel_config}" \
    "${user_panel_config}"
fi

if [[ ! -s "${VNC_PASSWORD_FILE}" ]]; then
  openssl rand -base64 6 | tr '/+' 'AZ' >"${VNC_PASSWORD_FILE}"
  printf '\n' >>"${VNC_PASSWORD_FILE}"
fi

chmod 0600 "${VNC_PASSWORD_FILE}"
vnc_password="$(<"${VNC_PASSWORD_FILE}")"
x11vnc -storepasswd "${vnc_password}" "${VNC_AUTH_FILE}" >/dev/null
chmod 0600 "${VNC_AUTH_FILE}"

chown -R "${BROWSER_USER}:${BROWSER_USER}" "${BROWSER_HOME}/.config"

systemctl daemon-reload
systemctl set-default graphical.target
systemctl enable lightdm.service
systemctl enable newspaper-x11vnc.service
systemctl restart lightdm.service
systemctl restart newspaper-x11vnc.service

echo
echo "Persistent browser desktop configuration installed."
echo "VNC endpoint: vnc://news.home:5900"
echo "VNC password: ${vnc_password}"
