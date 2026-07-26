# Persistent Browser Desktop

## Purpose

Newspaper needs one durable, operator-visible browser session for extraction
that depends on paid-site authentication, persistent cookies, or browser state.
The browser must continue running when no remote desktop client is connected,
and a human must be able to attach to the same desktop and browser from macOS
for authentication, debugging, and maintenance.

This document specifies the host capability. The headed extraction worker and
its application integration are separate concerns that consume this capability
through Chrome DevTools Protocol (CDP).

## Required Invariants

- The production host owns the graphical session from boot.
- Remote desktop clients attach to the existing session; they do not create a
  separate desktop.
- Disconnecting the remote client does not log out the desktop, stop Chrome, or
  alter extraction state.
- Chrome runs headed, not in headless mode, on the persistent Xorg display.
- Chrome uses a dedicated durable profile that is not shared with isolated
  headless extraction.
- Chrome is supervised by systemd and automatically restarts after an
  unexpected exit.
- A host reboot recreates the desktop and Chrome automatically against the same
  durable profile.
- VNC is reachable only through the trusted LAN or its VPN.
- CDP is bound to loopback and is never exposed directly to the LAN.
- No browser or VNC credentials are committed to Git.

## Host And Session Ownership

The initial host is `news`, an Intel N150 machine running Ubuntu Server 24.04.

The host uses this graphical stack:

```text
system boot
  -> graphical.target
    -> LightDM
      -> automatic local login as news-browser
        -> Xorg display :0 using the dummy video driver
          -> XFCE desktop session
            -> newspaper-chrome.service
              -> headed Google Chrome

    -> newspaper-x11vnc.service
      -> shares the existing Xorg display :0
```

LightDM owns the local login and graphical-session lifecycle. XFCE provides a
small conventional desktop. The remote-access service only shares the display
that LightDM already created.

The dedicated `news-browser` account is a normal local user with a home
directory, a locked password, and no sudo access. LightDM may automatically log
it in locally. It is not intended for SSH login or general host administration.

`loginctl enable-linger` is not required because the LightDM login keeps the
user session and its systemd user manager alive. Linger should be introduced
only if a future service must run independently of the graphical login.

## Display

Xorg uses `xserver-xorg-video-dummy`; no monitor, HDMI dummy plug, or active
remote client is required.

The initial display contract is:

- Display: `:0`
- Resolution: `1920x1080`
- Color depth: 24 bits
- Fixed geometry across boots and remote connections

The dummy display is intentionally deterministic. Authenticated article
extraction does not require GPU acceleration. A hardware-backed display should
only replace it if a measured browser workload requires GPU support.

The Xorg configuration lives at:

```text
/etc/X11/xorg.conf.d/20-newspaper-dummy.conf
```

The LightDM seat configuration lives at:

```text
/etc/lightdm/lightdm.conf.d/50-newspaper-browser.conf
```

## Chrome

Google Chrome Stable runs as `news-browser` on `DISPLAY=:0`.

Durable state lives under:

```text
/home/news-browser/.config/newspaper-chrome
```

This is both the dedicated authentication profile and the non-default
`--user-data-dir` required for modern Chrome remote debugging. Site cookies,
local storage, browser preferences, and other reusable authenticated state stay
in this profile.

Chrome starts with these behavioral requirements:

- Force the X11 display path.
- Use the dedicated Newspaper profile.
- Listen for CDP on `127.0.0.1:9222`.
- Suppress first-run and default-browser prompts.
- Avoid desktop keyring prompts in the unattended session.
- Remain a normal visible headed browser.

Chrome is managed by a systemd user service:

```text
/home/news-browser/.config/systemd/user/newspaper-chrome.service
```

An XFCE autostart entry imports the live graphical-session environment into the
user systemd manager and starts the service. This keeps systemd responsible for
restart behavior without guessing at `DISPLAY`, `XAUTHORITY`,
`DBUS_SESSION_BUS_ADDRESS`, or `XDG_RUNTIME_DIR` before the desktop exists.

Chrome uses `Restart=always`. Closing Chrome manually therefore starts a fresh
browser process against the same profile. Stopping the service explicitly is
the maintenance mechanism when Chrome must remain down.

The desktop processes cannot survive a host reboot. Persistence across reboot
means that LightDM recreates the session automatically and Chrome reopens
against the same profile. Whether a publisher preserves its authenticated
session remains subject to that publisher's own cookie and session-expiration
policy.

## Remote Desktop

