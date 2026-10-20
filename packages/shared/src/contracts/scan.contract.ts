import { NormalizedEvent } from "../types";

export type ScanRequest = {
  event_id: string;
  markets: NormalizedEvent["markets"];
  threshold_pct?: number;
};

export type ScanResponse = {
  event_id: string;
  validated_options: {
    market_id: string;
    market_type: string;
    line: number | null;
    selection_id: string;
    margin_pct: number;
    reason_code: string;
  }[];
  rejected_options: {
    market_id: string;
    selection_id?: string;
    margin_pct?: number;
    reason_code: string;
  }[];
  as_of: string;
};
