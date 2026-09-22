#!/usr/bin/env bash
# tableau-de-bord.sh — agrege les journaux chaines en metriques de supervision.
# Usage : tableau-de-bord.sh [--jours 7] [--format tsv|markdown|json] [--dry-run]
#         tableau-de-bord.sh --help
set -Eeuo pipefail
# shellcheck disable=SC1091
source "$(dirname "$0")/lib.sh"

JOURS=7
FORMAT="markdown"
DRY_RUN=0

show_help() {
  cat <<'EOF'
Usage:
  tableau-de-bord.sh [--jours 7] [--format tsv|markdown|json] [--dry-run]
  tableau-de-bord.sh --help

Agrege les journaux de decision, d escalade, de refus et de reponse en
metriques de supervision. Refuse de calculer si la chaine du journal de
decisions est rompue.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --help|-h) show_help; exit 0 ;;
    --dry-run) DRY_RUN=1; shift ;;
    --jours) JOURS="${2:?valeur manquante pour --jours}"; shift 2 ;;
    --format) FORMAT="${2:?valeur manquante pour --format}"; shift 2 ;;
    *) die "argument inattendu : $1" ;;
  esac
done

require jq awk python3
DEC="$ORCH_DIR/journal/decisions.jsonl"
ESC="$ORCH_DIR/etat/escalades/escalades.jsonl"
REF="$ORCH_DIR/journal/refus.jsonl"
REP="$ORCH_DIR/journal/reponses.jsonl"
GR="$ORCH_DIR/etat/graphe.json"
AB_EVAL_LOG="$ORCH_DIR/journal/evals-ab.jsonl"
QUAR="$ORCH_DIR/etat/quarantaine.tsv"
PRUNE_LOG="$ORCH_DIR/journal/prune-docs.jsonl"
QUAR_DOCS="$ORCH_DIR/etat/quarantaine-docs.tsv"
DEP="$(date -u -d "-${JOURS} days" +%FT%TZ)"

if (( DRY_RUN == 1 )); then
  printf '[DRY-RUN dashboard] decisions=%s\n' "$DEC"
  printf '[DRY-RUN dashboard] escalades=%s\n' "$ESC"
  printf '[DRY-RUN dashboard] refus=%s\n' "$REF"
  printf '[DRY-RUN dashboard] reponses=%s\n' "$REP"
  printf '[DRY-RUN dashboard] graphe=%s\n' "$GR"
  printf '[DRY-RUN dashboard] format=%s jours=%s depuis=%s\n' "$FORMAT" "$JOURS" "$DEP"
  exit 0
fi

[[ -f "$DEC" ]] || die "journal des decisions absent : $DEC"
"$ROOT/orchestrator/verify-journal.sh" "$DEC" >/dev/null || {
  echo "ERREUR : chaine du journal rompue — metriques non fiables" >&2
  exit 30
}

TMP="$(mktemp)"
python3 - "$DEC" "$ESC" "$REF" "$REP" "$GR" "$DEP" "$AB_EVAL_LOG" "$QUAR" "$PRUNE_LOG" "$QUAR_DOCS" >"$TMP" <<'PY'
import json, math, os, statistics, sys
from datetime import datetime, timezone

def load_jsonl(path):
    rows = []
    if not os.path.exists(path):
        return rows
    with open(path, encoding='utf-8') as fh:
        for line in fh:
            if line.strip():
                rows.append(json.loads(line))
    return rows

def parse_iso(s):
    if not s:
        return None
    try:
        if s.endswith('Z'):
            return datetime.fromisoformat(s.replace('Z', '+00:00'))
        return datetime.fromisoformat(s)
    except Exception:
        return None

def as_float(v, default=0.0):
    try:
        return float(v)
    except Exception:
        return default


def extract_cost(row):
    value = row.get('cout_usd', 0)
    if isinstance(value, dict):
        value = value.get('total', 0)
    return as_float(value)

def q95(values):
    if not values:
        return 0.0
    vals = sorted(values)
    idx = max(0, math.ceil(0.95 * len(vals)) - 1)
    return float(vals[idx])

def count_blocked_tasks(etat_dir):
    total = 0
    if not os.path.isdir(etat_dir):
        return 0
    for name in os.listdir(etat_dir):
        if not name.endswith('.env'):
            continue
        data = {}
        for line in open(os.path.join(etat_dir, name), encoding='utf-8'):
            if '=' in line:
                k, v = line.rstrip('\n').split('=', 1)
                data[k] = v
        if data.get('etat') == 'BLOCKED':
            total += 1
    return total

