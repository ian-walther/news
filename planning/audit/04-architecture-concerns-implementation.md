# Architecture Concerns Implementation Notes

This is a temporary implementation receipt for the next audit reconciliation.
The reconciled audit remains the source of the finding; durable product
decisions belong in the main planning documents.

## A-8 — Closed By Product Boundary

The authentication and direct-port concerns are closed by an explicit
deployment boundary:

- Newspaper is a trusted-LAN application.
- Network reachability is the authorization boundary.
- Remote access must enter the private network through a VPN.
- The intended deployment does not require application authentication or
  public-facing TLS.
- Phoenix port `4000` may remain reachable on the trusted LAN.
- nginx supplies a stable internal hostname and reverse-proxy entry point; it
  is not an authentication or security boundary.
- Direct public Internet exposure is unsupported.

This is not a claim that the current application is secure for public hosting.
It is a statement that public hosting is outside the product and deployment
model. If that boundary changes, authentication, authorization, TLS, proxy
trust, session security, rate limiting, and administrative-surface exposure
must be designed together before deployment.

The durable decision is recorded in `README.md`,
`planning/architecture.md`, and `planning/prod-topology.md`. The resolved
questions were removed from `planning/open-questions.md`.
