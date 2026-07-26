# Authenticated Headed Browser Extractor

This worker attaches to Newspaper's persistent headed Chrome session over CDP,
opens one temporary page in the existing authenticated browser context, and
returns the shared extraction JSON contract on stdout.

Chrome remains host-owned. The worker closes its own page and disconnects from
CDP after each request without closing the persistent browser or operator-owned
pages.

The endpoint defaults to `http://127.0.0.1:9222` for native development. Set
`NEWSPAPER_HEADED_BROWSER_CDP_URL` when the app reaches Chrome through a
host/container bridge.
