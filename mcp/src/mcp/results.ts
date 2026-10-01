/**
 * Tool result helpers. The text block is what the model reads: the Markdown
 * the News application produced, unchanged. Structured content carries only
 * the small continuation facts (cursor, counts), never a second copy of the
 * article text, and can be switched off with MCP_RESULT_STRUCTURED=false for
 * clients that mishandle it. The cursor is always present in the text too.
 */
import type { CallToolResult } from '@modelcontextprotocol/server';
import { BridgeError } from '../errors.js';

export interface ToolErrorPayload {
  error: { code: string; message: string };
}

export function textResult(
  text: string,
  structured: Record<string, unknown>,
  includeStructured: boolean,
): CallToolResult {
  return {
    content: [{ type: 'text', text }],
    ...(includeStructured ? { structuredContent: structured } : {}),
  };
}

export function fail(err: unknown, context?: string): CallToolResult {
  const bridge = BridgeError.from(err, context);
  const payload: ToolErrorPayload = { error: { code: bridge.code, message: bridge.message } };
  return {
    content: [{ type: 'text', text: JSON.stringify(payload) }],
    structuredContent: payload,
    isError: true,
  };
}
