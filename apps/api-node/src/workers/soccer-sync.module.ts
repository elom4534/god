import { Module } from '@nestjs/common';
import { ScheduleModule } from '@nestjs/schedule';
import { SoccerSyncWorker } from './soccer-sync.worker';

@Module({
  imports: [ScheduleModule.forRoot()],
  providers: [SoccerSyncWorker],
  exports: [SoccerSyncWorker],
})
export class SoccerSyncModule {}
