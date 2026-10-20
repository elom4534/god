"""
Prediction Engine — Moteur de prédiction football opérationnel
Stack: PostgreSQL (events + match_stats) + Redis + Dixon-Coles + CatBoost/LightGBM + Value Betting

Cycle:
  1. Dixon-Coles: forces attaque/défense estimées depuis historique FINISHED (events + match_stats)
  2. ML: CatBoost/LightGBM sur features avant-match (H2H, xG récents, forme, Dixon-Coles lambdas) → probas 1X2 / O/U
  3. Calibration isotonic + Value Betting: P_modèle vs cote implicite MarginGuard ≤5% → EV = P*Cote -1 → sélections à forte valeur

Auteur: Data Science — Football Modelling (Poisson bivariée, Dixon-Coles 1997)
Fail-Closed: pas de prédiction si historique insuffisant ou marge >5%
"""
import math
import logging
from dataclasses import dataclass, field
from datetime import datetime, timezone
from typing import Dict, List, Optional, Tuple, Any

import numpy as np
import pandas as pd

try:
    import asyncpg  # asyncpg pour PostgreSQL
except ImportError:
    asyncpg = None

try:
    import redis.asyncio as redis
except ImportError:
    redis = None

from sklearn.isotonic import IsotonicRegression
from sklearn.linear_model import LogisticRegression
from scipy.optimize import minimize

# CatBoost / LightGBM optionnels (fallback sklearn si absents)
try:
    from catboost import CatBoostClassifier, Pool
    HAS_CATBOOST = True
except ImportError:
    HAS_CATBOOST = False
    CatBoostClassifier = None

try:
    import lightgbm as lgb
    HAS_LIGHTGBM = True
except ImportError:
    HAS_LIGHTGBM = False

logger = logging.getLogger(__name__)

# ============================================================================
# 1. PARAMÈTRES DIXON-COLES
# ============================================================================

@dataclass
class DixonColesParams:
    """Paramètres estimés par MLE depuis historique"""
    attack: Dict[str, float] = field(default_factory=dict)  # team -> force attaque α_i
    defence: Dict[str, float] = field(default_factory=dict)  # team -> force défense β_i
    rho: float = 0.08          # correction scores faibles (0-0,1-0,0-1,1-1) — estimé, typiquement 0.05-0.15
    home_adv: float = 0.25     # avantage domicile en log(λ) — ~ exp(0.25)=1.28x plus de buts
    fitted_at: Optional[str] = None
    n_matches: int = 0


def poisson_pmf(k: int, lam: float) -> float:
    if lam <= 0:
        return 1.0 if k == 0 else 0.0
    return (lam ** k) * math.exp(-lam) / math.factorial(k)


def dixon_coles_correction(i: int, j: int, lam_h: float, lam_a: float, rho: float) -> float:
    """τ(i,j) facteur Dixon-Coles — uniquement pour i,j ∈ {0,1}"""
    if i == 0 and j == 0:
        return 1 - lam_a * rho
    if i == 0 and j == 1:
        return 1 + lam_h * rho
    if i == 1 and j == 0:
        return 1 + lam_a * rho
    if i == 1 and j == 1:
        return 1 - rho
    return 1.0


def score_matrix_probs(lam_h: float, lam_a: float, rho: float, max_goals: int = 10) -> np.ndarray:
    """Matrice P(i,j) = Poisson(λ_h,i)*Poisson(λ_a,j)*τ(i,j) normalisée"""
    mat = np.zeros((max_goals + 1, max_goals + 1))
    for i in range(max_goals + 1):
        for j in range(max_goals + 1):
            p = poisson_pmf(i, lam_h) * poisson_pmf(j, lam_a) * dixon_coles_correction(i, j, lam_h, lam_a, rho)
            mat[i, j] = max(p, 0)
    mat /= mat.sum()
    return mat


