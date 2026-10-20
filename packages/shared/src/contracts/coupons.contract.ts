export type CouponsGenerateRequest = {
  mode: "real_only" | "virtual_only" | "mix";
  format: "SINGLE" | "COMBINE" | "SYSTEM";
  system_k?: number;
  system_n?: number;
  event_ids: string[];
  preferences?: {
    risk_profile?: "conservative" | "balanced" | "aggressive";
    leagues?: string[];
  };
};

export type CouponsGenerateResponse = {
  draft_id: string;
  mode: string;
  format: string;
  selections: {
    event_id: string;
    market_id: string;
    selection_id: string;
    p_lower: number;
    confidence: string;
  }[];
  constraints_ok: boolean;
  warnings: string[];
  created_at: string;
  expires_at: string;
};
