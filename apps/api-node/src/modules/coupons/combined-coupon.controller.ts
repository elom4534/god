import { Controller, Post, Body, HttpCode } from '@nestjs/common';
import { CombinedCouponService } from './combined-coupon.service';

@Controller('coupons')
export class CombinedCouponController {
  constructor(private svc: CombinedCouponService) {}

  @Post('generate-combined')
  @HttpCode(201)
  async generateCombined(@Body() body: { num_matches: number; target_total_odds: number; currency?: string; language?: string }) {
    const { num_matches, target_total_odds, currency, language } = body || ({} as any);
    return this.svc.generateCombined(num_matches, target_total_odds, currency, language);
  }
}
