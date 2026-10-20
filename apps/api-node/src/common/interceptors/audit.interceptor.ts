import { Injectable, NestInterceptor, ExecutionContext, CallHandler } from '@nestjs/common';
import { Observable, tap } from 'rxjs';

/**
 * Audit logs: user_id, provider, model_version, as_of, décisions + reason_codes.
 * Ici: log structuré JSON → en prod → Postgres audit_logs.
 */
@Injectable()
export class AuditInterceptor implements NestInterceptor {
  intercept(context: ExecutionContext, next: CallHandler): Observable<any> {
    const req = context.switchToHttp().getRequest();
    const start = Date.now();
    const audit = {
      user_id: req.user?.sub || req.user?.id || 'anon',
      action: `${req.method} ${req.route?.path || req.url}`,
      provider: req.body?.provider || req.query?.provider,
      ip: req.ip,
      trace_id: req.headers['x-request-id'] || `trace_${Date.now()}`,
    };
    return next.handle().pipe(
      tap({
        next: (data) => {
          const duration = Date.now() - start;
          console.log(JSON.stringify({
            level: 'audit',
            ...audit,
            status: 'success',
            duration_ms: duration,
            model_version: data?.model_version,
            as_of: data?.as_of,
          }));
        },
        error: (err) => {
          console.log(JSON.stringify({
            level: 'audit',
            ...audit,
            status: 'error',
            error: err?.message,
            reason_code: err?.response?.reason_code,
          }));
        }
      })
    );
  }
}
