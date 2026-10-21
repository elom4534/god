"""
Ingestion Football Virtuel temps réel — flux Partner API MegaPari UNIQUEMENT.

Machine à états d'un round : SCHEDULED → LIVE → FINISHED (+ CANCELLED),
reconstituée à partir du flux réel (jamais simulée). Polling adaptatif qui
respecte les rate limits officiels (1 req/20 s prematch, 1 req/5 s live).
"""
from __future__ import annotations

import asyncio
import logging
import re
import time
from datetime import datetime, timedelta, timezone
from typing import Any, Dict, List, Optional, Tuple

from app.virtual import config as C
from app.virtual import store
from app.virtual.partner_client import PartnerAuthError, PartnerClient, PartnerApiError
from app.virtual.ratings import engine as ratings_engine

log = logging.getLogger("virtual.ingestor")

_fifa_re = re.compile(C.FIFA_TOURNAMENT_RE, re.IGNORECASE)
_sega_re = re.compile(C.SEGA_TOURNAMENT_RE, re.IGNORECASE)


def classify_provider(tournament_name: str) -> Optional[str]:
    """Classification par regex de nom de tournoi (aucun ID provider dans le flux)."""
    name = (tournament_name or "").strip()
    if not name:
        return None
    if _sega_re.search(name):
        return "SEGA_VIRTUAL"
    if _fifa_re.search(name):
        return "FIFA_VIRTUAL"
    return None


def parse_score(raw: Optional[str]) -> Optional[Tuple[int, int, Optional[str]]]:
    """`"3:2 (3:0,0:2)"` → (3, 2, "3:0,0:2"). Score réel du flux, jamais estimé."""
    if not raw or ":" not in raw:
        return None
    main = raw.split(" ", 1)[0]
    try:
        h, a = main.split(":", 1)
        return int(h.strip()), int(a.strip()), (raw.split("(", 1)[1].rstrip(")") if "(" in raw else None)
    except (ValueError, IndexError):
        return None


def _epoch_to_dt(ts: Any) -> Optional[datetime]:
    try:
        return datetime.fromtimestamp(int(ts), tz=timezone.utc)
    except (TypeError, ValueError):
        return None


def _mapped_odds(item: Dict[str, Any]) -> List[Dict[str, Any]]:
    """oddsLocalization[] → lignes de cotes normalisées (raw conservé)."""
    rows: List[Dict[str, Any]] = []
    for o in item.get("oddsLocalization") or []:
        typ = o.get("type")
        mapping = C.MARKET_BY_TYPE.get(typ)
        if mapping:
            market, selection = mapping
        elif typ in C.HTFT_TYPES:
            market, selection = "HTFT", str(o.get("display") or typ)
        elif typ == C.CORRECT_SCORE_TYPE:
            market, selection = "CORRECT_SCORE", str(o.get("display") or typ)
        else:
            market, selection = f"TYPE_{typ}", str(o.get("display") or typ)
        line = None
        if market in C.LINE_MARKETS:
            try:
                line = float(o.get("parameter"))
            except (TypeError, ValueError):
                line = None
        odd_val = o.get("oddsMarket")
        try:
            odd_val = float(odd_val)
        except (TypeError, ValueError):
            continue
        rows.append({
            "market": market, "selection": selection, "odds": odd_val, "line": line,
            "is_blocked": bool(o.get("isBlocked")), "raw": o,
        })
    return rows