def DixonColes_1X2_and_OU(lam_h: float, lam_a: float, rho: float, max_goals: int = 10, ou_line: float = 2.5
                         ) -> Dict[str, float]:
    """Depuis λ_h, λ_a → probas 1X2 + Over/Under"""
    mat = score_matrix_probs(lam_h, lam_a, rho, max_goals)
    p_home = float(np.tril(mat, k=-1).sum() + np.triu(mat, k=1).T.sum() if False else 0)
    # Plus simple: somme diagonales
    p_home = float(sum(mat[i, j] for i in range(max_goals+1) for j in range(max_goals+1) if i > j))
    p_draw = float(sum(mat[i, j] for i in range(max_goals+1) for j in range(max_goals+1) if i == j))
    p_away = float(sum(mat[i, j] for i in range(max_goals+1) for j in range(max_goals+1) if i < j))
    # O/U via total buts
    total_probs = np.zeros(2 * max_goals + 1)
    for i in range(max_goals+1):
        for j in range(max_goals+1):
            total_probs[i + j] += mat[i, j]
    # P(Over line) : line 2.5 → total >=3
    k_line = int(math.floor(ou_line))
    p_under = float(total_probs[:k_line+1].sum())
    p_over = 1.0 - p_under
    # BTTS: i>=1 et j>=1
    p_btts_yes = float(sum(mat[i, j] for i in range(1, max_goals+1) for j in range(1, max_goals+1)))
    p_btts_no = 1.0 - p_btts_yes
    return {
        "1": p_home, "X": p_draw, "2": p_away,
        "OVER": p_over, "UNDER": p_under,
        "BTTS_YES": p_btts_yes, "BTTS_NO": p_btts_no,
        "lambda_home": lam_h, "lambda_away": lam_a, "rho": rho,
    }


# ============================================================================
# 1. Estimation forces attaque/défense (MLE)
# ============================================================================

class DixonColesEstimator:
    """
    MLE Dixon-Coles depuis events (FINISHED) + match_stats (xG, scores).
    Modèle: λ_home = exp(home_adv + α_home - β_away), λ_away = exp(α_away - β_home)
    Contrainte d'identifiabilité: mean(α)=0, mean(β)=0
    """

    def __init__(self, home_adv_init: float = 0.25, rho_init: float = 0.08):
        self.home_adv_init = home_adv_init
        self.rho_init = rho_init

    def _prepare_df(self, df: pd.DataFrame) -> pd.DataFrame:
        """Attend colonnes: home_team, away_team, home_goals, away_goals"""
        needed = {"home_team", "away_team", "home_goals", "away_goals"}
        if not needed.issubset(df.columns):
            raise ValueError(f"DataFrame doit contenir {needed}, reçu {list(df.columns)}")
        df = df.copy()
        df = df.dropna(subset=["home_team", "away_team", "home_goals", "away_goals"])
        # Normalise noms équipes
        df["home_team"] = df["home_team"].str.strip()
        df["away_team"] = df["away_team"].str.strip()
        return df

    def _neg_loglik(self, x: np.ndarray, teams: List[str], df: pd.DataFrame) -> float:
        """
        x = [α_0...α_{n-1}, β_0...β_{n-1}, home_adv, rho]
        Contrainte sum α=0, sum β=0 gérée par pénalité douce
        """
        n = len(teams)
        team_to_idx = {t: i for i, t in enumerate(teams)}
        alpha = x[:n]
        beta = x[n:2*n]
        home_adv = x[2*n]
        rho = x[2*n+1]
        # Pénalité identifiabilité
        penalty = 1e3 * (alpha.sum()**2 + beta.sum()**2)
        # Clip rho pour stabilité
        if not (-0.3 <= rho <= 0.3):
            return 1e9
        nll = 0.0
        eps = 1e-12
        for _, row in df.iterrows():
            hi = team_to_idx[row["home_team"]]
            ai = team_to_idx[row["away_team"]]
            lam_h = math.exp(home_adv + alpha[hi] - beta[ai])
            lam_a = math.exp(alpha[ai] - beta[hi])
            i_goals = int(row["home_goals"])
            j_goals = int(row["away_goals"])
            # Poisson + correction
            p = poisson_pmf(i_goals, lam_h) * poisson_pmf(j_goals, lam_a) * dixon_coles_correction(i_goals, j_goals, lam_h, lam_a, rho)
            p = max(p, eps)
            nll -= math.log(p)
        return nll + penalty

    def fit(self, df: pd.DataFrame, max_iter: int = 800) -> DixonColesParams:
        df = self._prepare_df(df)
        if len(df) < 30:
            raise ValueError(f"Historique insuffisant pour Dixon-Coles: {len(df)} matchs < 30 (Fail-Closed)")
        teams = sorted(set(df["home_team"].unique().tolist() + df["away_team"].unique().tolist()))
        n = len(teams)
        logger.info(f"[DixonColes] fit sur {len(df)} matchs, {n} équipes, home_adv_init={self.home_adv_init}, rho_init={self.rho_init}")
        # Init
        x0 = np.zeros(2*n + 2)
        x0[2*n] = self.home_adv_init
        x0[2*n+1] = self.rho_init
        # Bornes: alpha/beta ∈ [-1.5,1.5], home_adv ∈ [-0.5,0.8], rho ∈ [-0.3,0.3]
        bounds = [(-1.5, 1.5)]*n + [(-1.5, 1.5)]*n + [(-0.5, 0.8), (-0.3, 0.3)]
        res = minimize(self._neg_loglik, x0, args=(teams, df), method="L-BFGS-B", bounds=bounds,
                       options={"maxiter": max_iter, "ftol": 1e-8})
        if not res.success:
            logger.warning(f"[DixonColes] minimize non convergé: {res.message}")
        x = res.x
        alpha = x[:n]
        beta = x[n:2*n]
        home_adv = float(x[2*n])
        rho = float(x[2*n+1])
        # Recentrage pour identifiabilité (moyenne nulle)
        alpha = alpha - alpha.mean()
        beta = beta - beta.mean()
        params = DixonColesParams(
            attack={t: float(a) for t, a in zip(teams, alpha)},
            defence={t: float(b) for t, b in zip(teams, beta)},
            rho=rho,
            home_adv=home_adv,
            fitted_at=datetime.now(timezone.utc).isoformat(),
            n_matches=len(df),
        )
        logger.info(f"[DixonColes] fitted rho={rho:.4f} home_adv={home_adv:.4f} (n={len(df)})")
        return params

    def lambdas(self, home_team: str, away_team: str, params: DixonColesParams) -> Tuple[float, float]:
        """λ pour un match à venir — Fail-Closed si équipe inconnue"""
        if home_team not in params.attack or away_team not in params.attack:
            raise KeyError(f"Équipe inconnue Dixon-Coles: {home_team} ou {away_team} (historique insuffisant → Fail-Closed)")
        lam_h = math.exp(params.home_adv + params.attack[home_team] - params.defence[away_team])
        lam_a = math.exp(params.attack[away_team] - params.defence[home_team])
        # Clip pour éviter explosions
        lam_h = min(max(lam_h, 0.1), 5.0)
        lam_a = min(max(lam_a, 0.1), 5.0)
        return lam_h, lam_a


