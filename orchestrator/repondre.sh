#!/usr/bin/env bash
# repondre.sh — applique une reponse humaine a une escalade, avant ou apres expiration.
# AVANT : # Usage : repondre.sh [--dry-run] T-NNN <approuver|refuser|modifier|reporter> [message]
# Usage : repondre.sh [--dry-run] T-NNN <approuver|refuser|modifier|reporter|republier> [message]
#         repondre.sh --help
#
# (2026-09-22, O11) « republier » : apres une publication ratee (P9), relance
# publisher.sh SEUL, sur la decision deja prise — ni l'agent ni la revue ne
# repartent. Au premier essai GitHub, aucune reponse ne convenait : « approuver »
# relancait l'agent entier (et son cout). Test Y7.
set -Eeuo pipefail
# shellcheck disable=SC1091
source "$(dirname "$0")/lib.sh"

ETAT_DIR="$ORCH_DIR/etat"
STATE_DIR="${STATE_DIR:-$ORCH_DIR/state}"   # comme scheduler.sh et reconcile.sh (decision de la tache)
JOURNAL_ESC_T="$ETAT_DIR/escalades/escalades.jsonl"
DRY_RUN=0
TASK_ID=""
DECISION_H=""
MESSAGE=""
ORIGINE="${RESPONSE_ORIGINE:-humain}"
REGLE="${RESPONSE_REGLE:-}"

show_help() {
  cat <<'EOF'
Usage:
  repondre.sh [--dry-run] T-NNN <approuver|refuser|modifier|reporter> [message]
  repondre.sh [--dry-run] T-NNN republier
  repondre.sh --help

Applique une decision a une tache PARKED ou BLOCKED et ferme l'escalade ouverte.
« republier » : apres une publication ratee (P9) seulement ; relance la
publication seule, puis PUBLISHED.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --help|-h) show_help; exit 0 ;;
    --dry-run) DRY_RUN=1; shift ;;
    *)
      if [[ -z "$TASK_ID" ]]; then
        TASK_ID="$1"
      elif [[ -z "$DECISION_H" ]]; then
        DECISION_H="$1"
      elif [[ -z "$MESSAGE" ]]; then
        MESSAGE="$1"
      else
        MESSAGE+=" $1"
      fi
      shift ;;
  esac
done

# AVANT : [[ -n "$TASK_ID" && -n "$DECISION_H" ]] || die "usage: repondre.sh [--dry-run] T-NNN <approuver|refuser|modifier|reporter> [message]"
[[ -n "$TASK_ID" && -n "$DECISION_H" ]] || die "usage: repondre.sh [--dry-run] T-NNN <approuver|refuser|modifier|reporter|republier> [message]"
ENVF="$ETAT_DIR/taches/$TASK_ID.env"
[[ -f "$ENVF" ]] || die "tache inconnue : $TASK_ID"

ETAT_ACTUEL="$(sed -n 's/^etat=//p' "$ENVF" | head -1)"
[[ "$ETAT_ACTUEL" == "PARKED" || "$ETAT_ACTUEL" == "BLOCKED" ]] || die "tache $TASK_ID en etat $ETAT_ACTUEL — aucune escalade ouverte"

# Etat cible selon la decision humaine (transition gardee, Phase 5 / P3-a)
case "$DECISION_H" in
  approuver) CIBLE="RUNNING" ;;
  refuser)   CIBLE="FAILED" ;;
  modifier)  CIBLE="READY" ;;
  reporter)  CIBLE="PARKED" ;;
  republier) CIBLE="PUBLISHED" ;;
  *) die "decision inconnue : $DECISION_H" ;;
esac

# (2026-09-22, O11) « republier » n'a de sens qu'apres une publication ratee :
# l'escalade ouverte de la tache doit porter P9, et la decision prise doit etre
# publiable. Sinon refus, rien ne change.
if [[ "$DECISION_H" == "republier" ]]; then
  jq -e --arg t "$TASK_ID" 'select(.tache == $t and .statut == "ouverte") | select(.raisons | test("P9:"))' \
    "$JOURNAL_ESC_T" >/dev/null 2>&1 \
    || die "republier : aucune publication ratee (P9) ouverte pour $TASK_ID"
  DECISION_F="$STATE_DIR/$TASK_ID.decision.json"
  VERDICT_PRIS="$(jq -r '.verdict // empty' "$DECISION_F" 2>/dev/null || true)"
  [[ "$VERDICT_PRIS" =~ ^(AUTO_MERGE|PR_DRAFT|PR_READY)$ ]] \
    || die "republier : decision publiable introuvable pour $TASK_ID (verdict : ${VERDICT_PRIS:-aucun})"
