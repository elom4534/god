import { Controller, Post, Body } from '@nestjs/common';
import axios from 'axios';

@Controller()
export class ScanController {
  private mlUrl = process.env.ML_PYTHON_URL || 'http://ml-python:8000';

  @Post('scan')
  async scan(@Body() body: any) {
    const { data } = await axios.post(`${this.mlUrl}/ml/v1/scan`, body, { timeout: 3000 });
    // Filtre: ne jamais renvoyer cotes au client (déjà absent côté ML validated_options)
    return data;
  }
}
