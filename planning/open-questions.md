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

## Retention

- How long should raw items, articles, and generated feed items be retained by default?
- Should retention be based on age, item count, output feed membership, or a mix?
- What should be protected from autopurge once extraction, digests, or newspaper history exist?
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

- What failure types need a first-class queue?
- What failure lifecycle states are needed after real usage?
- When, if ever, does the job surface justify moving from supervised GenServers to Oban or another job system?

## Hosting

- What persistent volumes are needed outside Postgres?

## Production Architecture

- Which future services should run in Docker and which should stay on the host alongside the Chrome/desktop stack?
- How should deploy, backup, restore, logs, and upgrades work?
- What exact systemd unit structure should manage Xorg, the desktop session, Chrome, and x11vnc?
- What fixed virtual display resolution should the Xorg dummy display use?

## Extraction

- What config fields should `extraction.headed_browser` expose in the first UI?
- How should paid-site auth expiration be detected and surfaced?
- How should the Dockerized app reach host Chrome/CDP securely when CDP is bound narrowly?
- What failure kinds and thresholds should teach a site-level minimum extractor?

## Pipeline Configuration

- When is there enough real demand to add global, intake-group, or input-feed pipeline scope?
- How much implementation config should be editable as typed fields versus raw JSON?
- Should pipeline attempts be retained forever until retention policies exist?

## Article Digestion

- What summary length and paragraph shape work best in Reeder?
- What prompt and validation bounds reliably produce a factual one-sentence title without clickbait framing?
- Which connection, model, and structured-output failures should retry automatically?

## Home Assistant

- Which MQTT entities should exist first?
- Should HA controls be read live, snapshotted at run start, or both?
- Which status sensors are useful once the morning newspaper is underway?
