import { Controller, Post, Body, UseInterceptors } from '@nestjs/common';
import axios from 'axios';
import { AuditInterceptor } from '../../common/interceptors/audit.interceptor';

@Controller()
@UseInterceptors(AuditInterceptor)
export class PicksController {
  private mlUrl = process.env.ML_PYTHON_URL || 'http://ml-python:8000';

  @Post('picks/best')
  async best(@Body() body: any) {
    const { data } = await axios.post(`${this.mlUrl}/ml/v1/picks/best`, body, { timeout: 4000 });
    // En prod: cache Redis picks:today:{league}:{event_id} TTL 6h
    // Ici on retourne direct, sans cotes
    return data;
  }
}
