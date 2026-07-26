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

## Network And Access Boundary

The production deployment is intentionally internal-only. The trusted LAN is
the application's access-control boundary, and remote users must connect to
that LAN through a VPN before accessing Newspaper.

- Do not expose Newspaper through public DNS, public port forwarding, or a
  public reverse proxy.
- Application-level authentication and public-facing TLS termination are out
  of scope for this topology.
- Internal plain HTTP is acceptable.
- `http://news.home` through nginx is the normal operator entry point.
- Phoenix port `4000` may also remain reachable directly from the trusted LAN
  for operation and debugging.
- nginx provides stable internal naming and routing, not a security boundary.

Any future requirement for direct public access invalidates these assumptions
and requires a separate security design before deployment.

## Persistent Desktop Session

The host should run a persistent real desktop session. Remote access should view and control that existing session rather than creating a new session per connection.

- LightDM owns an automatic local login for the dedicated, non-sudo
  `news-browser` user.
- XFCE runs on Xorg display `:0`.
- The Xorg dummy display is fixed at `1920x1080` and 24-bit color.
- No physical display, HDMI dummy plug, or active VNC client is required.

The desktop session should exist because the host starts it, not because a human connected remotely.

See `planning/persistent-browser-desktop.md` for the complete host,
service-lifecycle, networking, credential, and acceptance contract.

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
LightDM starts Xorg :0 with the dummy display
LightDM starts XFCE as news-browser
XFCE imports the graphical environment into the news-browser systemd manager
systemd starts headed Chrome on DISPLAY=:0
x11vnc shares DISPLAY=:0 for human access
```

Chrome should use a dedicated persistent profile for this project.

Example command shape:

```bash
DISPLAY=:0 google-chrome \
  --user-data-dir=/home/news-browser/.config/newspaper-chrome \
  --remote-debugging-address=127.0.0.1 \
  --remote-debugging-port=9222
```

Chrome is a continuously running headed browser process attached to the
persistent Xorg session. Its systemd user service receives the real graphical
session environment through XFCE autostart and restarts Chrome after an
unexpected or manual browser exit.

## Chrome Security

Chrome remote debugging is privileged access to the logged-in browser profile.

Security requirements:

- Use a dedicated Linux user for the browser session.
- Use a dedicated Chrome profile for news extraction.
- Bind CDP narrowly, ideally to localhost.
- Expose CDP to containers only through an intentionally restricted path.
- Do not expose CDP broadly on the LAN.
- Restrict VNC to trusted LAN or VPN access.

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
