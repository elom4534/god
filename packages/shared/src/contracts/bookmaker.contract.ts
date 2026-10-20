export type BookmakerCouponCreateRequest = {
  draft_id: string;
  provider: "1xBet" | "Méga Pari";
  stake: number;
  currency: string;
};

export type BookmakerCouponCreateSuccess = {
  ticket_id: string;
  status: "PLACED";
  provider: string;
  placed_at: string;
};

export type BookmakerCouponCreateError = {
  error: string;
  reason_code: string;
  details?: string;
};
