import { CanActivate, ExecutionContext, Injectable, ForbiddenException } from '@nestjs/common';

/**
 * Country Policy Gate — fail-closed.
 * Si pays non autorisé/non configuré → bloque création coupon, mais probas informatives restent OK.
 * Config via env ALLOWED_COUNTRIES (whitelist). Si absent → BLOQUE.
 */
@Injectable()
export class CountryPolicyGuard implements CanActivate {
  private allowed: Set<string>;
  private blocked: Set<string>;

  constructor() {
    const allowedRaw = process.env.ALLOWED_COUNTRIES || '';
    const blockedRaw = process.env.BLOCKED_COUNTRIES || '';
    this.allowed = new Set(allowedRaw.split(',').map(s => s.trim().toUpperCase()).filter(Boolean));
    this.blocked = new Set(blockedRaw.split(',').map(s => s.trim().toUpperCase()).filter(Boolean));
  }

  canActivate(context: ExecutionContext): boolean {
    const req = context.switchToHttp().getRequest();
    // pays depuis JWT, header, ou IP geo (ici header X-Country-Code pour démo)
    const country = (req.user?.country_code || req.headers['x-country-code'] || req.body?.country_code || '').toUpperCase();

    if (!country) {
      throw new ForbiddenException({
        error: 'COUNTRY_NOT_CONFIGURED',
        reason_code: 'COUNTRY_GATE_BLOCKED',
        details: 'Missing X-Country-Code or user.country_code',
      });
    }
    if (this.blocked.has(country)) {
      throw new ForbiddenException({
        error: 'COUNTRY_BLOCKED',
        reason_code: 'COUNTRY_GATE_BLOCKED',
        country,
      });
    }
    if (this.allowed.size > 0 && !this.allowed.has(country)) {
      // fail-closed: non listé = bloqué
      throw new ForbiddenException({
        error: 'COUNTRY_NOT_CONFIGURED',
        reason_code: 'COUNTRY_GATE_BLOCKED',
        country,
        details: `Country ${country} not in ALLOWED_COUNTRIES (fail-closed)`,
      });
    }
    return true;
  }
}
