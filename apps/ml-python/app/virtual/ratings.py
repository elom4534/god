"""
Pipeline d'apprentissage Football Virtuel.

- Ratings Dixon-Coles + Elo PAR PROVIDER (jamais mélangés), mis à jour
  incrémentalement à chaque round FINISHED.
- Affinement LightGBM (optionnel, mélange avec le Poisson Dixon-Coles).
- Détection de dérive (drift) → reset partiel des forces vers la moyenne.
- Les prédictions restent en « Calibration en cours » tant que la capture
  réelle < 24 h ou l'échantillon < 100 rounds (aucune donnée inventée).
"""
from __future__ import annotations

import logging
import math
import random
from collections import defaultdict, deque
from dataclasses import dataclass, field
from datetime import datetime, timezone
from typing import Any, Deque, Dict, List, Optional, Tuple

from app.virtual import config as C

log = logging.getLogger("virtual.ratings")

try:  # affinement optionnel
    import lightgbm as lgb
    _HAS_LGB = True
except Exception:  # pragma: no cover — silencieux si indisponible
    lgb = None
    _HAS_LGB = False

try:
    import numpy as np
    _HAS_NP = True
except Exception:  # pragma: no cover
    np = None
    _HAS_NP = False

RHO = -0.13          # correction Dixon-Coles bas scores
ELO_K = 20.0
ELO_HOME_ADV = 60.0  # Elo points d'avantage domicile (par provider)
LR = 0.05            # pas de mise à jour attaque/défense
MAX_GOALS = 12


@dataclass
class ProviderModel:
    provider: str
    elo: Dict[str, float] = field(default_factory=lambda: defaultdict(lambda: 1500.0))
    att: Dict[str, float] = field(default_factory=lambda: defaultdict(float))
    defense: Dict[str, float] = field(default_factory=lambda: defaultdict(float))
    home_adv: float = 0.12           # log-buts d'avantage domicile
    matches: Dict[str, int] = field(default_factory=lambda: defaultdict(int))
    rounds_seen: int = 0
    brier_history: Deque[float] = field(default_factory=lambda: deque(maxlen=C.DRIFT_WINDOW))
    brier_global: Deque[float] = field(default_factory=lambda: deque(maxlen=500))
    lgbm_model: Any = None
    lgbm_trained_at: int = 0
    features: List[List[float]] = field(default_factory=list)
    labels: List[int] = field(default_factory=list)
    rng: random.Random = field(default_factory=lambda: random.Random(20261021))


