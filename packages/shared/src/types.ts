import { Confidence, MarketPeriod, MarketType, Provider } from "./enums";

export type Event = {
  event_id: string;
  sport: string;
  league: string;
  start_time: string; // ISO
  home: string;
  away: string;
  is_virtual: boolean;
  provider?: Provider;
};

export type Market = {
  market_id: string;
  market_type: MarketType;
  name: string;
  period: MarketPeriod;
  line: number | null;
  selections: Selection[];
};

export type Selection = {
  selection_id: string;
  name: string;
  tags: string[];
  // odds_internal is NEVER exposed to client, only internal
  odds_internal?: number;
};

export type NormalizedEvent = Event & { markets: Market[] };

export type ScanValidatedOption = {
  market_id: string;
  market_type: MarketType;
  line: number | null;
  selection_id: string;
  margin_pct: number;
  reason_code: string;
};

export type Pick = {
  event_id: string;
  market_id: string;
  selection_id: string;
  market_type: MarketType;
  line: number | null;
  p_model: number;
  sigma: number;
  p_lower: number;
  confidence: Confidence;
  score: number;
  factors: { name: string; impact: string }[];
  warnings: string[];
  model_version: string;
  as_of: string;
};

export type CouponDraft = {
  draft_id: string;
  mode: string;
  format: string;
  selections: Pick[];
  constraints_ok: boolean;
  warnings: string[];
  created_at: string;
  expires_at: string;
};