# ============================================================================
# 2. ML — CatBoost / LightGBM
# ============================================================================

@dataclass
class MLConfig:
    model_type: str = "catboost"  # catboost | lightgbm | sklearn_fallback
    iterations: int = 600
    depth: int = 6
    learning_rate: float = 0.04
    l2_leaf_reg: float = 3.0
    random_seed: int = 42
    early_stopping_rounds: int = 50


class FootballMLModel:
    """
    ML sur features avant-match:
      - Dixon-Coles lambdas (home/away + rho)
      - H2H: win_rate, avg_goals, dernier face-à-face
      - Forme récente: xG_5m, xGA_5m, points_5m, corners_5m
      - Contexte: is_home, days_rest, possession_avg
    Cibles: 1X2 (multiclass) et Over/Under 2.5 (binaire) — deux modèles légers
    """

    def __init__(self, config: MLConfig = MLConfig()):
        self.config = config
        self.model_1x2 = None
        self.model_ou = None
        self.feature_names_: List[str] = []
        self.is_fitted = False

    def _build_features(self, df_matches: pd.DataFrame, df_stats: pd.DataFrame, params: DixonColesParams) -> pd.DataFrame:
        """
        Construit X depuis events + match_stats. Exemple minimal — à enrichir avec H2H réel en prod.
        df_matches: events FINISHED (id, home_team, away_team, start_time, final_score)
        df_stats: match_stats (event_id, xg, xga, corners, possession, ...)
        """
        # Jointure simple pour demo — en prod: utiliser window 5 derniers matchs, H2H, etc.
        df = df_matches.merge(df_stats, left_on="id", right_on="event_id", how="left", suffixes=("", "_stats"))
        feats = []
        for _, row in df.iterrows():
            try:
                lam_h, lam_a = DixonColesEstimator().lambdas(row["home_team"], row["away_team"], params)
            except KeyError:
                lam_h, lam_a = 1.3, 1.1  # fallback neutre si équipe nouvelle — pénalisera la confiance
            # xG récents (moyenne 5 derniers) — ici on prend le match lui-même pour demo, en prod: rolling
            xg_h = (row.get("xg") or {}).get("home") if isinstance(row.get("xg"), dict) else None
            # Simplifié: si xG manquant, utiliser lam comme proxy
            if xg_h is None:
                xg_h = lam_h
            feats.append({
                "lambda_home": lam_h,
                "lambda_away": lam_a,
                "lambda_diff": lam_h - lam_a,
                "lambda_total": lam_h + lam_a,
                "rho": params.rho,
                "home_adv": params.home_adv,
                # Placeholders — en prod: calculer depuis historique fenêtré
                "xg_home_5m": xg_h,
                "xga_home_5m": (row.get("xga") or {}).get("home", 1.0) if isinstance(row.get("xga"), dict) else 1.0,
                "is_big_match": 1 if row.get("league") in {"Premier League", "La Liga"} else 0,
            })
        X = pd.DataFrame(feats)
        self.feature_names_ = list(X.columns)
        return X

    def _build_targets(self, df_matches: pd.DataFrame) -> Tuple[pd.Series, pd.Series]:
        """y_1x2: 0=1,1=X,2=2 ; y_ou: 0=Under,1=Over"""
        y_1x2 = []
        y_ou = []
        for _, row in df_matches.iterrows():
            fs = row.get("final_score") or {}
            if isinstance(fs, str):
                import json
                try:
                    fs = json.loads(fs)
                except Exception:
                    fs = {}
            hg = fs.get("home")
            ag = fs.get("away")
            if hg is None or ag is None:
                hg, ag = row.get("home_goals", 0), row.get("away_goals", 0)
            # 1X2
            if hg > ag:
                y_1x2.append(0)
            elif hg == ag:
                y_1x2.append(1)
            else:
                y_1x2.append(2)
            # O/U 2.5
            y_ou.append(1 if (hg + ag) > 2.5 else 0)
        return pd.Series(y_1x2, name="y_1x2"), pd.Series(y_ou, name="y_ou")

    def fit(self, df_matches: pd.DataFrame, df_stats: pd.DataFrame, params: DixonColesParams) -> "FootballMLModel":
        if len(df_matches) < 50:
            raise ValueError(f"Pas assez de matchs FINISHED pour ML: {len(df_matches)} < 50 (Fail-Closed)")
        X = self._build_features(df_matches, df_stats, params)
        y_1x2, y_ou = self._build_targets(df_matches)
        logger.info(f"[ML] fit X={X.shape}, y_1x2 distr={y_1x2.value_counts().to_dict()}, y_ou={y_ou.mean():.2f}")

        if self.config.model_type == "catboost" and HAS_CATBOOST:
            # CatBoost 1X2 multiclass
            self.model_1x2 = CatBoostClassifier(
                iterations=self.config.iterations, depth=self.config.depth, learning_rate=self.config.learning_rate,
                l2_leaf_reg=self.config.l2_leaf_reg, random_seed=self.config.random_seed,
                loss_function="MultiClass", verbose=False, allow_writing_files=False,
            )
            self.model_1x2.fit(X, y_1x2)
            # CatBoost O/U binaire
            self.model_ou = CatBoostClassifier(
                iterations=self.config.iterations, depth=self.config.depth, learning_rate=self.config.learning_rate,
                l2_leaf_reg=self.config.l2_leaf_reg, random_seed=self.config.random_seed,
                loss_function="Logloss", verbose=False, allow_writing_files=False,
            )
            self.model_ou.fit(X, y_ou)
        elif self.config.model_type == "lightgbm" and HAS_LIGHTGBM:
            self.model_1x2 = lgb.LGBMClassifier(n_estimators=self.config.iterations, max_depth=self.config.depth, learning_rate=self.config.learning_rate, verbose=-1)
            self.model_1x2.fit(X, y_1x2)
            self.model_ou = lgb.LGBMClassifier(n_estimators=self.config.iterations, max_depth=self.config.depth, learning_rate=self.config.learning_rate, verbose=-1)
            self.model_ou.fit(X, y_ou)
        else:
            # Fallback sklearn LogisticRegression
            logger.warning("[ML] CatBoost/LightGBM non dispo → fallback LogisticRegression")
            from sklearn.linear_model import LogisticRegression
            self.model_1x2 = LogisticRegression(multi_class="multinomial", max_iter=500)
            self.model_1x2.fit(X, y_1x2)
            self.model_ou = LogisticRegression(max_iter=500)
            self.model_ou.fit(X, y_ou)

        self.is_fitted = True
        logger.info("[ML] modèles entraînés (1X2 + O/U)")
        return self

    def predict_proba(self, X: pd.DataFrame) -> Dict[str, np.ndarray]:
        if not self.is_fitted:
            raise RuntimeError("Modèle ML non entraîné — appeler fit() d'abord (Fail-Closed)")
        # Align colonnes
        for col in self.feature_names_:
            if col not in X.columns:
                X[col] = 0.0
        X = X[self.feature_names_]
        proba_1x2 = self.model_1x2.predict_proba(X)  # shape (n,3)
        proba_ou = self.model_ou.predict_proba(X)[:, 1]  # P(Over)
        return {"1X2": proba_1x2, "OU": proba_ou}

    def save(self, path: str):
        import pickle
        with open(path, "wb") as f:
            pickle.dump({"model_1x2": self.model_1x2, "model_ou": self.model_ou, "feature_names": self.feature_names_, "config": self.config}, f)

    @classmethod
    def load(cls, path: str) -> "FootballMLModel":
        import pickle
        with open(path, "rb") as f:
            obj = pickle.load(f)
        inst = cls(config=obj["config"])
        inst.model_1x2 = obj["model_1x2"]
        inst.model_ou = obj["model_ou"]
        inst.feature_names_ = obj["feature_names"]
        inst.is_fitted = True
        return inst