class VirtualIngestor:
    def __init__(self, client: Optional[PartnerClient] = None) -> None:
        self.client = client or PartnerClient()
        self._last_scores: Dict[str, Tuple[Optional[int], Optional[int]]] = {}
        self._last_snapshot: Dict[str, float] = {}
        self._seen_live: Dict[str, str] = {}
        self._tournament_ids: Dict[str, int] = {}
        self._pending_start: Dict[str, float] = {}
        self._stop = asyncio.Event()

    def stop(self) -> None:
        self._stop.set()

    # --------------------------------------------------------------- cycle
    async def run(self) -> None:
        log.info("Ingestion Football Virtuel démarrée (flux réel Partner API)")
        await ratings_engine.load_from_db()
        backoff = 5.0
        while not self._stop.is_set():
            try:
                await self._cycle()
                backoff = 5.0
            except PartnerAuthError as exc:
                # Échec explicite et bloquant : jamais silencieux.
                log.error("AUTH PARTENAIRE — %s", exc)
                backoff = max(backoff, 60.0)
            except (PartnerApiError, OSError) as exc:
                log.warning("Flux partenaire indisponible : %s", exc)
                backoff = min(backoff * 2, 300.0)
            except asyncio.CancelledError:
                raise
            except Exception as exc:  # pragma: no cover — le flux ne doit jamais tuer le site
                log.exception("Cycle ingestion virtuel en erreur : %s", exc)
                backoff = min(backoff * 2, 300.0)
            try:
                await asyncio.wait_for(self._stop.wait(), timeout=self._next_sleep(backoff))
            except asyncio.TimeoutError:
                pass

    def _next_sleep(self, backoff: float) -> float:
        if backoff > 5.0:
            return backoff
        now = time.time()
        soonest = None
        # Fréquence accrue si round dans les 2 dernières minutes ou en direct.
        if self._seen_live:
            return C.POLL_LIVE
        for _, ts in self._pending_start.items():
            delta = ts - now
            if delta <= C.PRE_ROUND_WINDOW:
                return C.POLL_PRE_ROUND
            soonest = delta if soonest is None else min(soonest, delta)
        return min(C.POLL_NORMAL, max(C.POLL_PRE_ROUND, (soonest or C.POLL_NORMAL)))

    # -------------------------------------------------------------- cycle
    async def _cycle(self) -> None:
        now_utc = datetime.now(timezone.utc)
        now_epoch = int(now_utc.timestamp())

        # 1) Rounds à venir + snapshots de cotes (prematch)
        premark = await asyncio.to_thread(self.client.fetch_prematch)
        await self._handle_premark(premark, now_utc)

        # 2) Rounds en direct (scores, minutes, événements)
        live = await asyncio.to_thread(self.client.fetch_live)
        await self._handle_live(live, now_utc)

        # 3) Balayage des résultats (clôture exacte)
        await self._handle_results(now_epoch, now_utc)

    # --------------------------------------------------------- prematch
    async def _handle_premark(self, items: List[Dict[str, Any]], now_utc: datetime) -> None:
        self._pending_start.clear()
        for item in items:
            name = item.get("tournamentNameLocalization") or ""
            provider = classify_provider(name)
            if not provider:
                continue
            const_id = item.get("constSportEventId") or item.get("sportEventId")
            if const_id is None:
                continue
            round_id = str(const_id)
            scheduled = _epoch_to_dt(item.get("startDate"))
            if scheduled is None:
                continue
            self._tournament_ids[round_id] = int(item.get("tournamentId") or 0) or \
                self._tournament_ids.get(round_id, 0)
            self._pending_start[round_id] = scheduled.timestamp()
            home = item.get("opponent1NameLocalization") or "?"
            away = item.get("opponent2NameLocalization") or "?"
            source_ts = now_utc
            await store.upsert_round_scheduled({
                "round_id": round_id, "provider": provider,
                "league": name, "home_team": home, "away_team": away,
                "scheduled_start": scheduled,
                "tournament_id": item.get("tournamentId"),
                "api_event_id": item.get("sportEventId"),
                "api_const_event_id": const_id,
                "match_format": (item.get("matchInfoObject") or {}).get("matchFormat"),
                "home_logo": (item.get("imageOpponent1") or [None])[0],
                "away_logo": (item.get("imageOpponent2") or [None])[0],
                "source_ts": source_ts, "captured_at": now_utc,
            })
            await self._maybe_snapshot_odds(round_id, item, "PREMATCH", now_utc)

    async def _maybe_snapshot_odds(self, round_id: str, item: Dict[str, Any],
                                   phase: str, now_utc: datetime) -> None:
        last = self._last_snapshot.get(round_id, 0.0)
        start_ts = self._pending_start.get(round_id, 0.0)
        soon = start_ts and (start_ts - time.time()) <= C.PRE_ROUND_WINDOW
        interval = C.ODDS_SNAPSHOT_INTERVAL if not soon else max(C.POLL_PRE_ROUND, 20.0)
        if phase == "LIVE":
            interval = max(C.POLL_LIVE, 20.0)
        if time.time() - last < interval:
            return
        rows = _mapped_odds(item)
        if not rows:
            return
        self._last_snapshot[round_id] = time.time()
        for row in rows:
            row.update({"round_id": round_id, "phase": phase,
                        "source_ts": now_utc, "captured_at": now_utc})
            await store.insert_odds_snapshot(row)

    # ------------------------------------------------------------- live
    async def _handle_live(self, items: List[Dict[str, Any]], now_utc: datetime) -> None:
        seen_ids = set()
        for item in items:
            name = item.get("tournamentNameLocalization") or ""
            provider = classify_provider(name)
            if not provider:
                continue
            const_id = item.get("constSportEventId") or item.get("sportEventId")
            if const_id is None:
                continue
            round_id = str(const_id)
            seen_ids.add(round_id)
            home = item.get("opponent1NameLocalization") or "?"
            away = item.get("opponent2NameLocalization") or "?"
            scheduled = _epoch_to_dt(item.get("startDate")) or now_utc
            cur = item.get("curScore") or {}
            hg, ag = cur.get("sc1"), cur.get("sc2")
            time_sec = item.get("timeSec")
            minute = int(time_sec) // 60 if isinstance(time_sec, (int, float)) else None
            period = item.get("currentPeriodName")
            self._tournament_ids.setdefault(round_id, int(item.get("tournamentId") or 0))

            await store.upsert_round_live({
                "round_id": round_id, "provider": provider, "league": name,
                "home_team": home, "away_team": away, "scheduled_start": scheduled,
                "started_at": None, "home_score": hg, "away_score": ag,
                "time_sec": time_sec, "period_name": period,
                "tournament_id": item.get("tournamentId"),
                "api_event_id": item.get("sportEventId"),
                "api_const_event_id": const_id,
                "match_format": (item.get("matchInfoObject") or {}).get("matchFormat"),
                "home_logo": (item.get("imageOpponent1") or [None])[0],
                "away_logo": (item.get("imageOpponent2") or [None])[0],
                "source_ts": now_utc, "captured_at": now_utc,
            })

            # Événements dérivés des écarts de score RÉELS du flux
            prev = self._last_scores.get(round_id)
            if prev is None:
                await store.insert_live_event(round_id, minute, "KICKOFF",
                                              {"score": [hg, ag], "period": period})
            elif prev != (hg, ag) and hg is not None and ag is not None:
                ph, pa = prev
                if ph is not None and pa is not None:
                    if hg > ph:
                        await store.insert_live_event(round_id, minute, "GOAL_HOME",
                                                      {"from": [ph, pa], "to": [hg, ag], "period": period})
                    if ag > pa:
                        await store.insert_live_event(round_id, minute, "GOAL_AWAY",
                                                      {"from": [ph, pa], "to": [hg, ag], "period": period})
            if period and isinstance(period, str) and "1st" in period and prev is not None:
                pass  # les ticks de période sont portés par period_name sur virtual_rounds
            self._last_scores[round_id] = (hg, ag)
            self._seen_live[round_id] = period or ""

            await self._maybe_snapshot_odds(round_id, item, "LIVE", now_utc)

        # Sortie de live → conservation du dernier score connu (réel)
        for round_id in list(self._seen_live):
            if round_id not in seen_ids:
                self._seen_live.pop(round_id, None)

    # ---------------------------------------------------------- résultats
    async def _handle_results(self, now_epoch: int, now_utc: datetime) -> None:
        pending = await store.pending_results(limit=20)
        missing = await store.rounds_missing_result(limit=10)
        targets = {r["round_id"]: r for r in list(pending) + list(missing)}
        if not targets:
            return
        by_tournament: Dict[int, List[str]] = {}
        for r in targets.values():
            tid = int(r["tournament_id"] or 0)
            by_tournament.setdefault(tid, []).append(r["round_id"])
        # On interroge le résultat des tournois connus (fenêtre glissante 48 h).
        all_tids = [t for t in by_tournament if t]
        # Inclure les tournois réels référencés par provider (connus du flux).
        all_tids += [3105089, 2834136, 2876177]
        if not all_tids:
            return
        items = await asyncio.to_thread(
            self.client.fetch_results, all_tids, now_epoch - 6 * 3600, now_epoch + 60,
        )
        by_const: Dict[str, Dict[str, Any]] = {}
        for it in items:
            cid = it.get("constSportEventId") or it.get("sportEventId")
            if cid is not None:
                by_const[str(cid)] = it

        for round_id, row in targets.items():
            item = by_const.get(round_id)
            if not item:
                continue
            parsed = parse_score(item.get("score"))
            if not parsed:
                continue
            hg, ag, half = parsed
            closed_at = _epoch_to_dt(item.get("startDate")) or now_utc
            recorded = await store.upsert_result(round_id, hg, ag, item, "result_api", half)
            finished = await store.mark_finished(round_id, now_utc, hg, ag)
            if finished or recorded:
                await store.insert_live_event(round_id, None, "FULLTIME",
                                              {"score": [hg, ag], "half": half})
                if recorded:
                    await self._apply_ratings(row["provider"], row, hg, ag, round_id)

    async def _apply_ratings(self, provider: str, row: Any, hg: int, ag: int, round_id: str) -> None:
        try:
            await ratings_engine.apply_round(provider, row["home_team"], row["away_team"], hg, ag)
            await store.mark_ratings_applied(round_id)
        except Exception as exc:
            log.warning("Mise à jour ratings impossible pour %s : %s", round_id, exc)


ingestor = VirtualIngestor()
