import { Injectable, UnauthorizedException, ConflictException, BadRequestException } from '@nestjs/common';
import { JwtService } from '@nestjs/jwt';
import { createClient } from 'redis';
import * as crypto from 'crypto';

const REDIS_URL = process.env.REDIS_URL || 'redis://localhost:6379';
const ACCESS_TTL = process.env.JWT_ACCESS_TTL || '15m';
const REFRESH_TTL_SEC = 7 * 24 * 60 * 60;
let redisClient: any = null;
async function getRedis() {
  if (redisClient) return redisClient;
  try { redisClient = createClient({ url: REDIS_URL }); await redisClient.connect(); return redisClient; } catch { return null; }
}

const USERS_MEM = new Map<string, any>();

function hashPassword(password: string, salt?: string) {
  const s = salt || crypto.randomBytes(16).toString('hex');
  const hash = crypto.scryptSync(password, s, 64).toString('hex');
  return { salt: s, hash };
}

function verifyPassword(password: string, salt: string, hash: string) {
  const h = crypto.scryptSync(password, salt, 64).toString('hex');
  return crypto.timingSafeEqual(Buffer.from(h, 'hex'), Buffer.from(hash, 'hex'));
}

@Injectable()
export class AuthService {
  private readonly accessSecret = process.env.JWT_SECRET || 'dev-secret';
  private readonly refreshSecret = process.env.JWT_REFRESH_SECRET || (process.env.JWT_SECRET || 'dev-secret') + '-refresh';

  constructor(private jwt: JwtService) {}

  private async getUser(email: string) {
    const r = await getRedis();
    if (r) {
      try {
        const raw = await r.get(`auth:user:${email.toLowerCase()}`);
        if (raw) return JSON.parse(raw);
      } catch { /* fallback */ }
    }
    return USERS_MEM.get(email.toLowerCase()) || null;
  }

  private async saveUser(user: any) {
    const r = await getRedis();
    if (r) {
      try { await r.set(`auth:user:${user.email.toLowerCase()}`, JSON.stringify(user)); return; } catch { /* fallback */ }
    }
    USERS_MEM.set(user.email.toLowerCase(), user);
  }

  async register(email: string, password: string, country?: string) {
    if (!email || !password) throw new BadRequestException('email/password requis');
    const existing = await this.getUser(email);
    if (existing) throw new ConflictException('utilisateur existe déjà');
    const { salt, hash } = hashPassword(password);
    const user = {
      email: email.toLowerCase(),
      salt,
      passwordHash: hash,
      country: country || null,
      createdAt: new Date().toISOString(),
      roles: ['user'],
    };
    await this.saveUser(user);
    return this.issueTokens(user);
  }

  async login(email: string, password: string) {
    const user = await this.getUser(email);
    if (!user) throw new UnauthorizedException('identifiants invalides');
    if (!verifyPassword(password, user.salt, user.passwordHash)) {
      throw new UnauthorizedException('identifiants invalides');
    }
    return this.issueTokens(user);
  }

  private async issueTokens(user: any) {
    const payload = { sub: user.email, roles: user.roles || ['user'], country: user.country };
    const accessToken = this.jwt.sign(payload, { secret: this.accessSecret, expiresIn: ACCESS_TTL });
    const refreshToken = this.jwt.sign({ sub: user.email, type: 'refresh' }, { secret: this.refreshSecret, expiresIn: `${REFRESH_TTL_SEC}s` });
    // store refresh token in redis for revocation/rotation
    const r = await getRedis();
    if (r) {
      try { await r.setEx(`auth:refresh:${refreshToken}`, REFRESH_TTL_SEC, user.email); } catch { /* ignore */ }
    }
    return {
      accessToken,
      refreshToken,
      tokenType: 'Bearer',
      expiresIn: ACCESS_TTL,
      user: { email: user.email, roles: user.roles, country: user.country },
    };
  }

  async refresh(refreshToken: string) {
    if (!refreshToken) throw new UnauthorizedException('refresh token manquant');
    let decoded: any;
    try {
      decoded = this.jwt.verify(refreshToken, { secret: this.refreshSecret });
    } catch {
      throw new UnauthorizedException('refresh token invalide');
    }
    if (decoded?.type !== 'refresh') throw new UnauthorizedException('token invalide');
    // check revocation store
    const r = await getRedis();
    if (r) {
      try {
        const stored = await r.get(`auth:refresh:${refreshToken}`);
        if (!stored) throw new UnauthorizedException('refresh token révoqué/expiré');
      } catch (e) {
        if (e instanceof UnauthorizedException) throw e;
      }
    }
    const user = await this.getUser(decoded.sub);
    if (!user) throw new UnauthorizedException('utilisateur introuvable');
    // rotate: revoke old refresh token
    if (r) {
      try { await r.del(`auth:refresh:${refreshToken}`); } catch { /* ignore */ }
    }
    return this.issueTokens(user);
  }

  async validateAccessToken(token: string) {
    try {
      const decoded = this.jwt.verify(token, { secret: this.accessSecret });
      return decoded;
    } catch {
      return null;
    }
  }

  async me(token: string) {
    const decoded: any = await this.validateAccessToken(token);
    if (!decoded) throw new UnauthorizedException('token invalide');
    const user = await this.getUser(decoded.sub);
    if (!user) throw new UnauthorizedException('utilisateur introuvable');
    return { email: user.email, roles: user.roles, country: user.country, createdAt: user.createdAt };
  }

  async logout(refreshToken: string) {
    const r = await getRedis();
    if (r && refreshToken) {
      try { await r.del(`auth:refresh:${refreshToken}`); } catch { /* ignore */ }
    }
    return { ok: true };
  }
}
