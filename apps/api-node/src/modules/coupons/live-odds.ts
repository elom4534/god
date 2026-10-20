/**
 * LiveOdds — lecture DIRECTE des marchés MegaPari (BetB2B), sans cache métier.
 *
 * Pourquoi ce module ?
 * --------------------
 * Le générateur de combiné s'appuyait sur le cache Redis alimenté par l'ETL
 * (toutes les 10 min). Une cote peut bouger — ou un marché disparaître — en
 * quelques secondes : composer sur un cache de 10 min puis générer un code
 * coupon revient à figer des cotes qui n'existent peut-être plus.
 *
 * `buildLivePool()` reconstruit les marchés à partir du flux `oddsLocalization`
 * (liste PLATE de sélections) renvoyé par LoadSingle v2, applique le même
 * Margin Guard fail-closed que l'ETL, et calcule pour chaque issue :
 *
 *     odds   cote décimale réellement proposée à cet instant
 *     prob   probabilité "fair" (marge retirée) que la sélection passe
 *
 * Probabilité :
 *     p_i = (1 / cote_i) / Σ_j (1 / cote_j)
 * La somme Σ(1/cote) vaut 1 + marge sur un marché exclusif et exhaustif
 * (1X2, Totaux, Handicap) : diviser par cette somme retire donc exactement
 * la marge du bookmaker.
 *
 * ⚠️ La taxonomie est celle de `app/core/betb2b_adapter.py` — elle doit rester
 * identique, sinon les `type`/`parameter` envoyés à `sharecoupon` divergent.
 */

/** Type BetB2B → famille interne + libellé + tags (cf. betb2b_adapter.py). */
interface TypeSpec {
  family: '1X2' | 'DOUBLE_CHANCE' | 'HANDICAP' | 'OVER_UNDER';
  group: string;
  label: string;
  tags: string[];
  slot: string;
}

const TYPES: Record<number, TypeSpec> = {
  1: { family: '1X2', group: 'main', label: '1', tags: ['HOME'], slot: 'home' },
  2: { family: '1X2', group: 'main', label: 'X', tags: ['DRAW'], slot: 'draw' },
  3: { family: '1X2', group: 'main', label: '2', tags: ['AWAY'], slot: 'away' },
  4: { family: 'DOUBLE_CHANCE', group: 'main', label: '1X', tags: ['HOME', 'DRAW'], slot: 'dc_1x' },
  5: { family: 'DOUBLE_CHANCE', group: 'main', label: '12', tags: ['HOME', 'AWAY'], slot: 'dc_12' },
  6: { family: 'DOUBLE_CHANCE', group: 'main', label: '2X', tags: ['DRAW', 'AWAY'], slot: 'dc_2x' },
  7: { family: 'HANDICAP', group: 'main', label: 'Handicap 1', tags: ['HOME', 'HANDICAP'], slot: 'hc_home' },
  8: { family: 'HANDICAP', group: 'main', label: 'Handicap 2', tags: ['AWAY', 'HANDICAP'], slot: 'hc_away' },
  9: { family: 'OVER_UNDER', group: 'main', label: 'Total Over', tags: ['OVER'], slot: 'ou_over' },
  10: { family: 'OVER_UNDER', group: 'main', label: 'Total Under', tags: ['UNDER'], slot: 'ou_under' },
};

const LINE_FAMILIES = new Set(['HANDICAP', 'OVER_UNDER']);

export interface LiveSelection {
  selection_id: string;
  name: string;
  tags: string[];
  b2b_type: number;
  b2b_parameter: number | null;
  b2b_player_id: number;
  odds: number;
  /** Probabilité fair (marge retirée), 0..1. */
  prob: number;
}

export interface LiveMarket {
  market_id: string;
  market_type: string;
  line: number | null;
  margin_percent: number;
  selections: LiveSelection[];
}

export interface LiveEvent {
  event_id: string;
  home: string;
  away: string;
  league: string;
  sport_id: number | null;
  sport_name: string;
  start_time: string | null;
  markets: LiveMarket[];
}

export interface LivePool {
  events: LiveEvent[];
  validatedMarkets: number;
  rejectedMarkets: number;
  eventsFetched: number;
}