def level_order(level):
    return {'L1':1,'L2':2,'L3':3,'L4':4}.get(level, 99)

dec_path, esc_path, ref_path, rep_path, gr_path, dep = sys.argv[1:7]
ab_eval_path = sys.argv[7] if len(sys.argv) > 7 else ''
quar_path = sys.argv[8] if len(sys.argv) > 8 else ''
prune_path = sys.argv[9] if len(sys.argv) > 9 else ''
quar_docs_path = sys.argv[10] if len(sys.argv) > 10 else ''
depuis = parse_iso(dep)
decisions = [r for r in load_jsonl(dec_path) if parse_iso(r.get('ts_utc') or r.get('horodatage') or '') and parse_iso(r.get('ts_utc') or r.get('horodatage')) >= depuis]
escalades = [r for r in load_jsonl(esc_path) if not r.get('ouvert_le') or (parse_iso(r.get('ouvert_le')) and parse_iso(r.get('ouvert_le')) >= depuis)]
refus = [r for r in load_jsonl(ref_path) if not r.get('ts') or (parse_iso(r.get('ts')) and parse_iso(r.get('ts')) >= depuis)]
reponses = [r for r in load_jsonl(rep_path) if not r.get('ts') or (parse_iso(r.get('ts')) and parse_iso(r.get('ts')) >= depuis)]
graphe = {}
if os.path.exists(gr_path):
    graphe = json.load(open(gr_path, encoding='utf-8'))

# M01 / M04
verdicts = {}
for row in decisions:
    verdict = row.get('verdict') or row.get('decision') or '?'
    verdicts[verdict] = verdicts.get(verdict, 0) + 1
total = sum(verdicts.values())
auto = verdicts.get('AUTO_MERGE', 0)
park = verdicts.get('PARK', 0)
pr_draft = verdicts.get('PR_DRAFT', 0)
pr_ready = verdicts.get('PR_READY', 0)

# M02 / M03 / M10 / M11
couts_done = [extract_cost(row) for row in decisions if row.get('etat') == 'DONE']
if not couts_done:
    couts_done = [extract_cost(row) for row in decisions if (row.get('verdict') or row.get('decision')) in ('AUTO_MERGE', 'PR_DRAFT', 'PR_READY', 'PARK')]
conf = []
for row in decisions:
    revue = row.get('axe_d_revue') or row.get('revue') or {}
    if 'confiance' in revue:
        conf.append(as_float(revue.get('confiance')))
red = sum(1 for row in decisions if row.get('etat') == 'RED' or row.get('axe_a_gates') == 'red')
derive = sum(
    1
    for row in decisions
    if (
        ('P5:derive-apres-revue' in row.get('raisons', []))
        if isinstance(row.get('raisons', []), list)
        else row.get('raisons') == 'P5:derive-apres-revue'
    )
)

# M05
m05 = {}
for row in decisions:
    if row.get('verdict') != 'PARK':
        continue
    for reason in row.get('raisons', []):
        m05[reason] = m05.get(reason, 0) + 1
m05_top = sorted(m05.items(), key=lambda x: (-x[1], x[0]))[:3]

# M06 / M07 / M08 / M09
m06 = {}
opened_by_task = {}
for row in escalades:
    lvl = row.get('niveau', '?')
    m06[lvl] = m06.get(lvl, 0) + 1
    opened_by_task[row.get('tache')] = row

lat_by_level = {'L1': [], 'L2': [], 'L3': [], 'L4': []}
for rep in reponses:
    task = rep.get('tache')
    esc = opened_by_task.get(task)
    if not esc:
        continue
    t1 = parse_iso(esc.get('ouvert_le'))
    t2 = parse_iso(rep.get('ts') or rep.get('horodatage'))
    if not t1 or not t2:
        continue
    hours = max(0.0, (t2 - t1).total_seconds() / 3600.0)
    lat_by_level.setdefault(esc.get('niveau','?'), []).append(hours)

rel_prev = 0
rel_env = 0
for row in escalades:
    prev = row.get('relances_prevues', [])
    if isinstance(prev, list):
        rel_prev += len(prev)
    elif isinstance(prev, (int, float)):
        rel_prev += int(prev)
    rel_env += int(row.get('relances_envoyees', 0) or 0)

