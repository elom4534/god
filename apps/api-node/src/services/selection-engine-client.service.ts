import { Injectable } from '@nestjs/common';
import axios from 'axios';

@Injectable()
export class SelectionEngineClient {
  private base = process.env.ML_PYTHON_URL || 'http://ml-python:8000';

  async getBestPicks(events: any[], mode: string, kSigma = 1.0, thresholdPct = 5.0) {
    const url = `${this.base}/ml/v1/picks/best`;
    const { data } = await axios.post(url, { events, mode, k_sigma: kSigma, threshold_pct: thresholdPct }, { timeout: 3000 });
    return data;
  }
}
