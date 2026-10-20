import { Controller, Get, Post, Query } from '@nestjs/common';
import { OddsRefreshWorker } from './odds-refresh.worker';

/** Diagnostic + déclenchement manuel du rafraîchissement des cotes. */
@Controller('system/odds-refresh')
export class OddsRefreshController {
  constructor(private readonly worker: OddsRefreshWorker) {}

  @Get()
  status() {
    return this.worker.status();
  }

  /** Force un rafraîchissement (admin / exploitation). */
  @Post()
  async trigger(@Query('reason') reason?: string) {
    return this.worker.refresh(reason || 'manuel');
  }
}
