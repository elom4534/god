import { Module } from '@nestjs/common';
import { MegaPariCouponService } from './megapari-coupon.service';
import { MegaPariCouponController } from './megapari-coupon.controller';

@Module({
  providers: [MegaPariCouponService],
  controllers: [MegaPariCouponController],
  exports: [MegaPariCouponService],
})
export class MegaPariModule {}
