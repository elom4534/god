import { Module } from '@nestjs/common';
import { EventsModule } from './modules/events/events.module';
import { ScanModule } from './modules/scan/scan.module';
import { PicksModule } from './modules/picks/picks.module';
import { CouponsModule } from './modules/coupons/coupons.module';
import { BookmakerModule } from './modules/bookmaker/bookmaker.module';
import { AuthModule } from './modules/auth/auth.module';
import { PreferencesModule } from './modules/preferences/preferences.module';
import { HistoryModule } from './modules/history/history.module';

import { MegaPariModule } from './modules/bookmaker/megapari.module';
import { SoccerSyncModule } from './workers/soccer-sync.module';

@Module({
  imports: [AuthModule, EventsModule, ScanModule, PicksModule, CouponsModule, BookmakerModule, MegaPariModule, SoccerSyncModule, PreferencesModule, HistoryModule],
  controllers: [],
  providers: [],
})
export class AppModule {}
