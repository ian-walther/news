#!/usr/bin/env node
/**
 * Idempotently add the News MCP server to an Auth0 tenant that already
 * serves another MCP server (the Trilium one):
 *   1. the API (resource server) with the news.read permission, RBAC on,
 *      permissions in the access token, refresh tokens allowed;
 *   2. the tenant's Resource Parameter Compatibility Profile, so the OAuth
 *      `resource` parameter an MCP client sends selects this API. The tenant
 *      default audience is left alone: it stays the other server's API, and a
 *      client that sends neither `audience` nor `resource` gets a token this
 *      server rejects;
 *   3. optionally, grant news.read to one user by email (AUTH0_USER_EMAIL).
 *
 * Nothing else is touched: no connections, clients, grants, or default
 * audience. Connectors reuse the existing first-party application.
 *
 *   AUTH0_DOMAIN=tenant.us.auth0.com AUTH0_MGMT_TOKEN=... \
 *   [AUTH0_USER_EMAIL=you@example.com] [AUTH0_DRY_RUN=1] \
 *   node scripts/auth0-setup.mjs https://news-mcp.example.net/mcp
 */
import { setTimeout as sleep } from 'node:timers/promises';

const [, , audience] = process.argv;
const domain = process.env.AUTH0_DOMAIN;
const token = process.env.AUTH0_MGMT_TOKEN;
const dryRun = /^(1|true|yes)$/i.test(process.env.AUTH0_DRY_RUN ?? '');
if (!audience || !domain || !token) {
  console.error(
    'usage: AUTH0_DOMAIN=<tenant>.auth0.com AUTH0_MGMT_TOKEN=<token> node scripts/auth0-setup.mjs <audience-url>',
  );
  process.exit(2);
}

const api = async (method, path, body, attempt = 0) => {
  const res = await fetch(`https://${domain}/api/v2${path}`, {
    method,
    headers: { authorization: `Bearer ${token}`, 'content-type': 'application/json' },
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  const text = await res.text();
  if (res.status === 429 && attempt < 5) {
    // Free tenants have a small global Management API budget; back off and retry.
    const wait = 2000 * 2 ** attempt;
    console.log(`rate limited on ${method} ${path}; retrying in ${wait / 1000}s`);
    await sleep(wait);
    return api(method, path, body, attempt + 1);
  }
  if (!res.ok) throw new Error(`${method} ${path} → ${res.status}: ${text}`);
  return text ? JSON.parse(text) : undefined;
};

/** Reads always run; writes are skipped and reported under AUTH0_DRY_RUN. */
const write = async (description, method, path, body) => {
  if (dryRun) {
    console.log(`dry run, would ${description}`);
    return undefined;
  }
  return api(method, path, body);
};

const scopes = [{ value: 'news.read', description: 'Read extracted news articles' }];

// 1. API / resource server
const existing = (await api('GET', '/resource-servers?per_page=100')).find(
  (r) => r.identifier === audience,
);
const definition = {
  name: 'News MCP',
  scopes,
  signing_alg: 'RS256',
  token_lifetime: 3600,
  allow_offline_access: true,
  enforce_policies: true,
  token_dialect: 'access_token_authz',
  skip_consent_for_verifiable_first_party_clients: true,
};
if (existing) {
  await write(
    `update resource server ${audience}`,
    'PATCH',
    `/resource-servers/${existing.id}`,
    definition,
  );
} else {
  await write(`create resource server ${audience}`, 'POST', '/resource-servers', {
    identifier: audience,
    ...definition,
  });
}
console.log(`resource server ${existing ? 'present' : 'new'}: ${audience}`);

// 2. Tenant: let `resource` select the API; keep the default audience.
const fields = 'fields=default_audience,resource_parameter_profile';
const before = await api('GET', `/tenants/settings?${fields}`);
console.log(
  `tenant before: default_audience=${before.default_audience} resource_parameter_profile=${before.resource_parameter_profile ?? '(unset)'}`,
);
if (before.resource_parameter_profile !== 'compatibility') {
  await write('set resource_parameter_profile=compatibility', 'PATCH', '/tenants/settings', {
    resource_parameter_profile: 'compatibility',
  });
}
const after = await api('GET', `/tenants/settings?${fields}`);
console.log(
  `tenant after:  default_audience=${after.default_audience} resource_parameter_profile=${after.resource_parameter_profile ?? '(unset)'}`,
);
if (after.default_audience === audience) {
  console.log('warning: the tenant default audience is this API; other servers will be affected');
}

// 3. User permission
const email = process.env.AUTH0_USER_EMAIL;
if (email) {
  const users = await api('GET', '/users?per_page=50&fields=user_id,email');
  const user = users.find((u) => (u.email ?? '').toLowerCase() === email.toLowerCase());
  if (!user) {
    console.log(`user ${email} not found; nothing granted`);
  } else {
    await write(
      `grant news.read to ${email}`,
      'POST',
      `/users/${encodeURIComponent(user.user_id)}/permissions`,
      { permissions: [{ permission_name: 'news.read', resource_server_identifier: audience }] },
    );
    console.log(`news.read ${dryRun ? 'would be granted' : 'granted'} to ${email}`);
  }
}

console.log('\nServer configuration (.env.prod):');
console.log(`MCP_AUTH_MODE=oidc`);
console.log(`MCP_OIDC_ISSUER=https://${domain}/`);
console.log(`MCP_PUBLIC_URL=${audience}`);
