import { ExceptionFilter, Catch, ArgumentsHost, HttpException } from '@nestjs/common';

@Catch()
export class FailClosedFilter implements ExceptionFilter {
  catch(exception: any, host: ArgumentsHost) {
    const ctx = host.switchToHttp();
    const res = ctx.getResponse();
    const req = ctx.getRequest();

    if (exception instanceof HttpException) {
      const status = exception.getStatus();
      const body = exception.getResponse();
      return res.status(status).json({
        ...(typeof body === 'object' ? body : { error: String(body) }),
        path: req.url,
        timestamp: new Date().toISOString(),
      });
    }
    // Erreur inattendue → fail-closed générique, pas de leak
    console.error('Unhandled exception (fail-closed):', exception);
    return res.status(500).json({
      error: 'INTERNAL_FAIL_CLOSED',
      reason_code: 'UNEXPECTED_ERROR',
      details: 'Request rejected for safety (fail-closed).',
      timestamp: new Date().toISOString(),
    });
  }
}