class RatingsEngine:
    """Moteur de ratings + prédictions, un modèle isolé par provider."""

    def __init__(self) -> None:
        self.models: Dict[str, ProviderModel] = {}
        self._loaded = False

    # ---------------------------------------------------------------- état
    def model(self, provider: str) -> ProviderModel:
        if provider not in self.models:
            self.models[provider] = ProviderModel(provider=provider)
        return self.models[provider]

    async def load_from_db(self) -> None:
        """Charge l'état persisté (ratings + compteurs) au démarrage."""
        from app.virtual import store
        try:
            rows = await store.ratings_rows()
            for r in rows:
                m = self.model(r["provider"])
                m.elo[r["team"]] = float(r["elo_rating"])
                m.att[r["team"]] = float(r["attack_rating"])
                m.defense[r["team"]] = float(r["defense_rating"])
                m.matches[r["team"]] = int(r["matches_count"])
            for provider in C.PROVIDERS:
                self.model(provider).rounds_seen = await store.sample_size(provider)
            self._loaded = True
            log.info("Ratings chargés (%d équipes, échantillons %s)",
                     len(rows), {p: self.model(p).rounds_seen for p in self.models})
        except Exception as exc:
            log.warning("Chargement ratings impossible (premier démarrage ?) : %s", exc)

    # --------------------------------------------------------- prédictions
    @staticmethod
    def _poisson(lam: float, k: int) -> float:
        return math.exp(-lam) * lam ** k / math.factorial(k)

    def _tau(self, i: int, j: int, lam_h: float, lam_a: float) -> float:
        if i == 0 and j == 0:
            return 1 - lam_h * lam_a * RHO
        if i == 0 and j == 1:
            return 1 + lam_h * RHO
        if i == 1 and j == 0:
            return 1 + lam_a * RHO
        if i == 1 and j == 1:
            return 1 - RHO
        return 1.0

    def expected_goals(self, m: ProviderModel, home: str, away: str) -> Tuple[float, float]:
        lam_h = math.exp(m.home_adv + m.att[home] - m.defense[away])
        lam_a = math.exp(m.att[away] - m.defense[home])
        return max(0.05, min(lam_h, 8.0)), max(0.05, min(lam_a, 8.0))

    def outcome_grid(self, m: ProviderModel, home: str, away: str) -> Dict[str, float]:
        lam_h, lam_a = self.expected_goals(m, home, away)
        p1 = px = p2 = 0.0
        btts = over25 = 0.0
        score_matrix: Dict[Tuple[int, int], float] = {}
        for i in range(MAX_GOALS + 1):
            for j in range(MAX_GOALS + 1):
                p = self._poisson(lam_h, i) * self._poisson(lam_a, j) * self._tau(i, j, lam_h, lam_a)
                p = max(p, 0.0)
                score_matrix[(i, j)] = p
                if i > j:
                    p1 += p
                elif i == j:
                    px += p
                else:
                    p2 += p
                if i > 0 and j > 0:
                    btts += p
                if i + j > 2.5:
                    over25 += p
        total = p1 + px + p2 or 1.0
        return {
            "p_home": p1 / total, "p_draw": px / total, "p_away": p2 / total,
            "p_btts_yes": btts / total, "p_over_2_5": over25 / total,
            "lambda_home": lam_h, "lambda_away": lam_a,
        }

    def _lgbm_probs(self, m: ProviderModel, home: str, away: str) -> Optional[Dict[str, float]]:
        if not (_HAS_LGB and _HAS_NP and m.lgbm_model is not None):
            return None
        feats = self._features(m, home, away)
        try:
            proba = m.lgbm_model.predict(np.array([feats]))[0]
            return {"p_home": float(proba[0]), "p_draw": float(proba[1]), "p_away": float(proba[2])}
        except Exception as exc:  # pragma: no cover
            log.warning("LightGBM predict indisponible : %s", exc)
            return None

    @staticmethod
    def _features(m: ProviderModel, home: str, away: str) -> List[float]:
        return [
            m.elo[home] - m.elo[away],
            m.att[home], m.att[away], m.defense[home], m.defense[away],
            m.home_adv,
        ]

    def predict(self, provider: str, home: str, away: str) -> Dict[str, float]:
        m = self.model(provider)
        probs = self.outcome_grid(m, home, away)
        refined = self._lgbm_probs(m, home, away)
        if refined:
            w = C.LGBM_BLEND
            probs = dict(probs)
            probs["p_home"] = (1 - w) * probs["p_home"] + w * refined["p_home"]
            probs["p_draw"] = (1 - w) * probs["p_draw"] + w * refined["p_draw"]
            probs["p_away"] = (1 - w) * probs["p_away"] + w * refined["p_away"]
            probs["model"] = f"dixon-coles+lgbm(x{w})"
        else:
            probs = dict(probs)
            probs["model"] = "dixon-coles+elo"
        return probs

    # --------------------------------------------------- mise à jour fin de round
    async def apply_round(self, provider: str, home: str, away: str, hg: int, ag: int) -> None:
        m = self.model(provider)
        lam_h, lam_a = self.expected_goals(m, home, away)

        # 1) Elo (résultat 1X2, avantage domicile)
        exp_h = 1.0 / (1 + 10 ** -((m.elo[home] + ELO_HOME_ADV - m.elo[away]) / 400))
        s_h = 1.0 if hg > ag else (0.5 if hg == ag else 0.0)
        diff = abs(hg - ag)
        k_mult = 1 + math.log(1 + diff) * 0.35
        delta = ELO_K * k_mult * (s_h - exp_h)
        m.elo[home] += delta
        m.elo[away] -= delta

        # 2) Dixon-Coles : un pas de gradient du log-vraisemblance Poisson
        m.att[home] += LR * (hg - lam_h)
        m.defense[away] += LR * (hg - lam_h)
        m.att[away] += LR * (ag - lam_a)
        m.defense[home] += LR * (ag - lam_a)
        m.home_adv = max(-0.3, min(0.5, m.home_adv + 0.01 * ((hg - lam_h) + (ag - lam_a)) * 0.1))
        m.matches[home] += 1
        m.matches[away] += 1
        m.rounds_seen += 1

        # 3) Dérive : Brier du dernier résultat vs proba du modèle
        probs = self.outcome_grid(m, home, away)
        outcome = [1.0 if hg > ag else 0.0, 1.0 if hg == ag else 0.0, 1.0 if ag > hg else 0.0]
        brier = sum((probs[k] - o) ** 2 for k, o in
                    zip(("p_home", "p_draw", "p_away"), outcome)) / 3.0
        m.brier_history.append(brier)
        m.brier_global.append(brier)
        self._check_drift(m)

        # 4) Affinement LightGBM (réentraînement périodique si échantillon suffisant)
        m.features.append(self._features(m, home, away))
        m.labels.append(0 if hg > ag else (1 if hg == ag else 2))
        if _HAS_LGB and _HAS_NP and len(m.labels) >= C.MIN_OBSERVATIONS and \
                len(m.labels) - m.lgbm_trained_at >= 25:
            self._train_lgbm(m)

        await self._persist(m, home, away)

    def _check_drift(self, m: ProviderModel) -> None:
        if len(m.brier_history) < max(10, C.DRIFT_WINDOW // 2) or len(m.brier_global) < 30:
            return
        recent = sum(m.brier_history) / len(m.brier_history)
        baseline = sum(m.brier_global) / len(m.brier_global)
        if baseline > 0 and recent > C.DRIFT_FACTOR * baseline:
            # Reset PARTIEL : repli des forces vers la moyenne du provider
            for team in list(m.att):
                m.att[team] *= 0.5
                m.defense[team] *= 0.5
                m.elo[team] = 1500 + (m.elo[team] - 1500) * 0.5
            m.brier_history.clear()
            log.warning("Drift détecté sur %s (Brier récent %.3f > %.2f× base %.3f) — reset partiel",
                        m.provider, recent, C.DRIFT_FACTOR, baseline)

    def _train_lgbm(self, m: ProviderModel) -> None:  # pragma: no cover — optionnel
        try:
            train = lgb.Dataset(np.array(m.features), label=np.array(m.labels))
            m.lgbm_model = lgb.train(
                {"objective": "multiclass", "num_class": 3, "verbosity": -1,
                 "num_leaves": 15, "min_data_in_leaf": 10},
                train, num_boost_round=60,
            )
            m.lgbm_trained_at = len(m.labels)
            log.info("LightGBM réentraîné sur %s (%d rounds)", m.provider, len(m.labels))
        except Exception as exc:
            log.warning("Entraînement LightGBM impossible : %s", exc)

    async def _persist(self, m: ProviderModel, home: str, away: str) -> None:
        from app.virtual import store
        for team in (home, away):
            await store.upsert_rating(
                m.provider, team, round(m.elo[team], 2),
                round(m.att[team], 4), round(m.defense[team], 4), m.matches[team],
            )

    # ------------------------------------------------------------ garanties
    def calibration_state(self, provider: str, capture_started: Optional[datetime],
                          sample: int) -> Dict[str, Any]:
        now = datetime.now(timezone.utc)
        capture_hours = 0.0
        if capture_started is not None:
            started = capture_started if capture_started.tzinfo else capture_started.replace(tzinfo=timezone.utc)
            capture_hours = max(0.0, (now - started).total_seconds() / 3600.0)
        ready = sample >= C.MIN_OBSERVATIONS and capture_hours >= C.CALIBRATION_MIN_HOURS
        return {
            "sample_size": sample,
            "capture_hours": round(capture_hours, 2),
            "min_observations": C.MIN_OBSERVATIONS,
            "min_capture_hours": C.CALIBRATION_MIN_HOURS,
            "calibration_in_progress": not ready,
        }

    @staticmethod
    def _prob_for(probs: Dict[str, float], market: str, selection: str, line: Any) -> Optional[float]:
        if market == "1X2":
            return {"1": probs.get("p_home"), "X": probs.get("p_draw"),
                    "2": probs.get("p_away")}.get(selection)
        if market == "BTTS":
            return probs.get("p_btts_yes") if selection == "YES" else 1 - probs.get("p_btts_yes", 0)
        if market == "TOTAL" and line is not None and abs(float(line) - 2.5) < 1e-9:
            return probs.get("p_over_2_5") if selection == "OVER" else 1 - probs.get("p_over_2_5", 0)
        return None

    def value_bets(self, probs: Dict[str, float], odds: List[Dict[str, Any]],
                   ready: bool) -> List[Dict[str, Any]]:
        """Value bet UNIQUEMENT si significatif (edge ≥ seuil) et calibré."""
        if not ready:
            return []
        out: List[Dict[str, Any]] = []
        for o in odds:
            p = self._prob_for(probs, o.get("market"), o.get("selection"), o.get("line"))
            if p is None or not o.get("odds"):
                continue
            edge = p * float(o["odds"]) - 1.0
            if edge >= C.VALUE_MIN_EDGE:
                out.append({
                    "market": o.get("market"), "selection": o.get("selection"),
                    "line": o.get("line"), "odds": float(o["odds"]),
                    "probability": round(p, 4), "edge": round(edge, 4),
                })
        return sorted(out, key=lambda x: -x["edge"])


engine = RatingsEngine()
