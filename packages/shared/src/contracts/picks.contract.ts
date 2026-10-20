import { NormalizedEvent, Pick } from "../types";

export type PicksBestRequest = {
  events: NormalizedEvent[];
  mode: "real_only" | "virtual_only" | "mix";
  k_sigma?: number;
};

export type PicksBestResponse = {
  picks: Pick[];
  skipped: { event_id: string; reason_code: string }[];
  as_of: string;
};
