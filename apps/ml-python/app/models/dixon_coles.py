"""
Dixon-Coles Poisson — baseline 1X2 et Over/Under.
Pseudo-code complet; implémentation entraînement dans pipelines/training.
"""
import math
from typing import Tuple

def poisson_pmf(k: int, lam: float) -> float:
    return (lam ** k) * math.exp(-lam) / math.factorial(k)

def dixon_coles_probs(lambda_home: float, lambda_away: float, rho: float = 0.1) -> Tuple[float, float, float]:
    """
    Calcule P(1), P(X), P(2) en sommant Poisson bivarié avec correction rho pour scores faibles.
    """
    max_goals = 8
    p_home = p_draw = p_away = 0.0
    for i in range(max_goals+1):
        for j in range(max_goals+1):
            p = poisson_pmf(i, lambda_home) * poisson_pmf(j, lambda_away)
            # correction Dixon-Coles pour 0-0, 0-1, 1-0, 1-1
            if i==0 and j==0:
                p *= (1 - lambda_away*rho)
            elif i==0 and j==1:
                p *= (1 + lambda_home*rho)
            elif i==1 and j==0:
                p *= (1 + lambda_away*rho)
            elif i==1 and j==1:
                p *= (1 - rho)
            if i > j:
                p_home += p
            elif i == j:
                p_draw += p
            else:
                p_away += p
    total = p_home + p_draw + p_away
    return p_home/total, p_draw/total, p_away/total

def over_under_probs(lambda_home: float, lambda_away: float, line: float = 2.5) -> Tuple[float, float]:
    lam_total = lambda_home + lambda_away
    # P(Over) = 1 - CDF(line)
    p_under = 0.0
    k_max = int(math.floor(line))
    for k in range(k_max+1):
        p_under += poisson_pmf(k, lam_total)
    return 1-p_under, p_under