# M12
noeuds = graphe.get('noeuds', {}) if isinstance(graphe, dict) else {}
elig = len(graphe.get('eligibles', [])) if isinstance(graphe, dict) else 0
pending = sum(1 for node in noeuds.values() if node.get('etat') == 'PENDING') if isinstance(noeuds, dict) else 0
pending = pending or 1

# M13
etat_taches = os.path.join(os.path.dirname(gr_path), 'taches') if gr_path else ''

# M14 — contribution nette par règle (Phase 5 / P2-a)
# Agrège le journal A/B : dernière contribution par règle + compteur de runs
# à delta<0 consécutifs + liste des règles en quarantaine.
m14_regles = {}
if ab_eval_path and os.path.exists(ab_eval_path):
    ab_rows = load_jsonl(ab_eval_path)
    for row in ab_rows:
        regle = row.get('regle')
        if not regle:
            continue
        entree = m14_regles.setdefault(regle, {'dernier_delta': 0.0, 'derniere_contribution': 'NEUTRE', 'runs_delta_neg': 0, 'total_runs': 0})
        entree['dernier_delta'] = round(as_float(row.get('delta')), 3)
        entree['derniere_contribution'] = row.get('contribution', 'NEUTRE')
        entree['total_runs'] += 1
    # recalcule les runs delta<0 consécutifs (en fin de série)
    from collections import defaultdict
    par_regle = defaultdict(list)
    for row in ab_rows:
        par_regle[row.get('regle')].append(as_float(row.get('delta')))
    for regle, deltas in par_regle.items():
        neg = 0
        for d in reversed(deltas):
            if d < 0:
                neg += 1
            else:
                break
        m14_regles[regle]['runs_delta_neg'] = neg

m14_quarantaine = []
if quar_path and os.path.exists(quar_path):
    for line in open(quar_path, encoding='utf-8'):
        parts = line.rstrip('\n').split('\t')
        if parts and parts[0]:
            m14_quarantaine.append(parts[0])

m14_negatives = sum(1 for r in m14_regles.values() if r['derniere_contribution'] == 'NEGATIVE')
m14_positives = sum(1 for r in m14_regles.values() if r['derniere_contribution'] == 'POSITIVE')

# M16 — prune documentaire mesurée (Phase 5 / P3-b)
m16_docs = {}
if prune_path and os.path.exists(prune_path):
    for row in load_jsonl(prune_path):
        d = row.get('doc')
        if not d:
            continue
        m16_docs[d] = {'dernier_delta': round(as_float(row.get('delta')), 3),
                       'derniere_contribution': row.get('contribution', 'NEUTRE')}
m16_pos = sum(1 for v in m16_docs.values() if v['derniere_contribution'] == 'POSITIVE')
m16_neu = sum(1 for v in m16_docs.values() if v['derniere_contribution'] == 'NEUTRE')
m16_neg = sum(1 for v in m16_docs.values() if v['derniere_contribution'] == 'NEGATIVE')
m16_quar = []
if quar_docs_path and os.path.exists(quar_docs_path):
    for line in open(quar_docs_path, encoding='utf-8'):
        parts = line.rstrip('\n').split('\t')
        if parts and parts[0]:
            m16_quar.append(parts[0])

out = {
    'M01': round(auto / total, 3) if total else 0.0,
    'M02': round(sum(couts_done) / len(couts_done), 4) if couts_done else 0.0,
    'M03_moyenne': round(sum(conf) / len(conf), 3) if conf else 0.0,
    'M03_ecart_type': round(statistics.pstdev(conf), 3) if len(conf) > 1 else 0.0,
    'M04_distribution': {
        'AUTO_MERGE': auto,
        'PR_DRAFT': pr_draft,
        'PR_READY': pr_ready,
        'PARK': park,
        'TOTAL': total,
    },
    'M05_top': m05_top,
    'M06_par_niveau': {k: m06.get(k, 0) for k in ['L1','L2','L3','L4']},
    'M07_latence': {
        lvl: {
            'mediane_h': round(statistics.median(vals), 3) if vals else 0.0,
            'p95_h': round(q95(vals), 3) if vals else 0.0,
        } for lvl, vals in lat_by_level.items()
    },
    'M08': round(len(refus) / len(escalades), 3) if escalades else 0.0,
    'M09': round(rel_env / rel_prev, 3) if rel_prev else 1.0,
    'M10': round(derive / total, 3) if total else 0.0,
    'M11': round(red / total, 3) if total else 0.0,
    'M12': round(elig / pending, 3) if noeuds else 0.0,
    'M13': count_blocked_tasks(etat_taches),
    'M14': {
        'regles_evaluees': len(m14_regles),
        'contribution_positive': m14_positives,
        'contribution_negative': m14_negatives,
        'en_quarantaine': m14_quarantaine,
        'detail': {k: v for k, v in sorted(m14_regles.items())},
    },
    'M16': {
        'docs_evalues': len(m16_docs),
        'contribution_positive': m16_pos,
        'contribution_neutre': m16_neu,
        'contribution_negative': m16_neg,
        'en_quarantaine': m16_quar,
        'detail': {k: v for k, v in sorted(m16_docs.items())},
    },
    'escalades_ouvertes': sum(1 for row in escalades if row.get('statut') == 'ouverte'),
    'periode_jours': int(float(sys.argv[6].split('T')[0][:0] or 0)) if False else 0,
}
print(json.dumps(out, ensure_ascii=False))
PY

