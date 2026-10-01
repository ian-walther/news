# Upstream source

The token verifier, HTTP transport, rate limiter, scope policy, audited schema
wrapper, configuration loader, and logger in `src/` were copied from
`triliumnext-mcp` at revision `0368d1b` and trimmed to what this server needs.

| File here                    | Upstream file                | Changes                                             |
| ---------------------------- | ---------------------------- | --------------------------------------------------- |
| `src/auth/verifier.ts`       | `src/auth/verifier.ts`       | none                                                |
| `src/transport/rateLimit.ts` | `src/transport/rateLimit.ts` | none                                                |
| `src/mcp/auditedSchema.ts`   | `src/mcp/auditedSchema.ts`   | comment only                                        |
| `src/mcp/policy.ts`          | `src/mcp/policy.ts`          | HTTP transport only                                 |
| `src/logging/logger.ts`      | `src/logging/logger.ts`      | audit event names targets, not note ids             |
| `src/transport/http.ts`      | `src/transport/http.ts`      | health probe and server wiring target the News API  |
| `src/config.ts`              | `src/config.ts`              | Trilium, stdio, and write limits removed; one scope |

Security fixes to those upstream files are not picked up automatically. When
one lands upstream, apply it here by hand and update the revision above.
