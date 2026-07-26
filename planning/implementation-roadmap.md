# Implementation Roadmap

## Feed Product Validation

- Add authenticated sources through the existing intake and site-policy UI and
  validate them through normal FreshRSS and Reeder use.
- Treat publisher login expiration as an operator maintenance event: refresh
  the persistent Chrome profile over VNC, then retry the visible failure.
- Limit further feed, extraction, and digestion changes to concrete problems
  observed in normal reading.
- Keep operational browser documentation beside the checked-in host
  infrastructure.

## Expansion Boundary

Treat personalized newspaper generation, semantic filtering, cross-source
synthesis, delivery, and related integrations as a separate expansion. Before
implementing that work, reconcile its dedicated Trilium plans into
repo-local, AI-agnostic planning documents and replace this boundary with an
implementation-ready roadmap.