readarray -t METRICS < <(jq -r '
  [
    .M01,
    .M02,
    .M03_moyenne,
    .M03_ecart_type,
    .M08,
    .M09,
    .M10,
    .M11,
    .M12,
    .M13,
    .M14.contribution_positive,
    .M14.contribution_negative,
    (.M14.en_quarantaine | join(",")),
    .M16.docs_evalues,
    .M16.contribution_neutre,
    .M16.contribution_negative,
    (.M16.en_quarantaine | join(",")),
    .escalades_ouvertes,
    (.M05_top | map("\(.[0]):\(.[1])") | join(", ")),
    (.M06_par_niveau.L1|tostring),
    (.M06_par_niveau.L2|tostring),
    (.M06_par_niveau.L3|tostring),
    (.M06_par_niveau.L4|tostring)
  ] | .[]' "$TMP")

M01="${METRICS[0]}"; M02="${METRICS[1]}"; M03M="${METRICS[2]}"; M03E="${METRICS[3]}"
M08="${METRICS[4]}"; M09="${METRICS[5]}"; M10="${METRICS[6]}"; M11="${METRICS[7]}"
M12="${METRICS[8]}"; M13="${METRICS[9]}"
M14_POS="${METRICS[10]}"; M14_NEG="${METRICS[11]}"; M14_QUAR="${METRICS[12]:-}"
M16_EVAL="${METRICS[13]:-0}"; M16_NEU="${METRICS[14]:-0}"; M16_NEG="${METRICS[15]:-0}"
M16_QUAR="${METRICS[16]:-}"

# (2026-09-20) M17 — sante du canal de notification.
# escalade.sh journalise desormais chaque tentative dans notifications.jsonl.
# Sans cette metrique, un canal muet resterait indistinguable d'un canal qui a
# prevenu quelqu'un : il faudrait lire le journal pour s'en apercevoir.
# « muettes » compte les escalades dont AUCUN canal n'a abouti : c'est le cas
# grave, d'ou le ROUGE des qu'il est non nul.
NOTIF_JOURNAL="$ORCH_DIR/journal/notifications.jsonl"
compter_notifs() {
  local statut="$1" n=0
  if [[ -f "$NOTIF_JOURNAL" ]]; then
    n="$(jq -r --arg d "$DEP" --arg s "$statut" \
          'select(.ts >= $d and .statut == $s) | 1' "$NOTIF_JOURNAL" 2>/dev/null \
          | wc -l | tr -d ' ')" || n=0
  fi
  printf '%s' "${n:-0}"
}
M17_ECHECS="$(compter_notifs echec)"
M17_MUETTES="$(compter_notifs aucun_canal_abouti)"
A17="$(awk -v e="$M17_ECHECS" -v m="$M17_MUETTES" \
  'BEGIN{ print (m>0) ? "ROUGE" : ((e>0) ? "AMBRE" : "VERT") }')"
OUVERTES="${METRICS[17]}"; M05="${METRICS[18]:--}"
L1N="${METRICS[19]}"; L2N="${METRICS[20]}"; L3N="${METRICS[21]}"; L4N="${METRICS[22]}"
F_M01="$(awk -v v="$M01" 'BEGIN{printf "%.3f", v}')"
F_M02="$(awk -v v="$M02" 'BEGIN{printf "%.4f", v}')"
F_M09="$(awk -v v="$M09" 'BEGIN{printf "%.3f", v}')"

alerte_intervalle() {
  local v="$1" min="$2" max="$3"
  awk -v v="$v" -v mn="$min" -v mx="$max" 'BEGIN {
    if (v < mn) print "ROUGE";
    else if (v < mn*1.15) print "AMBRE";
    else if (v > mx) print "ROUGE";
    else if (v > mx/1.15) print "AMBRE";
    else print "VERT";
  }'
}
A01="$(alerte_intervalle "$M01" 0.40 1.00)"
A02="$(alerte_intervalle "$M02" 0.00 0.80)"
A09="$(awk -v v="$M09" 'BEGIN{ if (v < 0.90) print "ROUGE"; else if (v < 1.0) print "AMBRE"; else print "VERT" }')"
A13="$(awk -v v="$M13" 'BEGIN{ if (v >= 5) print "ROUGE"; else if (v >= 3) print "AMBRE"; else print "VERT" }')"

