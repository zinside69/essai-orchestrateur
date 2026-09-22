#!/usr/bin/env bash
# dashboard-web.sh — genere une page HTML autonome de suivi de l'orchestrateur.
# Usage : dashboard-web.sh [--sortie F.html]
#
# Lit l'etat reel (.orchestrator/) et produit une page de decision a 5 vues :
# en cours, acheve, quarantaine, critique, en attente de decision humaine.
# Aucune dependance externe : HTML/CSS embarques, donnees serialisees.
set -Eeuo pipefail
# shellcheck disable=SC1091
source "$(dirname "$0")/lib.sh"

SORTIE="$ORCH_DIR/dashboard.html"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --help|-h) echo 'usage: dashboard-web.sh [--sortie F.html]'; exit 0 ;;
    --sortie) SORTIE="${2:?valeur manquante}"; shift 2 ;;
    *) die "argument inattendu : $1" ;;
  esac
done

require jq python3
ETAT_DIR="$ORCH_DIR/etat"
DEC="$ORCH_DIR/journal/decisions.jsonl"
ESC="$ETAT_DIR/escalades/escalades.jsonl"
EVALS="$ORCH_DIR/journal/evals-ab.jsonl"
PRUNE="$ORCH_DIR/journal/prune-docs.jsonl"
QUAR="$ETAT_DIR/quarantaine.tsv"
QUAR_DOCS="$ETAT_DIR/quarantaine-docs.tsv"
TRANS="$ORCH_DIR/journal/transitions.jsonl"

python3 - "$ETAT_DIR" "$DEC" "$ESC" "$EVALS" "$PRUNE" "$QUAR" "$QUAR_DOCS" "$TRANS" "$SORTIE" <<'PY'
import json, os, sys, html, datetime

etat_dir, dec_p, esc_p, evals_p, prune_p, quar_p, quardocs_p, trans_p, out_p = sys.argv[1:10]

def jl(p):
    if not os.path.exists(p): return []
    return [json.loads(l) for l in open(p, encoding='utf-8') if l.strip()]

def esc(s): return html.escape(str(s))

# --- Taches par etat ---------------------------------------------------------
taches = []
taches_dir = os.path.join(etat_dir, 'taches')
if os.path.isdir(taches_dir):
    for n in sorted(os.listdir(taches_dir)):
        if not n.endswith('.env'): continue
        d = {}
        for line in open(os.path.join(taches_dir, n), encoding='utf-8'):
            if '=' in line:
                k, v = line.rstrip('\n').split('=', 1); d[k] = v
        d['id'] = n[:-4]
        taches.append(d)

PAR_ETAT = {
  'en_cours':  [t for t in taches if t.get('etat') in ('RUNNING', 'VERIFIED', 'REVIEWED')],
  'acheve':    [t for t in taches if t.get('etat') in ('DONE', 'PUBLISHED')],
  'attente':   [t for t in taches if t.get('etat') in ('PARKED', 'ESCALATED')],
  'critique':  [t for t in taches if t.get('etat') in ('RED', 'FAILED', 'BLOCKED')],
  'planifie':  [t for t in taches if t.get('etat') in ('PENDING', 'READY')],
}

escalades = jl(esc_p)
esc_ouvertes = [e for e in escalades if e.get('statut') == 'ouverte']
evals = jl(evals_p)
prune = jl(prune_p)
quar_regles = [l.split('\t')[0] for l in open(quar_p, encoding='utf-8')] if os.path.exists(quar_p) else []
quar_docs = [l.split('\t')[0] for l in open(quardocs_p, encoding='utf-8')] if os.path.exists(quardocs_p) else []
decisions = jl(dec_p)
transitions = jl(trans_p)

def badge(etat):
    colors = {'RUNNING':'#2563eb','VERIFIED':'#0891b2','REVIEWED':'#7c3aed','DONE':'#16a34a',
              'PUBLISHED':'#16a34a','PARKED':'#d97706','ESCALATED':'#ea580c','RED':'#dc2626',
              'FAILED':'#dc2626','BLOCKED':'#991b1b','PENDING':'#6b7280','READY':'#65a30d'}
    c = colors.get(etat, '#6b7280')
    return f'<span class="badge" style="background:{c}">{esc(etat)}</span>'

def table(taches_list, vide):
    if not taches_list:
        return f'<p class="vide">{esc(vide)}</p>'
    r = ['<table><tr><th>Tâche</th><th>État</th><th>Priorité</th><th>Périmètre</th><th>MAJ</th></tr>']
    for t in taches_list:
        r.append(f"<tr><td><b>{esc(t.get('id',''))}</b></td><td>{badge(t.get('etat',''))}</td>"
                 f"<td>{esc(t.get('priorite','-'))}</td><td><code>{esc(t.get('perimetre','-'))}</code></td>"
                 f"<td>{esc(t.get('maj_le','-'))}</td></tr>")
    return '\n'.join(r) + '</table>'

