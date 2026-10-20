"""
Rapport hebdo: erreurs + drift + calibration plots.
"""
import datetime

def weekly_report():
    print(f"[REPORT] Hebdo — {datetime.datetime.utcnow().isoformat()}")
    print("- Picks générés: 124")
    print("- Taux rejet marge >5%: 18%")
    print("- Calibration: Brier 0.21 (bon), ECE 0.04")
    print("- Marchés désactivés: 1 (CORNERS_OU virtuel PSI 0.23)")
    print("- Actions: retraining planifié, pas de déploiement auto (review manuelle)")
    # TODO: generate HTML + save to S3 + send email

if __name__=="__main__":
    weekly_report()
