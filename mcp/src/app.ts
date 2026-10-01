/** Shared bootstrap: config → News API client → transport inputs. */
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';
import type { AppConfig } from './config.js';
import { loadConfig } from './config.js';
import { createAuditLog, createLogger, type AuditLog, type Logger } from './logging/logger.js';
import { NewsClient, type FetchLike } from './news/client.js';

export interface AppContext {
  config: AppConfig;
  logger: Logger;
  audit: AuditLog;
  client: NewsClient;
}

export function packageVersion(): string {
  try {
    const here = dirname(fileURLToPath(import.meta.url));
    for (const candidate of [
      join(here, '..', 'package.json'),
      join(here, '..', '..', 'package.json'),
    ]) {
      try {
        const pkg = JSON.parse(readFileSync(candidate, 'utf8')) as {
          name?: string;
          version?: string;
        };
        if (pkg.name === 'news-mcp' && pkg.version) return pkg.version;
      } catch {
        /* try next */
      }
    }
  } catch {
    /* ignore */
  }
  return '0.0.0';
}

export function createAppContext(
  options: { env?: NodeJS.ProcessEnv; fetch?: FetchLike; logger?: Logger; config?: AppConfig } = {},
): AppContext {
  const config =
    options.config ?? loadConfig(options.env ?? process.env, { version: packageVersion() });
  const logger =
    options.logger ?? createLogger({ level: config.logging.level, format: config.logging.format });
  const audit = createAuditLog({
    enabled: config.logging.auditEnabled,
    path: config.logging.auditPath,
    logger,
  });
  const client = new NewsClient({
    baseUrl: config.news.baseUrl,
    timeoutMs: config.news.timeoutMs,
    userAgent: `${config.serverName}/${config.serverVersion}`,
    ...(options.fetch ? { fetch: options.fetch } : {}),
  });
  return { config, logger, audit, client };
}
