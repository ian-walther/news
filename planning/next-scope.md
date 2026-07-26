# Active Planning Focus

## Goal

Begin the Newspaper expansion by establishing the real-world source model and
shared upstream enrichment boundary without disrupting the dependable Reading
Feed.

## First Implementation Scope

Implement Phase 1 from
[`implementation-roadmap.md`](implementation-roadmap.md):

- migrate Intake Groups to required Outlets
- give every Input Feed one Outlet
- migrate Article Sources to Article Appearances
- migrate whole-group Output Feed memberships to Outlet memberships
- preserve all stable Article, Output Feed, generated feed item, and RSS GUID
  identities
- update operator vocabulary, routes, forms, associations, and tests

Design the migration against real current data before changing schemas. Ambiguous
multi-feed Outlet assignments should remain reviewable rather than being
guessed from a similar hostname alone.

## Immediately Following

Move extraction and app-owned Article classification upstream:

- configure demand at Outlet or Input Feed scope
- allow Newspaper-only feeds to enrich the shared corpus
- reuse one Article Extraction across all consumers
- preserve existing output-scoped attempt and artifact history
- add explicit backfill rather than silently reprocessing old Articles

## Required Planning Closure Before Later Phases

Before Claim and evidence tables land, finalize:

- minimal Claim types
- evidence relationship types
- source and interested-party roles
- independence and common-origin representation
- Citation source-location requirements

Before hosted Edition publication lands, finalize:

- stable archive route shape
- default timezone, cutoff, and delivery values
- deterministic post-publication correction workflow

These decisions do not block the Outlet migration or shared enrichment work.

## Non-Goals for the First Scope

- Do not create a second ingestion stack for the Newspaper.
- Do not require Newspaper sources to join an Output Feed.
- Do not deduplicate Articles across Outlets.
- Do not combine migration with Event clustering or synthesis.
- Do not silently recompute existing extraction or digest artifacts.
- Do not add a general workflow or prompt-management platform.
- Do not add Twitter, newsletter, automatic official-source, PDF, print, or
  public-access features.
