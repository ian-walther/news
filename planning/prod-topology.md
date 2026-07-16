# Production Topology

## Host

The initial production host should be the spare Intel N150 machine running Ubuntu Server.

The machine is primarily managed over SSH, but it should also run a persistent graphical desktop session for browser authentication, debugging, and occasional remote maintenance.

## High-Level Layout

```text
N150 Ubuntu Server
  host services
    SSH
    persistent Xorg desktop session
    headed Chrome with dedicated persistent profile
    x11vnc sharing the existing X display

  Docker Compose services
    Phoenix app image
      direct HTML worker
      isolated headless Chromium worker
    Postgres, initially
```

## Persistent Desktop Session

The host should run a persistent real desktop session. Remote access should view and control that existing session rather than creating a new session per connection.

Preferred direction:

- Xorg display, likely `:1`.
- Xorg dummy display configuration, not a physical dummy HDMI plug.
- Lightweight desktop environment, likely XFCE.
- Fixed virtual display resolution.
- A dedicated Linux user for the browser/desktop session, such as `news-browser`.

The desktop session should exist because the host starts it, not because a human connected remotely.

## Remote Desktop Access

Use low-level, native Linux remote access to the existing X session.

Preferred direction:

- `x11vnc` shares the persistent Xorg display.
- macOS connects with Screen Sharing, Finder `vnc://...`, or another VNC client.
- VNC access is for maintenance and debugging only.
- VNC should be reachable only on the trusted LAN or VPN.

Avoid remote access patterns that spawn a new desktop session per connection, because the browser automation needs the same persistent session that the human can inspect.

## Headed Chrome

Chrome should run as a normal headed browser inside the persistent Xorg desktop session.

Chrome should always be running and managed by systemd. It should not depend on an active VNC connection and should not run in headless mode for the main authenticated extraction path.

Expected shape:

```text
systemd starts Xorg :1 with dummy display
systemd starts XFCE or another lightweight session on DISPLAY=:1
systemd starts headed Chrome on DISPLAY=:1
x11vnc shares DISPLAY=:1 for human access
```

Chrome should use a dedicated persistent profile for this project.

Example command shape:

```bash
DISPLAY=:1 google-chrome \
  --user-data-dir=/home/news-browser/.config/chrome-news-profile \
  --remote-debugging-address=127.0.0.1 \
  --remote-debugging-port=9222
```

The exact systemd unit layout can be decided during implementation, but the invariant is that Chrome is a continuously running headed browser process attached to the persistent Xorg session.

## Chrome Security

Chrome remote debugging is privileged access to the logged-in browser profile.

Security requirements:

- Use a dedicated Linux user for the browser session.
- Use a dedicated Chrome profile for news extraction.
- Bind CDP narrowly, ideally to localhost.
- Expose CDP to containers only through an intentionally restricted path.
- Do not expose CDP broadly on the LAN.
- Restrict VNC to trusted LAN/VPN access.

## Application Stack

The Phoenix app and normal app services should run through Docker Compose in production.

Initial production should use a production Docker Compose file with the Phoenix app image and an app-specific Postgres service. Later production can point at a shared network Postgres instance by changing the database URL and operational configuration.

Local development should not require running the app in Docker. The local development Compose file should only spin up Postgres; the Phoenix app runs natively on the Mac against the configured database URL.

The app image should contain direct-HTML extraction and an isolated headless Chromium runtime. These workers are disposable and carry no durable browser state.

The host Chrome/desktop stack should live outside Docker. The app should treat that headed Chrome as an external host capability used only when extraction requires persistent authentication or operator-visible browser state.

## Design Implications

- Browser authentication can be refreshed through the remote desktop.
- Automation can connect to a real headed browser through CDP.
- Extraction should continue whether or not a human is connected.
- The production browser path should be designed early because content extraction is the first external capability that sets precedent for later workers.