`x11vnc` shares Xorg display `:0`. It runs as a host system service after
LightDM and waits for the real X display before accepting clients.

Required behavior:

- Continue listening after a client disconnects.
- Allow a later client to attach to the same desktop.
- Permit only one shared desktop state, even if multiple clients attach.
- Require VNC authentication.
- Bind only to the host's trusted-LAN IPv4 address, initially
  `192.168.1.234:5900`.
- Do not listen on the host's public IPv6 address.

The service definition lives at:

```text
/etc/systemd/system/newspaper-x11vnc.service
```

The generated VNC password is stored only on the host:

```text
/etc/newspaper-browser/vnc-password
/etc/newspaper-browser/x11vnc.pass
```

The plaintext recovery copy is root-readable only. The x11vnc password file is
also restricted locally and is never committed to the repository.

The preferred macOS connection is:

```text
vnc://news.home:5900
```

The built-in Screen Sharing application is the first client to try. A dedicated
VNC viewer is an acceptable fallback if macOS and x11vnc negotiate poorly, but
changing clients must not change the server-side session model.

## Network Boundary

The browser desktop follows Newspaper's trusted-LAN security posture.

- Port `5900` is bound to `192.168.1.234`, not wildcard IPv4 or IPv6.
- VNC still requires a password even on the trusted LAN.
- Off-network access goes through the existing VPN.
- Port `9222` remains bound to `127.0.0.1`.
- The future headed worker must reach CDP through an explicit, narrowly scoped
  host/container bridge. It must not make CDP generally reachable from the LAN
  or unrelated containers.

CDP access is equivalent to control of the authenticated browser and must be
treated as a privileged local capability.

## Repository-Owned Configuration

The checked-in host configuration is the source of truth. A root-level helper
script should install packages, create the dedicated user and directories,
install the Xorg, LightDM, systemd, and XFCE autostart files, generate the VNC
secret when absent, enable services, and start the graphical stack.

The setup must be idempotent:

- Re-running it updates repository-owned configuration.
- Re-running it does not replace the Chrome profile.
- Re-running it does not rotate an existing VNC password unless explicitly
  requested.
- Re-running it does not create another browser user or desktop session.

A separate verification helper should report package, account, display,
desktop, service, listener, and CDP state without modifying the host.

## Operational Behavior

The normal boot state, without a connected VNC client, is:

- LightDM active.
- One `news-browser` graphical login on Xorg `:0`.
- XFCE active at `1920x1080`.
- `newspaper-chrome.service` active.
- A visible Google Chrome process using the Newspaper profile.
- CDP answering on `127.0.0.1:9222`.
- `newspaper-x11vnc.service` active on `192.168.1.234:5900`.

The expected maintenance actions are:

```text
restart Chrome:
  restart newspaper-chrome.service in the news-browser user manager

restart the desktop:
  restart lightdm.service

restart remote access:
  restart newspaper-x11vnc.service

retrieve the VNC password:
  read /etc/newspaper-browser/vnc-password as root
```

Restarting LightDM ends and recreates the desktop session. The durable Chrome
profile remains intact. VNC may briefly restart while the new X display becomes
available.

## Acceptance Contract

The host capability is ready for headed-worker development when all of the
following are true:

1. Booting `news` with no VNC client produces an active LightDM/Xorg/XFCE
   session and headed Chrome process.
2. Xorg reports `1920x1080` at 24-bit depth on display `:0`.
3. `http://127.0.0.1:9222/json/version` returns Chrome CDP metadata.
4. VNC listens on `192.168.1.234:5900` and does not listen on wildcard IPv4 or
   IPv6.
5. macOS can attach, interact with Chrome, disconnect, and later recover the
   same browser and desktop state.
6. Closing Chrome causes systemd to restart it against the same profile.
7. Restarting the VNC service does not restart Chrome or the desktop.
8. Restarting the host recreates the graphical session and Chrome while
   retaining the profile.
9. The VNC and Chrome-profile secrets are absent from Git.

The server-side checks can be automated immediately. The macOS attachment and
manual authenticated-site login remain operator acceptance checks.

## Non-Goals

- VNC does not provide a separate per-user or per-connection desktop.
- This setup does not expose Newspaper, VNC, or CDP publicly.
- This setup does not add application-level authentication.
- The persistent Chrome profile is not mounted into Docker.
- Isolated headless workers do not reuse authenticated cookies.
- The infrastructure setup does not implement the headed extraction worker,
  escalation behavior, or application UI.
