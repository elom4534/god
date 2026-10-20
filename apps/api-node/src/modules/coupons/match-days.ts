/**
 * Fenêtre « aujourd'hui / demain » des matchs d'un combiné.
 *
 * Règle produit : un combiné ne contient QUE des matchs qui se jouent
 * aujourd'hui, ou à défaut demain. Jamais au-delà.
 *
 * Le calcul se fait dans le fuseau de l'utilisateur (`COUPON_TIMEZONE`,
 * défaut `Africa/Lome`) et non dans celui du serveur : un match à 00:30
 * heure de Lomé ne doit pas être classé « demain » parce que le serveur est
 * encore la veille.
 */
export type MatchDay = 'TODAY' | 'TOMORROW' | 'OUT_OF_WINDOW';

const DEFAULT_TZ = process.env.COUPON_TIMEZONE || 'Africa/Lome';

/**
 * Délai minimal entre l'instant présent et le coup d'envoi.
 *
 * Un coupon MegaPari est un coupon **prematch** (`kind=3`). Si le match démarre
 * pendant que l'utilisateur colle le code, le bookmaker répond « les événements
 * du coupon sont terminés » : le marché a basculé en live. On impose donc une
 * marge de sécurité (30 min par défaut).
 */
const MIN_LEAD_MINUTES = parseInt(process.env.COUPON_MIN_LEAD_MINUTES || '30', 10);

/** Décalage (minutes) du fuseau par rapport à UTC à l'instant donné. */
function tzOffsetMinutes(date: Date, timeZone: string): number {
  try {
    const dtf = new Intl.DateTimeFormat('en-US', {
      timeZone,
      hour12: false,
      year: 'numeric',
      month: '2-digit',
      day: '2-digit',
      hour: '2-digit',
      minute: '2-digit',
      second: '2-digit',
    });
    const parts = dtf.formatToParts(date);
    const map: Record<string, string> = {};
    for (const p of parts) map[p.type] = p.value;
    const asUtc = Date.UTC(
      Number(map.year),
      Number(map.month) - 1,
      Number(map.day),
      Number(map.hour) % 24,
      Number(map.minute),
      Number(map.second),
    );
    // Arrondi à la seconde : formatToParts ne donne pas les millisecondes.
    return (asUtc - Math.floor(date.getTime() / 1000) * 1000) / 60000;
  } catch {
    return 0; // fuseau inconnu → UTC
  }
}

/** Minuit local (epoch ms) du jour calendaire contenant `date`. */
function startOfZonedDay(date: Date, timeZone: string): number {
  const ymd = new Intl.DateTimeFormat('en-CA', {
    timeZone,
    year: 'numeric',
    month: '2-digit',
    day: '2-digit',
  }).format(date); // YYYY-MM-DD
  const [y, m, d] = ymd.split('-').map(Number);

  // Deux passes : le décalage peut changer entre le calcul et l'instant visé
  // (changement d'heure). Pour Africa/Lome (UTC+0) c'est neutre.
  let guess = Date.UTC(y, m - 1, d, 0, 0, 0) - tzOffsetMinutes(date, timeZone) * 60000;
  guess = Date.UTC(y, m - 1, d, 0, 0, 0) - tzOffsetMinutes(new Date(guess), timeZone) * 60000;
  return guess;
}

export interface DayWindow {
  timeZone: string;
  /** Marge de sécurité avant le coup d'envoi (minutes). */
  minLeadMinutes: number;
  /** Minuit local aujourd'hui. */
  todayStart: number;
  /** Minuit local demain. */
  tomorrowStart: number;
  /** Minuit local après-demain (borne exclue). */
  dayAfterStart: number;
}

export function dayWindow(now: Date = new Date(), timeZone: string = DEFAULT_TZ): DayWindow {
  const todayStart = startOfZonedDay(now, timeZone);
  const tomorrowStart = startOfZonedDay(new Date(todayStart + 26 * 3600 * 1000), timeZone);
  const dayAfterStart = startOfZonedDay(new Date(tomorrowStart + 26 * 3600 * 1000), timeZone);
  return { timeZone, minLeadMinutes: MIN_LEAD_MINUTES, todayStart, tomorrowStart, dayAfterStart };
}

/**
 * Classe un coup d'envoi dans la fenêtre autorisée.
 *
 * Un match déjà commencé est hors fenêtre, et un match qui démarre dans moins
 * de `minLeadMinutes` aussi : le coupon serait périmé avant d'être collé.
 */
export function classifyMatchDay(
  startTime: string | null | undefined,
  window: DayWindow,
  now: number = Date.now(),
): MatchDay {
  if (!startTime) return 'OUT_OF_WINDOW';
  const ts = Date.parse(startTime);
  if (!Number.isFinite(ts)) return 'OUT_OF_WINDOW';
  if (ts < now + window.minLeadMinutes * 60 * 1000) return 'OUT_OF_WINDOW';
  if (ts >= window.todayStart && ts < window.tomorrowStart) return 'TODAY';
  if (ts >= window.tomorrowStart && ts < window.dayAfterStart) return 'TOMORROW';
  return 'OUT_OF_WINDOW';
}