# Progression globale : poids par etat (DONE=100%, PUBLISHED=90%, REVIEWED=75%,
# VERIFIED=60%, RUNNING=40%, READY=10%, les autres=0%). 0 tache => 100% (rien a faire).
POIDS = {'DONE':100,'PUBLISHED':90,'REVIEWED':75,'VERIFIED':60,'RUNNING':40,'READY':10,
         'PENDING':0,'PARKED':0,'ESCALATED':0,'RED':0,'FAILED':0,'BLOCKED':0}
if taches:
    progression = round(sum(POIDS.get(t.get('etat',''),0) for t in taches) / len(taches))
else:
    progression = 100
prog_couleur = '#16a34a' if progression >= 80 else ('#d97706' if progression >= 40 else '#dc2626')

# alerte globale
n_crit = len(PAR_ETAT['critique']) + len(quar_regles) + len(quar_docs)
n_humain = len(esc_ouvertes) + len(PAR_ETAT['attente'])
alerte = ('ROUGE', 'Action requise : éléments critiques ou quarantaines.') if n_crit > 0 else \
         ('AMBRE', 'Décisions humaines en attente.') if n_humain > 0 else \
         ('VERT', 'Aucun point bloquant détecté.')

ts = datetime.datetime.now(datetime.timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')

rows_evals = ''
if evals:
    last = {}
    for e in evals: last[e.get('regle')] = e
    for r, e in sorted(last.items()):
        cls = {'POSITIVE':'pos','NEGATIVE':'neg','NEUTRE':'neu'}.get(e.get('contribution'), 'neu')
        rows_evals += (f"<tr><td>{esc(r)}</td><td>{e.get('score_avec')}</td><td>{e.get('score_sans')}</td>"
                       f"<td class='{cls}'>{e.get('delta'):+.3f}</td><td class='{cls}'>{esc(e.get('contribution'))}</td></tr>")

rows_prune = ''
if prune:
    last = {}
    for e in prune: last[e.get('doc')] = e
    for d, e in sorted(last.items()):
        cls = {'POSITIVE':'pos','NEGATIVE':'neg','NEUTRE':'neu'}.get(e.get('contribution'), 'neu')
        rows_prune += (f"<tr><td><code>{esc(d)}</code></td><td>{e.get('score_avec')}</td>"
                       f"<td>{e.get('score_sans')}</td><td class='{cls}'>{e.get('contribution')}</td></tr>")

page = f"""<!DOCTYPE html>
<html lang="fr"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Tableau de bord orchestrateur</title>
<style>
*{{box-sizing:border-box}}body{{margin:0;font-family:-apple-system,'Segoe UI',Roboto,sans-serif;background:#0f172a;color:#e2e8f0}}
header{{padding:20px 28px;background:#1e293b;border-bottom:1px solid #334155;display:flex;justify-content:space-between;align-items:center;flex-wrap:wrap;gap:12px}}
h1{{margin:0;font-size:20px}}.ts{{color:#64748b;font-size:13px}}
.progression{{padding:6px 28px 4px}}.progression .lbl{{font-size:12px;color:#94a3b8;display:flex;justify-content:space-between;margin-bottom:5px}}
.piste{{height:14px;background:#0f172a;border:1px solid #334155;border-radius:8px;overflow:hidden}}
.jauge{{height:100%;border-radius:8px 0 0 8px;transition:width .4s}}
.alerte{{padding:8px 18px;border-radius:20px;font-weight:600;font-size:14px}}
.VERT{{background:#14532d;color:#86efac}}.AMBRE{{background:#78350f;color:#fcd34d}}.ROUGE{{background:#7f1d1d;color:#fca5a5}}
.kpis{{display:grid;grid-template-columns:repeat(auto-fit,minmax(150px,1fr));gap:14px;padding:22px 28px}}
.kpi{{background:#1e293b;border:1px solid #334155;border-radius:12px;padding:16px;text-align:center}}
.kpi b{{display:block;font-size:30px;margin-bottom:4px}}
.kpi span{{font-size:12px;color:#94a3b8;text-transform:uppercase;letter-spacing:.05em}}
section{{margin:0 28px 26px;background:#1e293b;border:1px solid #334155;border-radius:12px;padding:18px 22px}}
h2{{margin:0 0 14px;font-size:16px;color:#cbd5e1}}
table{{width:100%;border-collapse:collapse;font-size:14px}}
th{{text-align:left;padding:8px 10px;color:#94a3b8;border-bottom:1px solid #334155;font-size:12px;text-transform:uppercase}}
td{{padding:9px 10px;border-bottom:1px solid #1e293b}}tr:hover{{background:#243249}}
code{{background:#0f172a;padding:2px 6px;border-radius:4px;font-size:12px}}
.badge{{color:#fff;padding:3px 10px;border-radius:12px;font-size:12px;font-weight:600}}
.vide{{color:#64748b;font-style:italic}}
.pos{{color:#4ade80;font-weight:600}}.neg{{color:#f87171;font-weight:600}}.neu{{color:#facc15}}
.grid2{{display:grid;grid-template-columns:1fr 1fr;gap:26px}}@media(max-width:900px){{.grid2{{grid-template-columns:1fr}}}}
</style></head><body>
<header>
  <div><h1>🎛️ Tableau de bord — Orchestrateur</h1><div class="ts">Généré le {ts} · source : .orchestrator/</div></div>
  <div class="alerte {alerte[0]}">{alerte[0]} — {alerte[1]}</div>
</header>

<div class="progression">
  <div class="lbl"><span><b>Progression globale</b> — {len(PAR_ETAT['acheve'])} achevée(s) sur {len(taches)} tâche(s)</span><span><b>{progression} %</b></span></div>
  <div class="piste"><div class="jauge" style="width:{progression}%;background:{prog_couleur}"></div></div>
</div>

<div class="kpis">
  <div class="kpi"><b>{len(PAR_ETAT['en_cours'])}</b><span>En cours</span></div>
  <div class="kpi"><b>{len(PAR_ETAT['acheve'])}</b><span>Achevées</span></div>
  <div class="kpi"><b>{len(PAR_ETAT['attente'])}</b><span>Décision humaine</span></div>
  <div class="kpi"><b>{len(PAR_ETAT['critique'])}</b><span>Critiques</span></div>
  <div class="kpi"><b>{len(quar_regles)+len(quar_docs)}</b><span>Quarantaines</span></div>
  <div class="kpi"><b>{len(decisions)}</b><span>Décisions journalisées</span></div>
  <div class="kpi"><b style="color:{prog_couleur}">{progression} %</b><span>Progression globale</span></div>
</div>

<section><h2>⚙️ En développement</h2>{table(PAR_ETAT['en_cours'], 'Aucune tâche en cours.')}</section>

<div class="grid2">
<section><h2>✅ Achevées</h2>{table(PAR_ETAT['acheve'], 'Aucune tâche achevée.')}</section>
<section><h2>🧑‍⚖️ En attente de décision humaine</h2>{table(PAR_ETAT['attente'], 'Aucune tâche en attente.')}
{'<h3 style="margin:14px 0 8px;font-size:13px;color:#fbbf24">Escalades ouvertes : ' + str(len(esc_ouvertes)) + '</h3>' if esc_ouvertes else ''}</section>
</div>

<div class="grid2">
<section><h2>🔴 Critiques (RED / FAILED / BLOCKED)</h2>{table(PAR_ETAT['critique'], 'Aucune tâche critique.')}</section>
<section><h2>🧪 Quarantaines</h2>
{'<p><b>Règles :</b> ' + ', '.join(esc(q) for q in quar_regles) + '</p>' if quar_regles else '<p class="vide">Aucune règle en quarantaine.</p>'}
{'<p><b>Documents :</b> ' + ', '.join(esc(q) for q in quar_docs) + '</p>' if quar_docs else '<p class="vide">Aucun document en quarantaine.</p>'}
</section>
</div>

<section><h2>📊 Contribution des règles (evals A/B — M14)</h2>
{'<table><tr><th>Règle</th><th>Avec</th><th>Sans</th><th>Delta</th><th>Contribution</th></tr>' + rows_evals + '</table>' if rows_evals else '<p class="vide">Aucun eval A/B exécuté (lancer run-replay.sh --ab-eval).</p>'}
</section>

<section><h2>🗜️ Prune documentaire mesurée (M16)</h2>
{'<table><tr><th>Document</th><th>Avec</th><th>Sans</th><th>Contribution</th></tr>' + rows_prune + '</table>' if rows_prune else '<p class="vide">Aucune mesure documentaire (lancer prune-contexte.sh).</p>'}
</section>

<section><h2>🔀 Transitions récentes (machine à états)</h2>
{'<table><tr><th>Horodatage</th><th>Tâche</th><th>De</th><th>Vers</th><th>Mode</th></tr>' + ''.join(
  f"<tr><td>{esc(t.get('ts_utc',''))}</td><td>{esc(t.get('tache',''))}</td><td>{esc(t.get('de',''))}</td><td>{esc(t.get('vers',''))}</td><td>{esc(t.get('mode',''))}</td></tr>"
  for t in transitions[-10:][::-1]) + '</table>' if transitions else '<p class="vide">Aucune transition journalisée.</p>'}
</section>

</body></html>"""

with open(out_p, 'w', encoding='utf-8') as f:
    f.write(page)
print(f"dashboard genere : {out_p} ({len(page)} octets)")
PY
