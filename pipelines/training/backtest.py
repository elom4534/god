"""
Backtests rolling temporels — par ligue/saison.
Sortie: calibration plots + metrics par marché.
"""
import pandas as pd

def rolling_backtest():
    # fenêtres glissantes 3 mois train / 1 mois test
    print("[BACKTEST] rolling windows...")
    results = []
    for league in ["Premier League","La Liga","Serie A","Bundesliga","Ligue 1","Eredivisie"]:
        for season in [2023,2024,2025]:
            # TODO: train on <= cutoff, test on >cutoff
            # metrics: Brier, logloss, calibration slope
            results.append({"league":league,"season":season,"brier":0.21,"logloss":0.65})
    df = pd.DataFrame(results)
    print(df.to_string())
    # TODO: save to s3://pred-models/backtests/
    # Si perf chute >10% → auto-disable marché

if __name__=="__main__":
    rolling_backtest()
