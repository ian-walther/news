import { describe, expect, it } from 'vitest';
import {
  ConfigError,
  loadConfig,
  normalizeNewsUrl,
  parseScopes,
  parseStaticTokens,
} from '../../src/config.js';

describe('loadConfig', () => {
  it('applies defaults', () => {
    const cfg = loadConfig({}, { version: '9.9.9' });
    expect(cfg.news.baseUrl).toBe('http://localhost:4000');
    expect(cfg.http.host).toBe('127.0.0.1');
    expect(cfg.http.port).toBe(3940);
    expect(cfg.auth.mode).toBe('none');
    expect(cfg.auth.anonymousScopes).toEqual(['news.read']);
    expect(cfg.results.structured).toBe(true);
    expect(cfg.serverName).toBe('news-mcp');
    expect(cfg.serverVersion).toBe('9.9.9');
  });
  it('knows exactly one scope', () => {
    expect(parseScopes('news.read', 'X')).toEqual(['news.read']);
    expect(() => parseScopes('trilium.read', 'X')).toThrow(/unknown scope/);
    expect(() => parseScopes('READ', 'X')).toThrow(/unknown scope/);
  });
  it('parses the response mode and the structured-result switch', () => {
    expect(loadConfig({}).http.responseMode).toBe('auto');
    expect(loadConfig({ MCP_HTTP_RESPONSE_MODE: 'json' }).http.responseMode).toBe('json');
    expect(() => loadConfig({ MCP_HTTP_RESPONSE_MODE: 'xml' })).toThrow(/MCP_HTTP_RESPONSE_MODE/);
    expect(loadConfig({ MCP_RESULT_STRUCTURED: 'false' }).results.structured).toBe(false);
  });
  it('refuses unauthenticated non-loopback binds', () => {
    expect(() => loadConfig({ MCP_HTTP_HOST: '0.0.0.0', MCP_AUTH_MODE: 'none' })).toThrow(
      /loopback/,
    );
    // Off loopback the default is oidc, which then demands its settings.
    expect(() => loadConfig({ MCP_HTTP_HOST: '0.0.0.0', MCP_ALLOWED_HOSTS: 'x.example' })).toThrow(
      /MCP_OIDC_ISSUER/,
    );
  });
  it('derives the host allow-list', () => {
    expect(loadConfig({}).http.allowedHosts).toEqual(
      expect.arrayContaining(['127.0.0.1', 'localhost', '::1']),
    );
    expect(() =>
      loadConfig({
        MCP_HTTP_HOST: '0.0.0.0',
        MCP_AUTH_MODE: 'static',
        MCP_STATIC_TOKENS: 'x@0123456789abcdef:news.read',
      }),
    ).toThrow(/MCP_ALLOWED_HOSTS/);
    const cfg = loadConfig({
      MCP_HTTP_HOST: '0.0.0.0',
      MCP_AUTH_MODE: 'static',
      MCP_STATIC_TOKENS: 'x@0123456789abcdef:news.read',
      MCP_PUBLIC_URL: 'https://news-mcp.example.net/mcp',
      MCP_ALLOWED_HOSTS: 'news-mcp.home',
    });
    expect(cfg.http.allowedHosts).toEqual(
      expect.arrayContaining(['news-mcp.home', 'news-mcp.example.net', '127.0.0.1']),
    );
  });
  it('validates oidc settings', () => {
    expect(() => loadConfig({ MCP_AUTH_MODE: 'oidc' })).toThrow(/MCP_OIDC_ISSUER/);
    const cfg = loadConfig({
      MCP_AUTH_MODE: 'oidc',
      MCP_OIDC_ISSUER: 'https://t.auth0.com/',
      MCP_PUBLIC_URL: 'https://news-mcp.example.net/mcp',
    });
    expect(cfg.auth.oidc?.audience).toBe('https://news-mcp.example.net/mcp');
    expect(cfg.auth.oidc?.scopeClaims).toEqual(['scope', 'scp']);
  });
  it('parses static tokens', () => {
    expect(() => loadConfig({ MCP_AUTH_MODE: 'static' })).toThrow(/MCP_STATIC_TOKENS/);
    expect(parseStaticTokens('dev@0123456789abcdef:news.read')).toEqual([
      { token: '0123456789abcdef', clientId: 'dev', scopes: ['news.read'] },
    ]);
    expect(() => parseStaticTokens('short:news.read')).toThrow(/16 characters/);
  });
  it('normalizes the News API url', () => {
    expect(normalizeNewsUrl('http://app:4000/')).toBe('http://app:4000');
    expect(() => normalizeNewsUrl('ftp://x')).toThrow(ConfigError);
    expect(() => normalizeNewsUrl('nope')).toThrow(ConfigError);
  });
});
