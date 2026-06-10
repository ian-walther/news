# Open Questions

## Product Center Of Gravity

- What does the first satisfying morning newspaper look like?
- Which intermediate features are required before the newspaper is worth building?
- Which future modes belong in this app versus a separate project?

## Intake And Output Feed Semantics

- How much source metadata should be visible in the generated feed body?
- When should explicit output-feed excludes be introduced?

## RSS Output Shape

- Are there source-specific metadata fields that should be preserved specially during raw capture?
- Should source attribution be added to generated feed bodies?
- What exact local hosted article URL shape should use the stable article identifier?
- Does hosted article routing need human-friendly URLs, or are GUID-only article URLs still sufficient?

## Retention

- How long should raw items, articles, and generated feed items be retained by default?
- Should retention be based on age, item count, output feed membership, or a mix?
- What should be protected from autopurge once extraction, summaries, or newspaper history exist?
- How long should verbose run/debug history be retained?

## Rebuild

- Should full rebuild be deferred as an admin-danger-zone action?
- If full rebuild is added later, should it operate by output feed, intake group, date range, item count, or a mix?

## Deduplication

- What URL parameters should always be stripped?
- When should title/date/source similarity override different URLs within an intake group?
- Should any dedupe happen across intake groups, or should that wait for semantic clustering?
- How should ambiguous dedupe matches be reviewed?
- What feed-provided ID patterns are reliable enough to use across feeds from the same publisher?

## Workflow

- Which pipeline attempt states are enough without overbuilding a workflow engine?
- What failure types need a first-class queue?
- What automatic retry/backoff behavior is needed after real usage?
- What failure lifecycle states are needed after real usage?
- When, if ever, does the job surface justify moving from supervised GenServers to Oban or another job system?

## Hosting

- What persistent volumes are needed outside Postgres?

## Production Architecture

- Which future services should run in Docker and which should stay on the host alongside the Chrome/desktop stack?
- Should workers run inside the main app container, as separate containers, or as host-level executables?
- How should deploy, backup, restore, logs, and upgrades work?
- What exact systemd unit structure should manage Xorg, the desktop session, Chrome, and x11vnc?
- What fixed virtual display resolution should the Xorg dummy display use?

## Extraction

- Which extraction implementation should be built first: simple HTTP, headless browser, or host Chrome?
- What config fields should `extraction.host_chrome` expose in the first UI?
- Should generated feeds include full extracted article text, summaries, excerpts, or a rendering pipeline setting beyond the initial extracted-body boolean?
- How should paid-site auth expiration be detected and surfaced?
- How should the Dockerized app reach host Chrome/CDP securely when CDP is bound narrowly?
- Is JSON over stdin/stdout the right worker contract, or should extraction use another boundary?
- What shared worker contract should extraction set for later classifier, summarizer, and PDF renderer workers?

## Pipeline Configuration

- Should pipeline step ordering support move up/down controls immediately?
- Should the initial implementation support only output-feed scoped steps, or also global defaults?
- How much implementation config should be editable as typed fields versus raw JSON?
- Should pipeline attempts be retained forever until retention policies exist?

## Home Assistant

- Which MQTT entities should exist first?
- Should HA controls be read live, snapshotted at run start, or both?
- Which status sensors are useful once the morning newspaper is underway?
