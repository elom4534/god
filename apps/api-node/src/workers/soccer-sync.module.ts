import { Module } from '@nestjs/common';
import { ScheduleModule } from '@nestjs/schedule';
import { SoccerSyncWorker } from './soccer-sync.worker';
import { OddsRefreshWorker } from './odds-refresh.worker';
import { OddsRefreshController } from './odds-refresh.controller';

@Module({
  imports: [ScheduleModule.forRoot()],
  controllers: [OddsRefreshController],
  providers: [SoccerSyncWorker, OddsRefreshWorker],
  exports: [SoccerSyncWorker],
})
export class SoccerSyncModule {}
