/**
 * OddsRefreshWorker — maintient le cache MegaPari frais.
 *
 * Pourquoi un worker dédié ?
 * --------------------------
 * Le générateur de combiné lit le cache Margin Guard (`megapari:event:*`, TTL 15 min).
 * Sans rafraîchissement, le pool se vide et l'écran « Combiné sur mesure » affiche
 * « aucun match éligible », même quand des centaines de matchs sont ouverts.
 *
 * Ce worker relance l'ETL Python (LoadSingle → Margin Guard → Redis) :
 *   • au démarrage de l'application (après un déploiement / redémarrage),
 *   • puis toutes les 10 minutes.
 *
 * Il est idempotent (pas deux exécutions simultanées) et **fail-open** : toute
 * erreur est journalisée sans jamais interrompre l'API.
 *
 * Variables d'environnement :
 *   ETL_REFRESH_ENABLED  "false" pour désactiver (défaut : activé)
 *   ETL_REFRESH_CRON     expression cron (défaut : toutes les 10 min)
 *   ETL_SCRIPT           chemin du script (défaut : <repo>/pipelines/etl/ingest_bookmaker_markets.py)
 *   ETL_PYTHON           interpréteur (défaut : /home/god/.venv/bin/python)
 *   ETL_REFRESH_LIMIT    nombre d'événements à charger (défaut : 400)
 */
import { Injectable, Logger, OnModuleInit } from '@nestjs/common';
import { Cron } from '@nestjs/schedule';
import { spawn } from 'child_process';
import { existsSync } from 'fs';
import * as path from 'path';

const ENABLED = String(process.env.ETL_REFRESH_ENABLED || 'true').toLowerCase() !== 'false';
const CRON_EXPR = process.env.ETL_REFRESH_CRON || '*/10 * * * *';
const PYTHON = process.env.ETL_PYTHON || '/home/god/.venv/bin/python';
const LIMIT = process.env.ETL_REFRESH_LIMIT || '400';

function resolveScript(): string {
  if (process.env.ETL_SCRIPT) return process.env.ETL_SCRIPT;
  // dist/workers/… → racine du dépôt
  const candidates = [
    '/home/god/pred-app/pipelines/etl/ingest_bookmaker_markets.py',
    path.resolve(__dirname, '../../../../pipelines/etl/ingest_bookmaker_markets.py'),
  ];
  return candidates.find(p => existsSync(p)) || candidates[0];
}

@Injectable()
export class OddsRefreshWorker implements OnModuleInit {
  private readonly logger = new Logger(OddsRefreshWorker.name);
  private running = false;
  private lastRunAt: string | null = null;
  private lastStatus: 'ok' | 'error' | 'skipped' = 'skipped';
  private lastSummary = '';

  onModuleInit(): void {
    if (!ENABLED) {
      this.logger.log('Rafraîchissement ETL désactivé (ETL_REFRESH_ENABLED=false)');
      return;
    }
    // Premier remplissage après le démarrage (laisse NestJS finir de se lancer).
    setTimeout(() => void this.refresh('démarrage'), 15_000);
  }

  @Cron(CRON_EXPR)
  async scheduled(): Promise<void> {
    if (!ENABLED) return;
    await this.refresh('planifié');
  }

  /** État exposé pour le diagnostic (`GET /api/v1/system/etl-status`). */
  status() {
    return {
      enabled: ENABLED,
      cron: CRON_EXPR,
      script: resolveScript(),
      limit: LIMIT,
      running: this.running,
      last_run_at: this.lastRunAt,
      last_status: this.lastStatus,
      last_summary: this.lastSummary,
    };
  }

  async refresh(reason = 'manuel'): Promise<{ ok: boolean; summary: string }> {
    if (this.running) return { ok: false, summary: 'déjà en cours' };
    const script = resolveScript();
    if (!existsSync(script)) {
      this.lastStatus = 'skipped';
      this.lastSummary = `script introuvable : ${script}`;
      this.logger.warn(this.lastSummary);
      return { ok: false, summary: this.lastSummary };
    }

    this.running = true;
    const startedAt = Date.now();
    this.logger.log(`ETL MegaPari (${reason}) — ${script} --limit ${LIMIT}`);

    try {
      const { code, stdout, stderr } = await this.run(script);
      const lines = (stdout || '').trim().split('\n').filter(Boolean);
      const summary = lines.slice(-2).join(' | ');
      this.lastRunAt = new Date().toISOString();
      this.lastStatus = code === 0 ? 'ok' : 'error';
      this.lastSummary = summary || (code === 0 ? 'ok' : String(stderr).slice(-300));
      if (code === 0) {
        this.logger.log(`ETL terminé en ${Date.now() - startedAt} ms — ${this.lastSummary}`);
      } else {
        this.logger.warn(`ETL code ${code} — ${this.lastSummary}`);
      }
      return { ok: code === 0, summary: this.lastSummary };
    } catch (e: any) {
      this.lastRunAt = new Date().toISOString();
      this.lastStatus = 'error';
      this.lastSummary = String(e?.message || e).slice(0, 300);
      this.logger.warn(`ETL échec : ${this.lastSummary}`);
      return { ok: false, summary: this.lastSummary };
    } finally {
      this.running = false;
    }
  }

  private run(script: string): Promise<{ code: number; stdout: string; stderr: string }> {
    return new Promise((resolve, reject) => {
      const repoRoot = path.resolve(path.dirname(script), '../..');
      const child = spawn(PYTHON, [script, '--provider', 'megapari', '--limit', LIMIT], {
        cwd: repoRoot,
        env: {
          ...process.env,
          PYTHONPATH: path.join(repoRoot, 'apps', 'ml-python'),
        },
      });

      let stdout = '';
      let stderr = '';
      const timer = setTimeout(() => {
        child.kill('SIGKILL');
        reject(new Error('timeout ETL (240 s)'));
      }, 240_000);

      child.stdout.on('data', d => { stdout += d.toString(); });
      child.stderr.on('data', d => { stderr += d.toString(); });
      child.on('error', e => { clearTimeout(timer); reject(e); });
      child.on('close', code => { clearTimeout(timer); resolve({ code: code ?? 1, stdout, stderr }); });
    });
  }
}