fi

if (( DRY_RUN == 1 )); then
  printf '[DRY-RUN repondre] task=%s decision=%s message=%s etat_avant=%s origine=%s regle=%s\n' \
    "$TASK_ID" "$DECISION_H" "$MESSAGE" "$ETAT_ACTUEL" "$ORIGINE" "$REGLE"
  exit 0
fi

# Publication relancee seule, depuis le worktree de la tache. Nouvel echec :
# la tache reste PARKED et l'escalade ouverte — rien n'est journalise comme resolu.
if [[ "$DECISION_H" == "republier" ]]; then
  "$ROOT/orchestrator/publisher.sh" "$TASK_ID" "$WORKTREE_ROOT/$TASK_ID" >>"$LOG_DIR/pipeline-$TASK_ID.log" 2>&1 \
    || die "republier : publication de nouveau en echec (voir $LOG_DIR/pipeline-$TASK_ID.log) — escalade maintenue"
  log "Publication relancee : $TASK_ID ($VERDICT_PRIS)"
fi

python3 - "$ENVF" "$DECISION_H" "$MESSAGE" <<'PY'
import sys
p, decision, message = sys.argv[1:4]
rows=[]
for line in open(p, encoding='utf-8'):
    if '=' not in line:
        rows.append(line)
        continue
    k, v = line.rstrip('\n').split('=', 1)
    if k == 'etat' or k == 'maj_le':
        rows.append(line)
    elif k == 'blocage':
        rows.append('blocage=none\n' if decision == 'approuver' else line)
    elif k == 'consigne_humaine':
        if decision == 'modifier':
            rows.append('consigne_humaine=' + message + '\n')
        elif decision == 'reporter' and message:
            rows.append('consigne_humaine=' + message + '\n')
        else:
            rows.append(line)
    else:
        rows.append(line)
open(p,'w',encoding='utf-8').writelines(rows)
PY

# Transition gardee : rc 30 si la machine a etats refuse (Phase 5 / P3-a)
transition_etat "$ENVF" "$CIBLE" repondre

# (2026-09-22, Y7) Filtre d'origine cite ici (lignes continuees ci-dessous) :
# AVANT :   '{tache:$t, decision:$d, message:$m, ts:$ts, etat_avant:$av, origine:$origine, regle:($regle|select(length>0))}' \
#   Regle vide (toute reponse HUMAINE) : « select » ne produit rien, et un objet
#   dont une valeur ne produit rien disparait en entier — aucune reponse humaine
#   n'etait journalisee, M07 ne les comptait pas. La cle n'est ajoutee que remplie.
jq -c -n --arg t "$TASK_ID" --arg d "$DECISION_H" --arg m "$MESSAGE" \
  --arg ts "$(date -u +%FT%TZ)" --arg av "$ETAT_ACTUEL" --arg origine "$ORIGINE" --arg regle "$REGLE" \
  '{tache:$t, decision:$d, message:$m, ts:$ts, etat_avant:$av, origine:$origine}
   + (if $regle == "" then {} else {regle:$regle} end)' \
  >>"$ORCH_DIR/journal/reponses.jsonl"

python3 - "$JOURNAL_ESC_T" "$TASK_ID" <<'PY' 2>/dev/null || true
import json, os, sys
p, task = sys.argv[1:3]
if not os.path.exists(p):
    sys.exit(0)
rows = [json.loads(l) for l in open(p, encoding='utf-8') if l.strip()]
for row in reversed(rows):
    if row.get('tache') == task and row.get('statut') == 'ouverte':
        row['statut'] = 'resolue'
        break
with open(p, 'w', encoding='utf-8') as f:
    for row in rows:
        f.write(json.dumps(row, ensure_ascii=False) + '\n')
PY

log "Reponse enregistree : $TASK_ID -> $DECISION_H ($ORIGINE)"
