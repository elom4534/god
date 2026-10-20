import { Injectable, CanActivate, ExecutionContext, UnauthorizedException } from '@nestjs/common';
import { AuthService } from './auth.service';

@Injectable()
export class JwtAuthGuard implements CanActivate {
  constructor(private auth: AuthService) {}
  async canActivate(ctx: ExecutionContext): Promise<boolean> {
    const req = ctx.switchToHttp().getRequest();
    const header = req.headers?.authorization || '';
    const token = String(header).replace(/^Bearer\s+/i, '').trim();
    if (!token) throw new UnauthorizedException('token manquant');
    const decoded = await this.auth.validateAccessToken(token);
    if (!decoded) throw new UnauthorizedException('token invalide/expiré');
    req.user = decoded;
    return true;
  }
}
