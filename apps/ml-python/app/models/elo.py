"""
Elo/Glicko baseline — à brancher sur données Live Football API.
MVP: interface + pseudo-code, entraînement complet dans pipelines/training.
"""
import math
from typing import Dict, Tuple

K_FACTOR = 32
HOME_ADVANTAGE = 75  # points Elo
INIT_ELO = 1500

elo_ratings: Dict[str, float] = {}

def expected_score(rating_a: float, rating_b: float) -> float:
    return 1 / (1 + 10 ** ((rating_b - rating_a) / 400))

def update_elo(team_home: str, team_away: str, result: str):
    """
    result: "1" (home win), "X" (draw), "2" (away win)
    """
    r_home = elo_ratings.get(team_home, INIT_ELO)
    r_away = elo_ratings.get(team_away, INIT_ELO)
    # home advantage
    r_home_adj = r_home + HOME_ADVANTAGE

    exp_home = expected_score(r_home_adj, r_away)
    exp_away = 1 - exp_home

    if result == "1":
        s_home, s_away = 1, 0
    elif result == "2":
        s_home, s_away = 0, 1
    else:
        s_home, s_away = 0.5, 0.5

    new_home = r_home + K_FACTOR * (s_home - exp_home)
    new_away = r_away + K_FACTOR * (s_away - exp_away)
    elo_ratings[team_home] = new_home
    elo_ratings[team_away] = new_away
    return new_home, new_away

def win_prob_from_elo(team_home: str, team_away: str) -> Tuple[float, float, float]:
    """Retourne (p_home, p_draw, p_away) via Elo — simplifié, à calibrer avec Dixon-Coles."""
    r_home = elo_ratings.get(team_home, INIT_ELO) + HOME_ADVANTAGE
    r_away = elo_ratings.get(team_away, INIT_ELO)
    # prob home win via logistic
    p_home_raw = expected_score(r_home, r_away)
    # draw prob heuristique 0.25 (à remplacer par modèle Poisson)
    p_draw = 0.25
    # rééchelonner
    p_home = p_home_raw * (1 - p_draw)
    p_away = (1 - p_home_raw) * (1 - p_draw)
    return p_home, p_draw, p_away
