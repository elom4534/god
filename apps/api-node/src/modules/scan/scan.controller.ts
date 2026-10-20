import { Controller, Post, Body, BadRequestException, HttpException, HttpStatus } from '@nestjs/common';
import axios from 'axios';

@Controller()
export class ScanController {
  private mlUrl = process.env.ML_PYTHON_URL || 'http://ml-python:8000';

  @Post('scan')
  async scan(@Body() body: any) {
    // Validation fail-closed: body vide / marchés manquants → 400 (pas 500)
    if (!body || typeof body !== 'object' || Array.isArray(body)) {
      throw new BadRequestException({ error: 'INVALID_BODY', reason_code: 'INVALID_BODY', details: 'JSON object attendu' });
    }
    const markets = body.markets ?? body.raw_markets;
    if (!Array.isArray(markets) || markets.length === 0) {
      throw new BadRequestException({ error: 'NO_MARKETS', reason_code: 'NO_MARKETS', details: 'markets[] requis et non vide' });
    }
    if (body.threshold_pct !== undefined) {
      const t = Number(body.threshold_pct);
      if (isNaN(t) || t <= 0 || t > 100) {
        throw new BadRequestException({ error: 'INVALID_THRESHOLD', reason_code: 'INVALID_THRESHOLD' });
      }
    }

    try {
      const { data } = await axios.post(`${this.mlUrl}/ml/v1/scan`, body, { timeout: 3000 });
      // Filtre: ne jamais renvoyer cotes au client (déjà absent côté ML validated_options)
      return data;
    } catch (e: any) {
      if (e?.response) {
        const status = e.response.status || HttpStatus.BAD_GATEWAY;
        throw new HttpException(e.response.data ?? { error: 'ML_ERROR' }, status);
      }
      if (e?.code === 'ECONNABORTED' || /timeout/i.test(e?.message || '')) {
        throw new HttpException({ error: 'ML_TIMEOUT', reason_code: 'ML_TIMEOUT' }, HttpStatus.GATEWAY_TIMEOUT);
      }
      throw new HttpException({ error: 'ML_UNAVAILABLE', reason_code: 'ML_UNAVAILABLE' }, HttpStatus.BAD_GATEWAY);
    }
  }
}