// --------------------------------------------------------------------- utils

const LANG_KEYS = ['en', 'fr', 'de', 'es', 'it', 'ru', 'pt', 'nl'];

/** BetB2B renvoie les libellés en {lang: texte} (singulier ou pluriel). */
function localized(value: unknown): string {
  if (value === null || value === undefined) return '';
  if (typeof value === 'string') return value.trim();
  if (typeof value === 'object') {
    const obj = value as Record<string, unknown>;
    for (const key of LANG_KEYS) {
      const v = obj[key];
      if (typeof v === 'string' && v.trim()) return v.trim();
    }
    for (const v of Object.values(obj)) {
      if (typeof v === 'string' && v.trim()) return v.trim();
    }
  }
  return '';
}

function toNumber(value: unknown): number | null {
  if (value === null || value === undefined || typeof value === 'boolean') return null;
  if (typeof value === 'number') return Number.isFinite(value) ? value : null;
  if (typeof value === 'string') {
    const n = Number(value.trim().replace(',', '.'));
    return Number.isFinite(n) ? n : null;
  }
  return null;
}

function epochToIso(value: unknown): string | null {
  const ts = toNumber(value);
  if (ts === null || ts <= 0) return null;
  try {
    return new Date(ts * 1000).toISOString();
  } catch {
    return null;
  }
}

// ------------------------------------------------------------------- marché

interface Bucket {
  market_id: string;
  market_type: string;
  line: number | null;
  selections: Array<{
    selection_id: string;
    name: string;
    tags: string[];
    b2b_type: number;
    b2b_parameter: number | null;
    b2b_player_id: number;
    odds: number;
  }>;
  blocked: boolean;
}

/**
 * Regroupe la liste plate `oddsLocalization` en marchés.
 * Clé de regroupement : (famille, groupe, |ligne|) — la ligne d'un handicap est
 * symétrique (type 7 = -1.5 / type 8 = +1.5).
 */
function groupSelections(rawSelections: any[], eventId: string): Bucket[] {
  const buckets = new Map<string, Bucket>();

  for (const sel of rawSelections) {
    if (!sel || typeof sel !== 'object') continue;
    const typeId = toNumber(sel.type);
    if (typeId === null) continue;
    const spec = TYPES[typeId];
    if (!spec) continue; // type hors taxonomie → ignoré (fail-closed)

    const parameter = toNumber(sel.parameter);
    const line = LINE_FAMILIES.has(spec.family) && parameter !== null ? Math.abs(parameter) : null;
    const key = `${spec.family}|${spec.group}|${line ?? ''}`;

    let bucket = buckets.get(key);
    if (!bucket) {
      const suffix = line !== null ? `_${line}` : '';
      bucket = {
        market_id: `${eventId}_${spec.family}_${spec.group}${suffix}`,
        market_type: spec.family,
        line,
        selections: [],
        blocked: false,
      };
      buckets.set(key, bucket);
    }

    const odds = toNumber(sel.oddsMarket);
    if (odds === null) continue; // cote illisible → sélection écartée

    let label = spec.label;
    if (spec.family === 'HANDICAP' && line !== null) label = `${label} (${line})`;
    if (spec.family === 'OVER_UNDER' && line !== null) {
      label = `Total (${line}) ${spec.label.endsWith('Over') ? 'Over' : 'Under'}`;
    }

    bucket.selections.push({
      selection_id: `${bucket.market_id}_${spec.slot}`,
      name: label,
      tags: [...spec.tags],
      b2b_type: typeId,
      // Paramètre BRUT signé (indispensable pour sharecoupon.parameter).
      b2b_parameter: parameter,
      // playerId BetB2B : 0 pour un marché d'équipe, >0 pour un marché joueur.
      b2b_player_id: toNumber(sel.playerId) ?? 0,
      odds,
    });
    if (sel.isBlocked) bucket.blocked = true;
  }

  return [...buckets.values()].filter(b => b.selections.length >= 2);
}

/**
 * Margin Guard + probabilités. Reproduit exactement les règles de
 * `megapari_margin_guard.py` :
 *   - marchés exclusifs (1X2, Totaux, Handicap) : marge = Σ(1/cote) − 1 ;
 *   - Double Chance : la somme des probabilités vaut ~2 → la marge « exclusive »
 *     est inexploitable, on applique donc le même calcul que l'ETL, qui rejette
 *     ces marchés (comportement identique, aucune divergence de pool).
 */
