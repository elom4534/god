/**
 * Controller NestJS — MegaPari Coupon Code + Deep Link
 * POST /api/v1/megapari/coupon/generate → {couponCode, deepLink}
 * POST /api/v1/megapari/coupon/create   → alias B2B direct (legacy)
 */
import { Controller, Post, Body, HttpCode, Headers, Logger } from '@nestjs/common';
import { ApiTags, ApiOperation } from '@nestjs/swagger';
import { MegaPariCouponService, Pick } from './megapari-coupon.service';

@ApiTags('MegaPari Coupon')
@Controller('megapari/coupon')
export class MegaPariCouponController {
  private readonly logger = new Logger(MegaPariCouponController.name);
  constructor(private readonly couponService: MegaPariCouponService) {}

  @Post('generate')
  @HttpCode(201)
  @ApiOperation({ summary: 'Génère Code Coupon MegaPari (ref=192) via B2B sharecoupon — 1 pick/match strict' })
  async generate(
    @Body() body: { picks: Pick[]; currency?: string; language?: string },
    @Headers('x-country-code') country?: string,
  ) {
    const { picks, currency, language } = body;
    const result = await this.couponService.generateCoupon(picks, { currency, language });

    // Réponse exacte demandée:
    // { success, couponCode, deepLink, message }
    return {
      success: result.success,
      provider: result.provider,
      totalPicks: result.totalPicks,
      couponCode: result.couponCode, // Code à copier ex: AB123CD
      deepLink: result.deepLink,     // https://megapari.com/en?coupon-code=AB123CD
      message: result.message,       // "Coupon généré avec succès"
      // debug/audit (optionnel, ne pas exposer en prod si sensible)
      _meta: {
        ref: result.couponPayload.ref,
        expiresAt: result.couponPayload.expiresAt,
        country: country || 'unknown',
      },
    };
  }

  // Alias pour compatibilité avec ancienne spec /bookmaker/coupon/create
  @Post('create')
  @HttpCode(201)
  @ApiOperation({ summary: 'Alias B2B — crée coupon et retourne couponCode (fail-closed)' })
  async create(@Body() body: { picks: Pick[]; draft_id?: string }) {
    return this.generate(body as any);
  }

  @Post('generate-from-validated')
  @HttpCode(201)
  @ApiOperation({ summary: 'Génère depuis validated_markets (sortie Margin Guard)' })
  async generateFromValidated(
    @Body() body: { validated_markets: any[]; currency?: string },
  ) {
    return this.couponService.generateFromValidatedMarkets(body.validated_markets, { currency: body.currency }).then(r => ({
      success: r.success,
      couponCode: r.couponCode,
      deepLink: r.deepLink,
      message: r.message,
      totalPicks: r.totalPicks,
    }));
  }
}
