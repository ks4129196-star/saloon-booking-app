import type { ErrorRequestHandler, RequestHandler } from 'express';
import { ZodError } from 'zod';

/**
 * An error whose message is safe to show to the user. Anything else that
 * reaches the error handler becomes a generic 500.
 */
export class ApiError extends Error {
  constructor(
    readonly status: number,
    message: string,
    readonly code?: string,
  ) {
    super(message);
  }
}

export const badRequest = (message: string) => new ApiError(400, message, 'bad_request');
export const unauthorized = (message = 'Please sign in again.') =>
  new ApiError(401, message, 'unauthorized');
export const forbidden = (message = 'You do not have permission to do this.') =>
  new ApiError(403, message, 'forbidden');
export const notFound = (message = 'Not found.') => new ApiError(404, message, 'not_found');
export const conflict = (message: string) => new ApiError(409, message, 'conflict');

export const notFoundHandler: RequestHandler = (_req, _res, next) => {
  next(notFound('This endpoint does not exist.'));
};

export const errorHandler: ErrorRequestHandler = (error, _req, res, _next) => {
  if (error instanceof ApiError) {
    res.status(error.status).json({ error: error.message, code: error.code });
    return;
  }
  if (error instanceof ZodError) {
    const first = error.issues[0];
    const field = first?.path.join('.');
    res.status(400).json({
      error: first ? `${field ? `${field}: ` : ''}${first.message}` : 'Invalid request.',
      code: 'validation_error',
    });
    return;
  }
  if (error?.type === 'entity.parse.failed') {
    res.status(400).json({ error: 'Request body must be valid JSON.', code: 'bad_request' });
    return;
  }
  console.error(error);
  res.status(500).json({ error: 'Something went wrong. Please try again.', code: 'internal' });
};
