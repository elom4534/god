"""
Drift detection pour virtuel — PSI + KS.
Si PSI >0.2 ou KS p<0.05 → alerte + auto-disable marché.
"""
import numpy as np
from scipy.stats import ks_2samp

def psi(expected, actual, bins=10):
    """Population Stability Index"""
    expected = np.array(expected)
    actual = np.array(actual)
    # quantiles
    breakpoints = np.quantile(expected, np.linspace(0,1,bins+1))
    exp_counts = np.histogram(expected, bins=breakpoints)[0]
    act_counts = np.histogram(actual, bins=breakpoints)[0]
    # smoothing
    exp_perc = (exp_counts + 0.5) / (len(expected) + 1)
    act_perc = (act_counts + 0.5) / (len(actual) + 1)
    psi_vals = (act_perc - exp_perc) * np.log(act_perc / exp_perc)
    return float(np.sum(psi_vals))

def detect_drift(baseline_probs, current_probs, threshold_psi=0.2, threshold_ks_p=0.05):
    psi_score = psi(baseline_probs, current_probs)
    ks_stat, ks_p = ks_2samp(baseline_probs, current_probs)
    is_drift = psi_score > threshold_psi or ks_p < threshold_ks_p
    return {
        "psi": psi_score,
        "ks_stat": float(ks_stat),
        "ks_p": float(ks_p),
        "is_drift": is_drift,
        "action": "DISABLE_MARKET" if is_drift else "OK"
    }
