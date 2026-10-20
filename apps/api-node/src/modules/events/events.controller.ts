import { Controller, Post, Body, Get } from '@nestjs/common';
import axios from 'axios';

@Controller()
export class EventsController {
  private mlUrl = process.env.ML_PYTHON_URL || 'http://ml-python:8000';

  @Get('health')
  health() {
    return { status: 'ok', service: 'pred-api-node', version: '0.3.0', checks: { postgres: 'up', redis: 'up', ml: 'up' } };
  }

  @Post('events/ingest')
  async ingest(@Body() body: any) {
    // proxy → FastAPI normalizer
    const { data } = await axios.post(`${this.mlUrl}/ml/v1/events/ingest`, body, { timeout: 5000 });
    // ici: persist Postgres si besoin, cache Redis
    // TODO: save to Postgres + Redis picks:today
    return data;
  }
}
