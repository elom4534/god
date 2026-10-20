import { Module } from '@nestjs/common';
import { CouponsController } from './coupons.controller';
import { CombinedCouponController } from './combined-coupon.controller';
import { CombinedCouponService } from './combined-coupon.service';
import { MegaPariModule } from '../bookmaker/megapari.module';

@Module({
  imports: [MegaPariModule],
  controllers: [CouponsController, CombinedCouponController],
  providers: [CombinedCouponService],
})
export class CouponsModule {}