function validateMarket(bucket: Bucket, threshold: number): LiveMarket | null {
  if (bucket.blocked) return null;

  const oddsList = bucket.selections.map(s => s.odds);
  if (oddsList.length < 2 || oddsList.some(o => !Number.isFinite(o) || o <= 1.0)) return null;

  const invSum = oddsList.reduce((acc, o) => acc + 1 / o, 0);
  const margin = (invSum - 1) * 100;

  if (!Number.isFinite(margin) || margin > threshold) return null;

  // Double chance : le pool de l'ETL ne le retient pas (marge ≈ 100 %).
  // On garde la même règle ici pour que les deux sources soient identiques.
  if (bucket.market_type === 'DOUBLE_CHANCE') return null;

  const selections: LiveSelection[] = bucket.selections.map((s, i) => {
    const prob = (1 / oddsList[i]) / invSum;
    return {
      selection_id: s.selection_id,
      name: s.name,
      tags: s.tags,
      b2b_type: s.b2b_type,
      b2b_parameter: s.b2b_parameter,
      b2b_player_id: s.b2b_player_id,
      odds: Math.round(s.odds * 1000) / 1000,
      prob: Math.round(Math.min(Math.max(prob, 0), 0.995) * 10000) / 10000,
    };
  });

  return {
    market_id: bucket.market_id,
    market_type: bucket.market_type,
    line: bucket.line,
    margin_percent: Math.round(margin * 100) / 100,
    selections,
  };
}

// ---------------------------------------------------------------------- pool

/**
 * Transforme le flux brut LoadSingle v2 en pool exploitable.
 *
 * @param rawEvents   items de `/datafeed/prematch/api/v2/sportevents`
 * @param sportNames  répertoire {id: nom} (facultatif)
 * @param opts.sportId  filtre discipline
 * @param opts.marginThreshold  seuil de marge (défaut 5 %)
 */
export function buildLivePool(
  rawEvents: any[],
  sportNames: Record<number, string> = {},
  opts: { sportId?: number | null; marginThreshold?: number } = {},
): LivePool {
  const threshold = opts.marginThreshold ?? 5;
  const wantedSport = opts.sportId ?? null;

  const events: LiveEvent[] = [];
  let validatedMarkets = 0;
  let rejectedMarkets = 0;

  for (const raw of rawEvents ?? []) {
    if (!raw || typeof raw !== 'object') continue;

    const eventId = String(raw.sportEventId ?? raw.gameId ?? raw.id ?? '');
    if (!eventId || !/^\d+$/.test(eventId)) continue;

    const rawSportId = toNumber(raw.sportId);
    const sportId = rawSportId !== null ? Math.trunc(rawSportId) : null;
    if (wantedSport !== null && sportId !== wantedSport) continue;

    const rawSelections = Array.isArray(raw.oddsLocalization) ? raw.oddsLocalization : [];
    if (rawSelections.length === 0) continue;

    const markets: LiveMarket[] = [];
    for (const bucket of groupSelections(rawSelections, eventId)) {
      const valid = validateMarket(bucket, threshold);
      if (!valid) {
        rejectedMarkets += 1;
        continue;
      }
      validatedMarkets += 1;
      markets.push(valid);
    }
    if (markets.length === 0) continue;

    events.push({
      event_id: eventId,
      home: localized(raw.opponent1NameLocalization ?? raw.opponent1NameLocalizations),
      away: localized(raw.opponent2NameLocalization ?? raw.opponent2NameLocalizations),
      league: localized(raw.tournamentNameLocalization ?? raw.tournamentNameLocalizations),
      sport_id: sportId,
      sport_name: sportId !== null ? (sportNames[sportId] ?? '') : '',
      start_time: epochToIso(raw.startDate ?? raw.startTime),
      markets,
    });
  }

  return {
    events,
    validatedMarkets,
    rejectedMarkets,
    eventsFetched: Array.isArray(rawEvents) ? rawEvents.length : 0,
  };
}
