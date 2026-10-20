import { Module } from '@nestjs/common';
import { CouponsController } from './coupons.controller';

@Module({ controllers: [CouponsController] })
export class CouponsModule {}
