"""
Client Partner API MegaPari — Football Virtuel.

Flux réel uniquement. La clé partenaire est lue côté serveur via le
gestionnaire de secrets ; sa valeur n'est JAMAIS journalisée ni renvoyée.
Toute absence/invalidité produit une erreur explicite (jamais silencieuse).
"""
from __future__ import annotations

import html
import logging
import os
import threading
import time
from typing import Any, Dict, List, Optional

import requests

from app.virtual import config as C

log = logging.getLogger("virtual.partner_client")


class PartnerAuthError(RuntimeError):
    """Clé partenaire absente, invalide ou expirée — échec explicite."""


class PartnerApiError(RuntimeError):
    """Erreur HTTP/flux du partenaire."""


def _unquote(raw: str) -> str:
    raw = raw.strip()
    if len(raw) >= 2 and raw[0] == raw[-1] and raw[0] in "\"'":
        raw = raw[1:-1]
    return raw


def _secret_candidate(raw: str) -> List[str]:
    """Le secret contient parfois des entités HTML (`&amp;`) → on tente les deux formes."""
    raw = _unquote(raw)
    decoded = html.unescape(raw)
    return [raw, decoded] if decoded != raw else [raw]


class PartnerClient:
    """Client OAuth2 + GET rate-limités (verres par catégorie de flux)."""

    def __init__(self, session: Optional[requests.Session] = None) -> None:
        self._session = session or requests.Session()
        self._lock = threading.Lock()
        self._token: Optional[str] = None
        self._token_expires_at: float = 0.0
        self._next_allowed: Dict[str, float] = {}

    # ------------------------------------------------------------- secrets
    @staticmethod
    def _credentials() -> tuple:
        cid = os.getenv(C.CLIENT_ID_ENV, "").strip()
        key = os.getenv(C.API_KEY_ENV, "").strip() or os.getenv(C.API_KEY_FALLBACK_ENV, "").strip()
        if not cid or not key:
            missing = [name for name, val in ((C.CLIENT_ID_ENV, cid),
                                              (C.API_KEY_ENV, key)) if not val]
            raise PartnerAuthError(
                "Clé partenaire MegaPari absente du gestionnaire de secrets serveur "
                f"(variables manquantes : {', '.join(missing) or C.API_KEY_ENV}) — "
                "démarrage impossible sans identifiants explicites."
            )
        return cid, key

    # --------------------------------------------------------------- token
    def token(self, force: bool = False) -> str:
        with self._lock:
            if not force and self._token and time.time() < self._token_expires_at - 60:
                return self._token
            client_id, client_secret = self._credentials()
            last_error = ""
            for candidate in _secret_candidate(client_secret):
                try:
                    resp = self._session.post(
                        C.BOOKMAKER_TOKEN_URL,
                        data={"client_id": client_id, "client_secret": candidate},
                        headers={"Content-Type": "application/x-www-form-urlencoded"},
                        timeout=25,
                    )
                except requests.RequestException as exc:
                    last_error = f"{type(exc).__name__}: {exc}"
                    continue
                if resp.status_code == 200:
                    payload = resp.json() or {}
                    token = payload.get("access_token")
                    if token:
                        self._token = token
                        self._token_expires_at = time.time() + float(payload.get("expires_in", 3600))
                        log.info("Token Partner API obtenu (validité %ss)", payload.get("expires_in"))
                        return token
                last_error = f"HTTP {resp.status_code} {(resp.text or '')[:120]}"
            # Échec EXPLICITE — jamais silencieux, jamais de secret dans le log.
            self._token = None
            raise PartnerAuthError(
                "Échec d'authentification Partner API MegaPari "
                f"(client_id={os.getenv(C.CLIENT_ID_ENV, '?')[:4]}…, identifiants invalides) : {last_error}"
            )

    # ---------------------------------------------------------------- GET
    def _throttle(self, kind: str, pause: float) -> None:
        with self._lock:
            now = time.time()
            wait = self._next_allowed.get(kind, 0.0) - now
            if wait > 0:
                time.sleep(wait)
            self._next_allowed[kind] = time.time() + pause

    def _get(self, path: str, params: Dict[str, Any], kind: str, pause: float) -> Any:
        self._throttle(kind, pause)
        url = C.BOOKMAKER_API_BASE + path
        for attempt in range(3):
            token = self.token()
            resp = self._session.get(
                url, params=params,
                headers={"Authorization": f"Bearer {token}"}, timeout=40,
            )
            if resp.status_code in (401, 403) and attempt == 0:
                self.token(force=True)   # expiration → renouvellement explicite
                continue
            if resp.status_code == 200:
                try:
                    return resp.json()
                except ValueError as exc:
                    raise PartnerApiError(f"Réponse illisible sur {path} : {exc}") from exc
            if resp.status_code == 429 or resp.status_code >= 500:
                time.sleep(2 ** attempt * pause)
                continue
            raise PartnerApiError(f"HTTP {resp.status_code} sur {path} : {(resp.text or '')[:160]}")
        raise PartnerApiError(f"Rate limit/indisponibilité persistante sur {path}")

    # ------------------------------------------------------------ flux réels
    def fetch_prematch(self, count: int = 1000) -> List[Dict[str, Any]]:
        """LoadSingle prematch — rounds à venir + TOUTES les cotes (GetAllOdds)."""
        data = self._get(
            "/datafeed/prematch/api/v2/sportevents",
            {
                "ref": C.MEGAPARI_REF, "lng": "en", "sportIds": 1,
                "count": count, "periods": "0",
                "schemeOfGettingOddsOperations": "GetAllOdds",
            },
            kind="prematch", pause=C.PAUSE_LINE,
        )
        return list((data or {}).get("items") or [])

    def fetch_live(self, count: int = 1000) -> List[Dict[str, Any]]:
        """LoadSingle live — scores, minutes, cotes en cours."""
        data = self._get(
            "/datafeed/live/api/v2/sportevents",
            {
                "ref": C.MEGAPARI_REF, "lng": "en", "sportIds": 1,
                "count": count, "periods": "0",
                "schemeOfGettingOddsOperations": "GetMainOdds",
            },
            kind="live", pause=C.PAUSE_LIVE,
        )
        return list((data or {}).get("items") or [])

    def fetch_results(self, tournament_ids: List[int], date_from: int, date_to: int) -> List[Dict[str, Any]]:
        """Résultats réels (result/api/v1/sportevents) — fenêtre ≤ 48 h."""
        if not tournament_ids:
            return []
        date_from = max(int(date_from), int(date_to) - 48 * 3600 + 60)
        data = self._get(
            "/result/api/v1/sportevents",
            {
                "ref": C.MEGAPARI_REF, "lng": "en",
                "tournamentIds": ",".join(str(t) for t in sorted(set(tournament_ids))),
                "dateFrom": int(date_from), "dateTo": int(date_to),
            },
            kind="result", pause=C.PAUSE_RESULT,
        )
        return list((data or {}).get("items") or [])
