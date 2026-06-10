# Open Questions

## Product Center Of Gravity

- What does the first satisfying morning newspaper look like?
- Which intermediate features are required before the newspaper is worth building?
- Which future modes belong in this app versus a separate project?

## Intake And Output Feed Semantics

- What are the first intake groups and which input feeds do they contain?
- Should V1 output feeds be category feeds, review feeds, source bundles, or a mix?
- What are the first 3 to 5 generated feeds FreshRSS should subscribe to?
- How much source metadata should be visible in the generated feed body?
- When should explicit output-feed excludes be introduced after V1?

## RSS Output Shape

- Are there source-specific metadata fields that should be preserved specially during raw capture?
- Should source attribution be added to generated feed bodies in V1?
- What exact local hosted article URL shape should use the stable article identifier?
- What exact generated feed URL shape should use the stable feed identifier?

## Retention

- How long should raw items, articles, and generated feed items be retained by default?
- Should retention be based on age, item count, output feed membership, or a mix?
- What should be protected from autopurge once extraction, summaries, or newspaper history exist?
- How long should verbose run/debug history be retained?

## Rebuild And Backfill

- What manual rebuild/backfill actions should exist in V1?
- Should backfill operate by output feed, intake group, date range, item count, or a mix?
- Should re-rendering and backfilling be separate actions?
- Should full rebuild be deferred as an admin-danger-zone action?

## Deduplication

- What URL parameters should always be stripped?
- When should title/date/source similarity override different URLs within an intake group?
- Should any V1 dedupe happen across intake groups, or should that wait for later semantic clustering?
- How should ambiguous dedupe matches be reviewed?
- What feed-provided ID patterns are reliable enough to use across feeds from the same publisher?

## Workflow

- Which state fields are enough for V1 without overbuilding a workflow engine?
- What failure types need a first-class queue in V1?
- What automatic retry/backoff behavior is needed after real usage?
- What failure lifecycle states are needed after real usage?
- When, if ever, does the job surface justify moving from supervised GenServers to Oban or another job system?

## Hosting

- What persistent volumes are needed outside Postgres?

## Production Architecture

- Which services run in Docker and which stay on the host beyond the already-decided host Chrome/desktop stack?
- Should workers run inside the main app container, as separate containers, or as host-level executables?
- How should deploy, backup, restore, logs, and upgrades work?
- What exact systemd unit structure should manage Xorg, the desktop session, Chrome, and x11vnc?
- What fixed virtual display resolution should the Xorg dummy display use?

## Extraction

- When extraction is added, should feed body replacement be global or configurable per generated feed?
- Should generated feeds include full extracted article text, summaries, excerpts, or a per-feed setting beyond the initial extracted-body boolean?
- How should paid-site auth expiration be detected and surfaced?
- How should the Dockerized app reach host Chrome/CDP securely when CDP is bound narrowly?
- Is JSON over stdin/stdout the right worker contract, or should extraction use another boundary?
- What precedent should extraction set for later classifier, summarizer, and PDF renderer workers?

## Home Assistant

- Which MQTT entities should exist first?
- Should HA controls be read live, snapshotted at run start, or both?
- Which status sensors are useful once the morning newspaper is underway?
