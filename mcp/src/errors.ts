/**
 * Error model. Tool handlers translate these into `isError` results with a
 * stable machine-readable `code` so agents can branch on them. Codes that
 * come from the News API are passed through in upper case.
 */
export type BridgeErrorCode =
  | 'NOT_FOUND'
  | 'INVALID_PARAMETER'
  | 'INVALID_CURSOR'
  | 'CURSOR_PARAMETER_MISMATCH'
  | 'BUDGET_TOO_SMALL'
  | 'PERMISSION'
  | 'UPSTREAM'
  | 'UPSTREAM_UNAVAILABLE'
  | 'INTERNAL';

const UPSTREAM_CODES: Record<string, BridgeErrorCode> = {
  not_found: 'NOT_FOUND',
  invalid_parameter: 'INVALID_PARAMETER',
  invalid_cursor: 'INVALID_CURSOR',
  cursor_parameter_mismatch: 'CURSOR_PARAMETER_MISMATCH',
  budget_too_small: 'BUDGET_TOO_SMALL',
};

export class BridgeError extends Error {
  override readonly name: string = 'BridgeError';
  readonly code: BridgeErrorCode;
  readonly details: Record<string, unknown>;

  constructor(
    code: BridgeErrorCode,
    message: string,
    details: Record<string, unknown> = {},
    cause?: unknown,
  ) {
    super(message, cause !== undefined ? { cause } : undefined);
    this.code = code;
    this.details = details;
  }

  /** An error body the News API returned: `{error: {code, message}}`. */
  static fromUpstream(status: number, code: string | undefined, message: string): BridgeError {
    const mapped = code !== undefined ? UPSTREAM_CODES[code] : undefined;
    if (mapped) return new BridgeError(mapped, message, { upstreamStatus: status });
    if (status >= 500) {
      return new BridgeError('UPSTREAM_UNAVAILABLE', `News API answered ${status}`, {
        upstreamStatus: status,
      });
    }
    return new BridgeError('UPSTREAM', `News API answered ${status}: ${message}`, {
      upstreamStatus: status,
    });
  }

  static from(err: unknown, context?: string): BridgeError {
    if (err instanceof BridgeError) return err;
    const message = err instanceof Error ? err.message : String(err);
    return new BridgeError('INTERNAL', context ? `${context}: ${message}` : message, {}, err);
  }
}