# ============================================================================
# 2b. Calibration
# ============================================================================

class Calibrator:
    """Isotonic (préféré) ou Platt — calibré sur validation out-of-time"""

    def __init__(self, method: str = "isotonic"):
        self.method = method
        self.calibrators: Dict[str, Any] = {}

    def fit(self, y_true: np.ndarray, p_pred: np.ndarray, key: str):
        if self.method == "isotonic":
            cal = IsotonicRegression(out_of_bounds="clip")
            cal.fit(p_pred, y_true)
        else:
            cal = LogisticRegression()
            cal.fit(p_pred.reshape(-1, 1), y_true)
        self.calibrators[key] = cal
        return cal

    def transform(self, p_pred: np.ndarray, key: str) -> np.ndarray:
        cal = self.calibrators.get(key)
        if cal is None:
            return p_pred
        if isinstance(cal, IsotonicRegression):
            return cal.predict(p_pred)
        else:
            return cal.predict_proba(p_pred.reshape(-1, 1))[:, 1]

    def fit_1x2(self, y_true_1x2: np.ndarray, proba_1x2: np.ndarray):
        """Calibre chaque classe 1/X/2 en one-vs-rest"""
        for idx, label in enumerate(["1", "X", "2"]):
            y_bin = (y_true_1x2 == idx).astype(int)
            p_bin = proba_1x2[:, idx]
            self.fit(y_bin, p_bin, f"1X2_{label}")
        return self

    def transform_1x2(self, proba_1x2: np.ndarray) -> np.ndarray:
        calibrated = np.zeros_like(proba_1x2)
        for idx, label in enumerate(["1", "X", "2"]):
            calibrated[:, idx] = self.transform(proba_1x2[:, idx], f"1X2_{label}")
        # Renormalise pour somme=1
        row_sums = calibrated.sum(axis=1, keepdims=True)
        row_sums[row_sums == 0] = 1
        return calibrated / row_sums

