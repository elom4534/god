import { Module } from '@nestjs/common';
import { PicksController } from './picks.controller';

@Module({ controllers: [PicksController] })
export class PicksModule {}
