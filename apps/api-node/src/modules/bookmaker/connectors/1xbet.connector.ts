/**
 * Connecteur 1xBet — DUPLICATION EXACTE du connecteur Méga Pari
 * Seules différences: client_id / client_secret / ref=1
 * Base URL, headers, méthode OAuth, ordre params: IDENTIQUES
 */
import { BaseBetB2BConnector } from './base.connector';

export class XBetConnector extends BaseBetB2BConnector {
  constructor() { super('1xBet'); }
}

export const xbetConnector = new XBetConnector();
