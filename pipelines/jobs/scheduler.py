"""
Scheduler pipelines — lean (APScheduler).
- ETL réel: chaque heure
- ETL virtuel: toutes les 15 min
- Drift: quotidien 02:00
- Training: hebdo dim 03:00
"""
from apscheduler.schedulers.blocking import BlockingScheduler
import subprocess, sys

def run(cmd):
    print(f"[SCHED] run: {cmd}")
    try:
        subprocess.run(cmd, shell=True, check=False)
    except Exception as e:
        print(f"[SCHED] error {e}")

sched = BlockingScheduler()

# ETL
sched.add_job(lambda: run("python -m etl.ingest_live_football"), 'interval', hours=1, id='etl_real')
sched.add_job(lambda: run("python -m etl.ingest_virtual"), 'interval', minutes=15, id='etl_virtual')

# Monitoring
sched.add_job(lambda: run("python -m monitoring.drift_detection"), 'cron', hour=2, id='drift')
sched.add_job(lambda: run("python -m monitoring.calibration_report"), 'cron', day_of_week='mon', hour=8, id='report')

# Training hebdo
sched.add_job(lambda: run("python -m training.train_real"), 'cron', day_of_week='sun', hour=3, id='train_real')
sched.add_job(lambda: run("python -m training.train_virtual"), 'cron', day_of_week='sun', hour=4, id='train_virtual')
sched.add_job(lambda: run("python -m training.backtest"), 'cron', day_of_week='sun', hour=5, id='backtest')

if __name__ == "__main__":
    print("[SCHED] starting (lean, 1k/j) — ctrl+c to stop")
    try:
        sched.start()
    except (KeyboardInterrupt, SystemExit):
        print("[SCHED] stopped")
        sys.exit(0)
