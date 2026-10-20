/**
 * Connecteur Méga Pari — référence qui fonctionne
 * Base URL, headers, OAuth, ordre params: identiques à 1xBet
 */
import { BaseBetB2BConnector } from './base.connector';

export class MegaPariConnector extends BaseBetB2BConnector {
  constructor() { super('Méga Pari'); }
}

export const megaPariConnector = new MegaPariConnector();
