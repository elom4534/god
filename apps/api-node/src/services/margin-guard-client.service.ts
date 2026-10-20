import { Injectable } from '@nestjs/common';
import axios from 'axios';

@Injectable()
export class MarginGuardClient {
  private base = process.env.ML_PYTHON_URL || 'http://ml-python:8000';

  async scan(eventId: string, markets: any[], thresholdPct = 5.0) {
    const url = `${this.base}/ml/v1/scan`;
    const { data } = await axios.post(url, { event_id: eventId, markets, threshold_pct: thresholdPct }, { timeout: 2000 });
    return data;
  }

  async revalidateMarkets(markets: any[], thresholdPct = 5.0) {
    // helper for coupon create revalidation
    const url = `${this.base}/ml/v1/scan`;
    const { data } = await axios.post(url, { event_id: 'revalidate', markets, threshold_pct: thresholdPct }, { timeout: 2000 });
    return data;
  }
}
