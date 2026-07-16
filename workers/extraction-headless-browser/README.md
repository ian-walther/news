# Headless Browser Extraction Worker

Renders one article in an isolated Chromium process and passes the resulting HTML through Newspaper's shared Readability and sanitization pipeline.

This worker is the middle extraction tier. It does not reuse cookies or authenticated browser state; those responsibilities belong to the future headed-browser worker.

It reads one JSON request from stdin and writes one JSON response to stdout. Human-readable diagnostics belong on stderr.
