# Trilium Newspaper Planning Snapshot

This directory is a lossless source snapshot of the complete TriliumNext hierarchy rooted at **Newspaper App** (`LwHoLq61L0cO`).

It is source material, not the active forward-looking implementation plan. Active plans belong under `planning/`. Do not reconcile, correct, or prune this snapshot in place.

## Canonical Artifacts

- `snapshot.json` is the canonical machine-readable export. Its `content` fields preserve the exact HTML strings returned by TriliumNext together with note metadata, hierarchy, attributes, branch IDs, blob IDs, and Trilium content hashes.
- `notes/` contains directly readable HTML mirrors.
- `markdown/` contains Markdown-compatible mirrors for convenient review by humans and agents. They intentionally retain the original HTML because CommonMark accepts HTML blocks and conversion to native Markdown could lose structure.
- `manifest.json` records the exported hierarchy and checksums for the readable mirrors.

The JSON snapshot is authoritative if a generated mirror differs in whitespace or rendering.

## Exported Hierarchy

- Newspaper App (`LwHoLq61L0cO`)
  - Why This Project Should Exist (`c68SCQez9Qvw`)
  - Research Lineage And Concept Map (`0fUOFajiCzMK`)
  - Product Definition and Editorial Model (`e1OCATQ08PQL`)
    - Product Experience and Edition Contract (`hgzrog60aqcK`)
    - Source Configuration, Admission, and Ranking (`PVGbgrVhZK68`)
    - Editorial Synthesis, Evidence, and Corrections (`jt3iDNAWwMg6`)
    - Story, Event, Timeline, and Section Model (`mtOY4pVdFeCk`)
    - Product Decision Ledger and Open Questions (`audSvnHkNhaN`)
    - Outlet and Upstream Processing Domain Model (`p2N40lHGIcNh`)

## Reconciliation Rule

Reconciliation happens only in the active planning documents. This immutable snapshot exists so Ian, Codex, Fable, and future reviewers can distinguish original product decisions from later interpretation.