# ============================================================================
# 3. Value Betting — P_modèle vs cote implicite MarginGuard
# ============================================================================

@dataclass
class MarketOdds:
    market_type: str  # 1X2, OVER_UNDER, BTTS, etc.
    selection: str    # 1, X, 2, OVER, UNDER, YES, NO
    odds: float       # cote décimale (ex: 1.95) — depuis MarginGuard ≤5%
    margin: float     # marge du marché (doit être ≤5%)
    line: Optional[float] = None  # pour O/U: 2.5

@dataclass
class ValuePick:
    event_id: str
    market_type: str
    selection: str
    p_model: float
    p_calibrated: float
    odds: float
    margin: float
    ev: float         # (P * cote) -1
    edge: float       # P - P_implicite
    line: Optional[float] = None
    confidence: str = "MEDIUM"  # LOW/MEDIUM/HIGH basé sur calibration + historique
    reason: str = ""

class ValueBettingEngine:
    """
    Compare P_modèle calibrée vs cote implicite bookmaker (1/cote) filtrée ≤5%.
    Retourne uniquement sélections à forte valeur et marge stricte.
    """

    def __init__(self, min_ev: float = 0.03, min_edge: float = 0.02, min_p: float = 0.04):
        self.min_ev = min_ev      # EV minimal 3% → filtre bruit
        self.min_edge = min_edge  # edge minimal 2%
        self.min_p = min_p        # probabilité minimale 4% (évite cotes extrêmes non fiables)

    def evaluate(self,
                 p_model: Dict[str, float],  # ex: {"1":0.45,"X":0.25,"2":0.30, "OVER":0.55}
                 markets: List[MarketOdds],
                 calibrator: Optional[Calibrator] = None) -> List[ValuePick]:
        picks: List[ValuePick] = []
        for m in markets:
            # Fail-Closed: marge >5% déjà filtrée par MarginGuard, on revérifie
            if m.margin > 5.0:
                continue
            if m.odds <= 1.0 or math.isnan(m.odds) or math.isinf(m.odds):
                continue
            # Map marché → clé proba
            key = self._market_to_proba_key(m)
            p = p_model.get(key)
            if p is None:
                continue
            if p < self.min_p:
                continue
            # Calibration optionnelle
            p_cal = p
            # EV
            ev = (p_cal * m.odds) - 1.0
            p_implied = 1.0 / m.odds
            edge = p_cal - p_implied
            # Filtre valeur
            if ev < self.min_ev or edge < self.min_edge:
                continue
            # Confiance basée sur edge et p
            if edge >= 0.08 and p_cal >= 0.15:
                conf = "HIGH"
            elif edge >= 0.04:
                conf = "MEDIUM"
            else:
                conf = "LOW"
            picks.append(ValuePick(
                event_id="", market_type=m.market_type, selection=m.selection,
                p_model=p, p_calibrated=p_cal, odds=m.odds, margin=m.margin, ev=ev, edge=edge,
                line=m.line, confidence=conf,
                reason=f"P={p_cal:.3f} vs implied {p_implied:.3f} → EV={ev:+.2%} edge={edge:+.3f} marge={m.margin:.2f}%",
            ))
        # Tri par EV décroissant (meilleure valeur d'abord) pour Selection Engine
        picks.sort(key=lambda x: x.ev, reverse=True)
        return picks

    def _market_to_proba_key(self, m: MarketOdds) -> str:
        mt = m.market_type.upper()
        sel = m.selection.upper()
        if mt == "1X2":
            return {"1": "1", "HOME": "1", "X": "X", "DRAW": "X", "2": "2", "AWAY": "2"}.get(sel, sel)
        if mt in ("OVER_UNDER", "TOTAL"):
            return "OVER" if "OVER" in sel else "UNDER"
        if mt == "BTTS":
            return "BTTS_YES" if sel in ("YES", "OUI", "1") else "BTTS_NO"
        return sel


