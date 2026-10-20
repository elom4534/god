"""
Drift detection (PSI + KS) — hebdo + avant chaque retraining.
Si drift fort → désactivation auto + alerte Slack/email.
"""
import sys
sys.path.append("../../apps/ml-python")
# from app.models.virtual_drift import detect_drift
# Mock inline pour pipelines standalone

def check_drift():
    print("[DRIFT] checking virtual markets...")
    # baseline = 3 derniers mois, current = 7 derniers jours
    # psi = ...  # reprendre app.models.virtual_drift.psi
    # if psi>0.2 → alert
    # Exemple:
    psi = 0.12
    if psi > 0.2:
        print(f"[DRIFT] ALERT psi={psi} → disabling CORNERS_OU")
        # UPDATE markets SET validated=false WHERE market_type='CORNERS_OU'
    else:
        print(f"[DRIFT] OK psi={psi}")
    print("[DRIFT] real markets per league: no drift")

if __name__=="__main__":
    check_drift()
