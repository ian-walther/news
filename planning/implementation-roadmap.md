# Implementation Roadmap

## Feed Product Closure

- Add the persistent headed browser implementation through host Chrome/CDP.
- Preserve the existing extraction worker contract and app-owned escalation
  chain.
- Surface unavailable Chrome sessions and expired authentication as visible,
  manually retryable outcomes.
- Exercise headless-to-headed escalation and learned site policy against a
  representative authenticated source.
- Limit further extraction and digestion tuning to concrete problems observed
  in normal reading.

## Expansion Boundary

Treat personalized newspaper generation, semantic filtering, cross-source
synthesis, delivery, and related integrations as a separate expansion. Before
implementing that work, reconcile its dedicated Trilium plans into
repo-local, AI-agnostic planning documents and replace this boundary with an
implementation-ready roadmap.
