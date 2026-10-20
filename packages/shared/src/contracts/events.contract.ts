export type EventsIngestRequest = {
  provider: string;
  is_virtual: boolean;
  raw_events: unknown[];
  as_of: string;
};

export type EventsIngestResponse = {
  normalized: import("../types").NormalizedEvent[];
  rejected: { raw_id: string; reason_code: string }[];
  model_version: string;
  as_of: string;
};