# ============================================================================
# Service principal — PredictionEngine (orchestre Dixon-Coles + ML + Value)
# ============================================================================

class PredictionEngine:
    """
    Service opérationnel:
      - Charge historique depuis PostgreSQL (events FINISHED + match_stats)
      - Fit DixonColesEstimator + FootballMLModel + Calibrator
      - Pour chaque match UPCOMING (Redis/PostgreSQL), calcule P_modèle et Value Picks
    """

    def __init__(self,
                 pg_dsn: Optional[str] = None,
                 redis_url: Optional[str] = None,
                 ml_config: MLConfig = MLConfig()):
        self.pg_dsn = pg_dsn or "postgresql://preduser:predpass@localhost:5432/preddb"
        self.redis_url = redis_url or "redis://localhost:6379"
        self.ml_config = ml_config
        self.dc_params: Optional[DixonColesParams] = None
        self.dc_estimator = DixonColesEstimator()
        self.ml_model = FootballMLModel(config=ml_config)
        self.calibrator = Calibrator(method="isotonic")
        self.value_engine = ValueBettingEngine()
        self._redis = None

    async def _get_pool(self):
        if asyncpg is None:
            raise RuntimeError("asyncpg non installé — pip install asyncpg")
        return await asyncpg.create_pool(dsn=self.pg_dsn, min_size=1, max_size=5)

    async def load_history(self) -> Tuple[pd.DataFrame, pd.DataFrame]:
        """Charge events FINISHED + match_stats depuis PostgreSQL"""
        pool = await self._get_pool()
        async with pool.acquire() as conn:
            # Events FINISHED avec scores
            rows_events = await conn.fetch("""
                SELECT id::text as id, league, home_team, away_team, start_time, final_score, status
                FROM events
                WHERE status = 'FINISHED' AND final_score IS NOT NULL
                ORDER BY start_time DESC LIMIT 5000
            """)
            rows_stats = await conn.fetch("""
                SELECT event_id::text as event_id, xg, xga, corners, possession, shots_on_target, raw_stats_json
                FROM match_stats
                LIMIT 5000
            """)
        await pool.close()
        df_events = pd.DataFrame([dict(r) for r in rows_events])
        df_stats = pd.DataFrame([dict(r) for r in rows_stats])
        # Extrait home_goals/away_goals depuis final_score JSONB
        if not df_events.empty:
            import json as _json
            def _extract(fs):
                if fs is None:
                    return (None, None)
                if isinstance(fs, str):
                    try:
                        fs = _json.loads(fs)
                    except Exception:
                        return (None, None)
                return (fs.get("home"), fs.get("away"))
            df_events[["home_goals", "away_goals"]] = df_events["final_score"].apply(lambda x: pd.Series(_extract(x)))
        logger.info(f"[PredictionEngine] Historique chargé: {len(df_events)} events FINISHED, {len(df_stats)} stats")
        if len(df_events) < 30:
            logger.warning(f"[PredictionEngine] Historique faible ({len(df_events)} <30) — Dixon-Coles Fail-Closed possible")
        return df_events, df_stats

    async def fit(self, df_events: Optional[pd.DataFrame] = None, df_stats: Optional[pd.DataFrame] = None):
        """Entraîne Dixon-Coles + ML + calibration — à appeler offline (cron hebdo) ou au démarrage si modèle manquant"""
        if df_events is None or df_stats is None:
            df_events, df_stats = await self.load_history()
        if df_events.empty:
            raise ValueError("Aucun historique FINISHED — impossible d'entraîner (Fail-Closed)")

        # 1. Dixon-Coles
        self.dc_params = self.dc_estimator.fit(df_events)

        # 2. ML
        self.ml_model.fit(df_events, df_stats, self.dc_params)

        # 3. Calibration — split temporel 80/20 (ou KFold out-of-time en prod)
        n = len(df_events)
        split = int(n * 0.8)
        # Pour demo, on calibre sur le même set avec cross-val simple — en prod: séparer train/calibration par date
        X_all = self.ml_model._build_features(df_events, df_stats, self.dc_params)
        y_1x2, y_ou = self.ml_model._build_targets(df_events)
        proba = self.ml_model.predict_proba(X_all)
        # Isotonic par classe
        self.calibrator.fit_1x2(y_1x2.values, proba["1X2"])
        # O/U binaire
        self.calibrator.fit(y_ou.values, proba["OU"], "OU")

        logger.info("[PredictionEngine] Fit complet: Dixon-Coles + ML + calibration")
        return self

    def predict_match(self,
                      home_team: str,
                      away_team: str,
                      event_id: str = "",
                      ou_line: float = 2.5) -> Dict[str, float]:
        """Prédit un match UPCOMING via Dixon-Coles + ML (avec fallback Dixon seul si ML non dispo)"""
        if self.dc_params is None:
            raise RuntimeError("Moteur non entraîné — appeler fit() d'abord (Fail-Closed)")

        # Dixon-Coles lambdas
        lam_h, lam_a = self.dc_estimator.lambdas(home_team, away_team, self.dc_params)
        dc_probs = DixonColes_1X2_and_OU(lam_h, lam_a, self.dc_params.rho, ou_line=ou_line)

        # ML boost (si disponible)
        if self.ml_model.is_fitted:
            # Construit feature row pour ce match (besoin xG récents — ici on approxime avec lambdas)
            X_row = pd.DataFrame([{
                "lambda_home": lam_h, "lambda_away": lam_a, "lambda_diff": lam_h - lam_a,
                "lambda_total": lam_h + lam_a, "rho": self.dc_params.rho, "home_adv": self.dc_params.home_adv,
                "xg_home_5m": lam_h, "xga_home_5m": 1.0, "is_big_match": 0,
            }])
            ml_proba = self.ml_model.predict_proba(X_row)
            # Fusion: moyenne pondérée Dixon 40% + ML 60% (ou stack appris en prod)
            w_dc, w_ml = 0.4, 0.6
            p1 = w_dc * dc_probs["1"] + w_ml * float(ml_proba["1X2"][0, 0])
            px = w_dc * dc_probs["X"] + w_ml * float(ml_proba["1X2"][0, 1])
            p2 = w_dc * dc_probs["2"] + w_ml * float(ml_proba["1X2"][0, 2])
            p_over = w_dc * dc_probs["OVER"] + w_ml * float(ml_proba["OU"][0])
            p_under = 1 - p_over
            # BTTS: garder Dixon pur (ML n'a pas ce head)
            p_btts_yes, p_btts_no = dc_probs["BTTS_YES"], dc_probs["BTTS_NO"]
        else:
            p1, px, p2 = dc_probs["1"], dc_probs["X"], dc_probs["2"]
            p_over, p_under = dc_probs["OVER"], dc_probs["UNDER"]
            p_btts_yes, p_btts_no = dc_probs["BTTS_YES"], dc_probs["BTTS_NO"]
            ml_proba = None

        # Calibration
        # On calibre 1X2 ensemble
        if self.calibrator.calibrators:
            # Construit vecteur proba 1X2 pour calibration
            raw_1x2 = np.array([[p1, px, p2]])
            cal_1x2 = self.calibrator.transform_1x2(raw_1x2)[0]
            p1, px, p2 = float(cal_1x2[0]), float(cal_1x2[1]), float(cal_1x2[2])
            # O/U
            if "OU" in self.calibrator.calibrators:
                p_over = float(self.calibrator.transform(np.array([p_over]), "OU")[0])
                p_under = 1.0 - p_over

        return {
            "event_id": event_id,
            "home_team": home_team, "away_team": away_team,
            "lambda_home": lam_h, "lambda_away": lam_a, "rho": self.dc_params.rho,
            "1": p1, "X": px, "2": p2,
            "OVER": p_over, "UNDER": p_under,
            "BTTS_YES": p_btts_yes, "BTTS_NO": p_btts_no,
            "p_model": {"1": p1, "X": px, "2": p2, "OVER": p_over, "UNDER": p_under, "BTTS_YES": p_btts_yes, "BTTS_NO": p_btts_no},
        }

    async def predict_upcoming_and_value(self,
                                          upcoming_events: List[Dict[str, Any]],
                                          markets_by_event: Dict[str, List[MarketOdds]],
                                          min_ev: float = 0.03) -> List[ValuePick]:
        """
        Pour chaque match UPCOMING (cache Redis/PostgreSQL), calcule P_modèle et Value Picks
        upcoming_events: [{event_id, home_team, away_team, league}]
        markets_by_event: {event_id: [MarketOdds(odds, margin≤5%)]}
        → retourne uniquement sélections à forte valeur (EV >= min_ev, edge >=2%)
        """
        self.value_engine.min_ev = min_ev
        all_picks: List[ValuePick] = []
        for ev in upcoming_events:
            eid = str(ev.get("event_id") or ev.get("id"))
            home = ev.get("home_team") or ev.get("home")
            away = ev.get("away_team") or ev.get("away")
            if not home or not away:
                logger.warning(f"[Value] skip {eid}: équipe manquante")
                continue
            try:
                pred = self.predict_match(home, away, event_id=eid)
            except (KeyError, ValueError, RuntimeError) as e:
                logger.warning(f"[Value] skip {eid} ({home} vs {away}): {e} — Fail-Closed")
                continue
            markets = markets_by_event.get(eid, [])
            if not markets:
                continue
            # Value Betting
            picks = self.value_engine.evaluate(pred["p_model"], markets)
            for p in picks:
                p.event_id = eid
            all_picks.extend(picks)

        # Filtre final: marge stricte déjà vérifiée, on garde tri EV
        all_picks.sort(key=lambda x: x.ev, reverse=True)
        logger.info(f"[Value] {len(all_picks)} value picks sur {len(upcoming_events)} matchs (min_ev={min_ev:.1%})")
        return all_picks

    # ------------------------------------------------------------------
    # Helpers Redis/PostgreSQL pour upcoming
    # ------------------------------------------------------------------
    async def load_upcoming_from_db(self, limit: int = 100) -> List[Dict[str, Any]]:
        pool = await self._get_pool()
        async with pool.acquire() as conn:
            rows = await conn.fetch("""
                SELECT id::text as event_id, home_team, away_team, league, start_time
                FROM events WHERE status='UPCOMING' ORDER BY start_time ASC LIMIT $1
            """, limit)
        await pool.close()
        return [dict(r) for r in rows]

    async def load_markets_from_redis(self, event_ids: List[str]) -> Dict[str, List[MarketOdds]]:
        if redis is None:
            return {}
        r = redis.from_url(self.redis_url, decode_responses=True)
        out: Dict[str, List[MarketOdds]] = {}
        for eid in event_ids:
            raw = await r.get(f"megapari:event:{eid}")
            if not raw:
                # fallback sans prefix
                raw = await r.get(f"event:{eid}")
            if not raw:
                continue
            import json as _json
            try:
                data = _json.loads(raw)
                vms = data.get("validated_markets") or data.get("markets") or []
                markets: List[MarketOdds] = []
                for vm in vms:
                    mtype = vm.get("market_type") or vm.get("marketType") or "1X2"
                    margin = float(vm.get("margin_percent") or vm.get("margin") or 0)
                    if margin > 5.0:
                        continue
                    # Chaque marché peut avoir plusieurs sélections → une MarketOdds par sélection
                    for sel in vm.get("selections") or []:
                        odds = sel.get("odds") if isinstance(sel, dict) else None
                        # odds peut être dans _odds_internal (interne) — on tente
                        if odds is None and isinstance(sel, dict):
                            odds = vm.get("_odds_internal")
                            if isinstance(odds, list):
                                # Heuristique: on ne sait pas mapper — skip
                                continue
                        if odds is None:
                            continue
                        try:
                            odds_f = float(odds)
                        except Exception:
                            continue
                        markets.append(MarketOdds(
                            market_type=mtype,
                            selection=str(sel.get("selection_id") or sel.get("name") or sel.get("selection") or ""),
                            odds=odds_f,
                            margin=margin,
                            line=vm.get("line"),
                        ))
                if markets:
                    out[eid] = markets
            except Exception as e:
                logger.warning(f"[Redis] parse {eid}: {e}")
                continue
        await r.aclose()
        return out