case "$FORMAT" in
  tsv)
    printf 'metrique\tindicateur\tvaleur\talerte\n'
    printf 'M01\ttaux_auto_merge\t%s\t%s\n' "$F_M01" "$A01"
    printf 'M02\tcout_moyen_usd\t%s\t%s\n' "$F_M02" "$A02"
    printf 'M03\tconfiance_moyenne\t%s\t-\n' "$M03M"
    printf 'M03\tconfiance_ecart_type\t%s\t-\n' "$M03E"
    printf 'M05\ttop_park\t%s\t-\n' "$M05"
    printf 'M06\tescalades_L1\t%s\t-\n' "$L1N"
    printf 'M06\tescalades_L2\t%s\t-\n' "$L2N"
    printf 'M06\tescalades_L3\t%s\t-\n' "$L3N"
    printf 'M06\tescalades_L4\t%s\t-\n' "$L4N"
    printf 'M08\ttaux_expiration\t%s\t-\n' "$M08"
    printf 'M09\trelance_coverage\t%s\t%s\n' "$F_M09" "$A09"
    printf 'M10\tderive_post_revue\t%s\t-\n' "$M10"
    printf 'M11\ttaux_red\t%s\t-\n' "$M11"
    printf 'M12\tserialisation_graphe\t%s\t-\n' "$M12"
    printf 'M13\ttaches_blocked\t%s\t%s\n' "$M13" "$A13"
    printf 'M14\tregles_contrib_positive\t%s\t-\n' "$M14_POS"
    printf 'M14\tregles_contrib_negative\t%s\t%s\n' "$M14_NEG" "$(awk -v v="$M14_NEG" 'BEGIN{print (v>0)?"AMBRE":"VERT"}')"
    printf 'M14\tregles_en_quarantaine\t%s\t%s\n' "${M14_QUAR:--}" "$([[ -n "${M14_QUAR:-}" && "${M14_QUAR:-}" != "-" ]] && printf 'ROUGE' || printf 'VERT')"
    printf 'M16\tdocs_evalues\t%s\t-\n' "$M16_EVAL"
    printf 'M16\tdocs_contrib_neutre\t%s\t-\n' "$M16_NEU"
    printf 'M16\tdocs_contrib_negative\t%s\t%s\n' "$M16_NEG" "$(awk -v v="$M16_NEG" 'BEGIN{print (v>0)?"AMBRE":"VERT"}')"
    printf 'M16\tdocs_en_quarantaine\t%s\t%s\n' "${M16_QUAR:--}" "$([[ -n "${M16_QUAR:-}" && "${M16_QUAR:-}" != "-" ]] && printf 'ROUGE' || printf 'VERT')"
    printf 'M17\tnotifications_echouees\t%s\t%s\n' "$M17_ECHECS" "$(awk -v v="$M17_ECHECS" 'BEGIN{print (v>0)?"AMBRE":"VERT"}')"
    printf 'M17\tescalades_muettes\t%s\t%s\n' "$M17_MUETTES" "$A17"
    printf 'META\tescalades_ouvertes\t%s\t-\n' "$OUVERTES"
    ;;
  json)
    jq -n \
      --argjson M01 "$M01" \
      --argjson M02 "$M02" \
      --argjson M03_moyenne "$M03M" \
      --argjson M03_ecart_type "$M03E" \
      --argjson M08 "$M08" \
      --argjson M09 "$M09" \
      --argjson M10 "$M10" \
      --argjson M11 "$M11" \
      --argjson M12 "$M12" \
      --argjson M13 "$M13" \
      --argjson M14_pos "${M14_POS:-0}" \
      --argjson M14_neg "${M14_NEG:-0}" \
      --arg M14_quar "${M14_QUAR:-}" \
      --argjson M16_eval "${M16_EVAL:-0}" \
      --argjson M16_neu "${M16_NEU:-0}" \
      --argjson M16_neg "${M16_NEG:-0}" \
      --arg M16_quar "${M16_QUAR:-}" \
      --arg a01 "$A01" --arg a02 "$A02" --arg a09 "$A09" --arg a13 "$A13" \
      --argjson M17_echecs "${M17_ECHECS:-0}" \
      --argjson M17_muettes "${M17_MUETTES:-0}" \
      --arg a17 "$A17" \
      '{M01:$M01,M02:$M02,M03_moyenne:$M03_moyenne,M03_ecart_type:$M03_ecart_type,M08:$M08,M09:$M09,M10:$M10,M11:$M11,M12:$M12,M13:$M13,M14:{contribution_positive:$M14_pos,contribution_negative:$M14_neg,en_quarantaine:($M14_quar|if .=="" then [] else split(",") end)},M16:{docs_evalues:$M16_eval,contribution_neutre:$M16_neu,contribution_negative:$M16_neg,en_quarantaine:($M16_quar|if .=="" then [] else split(",") end)},M17:{notifications_echouees:$M17_echecs,escalades_muettes:$M17_muettes},alertes:{M17:$a17,M01:$a01,M02:$a02,M09:$a09,M13:$a13}}'
    ;;
  markdown)
    echo "# Tableau de bord — ${JOURS} derniers jours"
    echo
    echo "| Metrique | Valeur | Alerte |"
    echo "|---|---|---|"
    echo "| M01 taux d auto-merge | ${M01} | ${A01} |"
    echo "| M02 cout par tache terminee (USD) | ${M02} | ${A02} |"
    echo "| M03 confiance moyenne (ecart-type ${M03E}) | ${M03M} | - |"
    echo "| M05 regles les plus bloquantes | ${M05:--} | - |"
    echo "| M08 taux d expiration | ${M08} | - |"
    echo "| M09 sante du canal | ${M09} | ${A09} |"
    echo "| M10 derive post-revue | ${M10} | - |"
    echo "| M11 taux de RED | ${M11} | - |"
    echo "| M12 serialisation du graphe | ${M12} | - |"
    echo "| M13 quarantaines ouvertes | ${M13} | ${A13} |"
    echo "| M14 regles a contribution positive | ${M14_POS:-0} | - |"
    echo "| M14 regles a contribution negative | ${M14_NEG:-0} | $(awk -v v="${M14_NEG:-0}" 'BEGIN{print (v>0)?"AMBRE":"VERT"}') |"
    echo "| M14 regles en quarantaine | ${M14_QUAR:--} | $([[ -n "${M14_QUAR:-}" && "${M14_QUAR:-}" != "-" ]] && printf 'ROUGE' || printf 'VERT') |"
    echo "| M16 documents evalues | ${M16_EVAL:-0} | - |"
    echo "| M16 docs a contribution neutre | ${M16_NEU:-0} | - |"
    echo "| M16 docs a contribution negative | ${M16_NEG:-0} | $(awk -v v="${M16_NEG:-0}" 'BEGIN{print (v>0)?"AMBRE":"VERT"}') |"
    echo "| M16 docs en quarantaine | ${M16_QUAR:--} | $([[ -n "${M16_QUAR:-}" && "${M16_QUAR:-}" != "-" ]] && printf 'ROUGE' || printf 'VERT') |"
    echo "| M17 notifications en echec | ${M17_ECHECS} | $(awk -v v="${M17_ECHECS}" 'BEGIN{print (v>0)?"AMBRE":"VERT"}') |"
    echo "| M17 escalades n ayant prevenu personne | ${M17_MUETTES} | ${A17} |"
    echo
    echo "## Escalades par niveau"
    echo
    echo "| Niveau | Ouvertes sur la periode |"
    echo "|---|---:|"
    echo "| L1 | ${L1N} |"
    echo "| L2 | ${L2N} |"
    echo "| L3 | ${L3N} |"
    echo "| L4 | ${L4N} |"
    ;;
  *)
    die "format inconnu : $FORMAT"
    ;;
esac

rm -f "$TMP"
